#!/usr/bin/env bash
# 安装 Mihomo HTTP 订阅发布与 Quick Tunnel 域名自动更新模块（单文件安装器）
set -Eeuo pipefail

# ========== 01. 基础路径和参数 ==========
BASE=/etc/sing-box
SUB_DIR="$BASE/subscribe"
SCRIPT_DIR="$BASE/scripts"
NGINX_DIR="$BASE/nginx"
SYSTEMD_DIR="$BASE/systemd"
PROXIES="$SUB_DIR/proxies"
CLASH="$SUB_DIR/clash.yaml"
TEMPLATE_URL="https://raw.githubusercontent.com/meandyoung/sofa/main/config/clash.yaml"
PORT="${SUBSCRIPTION_PORT:-18080}"
NGINX_LINK=/etc/nginx/conf.d/subscription.conf
SERVICE_LINK=/etc/systemd/system/update-quicktunnel.service
TIMER_LINK=/etc/systemd/system/update-quicktunnel.timer
fail() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }
# ========== 01. 结束 ==========

# ========== 02. 前置条件及依赖检查 ==========
[[ $EUID -eq 0 ]] || fail '请以 root 身份运行。'
[[ $# -eq 0 ]] || fail "用法：bash $0（无需参数）"
[[ -s "$PROXIES" ]] || fail "缺少 $PROXIES；请先部署节点并生成 Mihomo proxies 文件。"
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1024 && PORT <= 65535 )) || fail '端口必须在 1024–65535 范围内。'
# 如果缺少 setfacl，自动安装 acl 软件包
if ! command -v setfacl >/dev/null 2>&1; then
  info "正在安装 acl 软件包..."
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y acl
fi
for cmd in nginx python3 openssl curl setfacl systemctl journalctl getent; do
  command -v "$cmd" >/dev/null || fail "缺少依赖：$cmd"
done
getent passwd www-data >/dev/null || fail '缺少 www-data 用户。'
python3 - "$PROXIES" <<'PY_CHECK' || fail 'proxies 文件格式不正确。'
import pathlib,sys
s=pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
if not s.lstrip().startswith('proxies:'):
    raise SystemExit('文件必须以 proxies: 开头')
PY_CHECK
# ========== 02. 结束 ==========

# ========== 03. 创建目录、订阅 Token 和 Nginx 读取权限 ==========
install -d -m 750 "$SUB_DIR" "$SCRIPT_DIR" "$NGINX_DIR" "$SYSTEMD_DIR"
if [[ ! -s "$SUB_DIR/token" ]]; then
  (umask 077; openssl rand -hex 24 > "$SUB_DIR/token")
fi
chmod 600 "$SUB_DIR/token"
TOKEN=$(<"$SUB_DIR/token")
[[ "$TOKEN" =~ ^[a-f0-9]{48}$ ]] || fail '现有 token 格式异常。'
chmod 600 "$PROXIES"
setfacl -m u:www-data:--x "$BASE"
setfacl -m u:www-data:--x "$SUB_DIR"
setfacl -m u:www-data:r-- "$PROXIES"
# ========== 03. 结束 ==========

# ========== 03A. 生成完整 Mihomo 配置 ==========
# 已部署 VPS 可单独运行此安装器；节点名称不会在此阶段被重命名。
NODE_NAME="${SOFA_NODE_NAME:-}"
if [[ -z "$NODE_NAME" ]]; then
  read -r -p '请输入 Provider 名称（例如 us-dmit）：' NODE_NAME
