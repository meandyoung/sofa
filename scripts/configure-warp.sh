#!/usr/bin/env bash
# 可选 WARP 模块：不运行或失败均不影响原有五节点。
set -Eeuo pipefail
B=/etc/sing-box; D=$B/warp; C=$B/config.json
mkdir -p "$D"; chmod 700 "$D"
mode=${1:-install}
fail(){ printf '[WARP] 失败：%s\n' "$*" >&2; printf 'failed: %s\n' "$*" > "$D/status"; exit 1; }
[[ $EUID -eq 0 && -s $C ]] || fail '需要 root 且 sing-box 已安装'
if [[ $mode == status ]]; then cat "$D/status" 2>/dev/null || echo not-configured; exit 0; fi
[[ -c /dev/net/tun ]] || fail 'TUN 不可用'
case "$mode" in install|register) ;; *) fail '用法：install | register | status（规则更新请使用 sync-config.sh）' ;; esac
tmp=$(mktemp -d "$D/.work.XXXXXX")
pid=''
cleanup(){ if [[ -n $pid ]]; then kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; fi; rm -f "$D/account.json.pending"; rm -rf "$tmp"; }
trap cleanup EXIT
rm -f "$D/account.json.pending"
if [[ ! -s $D/account.json || $mode == register ]]; then
  curl -fsSL --retry 2 --max-time 20 https://gitlab.com/fscarmen/warp/-/raw/main/api.sh -o "$tmp/api.sh" || fail '注册脚本下载失败'
  timeout 45 bash "$tmp/api.sh" --register > "$tmp/registration.json" || fail 'WARP 注册接口失败'
  python3 - "$tmp/registration.json" "$D/account.json" <<'PY'
import base64,json,sys,os,ipaddress
try:
 d=json.load(open(sys.argv[1]))
 # fscarmen api.sh --register：地址在 config.interface.addresses，
 # reserved 来自 config.client_id（api.sh 已将其解码后写入 config.reserved）。
 c=d['config']
 v=c['interface']['addresses']['v6']
 k=d['private_key']
 r=c.get('reserved')
 if r is None:
  r=list(base64.b64decode(c['client_id'],validate=True))
 assert isinstance(v,str) and ipaddress.ip_address(v.split('/')[0]).version==6
 assert isinstance(k,str) and len(base64.b64decode(k,validate=True))==32
 assert isinstance(r,list) and len(r)==3 and all(type(x)==int and 0<=x<=255 for x in r)
 assert d.get('warp_enabled') is True, 'WARP 未启用'
 with open(sys.argv[2]+'.pending','w') as f:json.dump({'v6':v,'private_key':k,'reserved':r},f)
 os.chmod(sys.argv[2]+'.pending',0o600)
except Exception as e:sys.exit('注册响应无效: '+str(e))
PY
  [[ -s $D/account.json.pending ]] || fail '注册数据无效'
fi
curl -fsSL --retry 2 --max-time 20 https://raw.githubusercontent.com/meandyoung/sofa/main/config/warp-rules.json -o "$tmp/rules.json" || fail '初始规则下载失败'
# 从独立规则文件生成配置，不修改节点入站及默认 direct 出站。
python3 - "$C" "$D" "$tmp" <<'PY'
import json,sys,re,os
c,d,t=sys.argv[1:]
rules=json.load(open(t+'/rules.json'))
assert set(rules)=={'auto','warp','direct','rule_sets'}
for k in ('auto','warp','direct'):
 assert isinstance(rules[k],list) and all(isinstance(x,str) and re.fullmatch(r'[a-z0-9-]+(?:\.[a-z0-9-]+)+',x) for x in rules[k])
assert isinstance(rules['rule_sets'],dict)
assert all(re.fullmatch(r'[A-Za-z0-9_-]+',k) and isinstance(v,str) and v.startswith('https://') and v.endswith('.srs') for k,v in rules['rule_sets'].items())
assert len(set(rules['auto']+rules['warp']+rules['direct']))==sum(len(rules[k]) for k in ('auto','warp','direct'))
a=json.load(open(d+'/account.json.pending' if os.path.exists(d+'/account.json.pending') else d+'/account.json'))
ep={'type':'wireguard','tag':'warp-ep','mtu':1400,'address':['172.16.0.2/32',a['v6'].split('/')[0]+'/128'],'private_key':a['private_key'],'peers':[{'address':'engage.cloudflareclient.com','port':2408,'public_key':'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=','allowed_ips':['0.0.0.0/0','::/0'],'reserved':a['reserved']}]}
cfg=json.load(open(c));cfg['endpoints']=[x for x in cfg.get('endpoints',[]) if x.get('tag')!='warp-ep']+[ep]
route=cfg.setdefault('route',{})
# 以最近一次成功应用的 rules.json 为依据，整体替换本模块旧规则。
# 仅删除与本模块上次生成内容完全相同的规则，不按 outbound 泛删用户规则。
state=d+'/openai-outbound'
choice=open(state).read().strip() if os.path.isfile(state) else 'direct'
if choice not in ('direct','warp-ep'):choice='direct'
previous_path=d+'/rules.json'
previous=json.load(open(previous_path)) if os.path.isfile(previous_path) else None
old=[]
old_tags=set()
if previous is not None:
 for key,outbound in (('direct','direct'),('warp','warp-ep'),('auto',choice)):
  if previous.get(key):old.append({'domain_suffix':previous[key],'action':'route','outbound':outbound})
 for name in previous.get('rule_sets',{}):
  tag='sofa-warp-'+name
  old_tags.add(tag)
  old.append({'rule_set':[tag],'action':'route','outbound':'warp-ep'})
