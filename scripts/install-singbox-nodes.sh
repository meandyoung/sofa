#!/usr/bin/env bash
# Ubuntu 22.04/24.04 | 一键部署 Reality / Hysteria2 / VLESS-WS Quick Tunnel / AnyTLS / ShadowTLS v3
# 注意：节点生成形式需要独立成行，因为quicktunnel更新脚本查找是按照这个格式寻找的
# 安装完成后生成 /etc/sing-box/subscribe/proxies，供独立 Mihomo 订阅安装器直接使用。
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
BASE=/etc/sing-box
PROXIES="$BASE/subscribe/proxies"
NODE_NAME="${SOFA_NODE_NAME:-}"
if [[ -z "$NODE_NAME" ]]; then
  read -r -p '请输入 VPS 名称（例如 us-dmit）：' NODE_NAME
fi
[[ "$NODE_NAME" =~ ^[a-z]{2}-[a-z0-9]+(-[a-z0-9]+)*$ ]] || { echo '[ERROR] VPS 名称格式错误'; exit 1; }
REALITY_PORT=443
HY2_PORT=8443
ANYTLS_PORT=8444
SHADOWTLS_PORT=8446
SHADOWTLS_SS_PORT=10081
WS_PORT=10080
NGINX_WS_PORT=57862
CF_METRICS_PORT=20241
WS_PATH=/sofa-vless
REALITY_SNI=www.apple.com
fail(){ echo "[ERROR] $*" >&2; exit 1; }
info(){ echo "[INFO] $*"; }
[[ $EUID -eq 0 ]] || fail '请使用 root 运行'
[[ -f /etc/os-release ]] || fail '不支持的系统'
. /etc/os-release
[[ $ID == ubuntu ]] || fail '目前仅支持 Ubuntu'
[[ $VERSION_ID == 22.04 || $VERSION_ID == 24.04 ]] || fail '仅支持 Ubuntu 22.04/24.04'
[[ ! -e "$BASE/config.json" && ! -e "$PROXIES" ]] || fail '检测到已有节点配置；为避免覆盖，脚本已停止。'
for p in "$REALITY_PORT/tcp" "$HY2_PORT/udp" "$ANYTLS_PORT/tcp" "$SHADOWTLS_PORT/tcp" "$SHADOWTLS_SS_PORT/tcp" "$NGINX_WS_PORT/tcp"; do
  port=${p%/*}; proto=${p#*/}
  if ss -H -lntup | grep -Eq ":${port}[[:space:]]"; then
    fail "端口 $port 可能已被占用，请检查现有服务"
  fi
done
if [[ "${SOFA_DEPS_READY:-0}" != 1 ]]; then
  # 单独运行时补装依赖，等待 APT 锁释放。
  apt-get -o DPkg::Lock::Timeout=600 update
  apt-get -o DPkg::Lock::Timeout=600 install -y curl ca-certificates openssl python3 nginx tar gzip iproute2 ufw acl
