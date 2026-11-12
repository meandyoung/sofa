#!/usr/bin/env bash
# ============================================================
# GitHub Config Sync — 手动配置更新入口（不调用安装脚本）
# ============================================================
set -Eeuo pipefail
ROOT=https://raw.githubusercontent.com/meandyoung/sofa/main
BASE=/etc/sing-box
WARP=$BASE/warp
CONFIG=$BASE/config.json
log(){ printf '[SYNC] %s\n' "$*"; }
fail(){ log "失败：$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail '需要 root'
[[ -s $CONFIG ]] || fail 'sing-box 配置不存在'
[[ -s $WARP/account.json ]] || fail 'WARP 尚未部署；不能通过同步脚本安装 WARP'
[[ -s $WARP/rules.json ]] || fail '缺少上次成功应用的规则记录，拒绝覆盖；请先人工核对'
command -v flock >/dev/null && command -v python3 >/dev/null && command -v sing-box >/dev/null || fail '缺少 flock、python3 或 sing-box'
mkdir -p "$WARP"; chmod 700 "$WARP"
# ---------- Update Lock ----------
exec 9>"$WARP/.sync.lock"
flock -n 9 || fail '已有配置更新正在执行'
tmp=$(mktemp -d "$WARP/.sync.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# ---------- WARP Rules ----------
# GitHub 是规则源；更新仅操作 route.rules / route.rule_set，不注册 WARP、不重建 Endpoint。
curl -fsSL --retry 2 --connect-timeout 5 --max-time 20 "$ROOT/config/warp-rules.json" -o "$tmp/rules.json" || fail 'GitHub 规则下载失败，旧配置不变'
python3 - "$CONFIG" "$WARP" "$tmp" <<'PY'
import json,sys,re,os
config_path,warp,tmp=sys.argv[1:]
def load(path):
 with open(path) as f:return json.load(f)
new=load(tmp+'/rules.json')
old=load(warp+'/rules.json')
def validate(d):
 if not isinstance(d,dict) or set(d)!={'auto','warp','direct','rule_sets'}:raise ValueError('规则字段错误')
 for k in ('auto','warp','direct'):
  if not isinstance(d[k],list) or any(not isinstance(x,str) or not re.fullmatch(r'[a-z0-9-]+(?:\.[a-z0-9-]+)+',x) for x in d[k]):raise ValueError(k+' 域名格式错误')
 if not isinstance(d['rule_sets'],dict) or any(not isinstance(k,str) or not re.fullmatch(r'[A-Za-z0-9_-]+',k) or not isinstance(v,str) or not v.startswith('https://') or not v.endswith('.srs') for k,v in d['rule_sets'].items()):raise ValueError('rule_sets 格式错误')
 if len(set(d['auto']+d['warp']+d['direct']))!=sum(len(d[k]) for k in ('auto','warp','direct')):raise ValueError('域名重复')
validate(old);validate(new)
if new==old:
 open(tmp+'/unchanged','w').close()
 sys.exit(0)
choice_path=warp+'/openai-outbound'
choice=open(choice_path).read().strip() if os.path.isfile(choice_path) else 'direct'
if choice not in ('direct','warp-ep'):raise ValueError('无效的 OpenAI 初始出口')
cfg=load(config_path)
if not any(x.get('tag')=='warp-ep' for x in cfg.get('endpoints',[])):raise ValueError('WARP Endpoint 不存在')
route=cfg.setdefault('route',{})
existing=list(route.get('rules',[]))
old_rules=[]
for key,outbound in (('direct','direct'),('warp','warp-ep'),('auto',choice)):
 if old[key]:old_rules.append({'domain_suffix':old[key],'action':'route','outbound':outbound})
for name in old['rule_sets']:
 old_rules.append({'rule_set':['sofa-warp-'+name],'action':'route','outbound':'warp-ep'})
for item in old_rules:
 try:existing.remove(item)
 except ValueError:raise ValueError('无法找到旧规则，拒绝更新以免产生残留: '+str(item))
old_tags={'sofa-warp-'+name for name in old['rule_sets']}
rule_sets=list(route.get('rule_set',[]))
for tag in old_tags:
 matches=[r for r in rule_sets if r.get('tag')==tag]
 if len(matches)!=1:raise ValueError('旧 rule_set 不一致: '+tag)
 rule_sets.remove(matches[0])
new_rules=[]
for key,outbound in (('direct','direct'),('warp','warp-ep'),('auto',choice)):
 if new[key]:new_rules.append({'domain_suffix':new[key],'action':'route','outbound':outbound})
for name,url in new['rule_sets'].items():
 tag='sofa-warp-'+name
 if any(x.get('tag')==tag for x in rule_sets):raise ValueError('rule_set 名称冲突: '+tag)
 rule_sets.append({'tag':tag,'type':'remote','format':'binary','url':url})
 new_rules.append({'rule_set':[tag],'action':'route','outbound':'warp-ep'})
route['rules']=new_rules+existing
route['rule_set']=rule_sets
with open(tmp+'/candidate.json','w') as f:json.dump(cfg,f,indent=2,ensure_ascii=False)
PY
[[ ! -e $tmp/unchanged ]] || { log '规则未变化，无需重启'; exit 0; }
sing-box check -c "$tmp/candidate.json" || fail '新配置校验失败，旧配置不变'
cp -p "$CONFIG" "$tmp/original.json"
install -m 600 "$tmp/candidate.json" "$CONFIG.new"
mv -f "$CONFIG.new" "$CONFIG"
if ! systemctl restart sing-box || ! systemctl is-active --quiet sing-box; then
 cp -p "$tmp/original.json" "$CONFIG"
 systemctl restart sing-box || true
 fail '重启失败，已恢复旧 config.json'
fi
# 仅在 sing-box 成功重启后提交规则状态，确保下次能正确识别旧规则。
if ! { cp -p "$WARP/rules.json" "$WARP/rules.json.bak" && install -m 600 "$tmp/rules.json" "$WARP/rules.json"; }; then
 cp -p "$tmp/original.json" "$CONFIG"
 systemctl restart sing-box || true
 fail '规则状态保存失败，已尝试恢复原配置'
fi
log 'WARP 规则更新成功'
# ---------- Other Configs ----------
# 后续配置模块可在此扩展；不得调用部署脚本。