fi
[[ "$NODE_NAME" =~ ^[a-z]{2}-[a-z0-9]+(-[a-z0-9]+)*$ ]] || fail 'Provider 名称格式错误，例如 us-dmit。'
PUBLIC_IP=$(curl -fsS --max-time 10 -4 https://api.ipify.org) || fail '无法获取 VPS 公网 IPv4。'
PROVIDER_URL="http://${PUBLIC_IP}:${PORT}/subscribe/${TOKEN}/proxies"
TMP_TEMPLATE=$(mktemp)
trap 'rm -f "$TMP_TEMPLATE"' EXIT
curl -fsSL --retry 3 "$TEMPLATE_URL" -o "$TMP_TEMPLATE" || fail '下载 Clash 模板失败。'
NODE_NAME="$NODE_NAME" PROVIDER_URL="$PROVIDER_URL" TEMPLATE="$TMP_TEMPLATE" OUTPUT="$CLASH" python3 - <<'PY_TEMPLATE'
import os, pathlib, tempfile
template=pathlib.Path(os.environ["TEMPLATE"]).read_text(encoding="utf-8")
result=template.replace("NODE_NAME",os.environ["NODE_NAME"]).replace("PROXY_PROVIDERS_URL",os.environ["PROVIDER_URL"])
out=pathlib.Path(os.environ["OUTPUT"])
with tempfile.NamedTemporaryFile(mode="w",encoding="utf-8",dir=out.parent,delete=False) as f:
    f.write(result)
    tmp=f.name
os.chmod(tmp,0o600)
os.replace(tmp,out)
PY_TEMPLATE
setfacl -m u:www-data:r-- "$CLASH"
# ========== 03A. 结束 ==========

# ========== 04. 生成 Quick Tunnel 域名更新脚本 ==========
# 运行安装器时，将其写入 /etc/sing-box/scripts/update-quicktunnel.sh。
cat > "$SCRIPT_DIR/update-quicktunnel.sh" <<'UPDATER'
#!/usr/bin/env bash
set -euo pipefail
SUB="/etc/sing-box/subscribe/proxies"
# 查找 Quick Tunnel 进程 PID
PID=$(ps -eo pid,args | awk '/[c]loudflared/ && /--url http:\/\/127\.0\.0\.1:57862/ {print $1; exit}')
[ -n "$PID" ] || { echo "Quick Tunnel process not found"; exit 1; }
# 根据 PID 动态获取 Metrics 监听地址
METRICS=$(ss -lntp | awk -v pid="pid=$PID," 'index($0,pid) {print $4; exit}')
[ -n "$METRICS" ] || { echo "Metrics address not found"; exit 1; }
# 获取 Quick Tunnel 域名
DOMAIN=$(curl -fsS --max-time 5 "http://$METRICS/quicktunnel" |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["hostname"])')
# 验证域名格式
[[ "$DOMAIN" =~ ^[a-zA-Z0-9-]+\.trycloudflare\.com$ ]] || {
    echo "Invalid Quick Tunnel domain: $DOMAIN"
    exit 1
}
# 更新订阅文件中的 VLESS-WS 域名
DOMAIN="$DOMAIN" SUB="$SUB" python3 - <<'PY'
import os
import re
import tempfile
from pathlib import Path
path = Path(os.environ["SUB"])
domain = os.environ["DOMAIN"]
content = path.read_text()
# 仅匹配 Quick Tunnel 域名，不修改 Reality 和 Hysteria2
pattern = r'(?m)^(\s*)(servername:|Host:)\s*"?([a-zA-Z0-9-]+\.trycloudflare\.com)"?\s*$'
updated, count = re.subn(
    pattern,
    lambda m: f'{m.group(1)}{m.group(2)} "{domain}"',
    content
)
if count != 2:
    raise SystemExit(f"Expected 2 domain fields, found {count}")
# 仅在域名变化时更新文件
if updated != content:
    with tempfile.NamedTemporaryFile(
        mode="w",
        dir=path.parent,
        delete=False
    ) as f:
        f.write(updated)
        tmp = f.name
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
    os.system(f"setfacl -m u:www-data:r-- {path}")
    print(f"Updated Quick Tunnel domain: {domain}")
else:
    print(f"Domain unchanged: {domain}")
PY
UPDATER
chmod 700 "$SCRIPT_DIR/update-quicktunnel.sh"
bash -n "$SCRIPT_DIR/update-quicktunnel.sh"
# ========== 04. 结束 ==========

# ========== 05. 生成 Nginx HTTP 订阅服务配置 ==========
# 使用带随机 Token 的 URL 提供 proxies YAML 文件；其他路径返回 404。
cat > "$NGINX_DIR/subscription.conf" <<CONF
server {
    listen ${PORT};
    server_name _;
    location = /subscribe/${TOKEN}/proxies {
        alias ${PROXIES};
        default_type text/yaml;
        add_header Cache-Control "no-store" always;
    }
    location = /subscribe/${TOKEN}/clash {
        alias ${CLASH};
        default_type text/yaml;
        add_header Cache-Control "no-store" always;
    }
    # 兼容此前已导入的旧节点订阅 URL。
    location = /subscribe/${TOKEN} {
        alias ${PROXIES};
        default_type text/yaml;
        add_header Cache-Control "no-store" always;
    }
    location / { return 404; }
}
CONF
chmod 644 "$NGINX_DIR/subscription.conf"
ln -sfn "$NGINX_DIR/subscription.conf" "$NGINX_LINK"
# ========== 05. 结束 ==========

# ========== 06. 生成 systemd 更新服务和定时器 ==========
# oneshot 服务执行更新脚本；定时器开机后启动，每次执行完成约 5 分钟后再次运行。
cat > "$SYSTEMD_DIR/update-quicktunnel.service" <<'CONF'
[Unit]
Description=Update Quick Tunnel Mihomo subscription domain
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
User=root
ExecStart=/bin/bash /etc/sing-box/scripts/update-quicktunnel.sh
CONF
cat > "$SYSTEMD_DIR/update-quicktunnel.timer" <<'CONF'
[Unit]
Description=Check Quick Tunnel domain every five minutes
[Timer]
OnBootSec=1min
OnUnitInactiveSec=5min
AccuracySec=1min
Unit=update-quicktunnel.service
Persistent=true
[Install]
WantedBy=timers.target
CONF
chmod 644 "$SYSTEMD_DIR/update-quicktunnel.service" "$SYSTEMD_DIR/update-quicktunnel.timer"
ln -sfn "$SYSTEMD_DIR/update-quicktunnel.service" "$SERVICE_LINK"
ln -sfn "$SYSTEMD_DIR/update-quicktunnel.timer" "$TIMER_LINK"
# ========== 06. 结束 ==========

# ========== 07. 检查并启动 Nginx、systemd 定时器 ==========
nginx -t || fail 'Nginx 配置检查失败，请检查端口及配置冲突。'
systemctl daemon-reload
systemctl reload nginx || systemctl restart nginx
systemctl enable --now update-quicktunnel.timer
# ========== 07. 结束 ==========

# ========== 08. 自动配置 UFW 防火墙 ==========
# 如果安装了 UFW，则放行 HTTP 订阅端口。
if command -v ufw >/dev/null 2>&1; then
  ufw allow "${PORT}/tcp" comment 'Mihomo HTTP Subscription'
fi
# ========== 08. 结束 ==========

# ========== 09. 本地验证订阅服务并输出地址 ==========
STATUS=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/subscribe/${TOKEN}" || true)
[[ "$STATUS" == 200 ]] || fail "订阅 URL 本地检查失败（HTTP $STATUS）。"
CLASH_STATUS=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/subscribe/${TOKEN}/clash" || true)
[[ "$CLASH_STATUS" == 200 ]] || fail "完整配置 URL 本地检查失败（HTTP $CLASH_STATUS）。"
info '安装完成。以下 URL 包含敏感凭据，请勿公开分享：'
printf '节点订阅： http://%s:%s/subscribe/%s/proxies\n' "$PUBLIC_IP" "$PORT" "$TOKEN"
printf '完整配置： http://%s:%s/subscribe/%s/clash\n' "$PUBLIC_IP" "$PORT" "$TOKEN"
if command -v qrencode >/dev/null 2>&1; then
  info '完整配置订阅二维码：'
  qrencode -t ANSIUTF8 "http://${PUBLIC_IP}:${PORT}/subscribe/${TOKEN}/clash"
fi
info '已自动配置 UFW 放行规则；如使用云平台防火墙，请确认相应 TCP 端口已放行。'
# ========== 09. 结束 ==========
