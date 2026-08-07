<#
.SYNOPSIS
G4 离线翻译模型下载器(Windows PowerShell 5.1+)。

.DESCRIPTION
按 MANIFEST.json 的 sources 优先级依次尝试, 每个文件下载后立即校验 SHA-256,
校验不过就换下一个源。三个源全失败才判该文件失败。已存在且校验通过的文件跳过,
故可重复执行、断点续跑。

为什么模型不进仓库: 见 MANIFEST.json 的 $comment 与 README.md。

.PARAMETER Destination
下载目标目录。默认为本脚本所在目录。

.PARAMETER VerifyOnly
只校验已有文件, 不下载。

.EXAMPLE
.\fetch_models.ps1

.EXAMPLE
.\fetch_models.ps1 -Destination D:\models -VerifyOnly
#>
[CmdletBinding()]
param(
    [string]$Destination,
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$manifestPath = Join-Path $scriptDir 'MANIFEST.json'
if (-not $Destination) { $Destination = $scriptDir }

if (-not (Test-Path $manifestPath)) {
    Write-Error "缺少清单: $manifestPath"
    exit 1
}

$manifest = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

# 按 priority 排源。ConvertFrom-Json 给的是 PSCustomObject, 用 Sort-Object 排。
$sources = $manifest.sources | Sort-Object -Property priority

function Get-FileSha256 {
    param([string]$Path)
    (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower()
}

function Expand-GzipFile {
    param([string]$Source, [string]$Target)
    # .NET 的 GZipStream 解压。避开对外部 gzip.exe 的依赖 ——
    # Windows 上不保证有, 而 System.IO.Compression 是 .NET Framework 自带。
    $input = [System.IO.File]::OpenRead($Source)
    try {
        $gzip = New-Object System.IO.Compression.GZipStream(
            $input, [System.IO.Compression.CompressionMode]::Decompress)
        try {
            $output = [System.IO.File]::Create($Target)
            try { $gzip.CopyTo($output) } finally { $output.Dispose() }
        } finally { $gzip.Dispose() }
    } finally { $input.Dispose() }
}

# TLS 1.2: PowerShell 5.1 默认可能仍用 TLS 1.0, 会连不上 HF/GCS。
[Net.ServicePointManager]::SecurityProtocol = `
    [Net.SecurityProtocolType]::Tls12 -bor [Net.ServicePointManager]::SecurityProtocol

$total = 0
$ok = 0
$failed = @()

foreach ($group in $manifest.groups) {
    foreach ($entry in $group.files) {
        $total++
        $target = Join-Path $Destination ($entry.path -replace '/', '\')
        $targetDir = Split-Path -Parent $target
        if (-not (Test-Path $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }

        if ((Test-Path $target) -and (Get-FileSha256 $target) -eq $entry.sha256) {
            Write-Host "[跳过] $($entry.path) (已存在且校验通过)"
            $ok++
            continue
        }

        if ($VerifyOnly) {
            Write-Host "[缺失/损坏] $($entry.path)"
            $failed += $entry.path
            continue
        }

        $got = $false
        foreach ($source in $sources) {
            if ($source.id -eq 'upstream') {
                $url = $entry.upstream_url
            } else {
                $url = $source.url_template.Replace('{path}', $entry.path).Replace('{name}', $entry.name)
            }

            Write-Host "[下载] $($entry.path)"
            Write-Host "       <- $url"
            $gzPath = "$target.gz"
            try {
                # -UseBasicParsing: 5.1 上避免依赖 IE 引擎
                Invoke-WebRequest -Uri $url -OutFile $gzPath -UseBasicParsing
            } catch {
                Write-Host "       下载失败($($_.Exception.Message)), 换下一个源"
                if (Test-Path $gzPath) { Remove-Item $gzPath -Force }
                continue
            }

            try {
                Expand-GzipFile -Source $gzPath -Target $target
            } catch {
                Write-Host "       解压失败, 换下一个源"
                if (Test-Path $gzPath) { Remove-Item $gzPath -Force }
                if (Test-Path $target) { Remove-Item $target -Force }
                continue
            }
            Remove-Item $gzPath -Force

            $actual = Get-FileSha256 $target
            if ($actual -ne $entry.sha256) {
                Write-Host "       [校验失败] 期望 $($entry.sha256)"
                Write-Host "                   实际 $actual"
                Remove-Item $target -Force
                continue
            }

            Write-Host "       [ok] 校验通过"
            $got = $true
            break
        }

        if ($got) { $ok++ } else { $failed += $entry.path }
    }
}

Write-Host ''
Write-Host "=== 完成: $ok/$total"
if ($failed.Count -gt 0) {
    Write-Host '失败文件:'
    $failed | ForEach-Object { Write-Host "  $_" }
    Write-Host ''
    Write-Host '三个源均不可用时, 可手工从上游取(见 MANIFEST.json 的 upstream_url)。'
    exit 1
}
Write-Host '全部文件校验通过, 可直接经 App 的 SAF 目录选择导入。'
