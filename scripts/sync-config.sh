#!/usr/bin/env bash
# ============================================================
# GitHub Config Sync
# ============================================================
set -Eeuo pipefail
ROOT=https://raw.githubusercontent.com/meandyoung/sofa/main
BASE=/etc/sing-box
WARP=$BASE/warp
log(){ printf '[SYNC] %s\n' "$*"; }
[[ $EUID -eq 0 ]] || { log '需要 root'; exit 1; }
mkdir -p "$WARP"; chmod 700 "$WARP"

# ---------- WARP Rules ----------
# GitHub 是唯一规则源；下载/校验/应用失败均保留 VPS 旧配置。
[[ -s $WARP/account.json && -s $BASE/config.json ]] || { log 'WARP 未安装，跳过 WARP 规则'; exit 0; }
tmp=$(mktemp -d "$WARP/.sync.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
if ! curl -fsSL --retry 2 --connect-timeout 5 --max-time 20 "$ROOT/config/warp-rules.json" -o "$tmp/rules.json"; then
  log 'GitHub 规则下载失败，保留旧规则'; exit 0
fi
if ! python3 - "$tmp/rules.json" <<'PY'
import json,sys,re
try:
 d=json.load(open(sys.argv[1]))
 assert set(d)=={'auto','warp','direct','rule_sets'}
 for key in ('auto','warp','direct'):
  assert isinstance(d[key],list)
  assert all(isinstance(x,str) and re.fullmatch(r'[a-z0-9-]+(?:\.[a-z0-9-]+)+',x) for x in d[key])
 assert isinstance(d['rule_sets'],dict)
 assert all(re.fullmatch(r'[A-Za-z0-9_-]+',k) and isinstance(v,str) and v.startswith('https://') and v.endswith('.srs') for k,v in d['rule_sets'].items())
 assert len(set(d['auto']+d['warp']+d['direct']))==sum(len(d[k]) for k in ('auto','warp','direct'))
except Exception as e:sys.exit('规则校验失败: '+str(e))
PY
then
  log 'GitHub 规则无效，保留旧规则'; exit 0
fi
if [[ -f $WARP/rules.json ]] && cmp -s "$tmp/rules.json" "$WARP/rules.json"; then
  log '规则未变化'; exit 0
fi
# configure-warp 负责 sing-box 检查、连通性验证、原子应用与失败回滚。
if /usr/local/libexec/sofa/configure-warp.sh apply "$tmp/rules.json"; then
  log 'WARP 规则同步成功'
else
  log 'WARP 规则应用失败，保留旧配置'
fi

# ---------- Other Configs ----------
# 未来其他 GitHub 规则在此增加独立模块；单个模块失败不影响其他模块。
