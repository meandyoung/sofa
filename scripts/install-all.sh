#!/usr/bin/env bash
# 全新 Ubuntu VPS：依次安装 sing-box 五节点与 Mihomo HTTP/HTTPS 订阅。
set -Eeuo pipefail

BASE_URL="https://raw.githubusercontent.com/meandyoung/sofa/main/scripts"
BASE="/etc/sing-box"

fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
info() { printf '[INFO] %s\n' "$*"; }

[[ $EUID -eq 0 ]] || fail '请以 root 身份运行。'
[[ ! -e "$BASE/config.json" && ! -e "$BASE/subscribe/proxies" ]] ||
  fail '检测到已有节点配置；此脚本仅用于全新部署，不会覆盖现有配置。'
command -v curl >/dev/null 2>&1 || fail '缺少 curl，请先安装 curl。'

# 安装时统一指定 Provider 和节点名前缀。
if [[ -z "${SOFA_NODE_NAME:-}" ]]; then
  read -r -p '请输入 VPS 名称（国家-运营商，例如 us-dmit）：' SOFA_NODE_NAME
fi
[[ "$SOFA_NODE_NAME" =~ ^[a-z]{2}-[a-z0-9]+(-[a-z0-9]+)*$ ]] ||
  fail '名称格式错误，例如 us-dmit。'
printf '当前 VPS 名称：%s\n' "$SOFA_NODE_NAME"
read -r -p '请确认名称无误，按回车继续安装（输入其他内容则取消）：' confirmation
[[ -z "$confirmation" ]] || fail '已取消安装，未执行后续安装步骤。'
export SOFA_NODE_NAME

# 临时下载安装器，退出时自动清理。
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for name in install-singbox-nodes.sh install-mihomo-subscription.sh configure-subscription-https.sh configure-warp.sh sync-config.sh; do
  info "下载 $name"
  curl -fsSL --retry 3 "$BASE_URL/$name" -o "$work/$name" ||
    fail "下载 $name 失败。"
  [[ -s "$work/$name" ]] || fail "$name 文件为空。"
  bash -n "$work/$name" || fail "$name 语法检查失败，未执行安装。"
done

# 订阅模式选择；完整域名由用户提供，不预设任何域名后缀。
SOFA_SUB_MODE=http
while :; do
  read -r -p '请输入完整 HTTPS 订阅域名，若不输入则提供 HTTP 订阅：' SOFA_SUB_DOMAIN
  if [[ -z "$SOFA_SUB_DOMAIN" ]]; then
    read -r -p '确认使用 HTTP 订阅？(yes/no)：' answer
    [[ "$answer" == yes ]] && break
    [[ "$answer" == no ]] && continue
    info '请输入 yes 或 no'; continue
  fi
  info "当前 HTTPS 订阅域名：$SOFA_SUB_DOMAIN"
  read -r -p '确认域名无误？(yes/no)：' answer
  [[ "$answer" == no ]] && continue
  [[ "$answer" == yes ]] || { info '请输入 yes 或 no'; continue; }
  # HTTPS 子脚本独立负责 Cloudflare 交互和预检查。
  if SOFA_REENTER_CF_TOKEN=1 bash "$work/configure-subscription-https.sh" preflight "$SOFA_SUB_DOMAIN"; then
    SOFA_SUB_MODE=https
    break
  fi
  while :; do
    printf 'Cloudflare 验证失败，请选择：1. 重新输入  2. 改用 HTTP  3. 退出\n'
    read -r -p '选择 (1/2/3)：' choice
    case "$choice" in
      1) break ;;
      2)
        read -r -p '确认改用 HTTP 订阅？(yes/no)：' answer
        if [[ "$answer" == yes ]]; then SOFA_SUB_MODE=http; SOFA_SUB_DOMAIN=''; break 2; fi ;;
      3) fail '用户取消安装' ;;
      *) info '无效选择' ;;
    esac
  done
