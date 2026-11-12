# sync-config.sh — 手动配置同步

## 职责与边界

`sync-config.sh` 是 VPS **部署完成后**统一的配置更新入口。它直接读取 GitHub 配置并修改 sing-box 配置，**不调用** `configure-warp.sh`、`install-singbox-nodes.sh` 或其他安装程序。

- 目前实现：同步 `config/warp-rules.json`，整体替换上次由 WARP 模块生成的路由规则。
- 未来可扩展：其他路由规则、节点相关配置；必须各自明确管理范围，避免覆盖手工配置。
- 不做：WARP 注册、创建或修改 WARP Endpoint、安装节点、自动定时同步、重新检测 OpenAI 原生 IP。
- Quick Tunnel 的原有域名更新服务独立运行，不受此脚本控制。

## 使用方法

在 GitHub 编辑 `config/warp-rules.json` 后，在 VPS 以 root 身份执行：

```bash
# 手动下载 GitHub 最新规则并应用
/usr/local/libexec/sofa/sync-config.sh
```

无需执行任何安装脚本。规则内容未改变时不重启 sing-box；规则改变且校验成功后才重启一次。

## 规则格式

```json
{
  "auto": ["openai.com", "chatgpt.com"],
  "warp": [],
  "direct": [],
  "rule_sets": {}
}
```

- `auto`：沿用首次部署保存的 `openai-outbound`（`direct` 或 `warp-ep`）；更新时不重新检测。
- `warp`：固定走 WARP Endpoint `warp-ep`。
- `direct`：固定走 VPS 原生出口。
- `rule_sets`：`{"名称": "https://.../规则.srs"}`，匹配后走 WARP。
- 同一域名不能同时出现在 `auto`、`warp` 和 `direct`。

## 更新流程

1. 获取互斥文件锁，避免并发修改。
2. 下载 GitHub 规则并校验结构。
3. 比较当前 `/etc/sing-box/warp/rules.json` 与新规则；无变化则退出。
4. 根据旧规则文件及 `openai-outbound`，在 `config.json` 中精确移除上次生成的规则。
5. 插入新规则，保留节点入站、WARP Endpoint、其他路由规则。
6. 执行 `sing-box check`；校验失败不替换运行配置。
7. 备份原 `config.json`，写入新配置并重启 sing-box。
8. 重启成功后更新 `rules.json`，备份旧规则到 `rules.json.bak`。

如果旧规则与现有 `config.json` 不一致，脚本拒绝更新，避免产生残留规则。重启失败时尝试恢复旧配置并重启。

## 文件与注意事项

| 文件 | 用途 |
|---|---|
| `/etc/sing-box/config.json` | sing-box 运行配置 |
| `/etc/sing-box/warp/rules.json` | 上次成功应用的规则 |
| `/etc/sing-box/warp/rules.json.bak` | 上一版规则备份 |
| `/etc/sing-box/warp/openai-outbound` | 首次部署确定的 auto 出口 |
| `/etc/sing-box/warp/account.json` | WARP 注册凭据（同步时不修改） |

本脚本不自动更新自身。修改 GitHub 中的 `scripts/sync-config.sh` 后，需要单独将新版脚本部署到 VPS。

**当前限制：** 仅实现 WARP 规则模块；服务启动状态检查不能保证所有代理连接持续正常。异常中断或磁盘写入失败仍可能需要人工核对 `config.json` 与 `rules.json`。
