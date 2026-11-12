#!/usr/bin/env bash
# 全新 Ubuntu VPS：依次安装 sing-box 五节点与 Mihomo HTTP 订阅。
set -Eeuo pipefail

BASE_URL="https://raw.githubusercontent.com/meandyoung/sofa/main/scripts"
BASE="/etc/sing-box"

fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
info() { printf '[INFO] %s\n' "$*"; }

[[ $EUID -eq 0 ]] || fail '请以 root 身份运行。'
[[ ! -e "$BASE/config.json" && ! -e "$BASE/subscribe/proxies" ]] ||
  fail '检测到已有节点配置；此脚本仅用于全新部署，不会覆盖现有配置。'
command -v curl >/dev/null 2>&1 || fail '缺少 curl，请先安装 curl。'

# 临时下载安装器，退出时自动清理。
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for name in install-singbox-nodes.sh install-mihomo-subscription.sh configure-warp.sh sync-config.sh; do
  info "下载 $name"
  curl -fsSL --retry 3 "$BASE_URL/$name" -o "$work/$name" ||
    fail "下载 $name 失败。"
  [[ -s "$work/$name" ]] || fail "$name 文件为空。"
  bash -n "$work/$name" || fail "$name 语法检查失败，未执行安装。"
done

# 所有脚本通过语法检查后，才开始安装。
info '开始安装 sing-box 五节点'
bash "$work/install-singbox-nodes.sh" || fail '节点安装失败，订阅安装不会执行。'

install -d -m 755 /usr/local/libexec/sofa
install -m 755 "$work/configure-warp.sh" /usr/local/libexec/sofa/configure-warp.sh
install -m 755 "$work/sync-config.sh" /usr/local/libexec/sofa/sync-config.sh

info '开始配置可选 WARP（失败不影响其他节点）'
if bash "$work/configure-warp.sh" install; then
  info 'WARP 已配置且连接正常'
else
  info 'WARP 未启用，继续安装订阅'
fi
info '开始安装 Mihomo HTTP 订阅与 Quick Tunnel 自动更新'
bash "$work/install-mihomo-subscription.sh" || fail '订阅安装失败，请检查输出日志。'

# 每日同步 GitHub 规则；定时器不依赖 WARP 是否安装成功。
cat > /etc/systemd/system/sofa-sync-config.service <<'UNIT'
[Unit]
Description=Sync sofa configuration from GitHub
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/libexec/sofa/sync-config.sh
UNIT
cat > /etc/systemd/system/sofa-sync-config.timer <<'UNIT'
[Unit]
Description=Daily sofa GitHub configuration sync
[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=15m
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now sofa-sync-config.timer || info '配置同步定时器未启用，请手动检查'
info '全部安装完成，节点名称如下：'
grep -E '^  - name:' "$BASE/subscribe/proxies"
info '服务状态：'
systemctl is-active sing-box nginx quicktunnel update-quicktunnel.timer

info 'WARP 状态：'
cat "$BASE/warp/status" 2>/dev/null || info '未运行 WARP 模块'
