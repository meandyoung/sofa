#!/usr/bin/env bash
# fscarmen sing-box addon: HTTPS subscription and user Mihomo template
set -Eeuo pipefail
BASE=/etc/sing-box
SOFA=$BASE/sofa
SOURCE=$BASE/subscribe/proxies
PORT=18443
TEMPLATE=https://raw.githubusercontent.com/meandyoung/sofa/main/config/clash.yaml
fail(){ echo "[ERROR] $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail '请使用 root 运行'
[[ -s "$SOURCE" ]] && grep -q '^proxies:' "$SOURCE" || fail "请先通过 fscarmen 生成 $SOURCE"
[[ -s "$BASE/sb.sh" ]] || fail '未检测到 fscarmen 安装'
command -v apt-get >/dev/null || fail '仅支持 Debian/Ubuntu'
install -d -m 755 "$SOFA" "$SOFA/www" "$SOFA/logs"
install -d -m 700 "$SOFA/secrets"
if [[ -s "$SOFA/domain" ]]; then DOMAIN=$(cat "$SOFA/domain"); else
  while :; do
    read -r -p 'HTTPS 订阅域名：' DOMAIN
    [[ "$DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]] || { echo '域名格式错误'; continue; }
    read -r -p "确认 $DOMAIN？(yes/no)：" answer
    [[ "$answer" == yes ]] && break
  done
fi
if [[ -s "$SOFA/provider-name" ]]; then PROVIDER=$(cat "$SOFA/provider-name"); else
  while :; do
    read -r -p 'Provider 名称（例如 us-vultr）：' PROVIDER
    [[ "$PROVIDER" =~ ^[a-z]{2}-[a-z0-9]+(-[a-z0-9]+)*$ ]] && break
  done
fi
if [[ ! -s "$SOFA/secrets/cloudflare.ini" ]]; then
  read -r -s -p 'Cloudflare API Token：' CF_TOKEN
  printf '\n'
  [[ -n "$CF_TOKEN" ]] || fail 'Token 不能为空'
  (umask 077; printf 'dns_cloudflare_api_token = %s\n' "$CF_TOKEN" > "$SOFA/secrets/cloudflare.ini")
  unset CF_TOKEN
fi
chmod 600 "$SOFA/secrets/cloudflare.ini"
export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=600 update -qq
apt-get -o DPkg::Lock::Timeout=600 install -y nginx certbot python3-certbot-dns-cloudflare curl python3 openssl qrencode
IP=$(curl --noproxy '*' -4fsS --max-time 10 https://api.ipify.org) || fail '无法获取公网 IPv4'
CF_TOKEN=$(sed -n 's/^dns_cloudflare_api_token = //p' "$SOFA/secrets/cloudflare.ini" | head -1)
CF_TOKEN="$CF_TOKEN" DOMAIN="$DOMAIN" IP="$IP" python3 - <<'PY'
import os,json,urllib.request,sys
domain=os.environ['DOMAIN'].lower();ip=os.environ['IP']
headers={'Authorization':'Bearer '+os.environ['CF_TOKEN'],'Content-Type':'application/json'}
def call(path,data=None):
    req=urllib.request.Request('https://api.cloudflare.com/client/v4/'+path,
      headers=headers,data=json.dumps(data).encode() if data else None,
      method='POST' if data else 'GET')
    with urllib.request.urlopen(req,timeout=20) as r: result=json.load(r)
    if not result.get('success'): raise ValueError(str(result.get('errors')))
    return result['result']
try:
    zone=None
    labels=domain.split('.')
    for i in range(1,len(labels)):
        zones=call('zones?name='+'.'.join(labels[i:]))
        if zones:zone=zones[0];break
    if not zone:raise ValueError('Zone 不存在或 Token 缺少 Zone Read 权限')
    path='zones/'+zone['id']+'/dns_records'
    records=call(path+'?name='+domain)
    if records:
        if len(records)!=1 or records[0]['type']!='A' or records[0]['content']!=ip or records[0].get('proxied'):
            raise ValueError('已有 DNS 记录与 VPS 不符，拒绝覆盖')
    else:
        call(path,{'type':'A','name':domain,'content':ip,'ttl':1,'proxied':False})
    print('[INFO] Cloudflare DNS 配置成功')
except Exception as e:
    print('[ERROR] '+str(e),file=sys.stderr);sys.exit(1)
PY
unset CF_TOKEN
CERT=/etc/letsencrypt/live/$DOMAIN/fullchain.pem
KEY=/etc/letsencrypt/live/$DOMAIN/privkey.pem
if [[ ! -s "$CERT" || ! -s "$KEY" ]] || ! openssl x509 -checkend 2592000 -noout -in "$CERT" >/dev/null 2>&1; then
  certbot certonly --non-interactive --agree-tos --register-unsafely-without-email \
    --dns-cloudflare --dns-cloudflare-credentials "$SOFA/secrets/cloudflare.ini" \
    --dns-cloudflare-propagation-seconds 60 -d "$DOMAIN" || fail '证书申请失败'
fi
[[ -s "$SOFA/token" ]] || (umask 077; openssl rand -hex 24 > "$SOFA/token")
TOKEN=$(cat "$SOFA/token")
[[ "$TOKEN" =~ ^[a-f0-9]{48}$ ]] || fail '订阅 Token 无效'
printf '%s\n' "$DOMAIN" > "$SOFA/domain"
printf '%s\n' "$PROVIDER" > "$SOFA/provider-name"
chmod 600 "$SOFA/token" "$SOFA/domain" "$SOFA/provider-name"
cat > "$SOFA/sync.sh" <<'SYNC'
#!/usr/bin/env bash
set -Eeuo pipefail
SOFA=/etc/sing-box/sofa
SOURCE=/etc/sing-box/subscribe/proxies
DOMAIN=$(cat "$SOFA/domain")
PROVIDER=$(cat "$SOFA/provider-name")
TOKEN=$(cat "$SOFA/token")
[[ -s "$SOURCE" ]] && grep -q '^proxies:' "$SOURCE" || exit 1
TMP=$(mktemp -d "$SOFA/.sync.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
curl -fsSL --retry 2 https://raw.githubusercontent.com/meandyoung/sofa/main/config/clash.yaml -o "$TMP/template"
DOMAIN="$DOMAIN" PROVIDER="$PROVIDER" TOKEN="$TOKEN" TMP="$TMP" python3 - <<'PY'
import os,pathlib
tmp=pathlib.Path(os.environ['TMP'])
s=(tmp/'template').read_text()
if 'NODE_NAME' not in s or 'PROXY_PROVIDERS_URL' not in s:
    raise SystemExit('模板缺少必要占位符')
url='https://'+os.environ['DOMAIN']+':18443/subscribe/'+os.environ['TOKEN']+'/proxies'
(tmp/'clash.yaml').write_text(s.replace('PROXY_PROVIDERS_URL',url).replace('NODE_NAME',os.environ['PROVIDER']))
PY
cp "$SOURCE" "$TMP/proxies"
chmod 644 "$TMP/proxies" "$TMP/clash.yaml"
mv -f "$TMP/proxies" "$SOFA/www/proxies"
mv -f "$TMP/clash.yaml" "$SOFA/www/clash.yaml"
SYNC
chmod 755 "$SOFA/sync.sh"
bash "$SOFA/sync.sh" || fail '生成订阅失败'
cat > "$SOFA/nginx.conf" <<CONF
worker_processes 1;
pid $SOFA/nginx.pid;
error_log $SOFA/logs/nginx-error.log warn;
events { worker_connections 256; }
http {
  access_log $SOFA/logs/nginx-access.log;
  server {
    listen $PORT ssl;
    server_name $DOMAIN;
    ssl_certificate $CERT;
    ssl_certificate_key $KEY;
    ssl_protocols TLSv1.2 TLSv1.3;
    location = /subscribe/$TOKEN/proxies {
      alias $SOFA/www/proxies;
      default_type text/yaml;
      add_header Cache-Control "no-store" always;
    }
    location = /subscribe/$TOKEN/clash {
      alias $SOFA/www/clash.yaml;
      default_type text/yaml;
      add_header Cache-Control "no-store" always;
    }
    location / { return 404; }
  }
}
CONF
nginx -t -c "$SOFA/nginx.conf" || fail 'Nginx 配置错误'
cat > "$SOFA/sofa-https.service" <<SERVICE
[Unit]
Description=Sofa HTTPS subscriptions
After=network-online.target
[Service]
Type=forking
PIDFile=$SOFA/nginx.pid
ExecStart=/usr/sbin/nginx -c $SOFA/nginx.conf
ExecReload=/usr/sbin/nginx -s reload -c $SOFA/nginx.conf
ExecStop=/usr/sbin/nginx -s quit -c $SOFA/nginx.conf
Restart=on-failure
[Install]
WantedBy=multi-user.target
SERVICE
cat > "$SOFA/sofa-sync.service" <<SERVICE
[Unit]
Description=Sync Sofa subscriptions
[Service]
Type=oneshot
ExecStart=/bin/bash $SOFA/sync.sh
SERVICE
cat > "$SOFA/sofa-sync.timer" <<'TIMER'
[Unit]
Description=Sync Sofa subscriptions periodically
[Timer]
OnBootSec=1min
OnUnitInactiveSec=5min
Unit=sofa-sync.service
[Install]
WantedBy=timers.target
TIMER
ln -sfn "$SOFA/sofa-https.service" /etc/systemd/system/sofa-https.service
ln -sfn "$SOFA/sofa-sync.service" /etc/systemd/system/sofa-sync.service
ln -sfn "$SOFA/sofa-sync.timer" /etc/systemd/system/sofa-sync.timer
systemctl daemon-reload
systemctl enable --now sofa-https.service sofa-sync.timer
systemctl restart sofa-https.service
cat > "$SOFA/reload-after-renewal.sh" <<'HOOK'
#!/usr/bin/env bash
set -e
systemctl reload sofa-https.service
HOOK
chmod 755 "$SOFA/reload-after-renewal.sh"
install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
ln -sfn "$SOFA/reload-after-renewal.sh" /etc/letsencrypt/renewal-hooks/deploy/sofa-reload.sh
systemctl enable --now certbot.timer || true
if command -v ufw >/dev/null; then ufw allow "$PORT/tcp" comment 'Sofa HTTPS Subscription'; fi
URL=https://$DOMAIN:$PORT/subscribe/$TOKEN
curl --noproxy '*' -fsS --resolve "$DOMAIN:$PORT:127.0.0.1" -o /dev/null "$URL/proxies" || fail 'HTTPS 节点订阅检查失败'
curl --noproxy '*' -fsS --resolve "$DOMAIN:$PORT:127.0.0.1" -o /dev/null "$URL/clash" || fail 'HTTPS 完整订阅检查失败'
printf '\n节点订阅：\n%s/proxies\n\n完整配置订阅：\n%s/clash\n\n完整配置二维码：\n' "$URL" "$URL"
qrencode -t ANSIUTF8 "$URL/clash"
