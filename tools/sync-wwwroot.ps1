# 同步 C# 参考工程的第三方静态资源到本项目 wwwroot
#
# 约定（与 Rust 版一致）：
#   - `wwwroot/static` 是 **825 个文件 / 24.6 MB 的第三方前端资产**（UEditor、layer、layui、
#     jQuery UI、swiper 等），**不入库**，也不编译进二进制；
#   - 它是运行期资源目录：运营可改、可单独替换；
#   - 需要单文件部署时再显式嵌入（本库暂未提供嵌入表，按需扩展）。
#
# 用法：
#   .\tools\sync-wwwroot.ps1
#   .\tools\sync-wwwroot.ps1 -Source 'D:\Other\wwwroot'
#   .\tools\sync-wwwroot.ps1 -Force     # 覆盖已存在文件

[CmdletBinding()]
param(
    [string]$Source = 'G:\Code\Pek.FrameWork\Pek.DsMallUI\Pek.DsMallUI\wwwroot',
    [string]$Target = '',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $Target) { $Target = Join-Path $root 'wwwroot' }

if (-not (Test-Path $Source)) {
    Write-Host "源目录不存在：$Source"
    Write-Host '请用 -Source 指定 C# 参考工程的 wwwroot 目录。'
    exit 2
}

Write-Host "源：$Source"
Write-Host "目标：$Target"

$copied = 0
$skipped = 0

Get-ChildItem -Path $Source -Recurse -File | ForEach-Object {
    $relative = $_.FullName.Substring($Source.Length).TrimStart('\', '/')
    $targetPath = Join-Path $Target $relative
    $targetDir = Split-Path -Parent $targetPath
    if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Force -Path $targetDir | Out-Null }

    $needCopy = $true
    if (-not $Force -and (Test-Path $targetPath)) {
        $existing = Get-Item $targetPath
        if ($existing.Length -eq $_.Length -and $existing.LastWriteTimeUtc -ge $_.LastWriteTimeUtc) {
            $needCopy = $false
        }
    }

    if ($needCopy) {
        Copy-Item -LiteralPath $_.FullName -Destination $targetPath -Force
        $script:copied++
    }
    else {
        $script:skipped++
    }
}

Write-Host "完成：复制 $copied 个，跳过 $skipped 个（增量同步）"
exit 0
