# WorkBuddy 一键诊断：kong 的额度焦虑缓解器

## 给电脑主人

把这个 Markdown 文件发送到出现问题的 Windows 电脑，然后在 WorkBuddy 新建一个任务，上传本文件，并发送下面这句话：

> 请完整读取并严格执行这个 MD。不要只解释内容，直接使用终端运行里面的诊断脚本。完成后把桌面生成的“kong额度焦虑缓解器-诊断报告.md”交给我。

整个过程只收集诊断信息，不会修改代理、账号、Codex、WorkBuddy 或系统设置。

---

## 给 WorkBuddy 的执行要求

请立即完成以下操作，不要反问用户：

1. 把下方 PowerShell 代码原样保存到临时文件：`$env:TEMP\kong_quota_diagnose.ps1`。
2. 使用下面的命令运行：

   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:TEMP\kong_quota_diagnose.ps1"
   ```

3. 确认桌面已经生成 `kong额度焦虑缓解器-诊断报告.md`，并确认文件不是空的。
4. 删除临时脚本 `$env:TEMP\kong_quota_diagnose.ps1`。
5. 不要尝试修复，不要更改系统代理，不要安装软件，不要退出用户正在使用的程序。
6. 最后只告诉用户报告文件的完整路径，并提醒用户把这个报告文件发回去。

## 必须执行的 PowerShell 代码

```powershell
$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$report = New-Object System.Collections.Generic.List[string]
$script:accessToken = ""
$script:accountID = ""
$script:fixedVersionFound = $false
$supportedHashes = @(
    "59c5d04579b5e5bbe0e54e97b1d90975c1db1d4358863aafae8ba12b69ecea6e",
    "252ba1f608539a3796d92b3ed82b582f156197364af5c0309d219fb1aa96eccc"
)

function Add-Line {
    param([string]$Text = "")
    $report.Add($Text)
}

function Add-Section {
    param([string]$Title)
    Add-Line ""
    Add-Line "## $Title"
    Add-Line ""
}

function Safe-Text {
    param($Value)
    if ($null -eq $Value) { return "" }
    $text = [string]$Value
    if ($env:USERPROFILE) {
        $text = $text -replace [regex]::Escape($env:USERPROFILE), "%USERPROFILE%"
    }
    if ($script:accessToken) {
        $text = $text.Replace($script:accessToken, "[已隐藏令牌]")
    }
    if ($script:accountID) {
        $text = $text.Replace($script:accountID, "[已隐藏账号ID]")
    }
    $text = $text -replace '(?i)Bearer\s+[^\s,;]+', 'Bearer [已隐藏令牌]'
    $text = $text -replace '(?i)(https?://)[^/@\s]+@', '$1[已隐藏凭据]@'
    $text = $text -replace 'eyJ[A-Za-z0-9_\-\.]{40,}', '[已隐藏疑似令牌]'
    $text = $text.Replace("`r", " ").Replace("`n", " ").Trim()
    if ($text.Length -gt 500) { $text = $text.Substring(0, 500) + "..." }
    return $text
}

function Exception-Text {
    param($Exception)
    if ($null -eq $Exception) { return "未知错误" }
    $current = $Exception
    while ($null -ne $current.InnerException) {
        $current = $current.InnerException
    }
    return Safe-Text $current.Message
}

function Yes-No {
    param([bool]$Value)
    if ($Value) { return "是" }
    return "否"
}

function Decode-JWTExpiry {
    param([string]$Token)
    try {
        $parts = $Token.Split('.')
        if ($parts.Count -lt 2) { return "不是可识别的 JWT" }
        $payload = $parts[1].Replace('-', '+').Replace('_', '/')
        while (($payload.Length % 4) -ne 0) { $payload += '=' }
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
        if ($null -eq $json.exp) { return "JWT 中没有过期时间" }
        $epoch = [DateTimeOffset]::FromUnixTimeSeconds([int64]$json.exp).ToLocalTime()
        return $epoch.ToString("yyyy-MM-dd HH:mm:ss zzz")
    } catch {
        return "JWT 过期时间解析失败"
    }
}

function Add-AppCandidate {
    param([string]$Path, [string]$Source)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    if ($script:seenApps.ContainsKey($Path.ToLowerInvariant())) { return }
    $script:seenApps[$Path.ToLowerInvariant()] = $true
    try {
        $file = Get-Item -LiteralPath $Path -ErrorAction Stop
        $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        $matches = $supportedHashes -contains $hash
        if ($matches) { $script:fixedVersionFound = $true }
        Add-Line "- 来源：$Source"
        Add-Line "  - 文件名：$($file.Name)"
        Add-Line "  - 大小：$($file.Length) 字节"
        Add-Line "  - 修改时间：$($file.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
        Add-Line "  - SHA256：$hash"
        Add-Line "  - 是否为受支持的公开版：$(Yes-No $matches)"
    } catch {
        Add-Line "- $Source：读取失败，$(Exception-Text $_.Exception)"
    }
}