fi
arch=$(dpkg --print-architecture)
case "$arch" in amd64|arm64) ;; *) fail "不支持架构 $arch";; esac
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# 从官方 GitHub Release 获取 sing-box 最新稳定版；生产环境建议锁定版本并验证校验和。
version=$(curl -fsSL --retry 3 https://api.github.com/repos/SagerNet/sing-box/releases/latest | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"].lstrip("v"))')
archive="sing-box-${version}-linux-${arch}.tar.gz"
curl -fL --retry 3 "https://github.com/SagerNet/sing-box/releases/download/v${version}/${archive}" -o "$work/$archive"
tar -xzf "$work/$archive" -C "$work"
install -m 755 "$work/sing-box-${version}-linux-${arch}/sing-box" /usr/local/bin/sing-box
# cloudflared 官方二进制
curl -fL --retry 3 "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}" -o "$work/cloudflared"
install -m 755 "$work/cloudflared" /usr/local/bin/cloudflared
install -d -m 700 "$BASE" "$BASE/subscribe" "$BASE/certs"
install -d -m 755 "$BASE/systemd" "$BASE/nginx"
# ============================================================
# 节点凭据模块：生成 UUID、Reality 密钥和 HY2 证书
# ============================================================
uuid=$(sing-box generate uuid)
ws_uuid=$(sing-box generate uuid)
keys=$(sing-box generate reality-keypair)
private_key=$(printf '%s\n' "$keys" | awk -F': ' '/PrivateKey|Private key/{print $2; exit}')
public_key=$(printf '%s\n' "$keys" | awk -F': ' '/PublicKey|Public key/{print $2; exit}')
[[ -n $private_key && -n $public_key ]] || fail 'Reality 密钥生成失败'
short_id=$(openssl rand -hex 8)
hy_password=$(openssl rand -hex 24)
anytls_password=$(openssl rand -hex 24)
shadowtls_password=$(openssl rand -hex 24)
ss2022_password=$(openssl rand -base64 16 | tr -d '\n')
# HY2 自签名证书使用 SNI www.apple.com，并固定 SHA-256 指纹验证。
public_ip=$(curl -fsS --max-time 10 -4 https://api.ipify.org) || fail '无法识别公网 IPv4'
[[ $public_ip =~ ^[0-9.]+$ ]] || fail '公网 IP 格式异常'
openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 365 \
  -keyout "$BASE/certs/hy2.key" -out "$BASE/certs/hy2.crt" \
  -subj '/CN=www.apple.com' -addext "subjectAltName=DNS:www.apple.com,IP:${public_ip}" >/dev/null 2>&1
chmod 600 "$BASE/certs/hy2.key"
chmod 644 "$BASE/certs/hy2.crt"
hy_fingerprint=$(openssl x509 -in "$BASE/certs/hy2.crt" -noout -fingerprint -sha256 | cut -d= -f2)
# 保存生成的 Reality 密钥及节点凭据，供后续管理和备份；服务端配置仍需引用其中的私钥。
python3 - "$BASE/certs/node-secrets.json" "$private_key" "$public_key" "$short_id" "$uuid" "$ws_uuid" "$hy_password" "$anytls_password" "$shadowtls_password" "$ss2022_password" <<'PYSECRETS'
import json,sys
p,private,public,short,uuid,ws_uuid,hy_password,anytls_password,shadowtls_password,ss2022_password=sys.argv[1:]
with open(p,"w") as f:
 json.dump({"reality_private_key":private,"reality_public_key":public,"reality_short_id":short,"reality_uuid":uuid,"ws_uuid":ws_uuid,"hysteria2_password":hy_password,"anytls_password":anytls_password,"shadowtls_password":shadowtls_password,"shadowsocks2022_password":ss2022_password},f,indent=2)
 f.write("\n")
PYSECRETS
chmod 600 "$BASE/certs/node-secrets.json"
# ============================================================
# sing-box 模块：生成五个代理节点（ShadowTLS 含本地 SS inbound）及直连 outbound
# ============================================================
python3 - "$BASE/config.json" "$uuid" "$ws_uuid" "$private_key" "$short_id" "$hy_password" "$WS_PATH" "$REALITY_SNI" "$WS_PORT" "$HY2_PORT" "$REALITY_PORT" "$ANYTLS_PORT" "$SHADOWTLS_PORT" "$SHADOWTLS_SS_PORT" "$anytls_password" "$shadowtls_password" "$ss2022_password" <<'PY'
import json,sys
p,uuid,ws_uuid,private,short,pwd,path,sni,wsport,hyport,realityport,anyport,shadowport,ssport,anypwd,shadowpwd,sspwd=sys.argv[1:]
config={"log":{"level":"info","timestamp":True},"inbounds":[
 {"type":"vless","tag":"reality-in","listen":"::","listen_port":int(realityport),"users":[{"uuid":uuid,"flow":"xtls-rprx-vision"}],"tls":{"enabled":True,"server_name":sni,"reality":{"enabled":True,"handshake":{"server":sni,"server_port":443},"private_key":private,"short_id":[short]}}},
 {"type":"hysteria2","tag":"hy2-in","listen":"::","listen_port":int(hyport),"users":[{"password":pwd}],"tls":{"enabled":True,"certificate_path":"/etc/sing-box/certs/hy2.crt","key_path":"/etc/sing-box/certs/hy2.key"}},
 {"type":"vless","tag":"ws-in","listen":"127.0.0.1","listen_port":int(wsport),"users":[{"uuid":ws_uuid}],"transport":{"type":"ws","path":path,"max_early_data":2560,"early_data_header_name":"Sec-WebSocket-Protocol"},"multiplex":{"enabled":True}},
 {"type":"anytls","tag":"anytls-in","listen":"::","listen_port":int(anyport),"users":[{"password":anypwd}],"tls":{"enabled":True,"certificate_path":"/etc/sing-box/certs/hy2.crt","key_path":"/etc/sing-box/certs/hy2.key"}},
 {"type":"shadowtls","tag":"shadowtls-in","listen":"::","listen_port":int(shadowport),"version":3,"users":[{"name":"client","password":shadowpwd}],"handshake":{"server":sni,"server_port":443},"detour":"shadowtls-ss-in","strict_mode":True},
 {"type":"shadowsocks","tag":"shadowtls-ss-in","listen":"127.0.0.1","listen_port":int(ssport),"method":"2022-blake3-aes-128-gcm","password":sspwd,"multiplex":{"enabled":True,"padding":True}}
],"outbounds":[{"type":"direct","tag":"direct"}]}
with open(p,'w') as f:json.dump(config,f,indent=2)
PY
chmod 600 "$BASE/config.json"
# ============================================================
# Nginx 模块：只在本地提供 WebSocket 上游，供 cloudflared 转发
# ============================================================
cat > "$BASE/nginx/quicktunnel-ws.conf" <<CONF
server {
    listen 127.0.0.1:${NGINX_WS_PORT};
    server_name _;
    location ${WS_PATH} {
        proxy_pass http://127.0.0.1:${WS_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 3600s;
    }
    location / { return 404; }
}
CONF
ln -sfn "$BASE/nginx/quicktunnel-ws.conf" /etc/nginx/conf.d/quicktunnel-ws.conf
# ============================================================
# systemd 模块：注册 sing-box 和 Quick Tunnel 开机启动服务
# ============================================================
cat > "$BASE/systemd/sing-box.service" <<'UNIT'
[Unit]
Description=sing-box proxy service
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
UNIT
cat > "$BASE/systemd/quicktunnel.service" <<UNIT
[Unit]
Description=Cloudflare Quick Tunnel for sing-box WS
After=network-online.target nginx.service sing-box.service
Wants=network-online.target
[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate --metrics 127.0.0.1:${CF_METRICS_PORT} --url http://127.0.0.1:${NGINX_WS_PORT}
# Quick Tunnel 申请失败（包括 HTTP 429）后等待 5 分钟再启动，避免密集重试。
Restart=always
RestartSec=300
[Install]
WantedBy=multi-user.target
UNIT
ln -sfn "$BASE/systemd/sing-box.service" /etc/systemd/system/sing-box.service
ln -sfn "$BASE/systemd/quicktunnel.service" /etc/systemd/system/quicktunnel.service
sing-box check -c "$BASE/config.json" || fail 'sing-box 配置校验失败'
nginx -t || fail 'Nginx 配置校验失败'
# ============================================================
# 防火墙模块：集中管理所有需要从公网访问的入站端口
# ============================================================
# Reality 直接使用 TCP 443；Hysteria2 使用 UDP 8443。
# Quick Tunnel 主动连接 Cloudflare，WS 上游仅监听 127.0.0.1，
# 因此 10080、57862 和 metrics 20241 都无需对公网开放。
# 保留现有 SSH 规则；如果 UFW 尚未启用，仅添加规则，不擅自启用防火墙。
ufw allow "${REALITY_PORT}/tcp" comment 'sing-box Reality'
ufw allow "${HY2_PORT}/udp" comment 'sing-box Hysteria2'
ufw allow "${ANYTLS_PORT}/tcp" comment 'sing-box AnyTLS'
ufw allow "${SHADOWTLS_PORT}/tcp" comment 'sing-box ShadowTLS'
info 'UFW 入站规则已配置；如 UFW 为 inactive，请按实际需要另行启用。'

# ============================================================
# 服务启动模块：启动 sing-box、Nginx 和 Cloudflare Quick Tunnel
# ============================================================
systemctl daemon-reload
systemctl enable --now sing-box.service
systemctl enable --now nginx.service
systemctl reload nginx
systemctl enable --now quicktunnel.service
# ============================================================
# Quick Tunnel 域名模块：获取动态域名，未获取则暂存占位符
# ============================================================
domain='PENDING.trycloudflare.com'
for i in $(seq 1 25); do
  found=$(curl -fsS --max-time 2 "http://127.0.0.1:${CF_METRICS_PORT}/quicktunnel" 2>/dev/null | grep -Eo '[a-zA-Z0-9-]+\.trycloudflare\.com' | head -1 || true)
  # 仅使用当前进程的 metrics 获取域名，避免读取旧日志中的过期域名。
  if [[ -n $found ]]; then domain=$found; break; fi
  sleep 2
done
# ============================================================
# Mihomo 节点模块：将五个节点统一输出为多行 YAML
# ============================================================
python3 - "$PROXIES" "$NODE_NAME" "$public_ip" "$uuid" "$ws_uuid" "$public_key" "$short_id" "$hy_password" "$domain" "$REALITY_SNI" "$WS_PATH" "$REALITY_PORT" "$HY2_PORT" "$hy_fingerprint" "$ANYTLS_PORT" "$SHADOWTLS_PORT" "$anytls_password" "$shadowtls_password" "$ss2022_password" <<'PY'
import json,sys
p,node_name,ip,uuid,ws_uuid,pub,short,pwd,domain,sni,path,rport,hport,hyfp,anyport,shadowport,anypwd,shadowpwd,sspwd=sys.argv[1:]
# 统一生成块式（多行）YAML；兼容 Mihomo 及现有域名更新器。
entries=[
 {"name":f"{node_name}-reality","type":"vless","server":ip,"port":int(rport),"uuid":uuid,"network":"tcp","tls":True,"udp":True,"servername":sni,"client-fingerprint":"chrome","flow":"xtls-rprx-vision","reality-opts":{"public-key":pub,"short-id":short}},
 {"name":f"{node_name}-hysteria2","type":"hysteria2","server":ip,"port":int(hport),"password":pwd,"sni":sni,"skip-cert-verify":False,"fingerprint":hyfp},
 {"name":f"{node_name}-anytls","type":"anytls","server":ip,"port":int(anyport),"password":anypwd,"sni":sni,"skip-cert-verify":False,"fingerprint":hyfp,"client-fingerprint":"chrome"},
 {"name":f"{node_name}-shadowtls","type":"ss","server":ip,"port":int(shadowport),"cipher":"2022-blake3-aes-128-gcm","password":sspwd,"plugin":"shadow-tls","plugin-opts":{"version":3,"host":sni,"password":shadowpwd},"smux":{"enabled":True,"protocol":"h2mux","padding":True}},
 {"name":f"{node_name}-vless-ws-tls","type":"vless","server":"skk.moe","port":443,"uuid":ws_uuid,"udp":True,"tls":True,"servername":domain,"network":"ws","skip-cert-verify":False,"ws-opts":{"path":path,"headers":{"Host":domain},"max-early-data":2560,"early-data-header-name":"Sec-WebSocket-Protocol"},"smux":{"enabled":True,"protocol":"h2mux","padding":True,"max-connections":8,"min-streams":16,"statistic":True,"only-tcp":False}}
]

def scalar(value):
    if isinstance(value,bool):return 'true' if value else 'false'
    if isinstance(value,(int,float)):return str(value)
    return json.dumps(value,ensure_ascii=False)

def emit_map(f,obj,indent):
    for key,value in obj.items():
        prefix=' '*indent+key+':'
        if isinstance(value,dict):
            f.write(prefix+'\n')
            emit_map(f,value,indent+2)
        else:
            f.write(prefix+' '+scalar(value)+'\n')

with open(p,'w',encoding='utf-8') as f:
    f.write('proxies:\n')
    for item in entries:
        first,*rest=item.items()
        f.write('  - '+first[0]+': '+scalar(first[1])+'\n')
        emit_map(f,dict(rest),4)
PY
chmod 600 "$PROXIES"
info "五个节点配置已生成：$PROXIES"
info "sing-box 配置：$BASE/config.json"
info "证书与密钥目录：$BASE/certs"
info "Quick Tunnel 域名：$domain"
if [[ $domain == PENDING.trycloudflare.com ]]; then
  info 'Quick Tunnel 申请失败或尚未就绪；将每隔 5 分钟重新申请，成功后自动更新订阅域名。'
fi
info 'UFW 已添加 TCP 443、8444、8446 及 UDP 8443 规则；仍需确认 UFW 状态及云平台防火墙。HTTP 订阅端口由另一安装器配置。'
info 'HY2 使用自签名证书和 SHA-256 指纹校验；证书更新时需同步更新 fingerprint。'
