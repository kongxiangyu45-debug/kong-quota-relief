# kong 的额度焦虑缓解器

一个放在系统状态栏里的本地小工具，帮你看懂 **Codex 额度、近期任务、Token 处理量和 WorkBuddy 积分**。

它不会替你增加额度，但能让“额度到底花到哪里了”这件事没那么玄学。

> 这是社区项目，不是 OpenAI、腾讯、CodexBar 或 WorkBuddy 的官方产品。

## 直接下载

请在 [最新版本下载页](https://github.com/kongxiangyu45-debug/kong-quota-relief/releases/latest) 选择自己的系统：

- [Mac 版（Apple 芯片）](https://github.com/kongxiangyu45-debug/kong-quota-relief/releases/latest/download/kong-quota-relief-macos-arm64.zip)
- [Windows 版（64 位 x64）](https://github.com/kongxiangyu45-debug/kong-quota-relief/releases/latest/download/kong-quota-relief-windows-x64.zip)

不会区分版本时：近几年的 M 系列 Mac 下载 Mac 版；普通 Windows 10/11 电脑下载 Windows 版。

## 它能做什么

| 功能 | Mac | Windows |
| --- | --- | --- |
| 查看 Codex 当前返回的额度窗口和重置倒计时 | 支持 | 支持 |
| 查看近期 Codex 任务和 Token 处理量 | 支持 | 支持 |
| 判断任务正在运行、刚完成或已经沉寂 | 支持 | 支持 |
| 点击任务回到对应对话 | 支持 | 支持 |
| 查看 WorkBuddy 剩余积分和近期任务消耗 | 支持 | 支持 |
| 生成本地 HTML 用量报告 | 支持 | 支持 |
| 深度复盘高消耗任务 | 支持 | 暂不支持 |

## Mac 怎么用

1. 先安装并登录 Codex。
2. 安装 [CodexBar](https://github.com/steipete/CodexBar)。Mac 版通过 CodexBar 读取服务器实际返回的额度窗口。
3. 下载并解压 `kong-quota-relief-macos-arm64.zip`。
4. 把应用放进“应用程序”，然后打开。
5. 如果 macOS 拦截，在 Finder 中按住 Control 点击应用，选择“打开”；也可以到“系统设置 → 隐私与安全性”确认打开。

Mac 版要求 macOS 14 或更高版本，目前只提供 Apple 芯片构建。

## Windows 怎么用

1. 先安装并登录 Codex；需要 WorkBuddy 数据时，也要安装并登录 WorkBuddy。
2. 下载并解压 `kong-quota-relief-windows-x64.zip`。
3. 双击 `kong的额度焦虑缓解器.exe`。
4. 程序不会弹出大窗口，它会出现在右下角托盘里；没看到时点击右下角的 `^`。
5. 如果 Windows SmartScreen 提示来源未知，请确认下载地址是本仓库，再选择“更多信息 → 仍要运行”。

Windows 版支持 Windows 10/11 64 位系统，不需要安装 .NET。

## 数字怎么看

- **额度百分比**来自平台当前实际返回的窗口；缺少的窗口不会拿旧缓存补齐。
- **普通 Codex 与 Spark**可能使用不同额度，不能把两个百分比直接相加。
- **Token**来自本机任务记录，表示模型处理量，不等于 API 账单金额。
- **任务额度归因**只在证据足够时才显示；并行任务或中途切换任务时，工具宁愿写“无法确认”，也不会硬猜。
- **任务进度**有明确计划时按步骤显示；没有计划时只做带“约”字的阶段估算。

## 隐私

任务标题、Token、进度和报告都在本机处理，不会上传到本项目作者的服务器，也没有广告或遥测。

为了读取余额，应用会使用当前电脑已有的登录状态访问对应平台的官方接口：

- Codex 官方用量接口；
- WorkBuddy 官方积分接口；
- Mac 版的 Codex 额度由本机 CodexBar 读取。

应用不会把登录令牌写进报告。提交问题时，请不要上传原始 `~/.codex` 日志；它们可能包含提示词、文件路径和项目内容。

## 已知限制

- Codex 和 WorkBuddy 的本地数据库属于内部格式，平台更新后可能需要同步适配。
- Mac 和 Windows 安装包目前没有购买商业签名证书，首次运行可能出现系统提醒。
- Windows ARM、Intel Mac 和 Linux 暂未提供成品安装包。
- 额度是平台的动态规则，最终以对应平台账号页面为准。

## 从源码构建

Mac 版需要 Swift 6：

```bash
./Scripts/verify.sh
./Scripts/install.sh
```

Windows 版需要 Go 1.22 或更高版本：

```bash
./Scripts/package-windows.sh 0.3.0
```

## 反馈问题

可以使用仓库的 [Issues](https://github.com/kongxiangyu45-debug/kong-quota-relief/issues)。请隐藏任务标题、用户名、本机路径和账号信息，只提供脱敏截图。

## 许可证

[MIT License](LICENSE)
