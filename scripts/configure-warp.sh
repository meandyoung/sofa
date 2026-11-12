#!/usr/bin/env bash
# 可选 WARP：注册失败不影响原有节点。
set -Eeuo pipefail
B=/etc/sing-box
D=$B/warp
C=$B/config.json
mkdir -p "$D"; chmod 700 "$D"
fail(){ echo "WARP: 失败 - $*" >&2; echo "failed: $*" > "$D/status"; exit 1; }
[[ $EUID -eq 0 && -s $C ]] || fail '请先部署 sing-box 节点'
[[ -c /dev/net/tun ]] || fail 'TUN 不可用'
mode=${1:-install}
case "$mode" in install|register|add-domain|remove-domain|add-rule-set|remove-rule-set|status) ;; *) fail '未知命令' ;; esac
if [[ $mode == status ]]; then cat "$D/status" 2>/dev/null || echo not-configured; exit 0; fi
tmp=$(mktemp -d "$D/.tmp.XXXX")
trap 'rm -rf "$tmp"' EXIT
if [[ ! -s $D/account.json || $mode == register ]]; then
 curl -fsSL --max-time 20 https://gitlab.com/fscarmen/warp/-/raw/main/api.sh -o "$tmp/api.sh" || fail '注册脚本下载失败'
 timeout 40 bash "$tmp/api.sh" --register > "$tmp/registration.json" || fail 'WARP 注册失败'
 python3 - "$tmp/registration.json" "$tmp/account.new" <<'PY'
import json,sys
try:
 d=json.load(open(sys.argv[1]))
 assert d.get('id') and d.get('v6') and d.get('private_key') and len(d.get('reserved',[]))==3
 json.dump({'v6':d['v6'],'private_key':d['private_key'],'reserved':d['reserved']},open(sys.argv[2],'w'))
except Exception as e:sys.exit('注册响应无效: '+str(e))
PY
 chmod 600 "$tmp/account.new"
fi
WARP_RULE_URL="${3:-}" python3 - "$C" "$D" "$tmp" "$mode" "${2:-}" <<'PY'
import json,sys,re,os
c,d,t,mode,domain=sys.argv[1:]
account=json.load(open(t+'/account.new' if os.path.exists(t+'/account.new') else d+'/account.json'))
try:rules=json.load(open(d+'/rules.json'))
except FileNotFoundError:rules={'domains':[],'sets':{}}
rules.setdefault('sets',{})
if mode in ('add-domain','remove-domain'):
 domain=domain.lower().strip().lstrip('.')
 if not re.fullmatch(r'[a-z0-9-]+(?:\.[a-z0-9-]+)+',domain):sys.exit('无效域名')
 if mode=='add-domain' and domain not in rules['domains']:rules['domains'].append(domain)
 if mode=='remove-domain':rules['domains']=[x for x in rules['domains'] if x!=domain]
if mode in ('add-rule-set','remove-rule-set'):
 if not re.fullmatch(r'[A-Za-z0-9_-]+',domain):sys.exit('规则集名称无效')
 if mode=='add-rule-set':
  url=os.environ.get('WARP_RULE_URL','')
  if not url.startswith('https://') or not url.endswith('.srs'):sys.exit('需要 HTTPS .srs 规则集 URL')
  rules['sets'][domain]=url
 else:rules['sets'].pop(domain,None)
json.dump(rules,open(t+'/rules.json','w'),indent=2)
ep={'type':'wireguard','tag':'warp-ep','mtu':1400,'address':['172.16.0.2/32',account['v6'].split('/')[0]+'/128'],'private_key':account['private_key'],'peers':[{'address':'engage.cloudflareclient.com','port':2408,'public_key':'bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=','allowed_ips':['0.0.0.0/0','::/0'],'reserved':account['reserved']}]}
cfg=json.load(open(c));cfg['endpoints']=[x for x in cfg.get('endpoints',[]) if x.get('tag')!='warp-ep']+[ep]
route=cfg.setdefault('route',{})
route['rules']=[r for r in route.get('rules',[]) if r.get('outbound')!='warp-ep']
if rules['domains']:route['rules'].insert(0,{'domain_suffix':rules['domains'],'outbound':'warp-ep'})
route['rule_set']=[r for r in route.get('rule_set',[]) if r.get('tag') not in rules['sets']]
for name,url in rules['sets'].items():
 route['rule_set'].append({'tag':name,'type':'remote','format':'binary','url':url})
if rules['sets']:route['rules'].insert(0,{'rule_set':list(rules['sets']),'outbound':'warp-ep'})
json.dump(cfg,open(t+'/candidate.json','w'),indent=2)
json.dump({'inbounds':[{'type':'socks','listen':'127.0.0.1','listen_port':19087}],'endpoints':[ep],'route':{'final':'warp-ep'}},open(t+'/probe.json','w'))
PY
sing-box check -c "$tmp/probe.json" >/dev/null || fail 'Endpoint 配置校验失败'
sing-box run -c "$tmp/probe.json" > "$tmp/probe.log" 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT
ok=false
for i in 1 2 3 4 5; do
 if curl -fsS --socks5-hostname 127.0.0.1:19087 --connect-timeout 3 --max-time 6 https://www.cloudflare.com/cdn-cgi/trace > "$tmp/trace" 2>/dev/null && grep -Eq '^warp=(on|plus)' "$tmp/trace"; then ok=true; break; fi
 sleep 1
done
[[ $ok == true ]] || fail 'WARP 连接检测失败'
kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true
trap 'rm -rf "$tmp"' EXIT
response=$(curl -4 -sSL --connect-timeout 3 --max-time 8 https://api.openai.com/compliance/cookie_requirements || true)
openai=direct
if grep -qi unsupported_country <<< "$response"; then
 openai=warp-ep
 python3 - "$tmp/candidate.json" <<'PY'
import json,sys
p=sys.argv[1];c=json.load(open(p));c['route']['rules'].insert(0,{'domain_suffix':['openai.com','chatgpt.com'],'outbound':'warp-ep'});json.dump(c,open(p,'w'),indent=2)
PY
fi
sing-box check -c "$tmp/candidate.json" >/dev/null || fail '合并配置校验失败'
cp -p "$C" "$tmp/backup"
install -m 600 "$tmp/candidate.json" "$C.new"; mv "$C.new" "$C"
if ! systemctl restart sing-box || ! systemctl is-active --quiet sing-box; then
 cp -p "$tmp/backup" "$C"; systemctl restart sing-box || true
 fail '应用失败，已回滚原配置'
fi
[[ ! -s "$tmp/account.new" ]] || install -m 600 "$tmp/account.new" "$D/account.json"
install -m 600 "$tmp/rules.json" "$D/rules.json"
printf 'registration=success\nendpoint=ok\nconnection=ok\nopenai=%s\n' "$openai" > "$D/status"
echo "WARP: 成功，连接正常，OpenAI=$openai"
