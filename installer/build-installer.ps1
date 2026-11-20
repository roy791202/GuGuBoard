<#
.SYNOPSIS
  從 repo 收檔、stage、呼叫 makensis 產出 GuGuBoard-Setup.exe（可重現）。
.DESCRIPTION
  單一事實來源為 installer\manifest.psd1。本腳本不含任何硬編碼檔案清單。
.EXAMPLE
  .\installer\build-installer.ps1
  .\installer\build-installer.ps1 -Version 1.0.0 -DryRun
#>
[CmdletBinding()]
param(
    # repo 根；預設為本腳本上一層
    [string]$Source   = '',
    # 輸出資料夾
    [string]$OutDir   = '',
    # makensis 執行檔
    [string]$MakeNsis = 'C:\Program Files (x86)\NSIS\makensis.exe',
    # 版本號；預設讀 package.json
    [string]$Version  = '',
    # 只列 stage 清單、不打包
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
function Say($m, $c = 'Gray') { Write-Host $m -ForegroundColor $c }

# 解析本腳本所在目錄（$PSScriptRoot 在某些呼叫方式下為空，退回 $MyInvocation）
$scriptDir = $PSScriptRoot
if (-not $scriptDir) { $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$repoRoot  = Split-Path -Parent $scriptDir
if (-not $Source) { $Source = $repoRoot }
if (-not $OutDir) { $OutDir = Join-Path $repoRoot 'depo' }

$Source = (Resolve-Path $Source).Path
$nsi    = Join-Path $scriptDir 'guguboard.nsi'
$manFile = Join-Path $scriptDir 'manifest.psd1'
if (-not (Test-Path $manFile)) { throw "找不到 manifest：$manFile" }
if (-not (Test-Path $nsi))     { throw "找不到 NSIS 腳本：$nsi" }
$man = Import-PowerShellDataFile -Path $manFile

# 版本
if (-not $Version) {
    $pkg = Join-Path $Source 'package.json'
    if (Test-Path $pkg) {
        try { $Version = (Get-Content $pkg -Raw | ConvertFrom-Json).version } catch {}
    }
    if (-not $Version) { $Version = '0.0.0' }
}
Say "GuGuBoard 安裝檔 build  版本=$Version" 'Cyan'
Say "  Source = $Source"
Say "  OutDir = $OutDir"

# ---- 乾淨的 stage 目錄 ----
$stage = Join-Path $env:TEMP 'guguboard-build-stage'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
$stageBoard  = Join-Path $stage 'board'
$stageSkills = Join-Path $stage 'skills'
New-Item -ItemType Directory -Force -Path $stageBoard, $stageSkills | Out-Null

$excludes = @($man.ExcludePatterns)
$optional = @($man.Optional)
$missing  = New-Object System.Collections.Generic.List[string]

function Strip-Excludes($root) {
    foreach ($pat in $excludes) {
        Get-ChildItem -Path $root -Recurse -Force -Filter $pat -ErrorAction SilentlyContinue |
            Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
    }
}

# ---- 板核心檔案 ----
foreach ($f in $man.BoardFiles) {
    $src = Join-Path $Source $f
    if (Test-Path $src) {
        Copy-Item $src -Destination $stageBoard -Force
    } elseif ($optional -contains $f) {
        $missing.Add($f) | Out-Null
    } else {
        throw "必要檔案缺失：$f（$src）"
    }
}
# ---- 板核心資料夾 ----
foreach ($d in $man.BoardDirs) {
    $src = Join-Path $Source $d
    if (Test-Path $src) {
        Copy-Item $src -Destination $stageBoard -Recurse -Force
    } else {
        throw "必要資料夾缺失：$d（$src）"
    }
}
Strip-Excludes $stageBoard

# ---- 技能 ----
$skillsRoot = Join-Path $Source $man.SkillsSource
foreach ($s in $man.Skills) {
    $src = Join-Path $skillsRoot $s
    if (-not (Test-Path $src)) { throw "技能缺失：$s（$src）" }
    Copy-Item $src -Destination $stageSkills -Recurse -Force
}
Strip-Excludes $stageSkills

# ---- 清單 ----
$boardCount = (Get-ChildItem $stageBoard -Recurse -File).Count
$skillCount = (Get-ChildItem $stageSkills -Recurse -File).Count
Say ""
Say "已 stage：board=$boardCount 檔、skills=$skillCount 檔" 'Green'
if ($missing.Count) { Say ("可選檔案缺（已略過）：" + ($missing -join ', ')) 'Yellow' }

if ($DryRun) {
    Say ""
    Say "=== DryRun：stage 內容 ===" 'Cyan'
    Get-ChildItem $stage -Recurse -File | ForEach-Object {
        Say ("  " + $_.FullName.Substring($stage.Length + 1))
    }
    Say ""
    Say "DryRun 結束，未打包。" 'Cyan'
    return
}

# ---- 打包 ----
if (-not (Test-Path $MakeNsis)) { throw "找不到 makensis：$MakeNsis（請安裝 NSIS 或用 -MakeNsis 指定）" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$outFile = Join-Path $OutDir "GuGuBoard-Setup-$Version.exe"
if (Test-Path $outFile) { Remove-Item $outFile -Force }

Say ""
Say "呼叫 makensis…" 'Cyan'
$args = @(
    "/DSTAGEDIR=$stage"
    "/DVERSION=$Version"
    "/DOUTFILE=$outFile"
    $nsi
)
& $MakeNsis @args
$nsisExit = $LASTEXITCODE
if ($nsisExit -ne 0) { throw "makensis 失敗，exit=$nsisExit" }

# ---- 驗證（對齊全域規則：建置後必須驗證）----
if (-not (Test-Path $outFile)) { throw "打包後找不到輸出：$outFile" }
$size = (Get-Item $outFile).Length
if ($size -le 0) { throw "輸出大小為 0：$outFile" }
$kb = [math]::Round($size / 1KB, 1)
Say ""
Say "✓ Verified: makensis 產出安裝檔" 'Green'
Say "  Output:  $outFile ($kb KB)" 'Green'
Say "  Result:  PASS" 'Green'
