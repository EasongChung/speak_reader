<#
.SYNOPSIS
G4 离线翻译模型下载器(Windows PowerShell 5.1+)。

.DESCRIPTION
按语向分别下载: 每个 group(语向)一个 zip 包。默认下载清单里的全部语向,
可用 -Groups "zhen,enzh" 只取指定语向。

每个语向两阶段:
  1. 整包优先 —— 下载该语向的 zip, 校验压缩包 SHA-256, 解压后校验该组文件。
  2. 逐文件回退 —— 整包失败时, 从 upstream_url 逐个下载 .gz, 解压后校验。
已存在且校验通过的文件跳过, 故可重复执行、断点续跑。

为什么模型不进仓库: 见 MANIFEST.json 的 $comment 与 README.md。

.PARAMETER Destination
下载目标目录。默认为本脚本所在目录。

.PARAMETER Groups
要下载的语向 group id, 逗号分隔。默认全部。

.PARAMETER VerifyOnly
只校验已有文件, 不下载。

.EXAMPLE
.\fetch_models.ps1

.EXAMPLE
.\fetch_models.ps1 -Destination D:\models -Groups zhen

.EXAMPLE
.\fetch_models.ps1 -VerifyOnly
#>
[CmdletBinding()]
param(
    [string]$Destination,
    [string]$Groups,
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

function Get-FileSha256 {
    param([string]$Path)
    (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower()
}

# 解压 zip 到目标目录。System.IO.Compression.ZipFile 是 .NET 自带。
function Expand-ZipArchive {
    param([string]$Source, [string]$TargetDir)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Source, $TargetDir)
}

# 解压单个 gzip 文件(逐文件回退路径用)。
function Expand-GzipFile {
    param([string]$Source, [string]$Target)
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

# 解析 Groups 参数: 空 = 全部
$wantGroups = @()
if ($Groups) {
    $wantGroups = ($Groups -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}
if ($wantGroups.Count -eq 0) {
    $wantGroups = @($manifest.groups | ForEach-Object { $_.id })
}

# 某 group 的全部文件是否已就位且正确
function Test-GroupReady {
    param([string]$GroupId)
    $bad = 0
    foreach ($group in ($manifest.groups | Where-Object { $_.id -eq $GroupId })) {
        foreach ($entry in $group.files) {
            $f = Join-Path $Destination ($entry.path -replace '/', '\')
            if (-not (Test-Path $f) -or (Get-FileSha256 $f) -ne $entry.sha256) { $bad++ }
        }
    }
    return ($bad -eq 0)
}

$total = 0
$ok = 0
$failed = @()

foreach ($gid in $wantGroups) {
    $total++
    $group = $manifest.groups | Where-Object { $_.id -eq $gid } | Select-Object -First 1
    if (-not $group) {
        Write-Host "[未知语向] $gid"
        $failed += $gid
        continue
    }

    if (Test-GroupReady $gid) {
        Write-Host "[跳过] $gid (文件已全部就位且校验通过)"
        $ok++
        continue
    }
    if ($VerifyOnly) {
        Write-Host "[缺失/损坏] $gid"
        $failed += $gid
        continue
    }

    # ── 整包优先 ──
    $archiveGot = $false
    if ($group.archive) {
        $tmpDir = Join-Path $Destination '.models_tmp'
        if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        $zipPath = Join-Path $tmpDir 'models.zip'

        Write-Host "[下载] $gid 整包"
        Write-Host "       <- $($group.archive.url)"
        try {
            Invoke-WebRequest -Uri $group.archive.url -OutFile $zipPath -UseBasicParsing
            if (-not $group.archive.sha256_zip -or
                (Get-FileSha256 $zipPath) -eq $group.archive.sha256_zip) {
                Expand-ZipArchive -Source $zipPath -TargetDir $tmpDir

                $bad = $false
                foreach ($entry in $group.files) {
                    $rel = $entry.path -replace '/', '\'
                    $f = Join-Path $tmpDir $rel
                    if (-not (Test-Path $f)) {
                        Write-Host "       [缺失] $($entry.path) (压缩包内无此文件)"
                        $bad = $true
                        continue
                    }
                    if ((Get-FileSha256 $f) -ne $entry.sha256) {
                        Write-Host "       [校验失败] $($entry.path)"
                        $bad = $true
                    }
                }

                if (-not $bad) {
                    foreach ($entry in $group.files) {
                        $rel = $entry.path -replace '/', '\'
                        $target = Join-Path $Destination $rel
                        $targetDir = Split-Path -Parent $target
                        if (-not (Test-Path $targetDir)) {
                            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
                        }
                        Move-Item (Join-Path $tmpDir $rel) $target -Force
                    }
                    $archiveGot = $true
                } else {
                    Write-Host "       整包内容校验失败, 回退逐文件"
                }
            } else {
                Write-Host "       [压缩包 SHA-256 校验失败], 回退逐文件"
            }
        } catch {
            Write-Host "       整包下载失败($($_.Exception.Message)), 回退逐文件"
        }
        if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force }
    }

    if ($archiveGot) {
        Write-Host "$gid 整包下载并校验通过"
        $ok++
        continue
    }

    # ── 逐文件回退 ──
    $groupFailed = @()
    foreach ($entry in $group.files) {
        $target = Join-Path $Destination ($entry.path -replace '/', '\')
        $targetDir = Split-Path -Parent $target
        if (-not (Test-Path $targetDir)) {
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
        }
        if ((Test-Path $target) -and (Get-FileSha256 $target) -eq $entry.sha256) {
            continue
        }

        $url = $entry.upstream_url
        $gzPath = "$target.gz"
        Write-Host "[下载] $($entry.path)"
        Write-Host "       <- $url"
        $got = $false
        try {
            Invoke-WebRequest -Uri $url -OutFile $gzPath -UseBasicParsing
            Expand-GzipFile -Source $gzPath -Target $target
            Remove-Item $gzPath -Force
            if ((Get-FileSha256 $target) -eq $entry.sha256) {
                Write-Host "       [ok] 校验通过"
                $got = $true
            } else {
                Write-Host "       [校验失败] 期望 $($entry.sha256)"
                Remove-Item $target -Force
            }
        } catch {
            Write-Host "       下载/解压失败($($_.Exception.Message))"
            if (Test-Path $gzPath) { Remove-Item $gzPath -Force }
            if (Test-Path $target) { Remove-Item $target -Force }
        }
        if (-not $got) { $groupFailed += $entry.path }
    }

    if ($groupFailed.Count -eq 0) { $ok++ } else { $failed += $gid }
}

Write-Host ''
Write-Host "=== 完成: $ok/$total 个语向"
if ($failed.Count -gt 0) {
    Write-Host '失败语向:'
    $failed | ForEach-Object { Write-Host "  $_" }
    Write-Host ''
    Write-Host '整包与上游均不可用时, 可手工从上游取(见 MANIFEST.json 的 upstream_url)。'
    exit 1
}
Write-Host '全部语向文件校验通过, 可直接经 App 导入对应 zip。'