done
export SOFA_SUB_MODE SOFA_SUB_DOMAIN

# 所有脚本通过语法检查后，统一安装系统依赖。
# APT 等待其他进程释放锁，最多 600 秒；不终止自动更新或删除锁文件。
info '统一检查并安装系统依赖'
export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=600 update ||
  fail 'APT 软件索引更新失败。'
apt-get -o DPkg::Lock::Timeout=600 install -y curl ca-certificates openssl python3 nginx tar gzip iproute2 ufw acl qrencode ||
  fail '系统依赖安装失败。'
for cmd in curl openssl python3 nginx tar gzip ip ufw setfacl qrencode; do
  command -v "$cmd" >/dev/null 2>&1 || fail "缺少依赖：$cmd"
done
# 子脚本独立运行仍自行安装依赖；完整安装时跳过重复的 APT 操作。
export SOFA_DEPS_READY=1
info '开始安装 sing-box 五节点'
bash "$work/install-singbox-nodes.sh" || fail '节点安装失败，订阅安装不会执行。'

install -d -m 755 /usr/local/libexec/sofa
install -m 755 "$work/configure-warp.sh" /usr/local/libexec/sofa/configure-warp.sh
install -m 755 "$work/sync-config.sh" /usr/local/libexec/sofa/sync-config.sh
install -m 755 "$work/configure-subscription-https.sh" "$BASE/scripts/configure-subscription-https.sh"

info '开始配置可选 WARP（失败不影响其他节点）'
warp_log="$work/warp-install.log"
if bash "$work/configure-warp.sh" install >"$warp_log" 2>&1; then
  info 'WARP 已配置且连接正常'
else
  info 'WARP 安装失败，继续安装其他代理节点及订阅（可稍后单独重试）'
fi
info "开始安装 Mihomo ${SOFA_SUB_MODE^^} 订阅与 Quick Tunnel 自动更新"
SOFA_SUPPRESS_SUB_OUTPUT=1 bash "$work/install-mihomo-subscription.sh" || fail '订阅安装失败，请检查输出日志。'
if [[ "$SOFA_SUB_MODE" == https ]]; then
  info '配置 HTTPS 订阅、证书及防火墙'
  SOFA_INSTALL_ALL=1 SOFA_SUPPRESS_SUB_OUTPUT=1 bash "$work/configure-subscription-https.sh" install "$SOFA_SUB_DOMAIN" ||
    fail 'HTTPS 配置失败；节点已保留，可单独重试 HTTPS 脚本。'
fi

# 仅保留手动同步入口，不创建或启用每日定时任务。
info '配置同步采用手动触发：/usr/local/libexec/sofa/sync-config.sh'
info '全部安装完成，节点名称如下：'
grep -E '^  - name:' "$BASE/subscribe/proxies"
info '服务状态：'
for unit in sing-box nginx quicktunnel update-quicktunnel.timer; do
  printf '%s: ' "$unit"
  systemctl is-active "$unit" || true
done

info 'WARP 状态：'
cat "$BASE/warp/status" 2>/dev/null || info '未运行 WARP 模块'

# 全部状态输出之后，最后只输出两个订阅地址及完整配置二维码。
TOKEN=$(<"$BASE/subscribe/token")
if [[ "$SOFA_SUB_MODE" == https ]]; then
  URL="https://${SOFA_SUB_DOMAIN}:${SOFA_HTTPS_PORT:-18443}/subscribe/${TOKEN}"
else
  PUBLIC_IP=$(curl -fsS --max-time 10 -4 https://api.ipify.org) || fail '无法获取公网 IP'
  URL="http://${PUBLIC_IP}:${SUBSCRIPTION_PORT:-18080}/subscribe/${TOKEN}"
fi
printf '\n节点订阅地址：\n%s/proxies\n\n完整配置订阅地址：\n%s/clash\n\n完整配置订阅二维码：\n' "$URL" "$URL"
qrencode -t ANSIUTF8 "$URL/clash"
