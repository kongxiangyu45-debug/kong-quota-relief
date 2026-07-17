# kong的额度焦虑缓解器 Windows 版

Windows 10/11 x64 托盘测试版。程序直接读取当前用户自己的 Codex 和 WorkBuddy 数据，不包含开发者的账号或用量记录。

## 功能

- 从 Codex 官方用量接口读取当前实际返回的额度窗口。
- 自动沿用 Windows 系统代理、PAC 或 `HTTP_PROXY` / `HTTPS_PROXY`，避免 Codex 任务能读取但在线额度连接失败。
- 从 `~/.codex/state_*.sqlite` 读取近期 Codex 任务和 Token 处理量。
- 从 WorkBuddy 官方接口读取剩余总积分。
- 从 `~/.workbuddy/workbuddy.db` 读取最近一次和任务累计积分。
- 点击任务直接打开 `codex://threads/<id>` 或 `workbuddy://chat/<id>`。
- 每分钟自动刷新，并可生成本地 HTML 用量报告。

## 构建

需要 Go 1.22 或更新版本：

```bash
./build-windows.sh
```

输出文件：`dist/kong的额度焦虑缓解器.exe`

程序只依赖 Windows 10/11 自带的系统 DLL，不需要安装 .NET。
