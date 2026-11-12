# WARP 可选出口与手动规则同步

## 设计

安装顺序：原有五节点 → 可选 WARP → Mihomo HTTP 订阅。
WARP 安装失败不会阻止节点或订阅安装。原有 `install-singbox-nodes.sh` 不依赖 WARP。

GitHub 的 `config/warp-rules.json` 是规则唯一维护入口：

```json
{
  "auto": ["openai.com", "chatgpt.com"],
  "warp": [],
  "direct": [],
  "rule_sets": {}
}
```

- `auto`：部署时检测原生 VPS 的 OpenAI 区域限制，选择 `direct` 或 `warp-ep`；这是安装时检测，不是实时故障切换。当前同步沿用上次检测结果。
- `warp`：固定使用 WARP。
- `direct`：固定使用 VPS 原生出口。
- `rule_sets`：以名称映射 HTTPS .srs 地址，固定走 WARP。
- 域名后缀不要重复归入多个分类。

## VPS 文件

- `/etc/sing-box/warp/account.json`：WARP 凭据（权限 600），正常重启或同步不会重新注册。
- `/etc/sing-box/warp/rules.json`：最近成功应用的 GitHub 规则。
- `/etc/sing-box/warp/rules.json.bak`：上一次成功规则。
- `/etc/sing-box/warp/status`：部署状态。
- `/usr/local/libexec/sofa/configure-warp.sh`：仅用于首次 WARP 安装和注册。
- `/usr/local/libexec/sofa/sync-config.sh`：部署后统一的手动配置更新入口（不调用安装脚本）。详见 [sync-config.md](sync-config.md)。

不创建每日同步定时器。只有手动运行 `sync-config.sh` 时才检查 GitHub 规则；下载失败、内容无变化或验证/应用失败时保留原配置；WARP 未安装则跳过 WARP 模块。未来其他配置可在 `sync-config.sh` 增加独立同步模块。

## 操作

```bash
# 查看 WARP 状态
/usr/local/libexec/sofa/configure-warp.sh status
# 手动触发一次 GitHub 规则同步
/usr/local/libexec/sofa/sync-config.sh
# 如果旧版安装曾启用每日定时器，执行一次以下命令关闭并删除它
systemctl disable --now sofa-sync-config.timer 2>/dev/null || true
rm -f /etc/systemd/system/sofa-sync-config.timer /etc/systemd/system/sofa-sync-config.service
systemctl daemon-reload
```

注意：目前一键安装脚本只允许全新 VPS 部署，不可直接在已有节点的 VPS 上重跑。WARP 不保证固定美国 IP；对固定 IP 有要求的金融网站应继续使用原生 VPS。首次注册依赖 fscarmen WARP 注册接口，外部接口发生变化可能导致注册失败。