function Test-TCP443 {
    try {
        $client = New-Object Net.Sockets.TcpClient
        $async = $client.BeginConnect("chatgpt.com", 443, $null, $null)
        $connected = $async.AsyncWaitHandle.WaitOne(8000, $false)
        if (-not $connected) {
            $client.Close()
            return "失败：8 秒内没有连上"
        }
        $client.EndConnect($async)
        $client.Close()
        return "成功"
    } catch {
        return "失败：$(Exception-Text $_.Exception)"
    }
}

function Invoke-UsageProbe {
    param(
        [string]$RouteName,
        [bool]$UseProxy,
        [string]$Token,
        [string]$Account
    )
    $result = [ordered]@{
        Route = $RouteName
        Status = 0
        Reason = ""
        Error = ""
        BodyLength = 0
        JSON = "否"
        TopKeys = ""
        Plan = ""
        HasRateLimit = "否"
        ExtraLimits = 0
    }
    $handler = $null
    $client = $null
    $request = $null
    $response = $null
    try {
        Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
        $handler = New-Object System.Net.Http.HttpClientHandler
        $handler.UseProxy = $UseProxy
        if (-not $UseProxy) { $handler.Proxy = $null }
        $client = New-Object System.Net.Http.HttpClient($handler)
        $client.Timeout = [TimeSpan]::FromSeconds(20)
        $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, "https://chatgpt.com/backend-api/wham/usage")
        $request.Headers.TryAddWithoutValidation("Accept", "application/json") | Out-Null
        if ($Token) {
            $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $Token)
        }
        if ($Account) {
            $request.Headers.TryAddWithoutValidation("ChatGPT-Account-Id", $Account) | Out-Null
        }
        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $result.Status = [int]$response.StatusCode
        $result.Reason = Safe-Text $response.ReasonPhrase
        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $result.BodyLength = $body.Length
        try {
            $json = $body | ConvertFrom-Json -ErrorAction Stop
            $result.JSON = "是"
            $result.TopKeys = (($json.PSObject.Properties.Name | Sort-Object) -join ", ")
            if ($null -ne $json.plan_type) { $result.Plan = Safe-Text $json.plan_type }
            if ($null -ne $json.rate_limit) { $result.HasRateLimit = "是" }
            if ($null -ne $json.additional_rate_limits) { $result.ExtraLimits = @($json.additional_rate_limits).Count }
        } catch {
            $result.JSON = "否"
        }
    } catch {
        $result.Error = Exception-Text $_.Exception
    } finally {
        if ($null -ne $response) { $response.Dispose() }
        if ($null -ne $request) { $request.Dispose() }
        if ($null -ne $client) { $client.Dispose() }
        if ($null -ne $handler) { $handler.Dispose() }
    }
    return [PSCustomObject]$result
}

Add-Line "# kong 额度焦虑缓解器诊断报告"
Add-Line ""
Add-Line "> 本报告由 WorkBuddy 执行诊断脚本自动生成。令牌、账号 ID、任务标题和用户名不会写入报告。"
Add-Line ""
Add-Line "- 生成时间：$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz'))"
Add-Line "- 诊断脚本版本：2026-07-16-v1"

Add-Section "1. Windows 基础环境"
try {
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    Add-Line "- 系统：$(Safe-Text $os.Caption)"
    Add-Line "- 版本：$(Safe-Text $os.Version)（Build $(Safe-Text $os.BuildNumber)）"
} catch {
    Add-Line "- 系统信息读取失败：$(Exception-Text $_.Exception)"
}
Add-Line "- 架构：$(Safe-Text $env:PROCESSOR_ARCHITECTURE)"
Add-Line "- PowerShell：$($PSVersionTable.PSVersion.ToString())"
try { Add-Line "- 时区：$((Get-TimeZone).Id)" } catch { Add-Line "- 时区：读取失败" }

Add-Section "2. 插件版本检查"
$script:seenApps = @{}
try {
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
        $path = ""
        try { $path = $_.Path } catch {}
        if ($path -and ([IO.Path]::GetFileName($path) -like "*额度焦虑缓解器*.exe" -or $_.ProcessName -like "*额度焦虑缓解器*")) {
            Add-AppCandidate $path "正在运行的程序"
        }
    }
} catch {}
foreach ($root in @([Environment]::GetFolderPath("Desktop"), (Join-Path $env:USERPROFILE "Downloads"))) {
    if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
    $folders = @($root)
    try { $folders += @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Select-Object -First 50 -ExpandProperty FullName) } catch {}
    foreach ($folder in $folders) {
        try {
            Get-ChildItem -LiteralPath $folder -File -Filter "*额度焦虑缓解器*.exe" -ErrorAction SilentlyContinue | ForEach-Object {
                Add-AppCandidate $_.FullName "桌面或下载目录"
            }
        } catch {}
    }
}
if ($script:seenApps.Count -eq 0) {
    Add-Line "- 没有找到正在运行或位于桌面/下载目录的插件 EXE。"
}
Add-Line "- 是否找到受支持的公开版：$(Yes-No $script:fixedVersionFound)"

