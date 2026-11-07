#!/usr/bin/env bash
# 安装 Mihomo HTTP 订阅发布与 Quick Tunnel 域名自动更新模块（单文件安装器）
set -Eeuo pipefail
BASE=/etc/sing-box
SUB_DIR="$BASE/subscribe"
SCRIPT_DIR="$BASE/scripts"
NGINX_DIR="$BASE/nginx"
SYSTEMD_DIR="$BASE/systemd"
PROXIES="$SUB_DIR/proxies"
PORT="${SUBSCRIPTION_PORT:-18080}"
NGINX_LINK=/etc/nginx/conf.d/subscription.conf
SERVICE_LINK=/etc/systemd/system/update-quicktunnel.service
TIMER_LINK=/etc/systemd/system/update-quicktunnel.timer
fail() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }
[[ $EUID -eq 0 ]] || fail '请以 root 身份运行。'
[[ $# -eq 0 ]] || fail "用法：bash $0（无需参数）"
[[ -s "$PROXIES" ]] || fail "缺少 $PROXIES；请先部署节点并生成 Mihomo proxies 文件。"
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1024 && PORT <= 65535 )) || fail '端口必须在 1024–65535 范围内。'
for cmd in nginx python3 openssl curl setfacl systemctl journalctl getent; do
  command -v "$cmd" >/dev/null || fail "缺少依赖：$cmd"
done
getent passwd www-data >/dev/null || fail '缺少 www-data 用户。'
python3 - "$PROXIES" <<'PY' || fail 'proxies 文件格式不正确。'
import pathlib,sys
s=pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
if not s.lstrip().startswith('proxies:'):
    raise SystemExit('文件必须以 proxies: 开头')
PY
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

# 将更新器直接嵌入安装器；无需额外携带 update-quicktunnel.sh。
cat > "$SCRIPT_DIR/update-quicktunnel.sh" <<'UPDATER'
#!/usr/bin/env bash
# 从 cloudflared Quick Tunnel 日志或 metrics 获取当前域名并更新 Mihomo WS 节点。
set -Eeuo pipefail
PROXIES=/etc/sing-box/subscribe/proxies
DOMAIN=$(
python3 - <<'PY'
import json,re,subprocess,urllib.request
pattern=re.compile(r'(?i)\b([a-z0-9-]+\.trycloudflare\.com)\b')
# 优先从 quicktunnel.service 最近日志获取最新的临时域名。
try:
    r=subprocess.run(['journalctl','-u','quicktunnel.service','-n','300','--no-pager','-o','cat'],capture_output=True,text=True,timeout=12)
    hits=pattern.findall(r.stdout)
    if hits:
        print(hits[-1].lower()); raise SystemExit(0)
except (OSError,subprocess.TimeoutExpired):
    pass
# 回退：查询 cloudflared 常见本地 metrics 端口的 /quicktunnel 接口。
for port in range(20241,20251):
    try:
        with urllib.request.urlopen(f'http://127.0.0.1:{port}/quicktunnel',timeout=0.6) as response:
            body=response.read(65536).decode('utf-8','replace')
        hits=pattern.findall(body)
        if hits:
            print(hits[-1].lower()); raise SystemExit(0)
    except Exception:
        continue
raise SystemExit('无法获取 Quick Tunnel 域名；请确认 quicktunnel.service 正在运行。')
PY
)
python3 - "$PROXIES" "$DOMAIN" <<'PY'
import os,pathlib,re,subprocess,sys,tempfile
path=pathlib.Path(sys.argv[1]); domain=sys.argv[2]
if not re.fullmatch(r'[a-z0-9-]+\.trycloudflare\.com',domain):
    raise SystemExit('无效的 Quick Tunnel 域名')
original=path.read_text(encoding='utf-8')
# 只替换已有 trycloudflare.com 的 servername/Host 字段；不改变 server、UUID、路径等配置。
old=r'[a-zA-Z0-9-]+\.trycloudflare\.com'
patterns=[
    re.compile(r'((?:\bservername\s*:\s*)["\']?)'+old+r'(["\']?)',re.I),
    re.compile(r'((?:\bHost\s*:\s*)["\']?)'+old+r'(["\']?)',re.I),
]
updated=original
for pattern in patterns:
    updated=pattern.sub(lambda m:m.group(1)+domain+m.group(2),updated)
if updated==original:
    print('[INFO] 域名未变化，或没有匹配的 Quick Tunnel WS 节点。')
    raise SystemExit(0)
fd,tmp=tempfile.mkstemp(prefix='.proxies-',dir=str(path.parent))
try:
    with os.fdopen(fd,'w',encoding='utf-8') as f:
        f.write(updated)
        f.flush();os.fsync(f.fileno())
    os.chmod(tmp,0o600)
    # 在替换前设置 ACL，确保 Nginx 不会短暂读到无权限的新文件。
    subprocess.run(['setfacl','-m','u:www-data:r--',tmp],check=True)
    os.replace(tmp,path)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
print('[INFO] Quick Tunnel 域名已更新为 '+domain)
PY
UPDATER
chmod 700 "$SCRIPT_DIR/update-quicktunnel.sh"
bash -n "$SCRIPT_DIR/update-quicktunnel.sh"

cat > "$NGINX_DIR/subscription.conf" <<CONF
server {
    listen ${PORT};
    server_name _;
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
nginx -t || fail 'Nginx 配置检查失败，请检查端口及配置冲突。'
systemctl daemon-reload
systemctl reload nginx || systemctl restart nginx
systemctl enable --now update-quicktunnel.timer
STATUS=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/subscribe/${TOKEN}" || true)
[[ "$STATUS" == 200 ]] || fail "订阅 URL 本地检查失败（HTTP $STATUS）。"
IP=$(hostname -I | awk '{print $1}')
info '安装完成。HTTP 订阅包含敏感凭据，请勿公开分享 URL：'
printf 'http://%s:%s/subscribe/%s\n' "${IP:-VPS_IP}" "$PORT" "$TOKEN"
info '如使用防火墙，请自行放行相应 TCP 端口。'
