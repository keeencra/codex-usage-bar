# Codex Usage Bar

**v0.11.0 · 小更新 · 第 2 次公开迭代**

[版本下载](docs/downloads.md) · [更新日志](CHANGELOG.md) · [维护计划](docs/maintenance.md) · [版本规则](docs/versioning.md) · [MIT 许可](LICENSE)


轻量 macOS 菜单栏额度工具，使用 Swift + AppKit 编写。支持 Pro / Plus，按账号实际返回的窗口显示剩余额度。

```text
◉ Pro  ·  周 99%
◉ Plus ·  5h 80% / 周 60%
```

以上为示例数据。仅保留菜单栏，不显示桌面悬浮组件。

## 界面展示

v0.11.0 本项目 AppKit 视图离屏渲染，使用虚构额度、余额和日期，不是桌面实机截图。示例套餐按窗口组合展示，实际以接口为准。原生底部菜单使用 darkAqua；下图仅展示自绘面板，不含底部操作区。

| Pro 单周额度 | Plus 双窗口额度 |
| --- | --- |
| <img src="docs/assets/v0.11.0-pro.png" width="300" alt="v0.11.0 Pro 演示：周额度与 DeepSeek 多币种余额"> | <img src="docs/assets/v0.11.0-plus.png" width="300" alt="v0.11.0 Plus 演示：5h、周额度与 DeepSeek 多币种余额"> |

生成方法：`python3 scripts/render_gallery.py`。参考来源见[致谢](docs/credits.md)。


## 功能

- Pro / Pro Lite 套餐在菜单栏统一标记为 Pro。
- Plus 保留接口返回的 5h 和周额度；不伪造缺失窗口。
- 额度圆环、等宽数字和原生菜单，适应系统外观。
- 每 60 秒刷新，支持手动刷新、重置时间和重置券查询。
- 主面板用深色卡片和分段额度条展示 Codex、DeepSeek 和最近任务用量；二级菜单保留完整明细。
- 下拉菜单可查看本机最近任务的 token 用量、模型及任务标题。
- 获取失败时使用本地缓存并在菜单中标明。

## 构建和运行

需要 macOS 13+、Xcode Command Line Tools，以及已登录的 Codex 桌面应用。

```bash
bash build_app.sh
open build/CodexUsageBarTotal.app
```

安装到当前用户的 Applications：

```bash
OUTPUT_DIR="$HOME/Applications" bash build_app.sh
open "$HOME/Applications/CodexUsageBarTotal.app"
```

构建脚本执行本地临时签名，不提供 Apple 公证。可将安装后的应用加入 macOS 登录项。

## 数据与兼容性

工具通过本地 app-server 的 `account/rateLimits/read` 读取账号额度，按实际窗口时长排序。它会在需要时启动监听于 `127.0.0.1:47891` 的后台服务。默认检查 `/Applications/Codex.app` 和 `/Applications/ChatGPT.app`，自定义位置可通过进程环境变量 `CODEX_BINARY` 指定。

缓存及后台日志位于当前用户的 `~/.codex/`。最近任务读取 `~/.codex/state_5.sqlite`；此数据库和 app-server 接口属于本地实现细节，未来版本变化可能需要适配。切换账号或升级套餐后，旧后台服务可能暂时返回旧额度。

源码仓库不包含凭据、账号额度缓存、任务记录、日志或数据库。应用不提供额外遥测上传；Codex 后台自身的联网和遥测行为由所用客户端决定。

本项目为非官方工具，与 OpenAI 无隶属关系。早期交互参考 QuotaDot 与 codex-float；当前版本已移除悬浮组件实现。

## DeepSeek 官方 API 余额

菜单栏同时显示 DeepSeek 余额，下拉菜单提供币种、充值余额、赠送余额及可用状态。每 60 秒独立查询一次；网络或鉴权失败显示未知状态，不沿用旧余额。

凭据优先从应用进程环境变量 `DEEPSEEK_API_KEY` 读取，否则读取当前用户的 `~/.codex/secrets/deepseek-api-key`。密钥仅发送到官方 `https://api.deepseek.com/user/balance` 查询接口，不写入源码、日志或余额缓存。此文件应仅允许当前用户读取。

## 开发验证

运行 `bash scripts/check.sh` 检查解析、公开文件和构建；无需真实 API Key 或付费模型调用。GitHub Actions 使用相同入口。构建验证不代表所有桌面交互已验收。