Add-Section "3. Codex 本地登录和数据库"
$codexHome = Join-Path $env:USERPROFILE ".codex"
$authPath = Join-Path $codexHome "auth.json"
Add-Line "- .codex 目录存在：$(Yes-No (Test-Path -LiteralPath $codexHome))"
Add-Line "- auth.json 存在：$(Yes-No (Test-Path -LiteralPath $authPath))"
if (Test-Path -LiteralPath $authPath) {
    try {
        $authFile = Get-Item -LiteralPath $authPath -ErrorAction Stop
        $auth = Get-Content -LiteralPath $authPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        Add-Line "- auth.json 修改时间：$($authFile.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
        Add-Line "- 顶层字段：$(($auth.PSObject.Properties.Name | Sort-Object) -join ', ')"
        Add-Line "- 登录模式：$(Safe-Text $auth.auth_mode)"
        if ($null -ne $auth.tokens) {
            Add-Line "- tokens 字段：$(($auth.tokens.PSObject.Properties.Name | Sort-Object) -join ', ')"
            $script:accessToken = [string]$auth.tokens.access_token
            $script:accountID = [string]$auth.tokens.account_id
        }
        Add-Line "- Access Token 存在：$(Yes-No ([bool]$script:accessToken))"
        if ($script:accessToken) {
            Add-Line "- Access Token 长度：$($script:accessToken.Length)（只记录长度，不记录内容）"
            Add-Line "- Access Token 过期时间：$(Decode-JWTExpiry $script:accessToken)"
        }
        Add-Line "- Account ID 存在：$(Yes-No ([bool]$script:accountID))"
    } catch {
        Add-Line "- auth.json 解析失败：$(Exception-Text $_.Exception)"
    }
}
try {
    $databases = @(Get-ChildItem -LiteralPath $codexHome -File -Filter "state_*.sqlite" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    Add-Line "- state_*.sqlite 数量：$($databases.Count)"
    if ($databases.Count -gt 0) {
        Add-Line "- 最新数据库修改时间：$($databases[0].LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
        Add-Line "- 最新数据库大小：$($databases[0].Length) 字节"
    }
} catch {
    Add-Line "- 数据库检查失败：$(Exception-Text $_.Exception)"
}
Add-Line "- 进程管理记录存在：$(Yes-No (Test-Path -LiteralPath (Join-Path $codexHome 'process_manager\chat_processes.json')))"

Add-Section "4. Windows 代理设置"
foreach ($name in @("HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY")) {
    $value = [Environment]::GetEnvironmentVariable($name, "Process")
    if (-not $value) { $value = [Environment]::GetEnvironmentVariable($name, "User") }
    if (-not $value) { $value = [Environment]::GetEnvironmentVariable($name, "Machine") }
    if ($value) {
        Add-Line "- ${name}：$(Safe-Text $value)"
    } else {
        Add-Line "- ${name}：未设置"
    }
}
try {
    $internet = Get-ItemProperty -LiteralPath "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction Stop
    Add-Line "- 系统代理开关 ProxyEnable：$(Safe-Text $internet.ProxyEnable)"
    Add-Line "- 系统代理 ProxyServer：$(Safe-Text $internet.ProxyServer)"
    Add-Line "- PAC 地址 AutoConfigURL：$(Safe-Text $internet.AutoConfigURL)"
    Add-Line "- 自动检测 AutoDetect：$(Safe-Text $internet.AutoDetect)"
} catch {
    Add-Line "- Windows 当前用户代理读取失败：$(Exception-Text $_.Exception)"
}
try {
    $targetURI = [Uri]"https://chatgpt.com/backend-api/wham/usage"
    $defaultProxy = [System.Net.WebRequest]::DefaultWebProxy
    $resolvedProxy = $defaultProxy.GetProxy($targetURI)
    $isBypassed = $defaultProxy.IsBypassed($targetURI)
    Add-Line "- .NET 判断是否直连：$(Yes-No $isBypassed)"
    Add-Line "- .NET 为 ChatGPT 选择的地址：$(Safe-Text $resolvedProxy.AbsoluteUri)"
} catch {
    Add-Line "- .NET 系统代理解析失败：$(Exception-Text $_.Exception)"
}
try {
    Add-Line ""
    Add-Line "### WinHTTP 原始结果"
    Add-Line ""
    Add-Line '```text'
    (& netsh winhttp show proxy 2>&1) | ForEach-Object { Add-Line (Safe-Text $_) }
    Add-Line '```'
} catch {
    Add-Line "- WinHTTP 代理读取失败：$(Exception-Text $_.Exception)"
}

Add-Section "5. 基础网络"
try {
    $addresses = @([System.Net.Dns]::GetHostAddresses("chatgpt.com"))
    Add-Line "- DNS 解析：成功，得到 $($addresses.Count) 个地址（不记录具体 IP）"
} catch {
    Add-Line "- DNS 解析：失败，$(Exception-Text $_.Exception)"
}
Add-Line "- 直连 chatgpt.com:443：$(Test-TCP443)"

Add-Section "6. Codex 额度接口实测"
Add-Line "本节会使用本机已有令牌发起只读额度查询，但报告不会保存令牌、账号 ID 或接口原文。"
Add-Line ""
$directProbe = Invoke-UsageProbe "直连（不使用代理）" $false $script:accessToken $script:accountID
$systemProbe = Invoke-UsageProbe "Windows 系统代理" $true $script:accessToken $script:accountID
foreach ($probe in @($directProbe, $systemProbe)) {
    Add-Line "### $($probe.Route)"
    Add-Line ""
    if ($probe.Status -gt 0) {
        Add-Line "- HTTP 状态：$($probe.Status) $($probe.Reason)"
        Add-Line "- 返回长度：$($probe.BodyLength) 字符"
        Add-Line "- 可以解析为 JSON：$($probe.JSON)"
        Add-Line "- JSON 顶层字段：$(Safe-Text $probe.TopKeys)"
        Add-Line "- 套餐字段：$(Safe-Text $probe.Plan)"
        Add-Line "- 包含 rate_limit：$($probe.HasRateLimit)"
        Add-Line "- additional_rate_limits 数量：$($probe.ExtraLimits)"
    } else {
        Add-Line "- HTTP 状态：没有收到响应"
        Add-Line "- 精确错误：$(Safe-Text $probe.Error)"
    }
    Add-Line ""
}

Add-Section "7. 自动初判"
if (-not $script:accessToken) {
    Add-Line "- 结论：没有读到 Codex Access Token。优先检查 Codex 是否登录，或 Windows 版登录信息是否换了存储位置。"
} elseif (-not $script:fixedVersionFound) {
    Add-Line "- 结论：没有找到受支持的公开版。很可能仍在运行旧 EXE，或解压后点错了文件。"
} elseif ($systemProbe.Status -eq 200) {
    Add-Line "- 结论：登录和系统代理都能成功访问额度接口。若插件仍不显示，重点检查旧进程是否没有退出，或接口返回格式与插件解析规则不一致。"
} elseif ($directProbe.Status -eq 200 -and $systemProbe.Status -ne 200) {
    Add-Line "- 结论：直连成功，但 Windows 系统代理路径失败。插件不应强制使用当前系统代理，需要增加直连回退。"
} elseif ($directProbe.Status -in @(401, 403) -or $systemProbe.Status -in @(401, 403)) {
    Add-Line "- 结论：网络已经连到接口，但登录令牌或 Account ID 被拒绝。重点检查登录是否过期、账号是否切换。"
} elseif ($directProbe.Status -gt 0 -or $systemProbe.Status -gt 0) {
    Add-Line "- 结论：至少有一条线路能连到服务器，但接口返回非 200。请结合上面的 HTTP 状态判断。"
} else {
    Add-Line "- 结论：直连和系统代理都没有收到服务器响应。重点检查代理软件模式、防火墙、DNS 或本地代理端口。"
}

Add-Section "8. 隐私检查"
Add-Line "- 报告未写入 Access Token 内容。"
Add-Line "- 报告未写入 Account ID 内容。"
Add-Line "- 报告未读取或写入任务标题、聊天正文。"
Add-Line "- 报告未修改任何系统、代理或软件设置。"

$desktop = [Environment]::GetFolderPath("Desktop")
$reportPath = Join-Path $desktop "kong额度焦虑缓解器-诊断报告.md"
try {
    $report | Set-Content -LiteralPath $reportPath -Encoding UTF8 -Force
} catch {
    $reportPath = Join-Path $env:TEMP "kong额度焦虑缓解器-诊断报告.md"
    $report | Set-Content -LiteralPath $reportPath -Encoding UTF8 -Force
}
Write-Output "REPORT_PATH=$reportPath"
```

## 完成标准

只有在报告文件已经生成、文件大小大于 0，并且临时脚本已经删除后，任务才算完成。不要把报告全文直接贴在 WorkBuddy 对话里，避免传输过程中被截断。
