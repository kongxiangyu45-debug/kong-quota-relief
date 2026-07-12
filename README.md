# AI Quota Bar

一个面向 Codex 重度用户的 macOS 菜单栏工具。它不只显示 5 小时和一周额度，还把本机 Codex 任务、运行状态、Token 处理量和进度放在同一个下拉菜单里。

> CodexBar 告诉你还剩多少；AI Quota Bar 尝试告诉你额度花在了哪里。

## 目前能做什么

- 显示 Codex 5 小时、一周额度和重置倒计时。
- 读取 Codex 本地任务标题，区分正在运行、刚完成和历史任务。
- 显示本地日志记录的 Token 处理量。
- 有任务计划时显示已完成步骤；没有计划时只显示带“约”字的阶段估算。
- 生成本地 HTML 用量报告，按观察到的额度下降从高到低排序。
- 生成深度复盘提示词，但不会自动调用 Codex，也不会额外消耗额度。

## 数据口径

AI Quota Bar 有意避免“看起来很准，实际算错任务”：

- **额度百分比**来自 [CodexBar](https://github.com/steipete/CodexBar)。
- **Token**来自本机 `~/.codex` 日志，表示模型处理量，不等于 API 账单金额。
- **任务额度**只在连续两次额度记录都能确认属于同一个任务时才归因；任务切换、并行运行或长时间缺口会留作“无法归因”，因此可能低估，但不会硬分给某个任务。
- **进度**只有任务主动维护计划时才是步骤比例；否则必须显示“约”，只代表当前阶段。

从公开版 `0.1.0` 起，可靠归因数据写入新的 `codex-task-usage-v2.json`。旧版账本会留在原处作为备份，但不会混入新报告。

## 隐私

所有任务解析和报告生成都在本机完成。应用不会上传任务标题、对话内容或日志，也没有遥测。生成报告后，如果你主动把深度分析提示词发送给 AI，对应内容才会进入你选择的平台。

## 系统要求

- macOS 14 或更高版本
- 已安装并登录 Codex
- 已安装 [CodexBar](https://github.com/steipete/CodexBar)，或系统中存在 `codexbar` CLI
- 从源码构建需要 Swift 6

## 构建与安装

```bash
git clone https://github.com/kongxiangyu45-debug/AIQuotaBar.git
cd AIQuotaBar
./Scripts/verify.sh
./Scripts/install.sh
```

仅构建应用：

```bash
./Scripts/build-app.sh
open "dist/AI Quota Bar.app"
```

打包 GitHub Release：

```bash
./Scripts/package-release.sh 0.1.0
```

卸载应用（默认保留本地用量历史）：

```bash
./Scripts/uninstall.sh
```

## 当前限制

- 目前主要针对 Codex Desktop 在 macOS 上产生的本地数据格式。
- Codex 更新内部日志或 SQLite 结构后，任务监控可能需要同步适配。
- 未使用 Apple Developer ID 签名的社区构建，首次打开时可能需要在“系统设置 → 隐私与安全性”中确认。
- Claude 解析代码暂时保留，但公开版默认关闭，待准确性重新验证后再开放。

## 与 CodexBar 的关系

AI Quota Bar 是独立的任务分析伴侣，使用 CodexBar CLI 获取官方套餐窗口的汇总数据。本项目不是 CodexBar 官方组件。感谢 CodexBar 提供稳定的额度数据入口。

## License

[MIT](LICENSE)
