# sing-box 五节点一键部署（更新版）

## 1. 用途与环境

适用于全新 Ubuntu 22.04/24.04 VPS（amd64/arm64），以 root 运行 `install-singbox-nodes.sh`。脚本安装 sing-box、Nginx、cloudflared，生成五个节点及 Mihomo 格式的 `/etc/sing-box/subscribe/proxies`。**不会安装 HTTP 订阅服务**；该服务由 `install-mihomo-subscription.sh` 单独完成。

> 本版依据此前实测成功的五节点配置修改，已通过 Bash 语法检查；本版的新增改动尚未在全新 VPS 完整回归测试。

## 2. 五个节点

| 名称 | 协议 | 监听/入口 | 说明 |
|---|---|---|---|
| `vultr-reality` | VLESS + Reality | TCP 443 | `xtls-rprx-vision` |
| `vultr-hysteria2` | Hysteria2 | UDP 8443 | 自签名证书 + SHA-256 fingerprint |
| `vultr-anytls` | AnyTLS + TLS | TCP 8444 | 复用 HY2 自签名证书及 SHA-256 fingerprint |\n| `vultr-shadowtls` | ShadowTLS v3 + Shadowsocks 2022 | TCP 8446 | 内部 Shadowsocks 仅监听 127.0.0.1:10081，不开放公网 |\n| `vultr-vless-ws-tls` | VLESS + WS + TLS | Cloudflare Quick Tunnel | 本地 Nginx 57862 → sing-box 10080；动态 `*.trycloudflare.com` 域名 |

三个客户端节点**统一采用多行块式 YAML**，并保留现有 HTTP 订阅安装器的 `servername` / `Host` 动态域名替换兼容性。WS 客户端仍使用此前实测的 `server: skk.moe`；此入口不是 Cloudflare 官方承诺的固定入口。

## 3. 脚本模块说明

1. **环境检查**：检查 root、Ubuntu 版本、现有配置与端口占用；发现已有节点配置时停止，避免覆盖。
2. **软件安装**：安装系统依赖、UFW、sing-box 和 cloudflared。
3. **凭据与证书**：生成 UUID、Reality 密钥、HY2/AnyTLS/ShadowTLS/Shadowsocks 密码及证书，并保存受限权限的凭据备份。
4. **sing-box 配置**：生成六个 inbound（含 ShadowTLS 内部 Shadowsocks）和 direct outbound，执行配置检查。
5. **Nginx WS 上游**：只在 `127.0.0.1:57862` 监听，转发至 `127.0.0.1:10080`。
6. **systemd 服务**：注册并启动 `sing-box.service` 和 `quicktunnel.service`，启动 Nginx。
7. **UFW 防火墙**：**集中在同一模块**添加 TCP 443、8444、8446 及 UDP 8443 的入站规则；不开放本地 WS 端口。若 UFW 原本未启用，仅添加规则，**不擅自启用**。不会删除原有 SSH 规则。
8. **动态域名**：从 Quick Tunnel metrics / 日志取得域名；暂时获取不到时使用 `PENDING.trycloudflare.com`。
9. **Mihomo 配置**：将五个节点统一生成块式 YAML，保存至 `subscribe/proxies`。

## 4. 安装与检查

```bash
# 在全新 VPS 上执行安装（不要在已有节点的 VPS 上重复运行）
bash install-singbox-nodes.sh

# 检查服务状态
systemctl is-active sing-box nginx quicktunnel

# 检查 sing-box 配置
sing-box check -c /etc/sing-box/config.json

# 查看防火墙规则和状态
ufw status

# 查看目录结构
tree -L 2 /etc/sing-box

# 仅列出节点名称，不展示密码或密钥
grep -E '^  - name:' /etc/sing-box/subscribe/proxies
```

如 UFW 显示 `inactive`，需先确认 SSH 已允许访问，再决定是否启用。云平台的防火墙/安全组也需允许 TCP 443、8444、8446 和 UDP 8443。HTTP 订阅端口 18080 由后续订阅安装器负责配置；如 UFW 开启，部署订阅时还需要单独放行 TCP 18080。

## 5. 生成目录

```text
/etc/sing-box/
├── config.json
├── certs/
│   ├── hy2.crt
│   ├── hy2.key
│   └── node-secrets.json
├── subscribe/
│   └── proxies
├── nginx/
│   └── quicktunnel-ws.conf
└── systemd/
    ├── sing-box.service
    └── quicktunnel.service
```

## 6. 后续订阅模块

安装成功后，另行执行 `install-mihomo-subscription.sh`。它会直接读取 `subscribe/proxies`，部署 HTTP 订阅，并创建自动更新 Quick Tunnel 域名的脚本及定时器。订阅安装器只更新 Quick Tunnel 节点的域名字段，不修改 AnyTLS 或 ShadowTLS 的节点信息。

## 7. 注意事项

- `config.json`、`certs/node-secrets.json`、`subscribe/proxies` 含有真实凭据，不要上传至公开仓库。
- HY2 / AnyTLS 共用的自签名证书默认有效期 365 天；更换证书后必须更新客户端 fingerprint。
- Quick Tunnel 域名可能改变，依赖后续订阅模块自动同步。
- 脚本下载最新 sing-box/cloudflared，尚未锁定版本或校验 release 文件哈希。
- 已有部署不应重新运行安装器；这次新增的 UFW 规则已在当前 VPS 手动应用，后续新 VPS 会自动添加。

## 8. 一次安装两个模块（推荐）

全新 Ubuntu VPS 可以使用 `scripts/install-all.sh` 一次完成五节点和 Mihomo HTTP 订阅部署。它会先下载两个安装器并分别通过 Bash 语法检查，再按顺序执行；任何一步失败都会停止后续安装。

```bash
# 下载统一安装器
curl -fsSL https://raw.githubusercontent.com/meandyoung/sofa/main/scripts/install-all.sh -o /root/install-all.sh

# 检查统一安装器语法，成功后执行
bash -n /root/install-all.sh && bash /root/install-all.sh
```

该脚本仅用于全新安装；检测到已有 sing-box 配置或订阅文件时会停止，不会覆盖现有节点。也可以继续分别运行两个原安装器。
