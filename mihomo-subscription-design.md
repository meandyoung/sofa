# Mihomo 订阅管理模块：单文件安装方案

## 1. 设计目标

先在 VPS 上手动或自动部署 sing-box 节点，再执行**一个** `install-mihomo-subscription.sh` 完成 HTTP 订阅发布和 Quick Tunnel 域名定时更新。

- 节点部署阶段负责安装 sing-box、cloudflared（如使用 Quick Tunnel），并**额外生成** Mihomo 格式的 `/etc/sing-box/subscribe/proxies`。sing-box 自身不会自动生成这个文件。
- 订阅安装阶段**直接使用现有 `proxies`**，不需要任何命令行参数，不复制或覆盖其节点内容。
- `update-quicktunnel.sh` 的完整代码**内嵌在安装器中**，安装时生成到固定路径；无需单独携带第二个 `.sh` 文件。
- 订阅模块不安装 sing-box、不创建节点、不启动 cloudflared Quick Tunnel 服务。

## 2. 运行安装器之前

```text
/etc/sing-box/
├── config.json                 # sing-box 服务端配置（名称取决于部署方式）
└── subscribe/
    └── proxies                # 必须预先生成，非空，Mihomo YAML 格式
```

`proxies` 顶层必须是 `proxies:`，其中包含 Reality、Hysteria2、WebSocket 等节点信息。**三个节点只是当前场景，不是脚本的固定数量限制。**

Quick Tunnel 自动更新的前提：现有 cloudflared 服务运行正常，推荐 systemd 单元名称为 `quicktunnel.service`。更新器先从该服务的 journal 日志提取最近的 `*.trycloudflare.com` 域名；如果没有找到，再尝试本机端口 `20241–20250` 的 `/quicktunnel` 接口。若部署方式不同，需要调整嵌入的更新器。

## 3. 安装器源文件

```text
/root/vps-proxy/subscription/
└── install-mihomo-subscription.sh  # 唯一需要携带的安装文件
```

## 4. 安装方法

前置依赖：Nginx、Python 3、OpenSSL、curl、ACL（`setfacl`）、systemd，且存在 `www-data` 用户。**安装器检查依赖，但不自动安装。** 默认监听 TCP 18080，可通过 `SUBSCRIPTION_PORT` 环境变量调整。系统防火墙和云防火墙需自行配置。

```bash
# 进入安装器目录
cd /root/vps-proxy/subscription

# 直接安装，无需传入节点文件或更新脚本路径
bash install-mihomo-subscription.sh
```

## 5. 安装后的目录

```text
/etc/sing-box/
├── config.json
├── subscribe/
│   ├── proxies                  # 保留节点内容；只调整文件权限
│   └── token                    # 首次生成；重复安装保留原 Token
├── scripts/
│   └── update-quicktunnel.sh    # 安装器内嵌生成
├── nginx/
│   └── subscription.conf        # 安装器生成
└── systemd/
    ├── update-quicktunnel.service
    └── update-quicktunnel.timer
```

安装器同时建立 Nginx 和 systemd 标准目录的软链接：

- `/etc/nginx/conf.d/subscription.conf` → `/etc/sing-box/nginx/subscription.conf`
- `/etc/systemd/system/update-quicktunnel.service` → `/etc/sing-box/systemd/update-quicktunnel.service`
- `/etc/systemd/system/update-quicktunnel.timer` → `/etc/sing-box/systemd/update-quicktunnel.timer`

`quicktunnel.service` 不由此模块创建，它应由节点部署阶段或其他运维方式管理。

## 6. 域名更新流程

```text
cloudflared Quick Tunnel 域名发生变化
  → update-quicktunnel.timer（约每 5 分钟）
  → update-quicktunnel.service
  → /etc/sing-box/scripts/update-quicktunnel.sh
  → 从 quicktunnel.service 日志或本地 metrics 提取域名
  → 只更新 proxies 中现有 trycloudflare.com 的 servername 和 Host
  → 新文件预先设置 www-data ACL，原子替换 proxies
  → Nginx 发布更新后的订阅
  → Mihomo Provider 按 interval 拉取
```

**注意：**更新器针对当前项目的 `trycloudflare.com` WS 节点格式设计；不会修改节点的 `server`、UUID、端口或 WS path。若上游使用不同 YAML 表达方式，应先验证匹配结果。若域名无法获取，更新器报错并保留原订阅文件。

## 7. 重复运行及安全边界

- 重复安装会保留 `subscribe/proxies` **内容**及 `subscribe/token`，但会**覆盖**同名的更新器、Nginx 配置、systemd 服务与定时器。请先备份已有定制配置。
- 安装器会对现有 `proxies` 设置 `600` 权限，并授予 `www-data` ACL 读取权限。更新器在原子替换前先对新文件设置 ACL，避免 Nginx 403。
- 订阅使用 **HTTP 明文**，URL Token 和节点凭据可能在传输途中泄露；生产环境建议改用 HTTPS，勿将 `proxies`、`token` 或真实订阅 URL 提交到公开仓库。
- 此版本已做 Bash 语法检查，但**尚未在全新 VPS 上完成端到端安装测试**。建议先在测试实例上验证 Quick Tunnel 日志提取与节点格式兼容性。