else:
 # 兼容首次安装及旧版本默认规则；不删除其他未知规则。
 old.append({'domain_suffix':['openai.com','chatgpt.com'],'action':'route','outbound':'direct'})
 old.append({'domain_suffix':['openai.com','chatgpt.com'],'action':'route','outbound':'warp-ep'})
# 删除每一条旧规则至多一次，避免误删用户恰好相同的重复规则。
existing=list(route.get('rules',[]))
for managed in old:
 for i,item in enumerate(existing):
  if item==managed:
   existing.pop(i)
   break
route['rules']=existing
route['rule_set']=[item for item in route.get('rule_set',[]) if item.get('tag') not in old_tags]
new=[]
if rules['direct']:new.append({'domain_suffix':rules['direct'],'action':'route','outbound':'direct'})
if rules['warp']:new.append({'domain_suffix':rules['warp'],'action':'route','outbound':'warp-ep'})
if rules['auto']:
 # auto 仅安装时检测一次；后续规则同步时复用既有判断结果。
 choice='direct'
 state=d+'/openai-outbound'
 if os.path.exists(state):choice=open(state).read().strip()
 if choice not in ('direct','warp-ep'):choice='direct'
 new.append({'domain_suffix':rules['auto'],'action':'route','outbound':choice})
for name,url in rules['rule_sets'].items():
 tag='sofa-warp-'+name
 route['rule_set'].append({'tag':tag,'type':'remote','format':'binary','url':url})
 new.append({'rule_set':[tag],'action':'route','outbound':'warp-ep'})
route['rules']=new+route['rules']
with open(t+'/candidate.json','w') as f:json.dump(cfg,f,indent=2)
with open(t+'/probe.json','w') as f:json.dump({'inbounds':[{'type':'socks','listen':'127.0.0.1','listen_port':19087}],'endpoints':[ep],'route':{'final':'warp-ep'}},f)
PY
sing-box check -c "$tmp/probe.json" >/dev/null || fail 'Endpoint 校验失败'
sing-box run -c "$tmp/probe.json" > "$tmp/probe.log" 2>&1 &
pid=$!
ok=false
for i in 1 2 3 4 5; do
 if curl -fsS --socks5-hostname 127.0.0.1:19087 --connect-timeout 3 --max-time 6 https://www.cloudflare.com/cdn-cgi/trace > "$tmp/trace" 2>/dev/null && grep -Eq '^warp=(on|plus)' "$tmp/trace"; then ok=true; break; fi
 sleep 1
done
[[ $ok == true ]] || fail 'WARP 连通性检查失败'
kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; pid=''
if true; then
 response=$(curl -4 -sSL --connect-timeout 3 --max-time 8 https://api.openai.com/compliance/cookie_requirements || true)
 if grep -qi unsupported_country <<< "$response"; then echo warp-ep > "$tmp/openai-outbound"; else echo direct > "$tmp/openai-outbound"; fi
 # 在生成最终配置前写入临时检测结果并更新 auto 规则。
 python3 - "$tmp/candidate.json" "$tmp/openai-outbound" "$tmp/rules.json" <<'PY'
import json,sys
p,choice,r=sys.argv[1:];c=json.load(open(p));d=json.load(open(r))
for rule in c.get('route',{}).get('rules',[]):
 if rule.get('domain_suffix')==d['auto']:rule['outbound']=open(choice).read().strip()
json.dump(c,open(p,'w'),indent=2)
PY
fi
sing-box check -c "$tmp/candidate.json" >/dev/null || fail '新配置校验失败'
cp -p "$C" "$tmp/original.json"
install -m 600 "$tmp/candidate.json" "$C.new"; mv -f "$C.new" "$C"
if ! systemctl restart sing-box || ! systemctl is-active --quiet sing-box; then
 cp -p "$tmp/original.json" "$C"; systemctl restart sing-box || true
 fail '应用失败，已回滚 sing-box 配置'
fi
[[ ! -s $D/account.json.pending ]] || mv -f "$D/account.json.pending" "$D/account.json"
[[ ! -s $D/rules.json ]] || cp -p "$D/rules.json" "$D/rules.json.bak"
install -m 600 "$tmp/rules.json" "$D/rules.json"
[[ ! -s $tmp/openai-outbound ]] || install -m 600 "$tmp/openai-outbound" "$D/openai-outbound"
printf 'registration=success\nendpoint=configured\nconnection=ok\n' > "$D/status"
echo '[WARP] 注册/复用成功，Endpoint 已配置，连接正常'
