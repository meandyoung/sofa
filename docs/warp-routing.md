# WARP 可选出口

一键部署顺序：五个代理节点 → 可选 WARP → Mihomo 订阅。WARP 失败只打印错误，不中断订阅安装。

- 默认出站仍为 direct。WARP 账户优先复用 `/etc/sing-box/warp/account.json`，权限 600。
- 首次注册使用 fscarmen WARP 注册脚本；注册失败不使用共享账户。
- 通过临时 SOCKS 入站及 Cloudflare trace 检测 WARP 实际连通性。
- 检测到 OpenAI 的 `unsupported_country` 才自动将 OpenAI 相关域名切换至 WARP。
- 自定义规则保存到 `/etc/sing-box/warp/rules.json`。
- 应用前进行 sing-box check，重启失败恢复原配置。
- 不修改 Mihomo 节点订阅；WARP 不保证固定美国 IP。

## 管理（在 VPS 上以 root 执行）

```bash
# 查看状态
bash configure-warp.sh status
# 重新注册账户
bash configure-warp.sh register
# 添加或删除域名后缀
bash configure-warp.sh add-domain example.com
bash configure-warp.sh remove-domain example.com
# 添加或删除远程二进制规则集
bash configure-warp.sh add-rule-set geosite-example https://example.com/geosite-example.srs
bash configure-warp.sh remove-rule-set geosite-example
```

注意：运行管理脚本需将其下载到 VPS；目前一键安装器下载后在临时目录执行，不会在 VPS 持久保存脚本本身。Cloudflare 注册接口或规则集地址变化时，WARP 可能部署失败，但原节点仍可运行。
