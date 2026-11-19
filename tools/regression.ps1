# 一键回归（Windows 宿主 · PowerShell 5.1）
#
# 口径（与生态各仓一致）：
#   - 串起「构建 → 单元测试 → 冒烟」，退出码 0 = 全绿、1 = 有失败；
#   - 报告落 artifacts/regression/report-<时间戳>.txt；
#   - 调外部命令后必须判 $LASTEXITCODE（PS 5.1 的 $ErrorActionPreference='Stop'
#     会把外部程序写 stderr 当成终止错误，脚本会被炸掉还不给提示）；
#   - 含中文的 .ps1 必须存 UTF-8 with BOM。
#
# 用法：
#   .\tools\regression.ps1              # 构建 + 单元测试 + 冒烟
#   .\tools\regression.ps1 -SkipSmoke   # 只跑构建与单元测试

[CmdletBinding()]
param(
    [switch]$SkipSmoke,
    [int]$Port = 18099,
    # 测试数基线（只能抬高；降低必须在 docs/决策记录.md 写明依据）
    [int]$MinTests = 94
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportDir = Join-Path $root 'artifacts/regression'
New-Item -ItemType Directory -Force -Path $reportDir | Out-Null
$reportPath = Join-Path $reportDir "report-$stamp.txt"

$script:results = New-Object System.Collections.Generic.List[string]
$script:failed = 0

function Write-Log([string]$text) {
    $line = "$(Get-Date -Format 'HH:mm:ss') $text"
    $script:results.Add($line)
    Write-Host $line
}

function Pass([string]$name, [string]$detail = '') {
    Write-Log ("PASS  $name" + $(if ($detail) { "  ($detail)" } else { '' }))
}

function Fail([string]$name, [string]$detail) {
    $script:failed++
    Write-Log "FAIL  $name  → $detail"
}

function Skip([string]$name, [string]$reason) {
    Write-Log "SKIP  $name  → $reason"
}

# 外部命令封装：临时 Continue → 执行 → 取退出码与输出（PS 5.1 必需）
function Invoke-External([string]$exe, [string[]]$arguments) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $exe @arguments 2>&1 | ForEach-Object { "$_" }
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

Write-Log "== Pek.ZDsMallUI 回归开始（$root）=="

# ————— 1. 构建 —————
$build = Invoke-External 'zig' @('build')
if ($build.ExitCode -eq 0) { Pass 'zig build' } else { Fail 'zig build' "exit=$($build.ExitCode)"; Write-Log $build.Output }

# ————— 2. 单元测试（--summary all 会输出统计；失败时才有细节）—————
$test = Invoke-External 'zig' @('build', 'test', '--summary', 'all')
if ($test.ExitCode -ne 0) {
    Fail 'zig build test' "exit=$($test.ExitCode)"
    Write-Log $test.Output
} else {
    $match = [regex]::Match($test.Output, '(\d+) tests passed')
    if ($match.Success) {
        $count = [int]$match.Groups[1].Value
        if ($count -lt $MinTests) {
            Fail 'zig build test' "测试数 $count 低于基线 $MinTests（降低基线请先写决策记录）"
        }
        else {
            Pass 'zig build test' "$count tests passed（基线 $MinTests）"
        }
    }
    else {
        # 缓存命中时 zig 可能不输出统计；退回只看退出码
        Pass 'zig build test' 'exit=0（缓存命中，无统计输出）'
    }
}

# ————— 3. 冒烟（起服务 → HTTP 断言 → 停服务）—————
if ($SkipSmoke) {
    Skip 'HTTP 冒烟' '按参数跳过（-SkipSmoke）'
} else {
    $exe = Join-Path $root 'zig-out/bin/zdsmallui-admin.exe'
    if (-not (Test-Path $exe)) {
        Fail 'HTTP 冒烟' "缺少可执行文件：$exe（先跑 zig build）"
    }
    else {
        $workDir = Join-Path $root '.zig-cache/regression'
        New-Item -ItemType Directory -Force -Path $workDir | Out-Null

        # 示例程序把视图落地到 `.zig-cache/zdsmallui-example`（只补缺失、不覆盖），
        # 回归前先清掉，保证本次断言比对的是**当前内置模板**而不是上一轮的旧副本。
        # 示例程序把视图落地到 `.zig-cache/zdsmallui-example`（只补缺失、不覆盖），
        # 回归前先清掉，保证本次断言比对的是**当前内置视图/静态文件**而不是上一轮的旧副本。
        $exampleBase = Join-Path $root '.zig-cache/zdsmallui-example'
        foreach ($sub in @('Views', 'Areas')) {
            $target = Join-Path $exampleBase $sub
            if (Test-Path $target) { Remove-Item -Path $target -Recurse -Force }
        }
        foreach ($file in @('wwwroot/static/admin/css/admin-ui.css', 'wwwroot/static/admin/js/login-md5.js', 'wwwroot/static/admin/js/admin-config.js')) {
            $target = Join-Path $exampleBase $file
            if (Test-Path $target) { Remove-Item -Path $target -Force }
        }

        $proc = $null
        $portBusy = $false
        try {
            $probe = New-Object System.Net.Sockets.TcpClient
            $probe.Connect('127.0.0.1', $Port)
            $probe.Close()
            $portBusy = $true
        }
        catch {
            $portBusy = $false
        }

        if ($portBusy) {
            Fail 'HTTP 冒烟' "端口 127.0.0.1:$Port 已被占用（很可能是上一次的 zdsmallui-admin 还在跑）：先停掉它或改 -Port，本次冒烟未执行"
        }
        else {
        $proc = Start-Process -FilePath $exe -ArgumentList @("$Port", 'Biz') -WorkingDirectory $root -PassThru -WindowStyle Hidden
        $ready = $false
        for ($i = 0; $i -lt 60; $i++) {
            try {
                $client = New-Object System.Net.Sockets.TcpClient
                $client.Connect('127.0.0.1', $Port)
                $client.Close()
                $ready = $true
                break
            }
            catch {
                Start-Sleep -Milliseconds 200
            }
        }

        if (-not $ready) {
            Fail 'HTTP 冒烟' "服务未在 12 秒内监听 127.0.0.1:$Port"
            if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
        }
        else {
            $base = "http://127.0.0.1:$Port"
            try {
                # 3.1 页面与配置
                foreach ($item in @(
                        @{ Name = 'GET /biz/home/index'; Url = "$base/biz/home/index"; Must = '快捷入口' },
                        @{ Name = 'GET /biz/home/index（退出链接）'; Url = "$base/biz/home/index"; Must = '/biz/login/logout' },
                        @{ Name = 'GET /biz/config/index'; Url = "$base/biz/config/index"; Must = '站点设置' },
                        @{ Name = 'GET /biz/login/index'; Url = "$base/biz/login/index"; Must = '密码' },
                        @{ Name = 'GET /biz/login/index（前端 MD5 脚本）'; Url = "$base/biz/login/index"; Must = '/static/admin/js/login-md5.js' },
                        @{ Name = 'GET /biz/login/index（回填 returnUrl）'; Url = "$base/biz/login/index?returnUrl=%2Fbiz%2Fconfig%2Findex"; Must = 'value="/biz/config/index"' },
                        @{ Name = 'GET /biz/home/index.html（伪静态）'; Url = "$base/biz/home/index.html"; Must = '快捷入口' },
                        @{ Name = 'GET /biz/config/index.html（伪静态）'; Url = "$base/biz/config/index.html"; Must = '站点设置' },
                        @{ Name = 'GET /biz/login/index（参考版式）'; Url = "$base/biz/login/index"; Must = 'login_body' },
                        @{ Name = 'GET /static/admin/css/admin.css（参考皮肤）'; Url = "$base/static/admin/css/admin.css"; Must = 'ncap-form-default' },
                        @{ Name = 'GET /static/admin/js/login-md5.js'; Url = "$base/static/admin/js/login-md5.js"; Must = 'dsmalluiMd5' },
                        @{ Name = 'GET /fileuploader?action=config'; Url = "$base/fileuploader?action=config"; Must = 'imageActionName' }
                    )) {
                    try {
                        $bytes = (New-Object System.Net.WebClient).DownloadData($item.Url)
                        $text = [Text.Encoding]::UTF8.GetString($bytes)
                        if ($text.Contains($item.Must)) { Pass $item.Name ("$($bytes.Length) bytes") }
                        else { Fail $item.Name "响应缺少关键字 $($item.Must)" }
                    }
                    catch {
                        Fail $item.Name $_.Exception.Message
                    }
                }

                # 伪静态不得“命中一切”：不存在的页面加后缀仍然 404
                $pseudoMissing = Invoke-External 'curl.exe' @('-s', '-o', 'NUL', '-w', '%{http_code}', "$base/biz/home/nope.html")
                if ($pseudoMissing.Output -match '404') { Pass 'GET /biz/home/nope.html（伪静态未命中→404）' }
                else { Fail 'GET /biz/home/nope.html（伪静态未命中→404）' "http=$($pseudoMissing.Output)" }

                # 3.2 multipart 上传（curl 10 自带；-F 走标准多段表单）
                $png = Join-Path $workDir 'regression.png'
                [IO.File]::WriteAllBytes($png, [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x52, 0x45, 0x47, 0x52))
                $upload = Invoke-External 'curl.exe' @('-s', '-F', "upfile=@$png", "$base/fileuploader?action=uploadimage")
                if ($upload.ExitCode -eq 0 -and $upload.Output.Contains('"state":"SUCCESS"')) {
                    Pass 'POST /fileuploader?action=uploadimage'
                    $urlMatch = [regex]::Match($upload.Output, '"url":"([^"]+)"')
                    $uploadedUrl = $urlMatch.Groups[1].Value

                    # 3.3 列表 + 下载（含 Content-Disposition）
                    $list = Invoke-External 'curl.exe' @('-s', "$base/fileuploader?action=listimage&start=0&size=10")
                    if ($list.Output.Contains('"total":') -and $list.Output.Contains('/upload/')) {
                        Pass 'GET /fileuploader?action=listimage'
                    }
                    else { Fail 'GET /fileuploader?action=listimage' $list.Output }

                    if ($uploadedUrl) {
                        $downloadUrl = "$base/Upload/downloads/" + $uploadedUrl.TrimStart('/').Substring('upload/'.Length)
                        $headers = Invoke-External 'curl.exe' @('-s', '-D', '-', '-o', 'NUL', $downloadUrl)
                        if ($headers.Output -match 'content-disposition: attachment') {
                            Pass 'GET /Upload/downloads/*' '含 Content-Disposition'
                        }
                        else { Fail 'GET /Upload/downloads/*' $headers.Output }
                    }
                    else { Fail 'GET /Upload/downloads/*' '上传响应没有 url 字段' }
                }
                else {
                    Fail 'POST /fileuploader?action=uploadimage' $upload.Output
                }

                # 3.4 保存设置（表单）+ 回读
                $save = Invoke-External 'curl.exe' @('-s', '-o', 'NUL', '-w', '%{http_code}', '-d', 'SiteName=RegressionShop&SeoTitle=RegressionTitle', "$base/biz/config/updatebase")
                if ($save.Output -match '200') {
                    $configBytes = (New-Object System.Net.WebClient).DownloadData("$base/biz/config/index")
                    $configText = [Text.Encoding]::UTF8.GetString($configBytes)
                    if ($configText.Contains('RegressionShop')) { Pass 'POST /biz/config/updatebase' '回读命中' }
                    else { Fail 'POST /biz/config/updatebase' '回读未命中 RegressionShop' }
                    if ($configText.Contains('/static/admin/css/admin.css')) { Pass 'GET /biz/config/index（复用参考样式）' }
                    else { Fail 'GET /biz/config/index（复用参考样式）' '未引用 admin.css' }
                    if ($configText.Contains('ncap-form-default')) { Pass 'GET /biz/config/index（参考版式类）' }
                    else { Fail 'GET /biz/config/index（参考版式类）' '未使用 ncap-form-default' }
                }
                else { Fail 'POST /biz/config/updatebase' "http=$($save.Output)" }

                # Prompt 页：meta refresh 自动返回（Razor 子集下 `@if` 块内不能写 JS 花括号，
                # 否则页面上会漏出孤立的 `}`）
                $prompt = Invoke-External 'curl.exe' @('-s', '-d', 'SiteName=PromptCheck', "$base/biz/config/updatebase")
                if ($prompt.Output.Contains('meta http-equiv="refresh"') -and -not $prompt.Output.Contains('1500')) {
                    Pass 'POST /biz/config/updatebase（Prompt 页自动返回）'
                }
                else { Fail 'POST /biz/config/updatebase（Prompt 页自动返回）' $prompt.Output }

                # 3.5 登录（成功 302 / 失败 200）
                $loginOk = Invoke-External 'curl.exe' @('-s', '-o', 'NUL', '-w', '%{http_code}', '-d', 'UserName=admin&Password=admin123', "$base/biz/login/login")
                if ($loginOk.Output -match '302') { Pass 'POST /biz/login/login（正确口令）' }
                else { Fail 'POST /biz/login/login（正确口令）' "http=$($loginOk.Output)" }

                # 前端 MD5 传输：md5("admin123") = 0192023a7bbd73250516f069df18b500（与 C#/Rust 同口径）
                $loginMd5 = Invoke-External 'curl.exe' @('-s', '-o', 'NUL', '-w', '%{http_code}', '-d', 'UserName=admin&Password=0192023a7bbd73250516f069df18b500', "$base/biz/login/login")
                if ($loginMd5.Output -match '302') { Pass 'POST /biz/login/login（前端 MD5 口令）' }
                else { Fail 'POST /biz/login/login（前端 MD5 口令）' "http=$($loginMd5.Output)" }

                $loginBad = Invoke-External 'curl.exe' @('-s', '-o', 'NUL', '-w', '%{http_code}', '-d', 'UserName=admin&Password=wrong', "$base/biz/login/login")
                if ($loginBad.Output -match '200') { Pass 'POST /biz/login/login（错误口令）' }
                else { Fail 'POST /biz/login/login（错误口令）' "http=$($loginBad.Output)" }

                # 3.6 登录签发 JWT（Ajax）+ 两条通道都能验 + 登出立即失效
                $ajax = Invoke-External 'curl.exe' @('-s', '-D', '-', '-H', 'X-Requested-With: XMLHttpRequest', '-d', 'UserName=admin&Password=admin123', "$base/biz/login/login")
                $token = [regex]::Match($ajax.Output, '"token":"([^"]+)"').Groups[1].Value
                if ($token.Length -gt 20 -and $ajax.Output -match 'set-cookie: biz_token=') {
                    Pass 'POST /biz/login/login（下发 JWT）' "token=$($token.Length) 字符 + Set-Cookie"
                }
                else { Fail 'POST /biz/login/login（下发 JWT）' $ajax.Output }

                $statusBearer = Invoke-External 'curl.exe' @('-s', '-H', "Authorization: Bearer $token", "$base/biz/login/status")
                if ($statusBearer.Output.Contains('"authenticated":true')) { Pass 'GET /biz/login/status（Bearer）' }
                else { Fail 'GET /biz/login/status（Bearer）' $statusBearer.Output }

                $statusCookie = Invoke-External 'curl.exe' @('-s', '-H', "Cookie: biz_token=$token", "$base/biz/login/status")
                if ($statusCookie.Output.Contains('"authenticated":true')) { Pass 'GET /biz/login/status（Cookie）' }
                else { Fail 'GET /biz/login/status（Cookie）' $statusCookie.Output }

                $logout = Invoke-External 'curl.exe' @('-s', '-D', '-', '-o', 'NUL', '-H', "Authorization: Bearer $token", "$base/biz/login/logout")
                if ($logout.Output -match 'Max-Age=0') { Pass 'GET /biz/login/logout（清 Cookie）' }
                else { Fail 'GET /biz/login/logout（清 Cookie）' $logout.Output }

                $statusAfter = Invoke-External 'curl.exe' @('-s', '-H', "Authorization: Bearer $token", "$base/biz/login/status")
                if ($statusAfter.Output.Contains('"authenticated":false')) { Pass 'GET /biz/login/status（登出后令牌失效）' }
                else { Fail 'GET /biz/login/status（登出后令牌失效）' $statusAfter.Output }

                # 3.7 未支持动作（按 UTF-8 解码后断言，终端编码不影响结论）
                try {
                    $unknownBytes = (New-Object System.Net.WebClient).DownloadData("$base/fileuploader?action=nope")
                    $unknownText = [Text.Encoding]::UTF8.GetString($unknownBytes)
                    if ($unknownText.Contains('不支持的操作')) { Pass 'GET /fileuploader?action=nope' }
                    else { Fail 'GET /fileuploader?action=nope' $unknownText }
                }
                catch {
                    Fail 'GET /fileuploader?action=nope' $_.Exception.Message
                }
            }
            finally {
                if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
                Start-Sleep -Milliseconds 200
            }
        }
        }
    }
}

# ————— 汇总 —————
if ($script:failed -eq 0) {
    Write-Log "== 回归通过（FAIL=0）=="
} else {
    Write-Log "== 回归失败（FAIL=$($script:failed)）=="
}

$script:results | Set-Content -Path $reportPath -Encoding UTF8
Write-Host "报告：$reportPath"

if ($script:failed -gt 0) { exit 1 }
exit 0
