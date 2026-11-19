#!/usr/bin/env bash
# Sofa HTTPS 订阅：preflight / install；可独立升级现有 HTTP 订阅。
set -Eeuo pipefail
BASE=/etc/sing-box
HTTPS_DIR="$BASE/https"
NGINX_DIR="$BASE/nginx"
SCRIPT_DIR="$BASE/scripts"
DOMAIN_FILE="$HTTPS_DIR/domain"
CREDENTIALS="$HTTPS_DIR/cloudflare.ini"
PORT="${SOFA_HTTPS_PORT:-18443}"
HTTP_PORT="${SUBSCRIPTION_PORT:-18080}"
SUB_DIR="$BASE/subscribe"
TOKEN_FILE="$SUB_DIR/token-https"
CLASH_FILE="$SUB_DIR/clash-https.yaml"
TEMPLATE_URL="https://raw.githubusercontent.com/meandyoung/sofa/main/config/clash.yaml"
ACTION="${1:-install}"
DOMAIN="${2:-${SOFA_SUB_DOMAIN:-}}"
fail(){ echo "[ERROR] $*" >&2; exit 1; }
info(){ echo "[INFO] $*"; }
[[ $EUID -eq 0 ]] || fail '需要 root 权限'
[[ "$ACTION" == preflight || "$ACTION" == install ]] || fail '用法：configure-subscription-https.sh [preflight|install] [完整域名]'
install -d -m 700 "$HTTPS_DIR"
install -d -m 755 "$NGINX_DIR" "$SCRIPT_DIR"
if ! command -v curl >/dev/null || ! command -v python3 >/dev/null; then
  apt-get -o DPkg::Lock::Timeout=600 update -qq
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y curl python3 ca-certificates
fi
# 独立运行时询问域名；主安装器传入域名时不重复询问。
if [[ -z "$DOMAIN" && -s "$DOMAIN_FILE" ]]; then DOMAIN=$(<"$DOMAIN_FILE"); fi
if [[ "${SOFA_DOMAIN_CONFIRMED:-0}" == 1 ]]; then
  [[ -n "$DOMAIN" && "$DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] || fail '已确认的域名格式无效'
else
  while :; do
    if [[ -z "$DOMAIN" ]]; then read -r -p '请输入完整 HTTPS 订阅域名：' DOMAIN; fi
    if [[ ! "$DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
      info '域名格式不正确，请重新输入。'; DOMAIN=''; continue
    fi
    printf 'HTTPS 订阅域名：%s\\n' "$DOMAIN"
    read -r -p '确认无误请按回车，输入其他内容重新输入：' answer
    [[ -z "$answer" ]] && break
    DOMAIN=''
  done
fi
# 只接受完整的 Cloudflare DNS Token，不输出密钥。
if [[ ! -s "$CREDENTIALS" || "${SOFA_REENTER_CF_TOKEN:-0}" == 1 ]]; then
  read -r -s -p '请输入 Cloudflare API Token：' CF_TOKEN
  printf '\n'
  [[ -n "$CF_TOKEN" ]] || fail 'Token 不能为空'
  (umask 077; printf 'dns_cloudflare_api_token = %s\n' "$CF_TOKEN" > "$CREDENTIALS")
  unset CF_TOKEN
fi
chmod 600 "$CREDENTIALS"
TOKEN=$(sed -n 's/^dns_cloudflare_api_token = //p' "$CREDENTIALS" | head -1)
[[ -n "$TOKEN" ]] || fail 'Cloudflare Token 文件无效'
# 验证 Token、Zone 读取权限和记录读取权限；写权限在实际创建记录时验证。
CF_TOKEN="$TOKEN" DOMAIN="$DOMAIN" python3 - <<'PY'
import json,os,sys,urllib.request,urllib.error
token=os.environ['CF_TOKEN']; domain=os.environ['DOMAIN'].lower()
def get(path):
    req=urllib.request.Request('https://api.cloudflare.com/client/v4/'+path,headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'})
    with urllib.request.urlopen(req,timeout=15) as r: return json.load(r)
try:
    # Account API Token 不适用 /user/tokens/verify；直接验证实际所需的 Zone/DNS 访问。
    labels=domain.split('.'); zone=None
    for i in range(1,len(labels)):
        candidate='.'.join(labels[i:])
        r=get('zones?name='+candidate)
        if r.get('success') and r.get('result'):
            zone=r['result'][0]; break
    if zone is None: raise ValueError('无法读取域名所属 Zone，请检查 Zone Read 权限')
    ip=urllib.request.urlopen('https://api.ipify.org',timeout=10).read().decode().strip()
    dns_response=get('zones/'+zone['id']+'/dns_records?name='+domain)
    if not dns_response.get('success'): raise ValueError('无法读取 DNS 记录，请检查 DNS 权限')
    records=dns_response.get('result',[])
    if records and (len(records)!=1 or records[0]['type']!='A' or records[0]['content']!=ip or records[0].get('proxied')):
        raise ValueError('DNS 记录与当前 VPS 不一致，拒绝覆盖')
    print('[INFO] Cloudflare Zone、DNS 读取及记录冲突检查通过（兼容 Account API Token）')
except Exception as e:
    print('[ERROR] Cloudflare 预检查失败：'+str(e),file=sys.stderr)
    sys.exit(1)
PY
unset TOKEN
if [[ "$ACTION" == preflight ]]; then
  # 预检查成功后缓存凭据和域名；不安装 Certbot 或变更 DNS。
  printf '%s\n' "$DOMAIN" > "$DOMAIN_FILE"
  chmod 600 "$DOMAIN_FILE"
  exit 0
fi
# 独立 HTTPS 订阅：不依赖任何节点安装器。
install -d -m 750 "$SUB_DIR"
PROXIES_FILE="$SUB_DIR/proxies"
if [[ ! -s "$PROXIES_FILE" ]]; then
  echo "[WARN] 未找到已有订阅节点信息：$PROXIES_FILE"
  while :; do
    printf '1. 手动输入节点订阅文件路径\n2. 退出安装\n'
    read -r -p '请输入选项 [1/2]：' choice
    case "$choice" in
      1)
        read -r -p '请输入 VPS 上节点订阅文件的绝对路径：' candidate
        if [[ "$candidate" != /* || ! -f "$candidate" || ! -s "$candidate" || ! -r "$candidate" ]]; then
          info '文件不存在、为空、不可读或不是绝对路径，请重试。'; continue
        fi
        PROXIES_FILE="$candidate"; break ;;
      2) info '已退出安装'; exit 0 ;;
      *) info '请输入 1 或 2' ;;
    esac
  done
fi
# 验证 Mihomo proxies 文件格式；不修改节点文件。
python3 - "$PROXIES_FILE" <<'PY_PROXIES' || fail '节点文件不是有效的 Mihomo proxies YAML'
import pathlib,sys
s=pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
if not any(line.strip() == 'proxies:' for line in s.splitlines()):
    raise SystemExit('缺少 proxies: 字段')
PY_PROXIES

# HTTPS 专用 Token；仅在不存在时创建。异常文件由用户决定是否覆盖。
if [[ -e "$TOKEN_FILE" ]]; then
  TOKEN=$(cat "$TOKEN_FILE" 2>/dev/null || true)
  if [[ ! -f "$TOKEN_FILE" || ! "$TOKEN" =~ ^[a-f0-9]{48}$ ]]; then
    echo "[WARN] HTTPS Token 文件为空或格式错误：$TOKEN_FILE"
    while :; do
      read -r -p '是否覆盖并生成新 Token？(yes/no)：' choice
      case "$choice" in
        yes) [[ ! -L "$TOKEN_FILE" ]] || fail '拒绝覆盖符号链接 Token 文件'
             info '旧 HTTPS 订阅地址可能失效'
             rm -f -- "$TOKEN_FILE"; break ;;
        no) info '保留原文件，退出安装'; exit 0 ;;
        *) info '请输入 yes 或 no' ;;
      esac
    done
  fi
fi
if [[ ! -e "$TOKEN_FILE" ]]; then
  (umask 077; openssl rand -hex 24 > "$TOKEN_FILE")
fi
chmod 600 "$TOKEN_FILE"
TOKEN=$(<"$TOKEN_FILE")
[[ "$TOKEN" =~ ^[a-f0-9]{48}$ ]] || fail 'HTTPS Token 格式错误'

# 根据 GitHub 模板生成独立完整配置；重复运行可选择保留。
GENERATE_CLASH=1
if [[ -s "$CLASH_FILE" ]]; then
  while :; do
    read -r -p '已有 clash-https.yaml，是否从 GitHub 更新？(yes/no)：' choice
    case "$choice" in
      yes) break ;;
      no) GENERATE_CLASH=0; break ;;
      *) info '请输入 yes 或 no' ;;
    esac
  done
fi
PROVIDER_URL="https://${DOMAIN}:${PORT}/subscribe/${TOKEN}/proxies"
if (( GENERATE_CLASH )); then
  if [[ -z "${SOFA_NODE_NAME:-}" ]]; then
    read -r -p '请输入 Provider 名称（例如 us-vmrack）：' SOFA_NODE_NAME
  fi
  [[ "$SOFA_NODE_NAME" =~ ^[a-z]{2}-[a-z0-9]+(-[a-z0-9]+)*$ ]] || fail 'Provider 名称格式错误'
  TEMPLATE_TMP=$(mktemp)
  OUTPUT_TMP=$(mktemp "$SUB_DIR/.clash-https.XXXXXX")
  trap 'rm -f "$TEMPLATE_TMP" "$OUTPUT_TMP"' EXIT
  curl -fsSL --retry 3 "$TEMPLATE_URL" -o "$TEMPLATE_TMP" || fail 'GitHub YAML 模板下载失败'
  NODE_NAME="$SOFA_NODE_NAME" PROVIDER_URL="$PROVIDER_URL" TEMPLATE="$TEMPLATE_TMP" OUTPUT="$OUTPUT_TMP" python3 - <<'PY_TEMPLATE' || fail '生成 HTTPS YAML 失败'
import os,pathlib
s=pathlib.Path(os.environ['TEMPLATE']).read_text(encoding='utf-8')
if 'NODE_NAME' not in s or 'PROXY_PROVIDERS_URL' not in s:
    raise SystemExit('模板缺少预期占位符')
s=s.replace('NODE_NAME',os.environ['NODE_NAME']).replace('PROXY_PROVIDERS_URL',os.environ['PROVIDER_URL'])
pathlib.Path(os.environ['OUTPUT']).write_text(s,encoding='utf-8')
PY_TEMPLATE
  chmod 600 "$OUTPUT_TMP"
  mv -f "$OUTPUT_TMP" "$CLASH_FILE"
  trap - EXIT
  rm -f "$TEMPLATE_TMP"
else
  # 保留文件时也确保 Provider URL 与当前 HTTPS 域名、Token 一致。
  PROVIDER_URL="$PROVIDER_URL" CLASH_FILE="$CLASH_FILE" python3 - <<'PY_URL' || fail '现有 YAML 无法同步 HTTPS Provider URL'
import os,pathlib,re,tempfile
p=pathlib.Path(os.environ['CLASH_FILE']); s=p.read_text(encoding='utf-8')
pattern=r'https?://[^\s"\x27]+/subscribe/[a-f0-9]{48}/proxies'
updated,n=re.subn(pattern,lambda _:os.environ['PROVIDER_URL'],s)
if n<1 and os.environ['PROVIDER_URL'] not in s:
    raise SystemExit('找不到 Provider URL，请选择重新生成 YAML')
if updated!=s:
    with tempfile.NamedTemporaryFile(mode='w',dir=p.parent,delete=False) as f:
        f.write(updated); tmp=f.name
    os.chmod(tmp,0o600); os.replace(tmp,p)
PY_URL
fi
PUBLIC_IP=$(curl -fsS --max-time 10 -4 https://api.ipify.org) || fail '无法获取 VPS 公网 IP'
export DEBIAN_FRONTEND=noninteractive
missing=()
for pkg in nginx certbot python3-certbot-dns-cloudflare ufw qrencode acl; do
  dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -qx 'install ok installed' || missing+=("$pkg")
done
if (( ${#missing[@]} )); then
  apt-get -o DPkg::Lock::Timeout=600 update -qq
  apt-get -o DPkg::Lock::Timeout=600 install -y "${missing[@]}"
fi
# Nginx 需要能够读取目录和订阅文件；不修改原节点文件权限。
if command -v setfacl >/dev/null; then
  setfacl -m u:www-data:--x "$BASE" "$SUB_DIR"
  setfacl -m u:www-data:r-- "$PROXIES_FILE" "$CLASH_FILE"
fi
# DNS 冲突检查：只创建不存在的 A 记录，不覆盖其他 VPS 的记录。
CF_TOKEN=$(sed -n 's/^dns_cloudflare_api_token = //p' "$CREDENTIALS" | head -1)
CF_TOKEN="$CF_TOKEN" DOMAIN="$DOMAIN" PUBLIC_IP="$PUBLIC_IP" python3 - <<'PY'
import json,os,sys,urllib.request
token=os.environ['CF_TOKEN']; domain=os.environ['DOMAIN'].lower(); ip=os.environ['PUBLIC_IP']
headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'}
def request(path,data=None):
    req=urllib.request.Request('https://api.cloudflare.com/client/v4/'+path,headers=headers,data=json.dumps(data).encode() if data is not None else None,method='POST' if data is not None else 'GET')
    with urllib.request.urlopen(req,timeout=20) as r: return json.load(r)
try:
    labels=domain.split('.'); zone=None
    for i in range(1,len(labels)):
        r=request('zones?name='+'.'.join(labels[i:]))
        if r.get('result'): zone=r['result'][0]; break
    if not zone: raise ValueError('找不到 Zone')
    path='zones/'+zone['id']+'/dns_records'
    records=request(path+'?name='+domain).get('result',[])
    if records:
        if len(records)!=1 or records[0]['type']!='A' or records[0]['content']!=ip or records[0].get('proxied'):
            raise ValueError('DNS 记录已存在但与当前 VPS 不一致，拒绝覆盖')
        print('[INFO] 已存在正确的 DNS-only A 记录')
    else:
        r=request(path,{'type':'A','name':domain,'content':ip,'ttl':1,'proxied':False})
        if not r.get('success'): raise ValueError('创建 DNS 失败：'+str(r.get('errors')))
        print('[INFO] 已创建 DNS-only A 记录')
except Exception as e:
    print('[ERROR] DNS 配置失败：'+str(e),file=sys.stderr); sys.exit(1)
PY
unset CF_TOKEN
# 使用标准证书路径；已有有效证书不重复申请。
CERT="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
KEY="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
if [[ ! -s "$CERT" || ! -s "$KEY" ]] || ! openssl x509 -checkend 2592000 -noout -in "$CERT" >/dev/null 2>&1; then
  certbot certonly --non-interactive --agree-tos --register-unsafely-without-email \
    --dns-cloudflare --dns-cloudflare-credentials "$CREDENTIALS" \
    --dns-cloudflare-propagation-seconds 60 -d "$DOMAIN" || fail '证书申请失败；原有 HTTP 保持不变'
fi
cat > "$NGINX_DIR/subscription-https.conf" <<CONF
server {
    listen ${PORT} ssl;
    server_name ${DOMAIN};
    ssl_certificate ${CERT};
    ssl_certificate_key ${KEY};
    ssl_protocols TLSv1.2 TLSv1.3;
    location = /subscribe/${TOKEN}/proxies {
        alias ${PROXIES_FILE};
        default_type text/yaml;
        add_header Cache-Control "no-store" always;
    }
    location = /subscribe/${TOKEN}/clash {
        alias ${CLASH_FILE};
        default_type text/yaml;
        add_header Cache-Control "no-store" always;
    }
    location / { return 404; }
}
CONF
chmod 644 "$NGINX_DIR/subscription-https.conf"
ln -sfn "$NGINX_DIR/subscription-https.conf" /etc/nginx/conf.d/subscription-https.conf
nginx -t || fail 'Nginx HTTPS 配置检查失败'
systemctl enable --now nginx
systemctl reload nginx
# 续期成功后安全重新加载 Nginx。
cat > "$SCRIPT_DIR/reload-nginx-cert.sh" <<'HOOK'
#!/usr/bin/env bash
set -e
nginx -t
systemctl reload nginx
HOOK
chmod 755 "$SCRIPT_DIR/reload-nginx-cert.sh"
install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
ln -sfn "$SCRIPT_DIR/reload-nginx-cert.sh" /etc/letsencrypt/renewal-hooks/deploy/reload-nginx-cert.sh
systemctl enable --now certbot.timer
ufw allow "${PORT}/tcp" comment 'Sofa HTTPS Subscription'
# 使用实际域名验证 TLS 证书及订阅响应。
URL="https://${DOMAIN}:${PORT}/subscribe/${TOKEN}"
[[ $(curl -fsS -o /dev/null -w '%{http_code}' --connect-timeout 10 "$URL/proxies") == 200 ]] || fail 'HTTPS 节点订阅验证失败；不关闭 HTTP'
[[ $(curl -fsS -o /dev/null -w '%{http_code}' --connect-timeout 10 "$URL/clash") == 200 ]] || fail 'HTTPS 完整订阅验证失败；不关闭 HTTP'
printf '%s\n' "$DOMAIN" > "$DOMAIN_FILE"
chmod 600 "$DOMAIN_FILE"
# 只有独立运行且原有 HTTP 入口存在时才询问是否关闭。
if [[ "${SOFA_INSTALL_ALL:-0}" != 1 && -e /etc/nginx/conf.d/subscription.conf ]]; then
  while :; do
    read -r -p 'HTTPS 已验证成功。是否取消原有 HTTP 订阅？(yes/no)：' choice
    case "$choice" in
      yes)
        mv /etc/nginx/conf.d/subscription.conf "$NGINX_DIR/subscription-http.disabled"
        if nginx -t; then
          systemctl reload nginx
          ufw delete allow "${HTTP_PORT}/tcp" || true
          info 'HTTP 订阅已关闭'
        else
          mv "$NGINX_DIR/subscription-http.disabled" /etc/nginx/conf.d/subscription.conf
          fail 'Nginx 检查失败，已恢复 HTTP'
        fi
        break ;;
      no) info '保留 HTTP 订阅'; break ;;
      *) info '请输入 yes 或 no' ;;
    esac
  done
fi
if [[ "${SOFA_SUPPRESS_SUB_OUTPUT:-0}" != 1 ]]; then
  printf '\n节点订阅地址：\n%s/proxies\n\n完整配置订阅地址：\n%s/clash\n\n完整配置订阅二维码：\n' "$URL" "$URL"
  qrencode -t ANSIUTF8 "$URL/clash"
fi
