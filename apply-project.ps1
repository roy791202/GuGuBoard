<#
.SYNOPSIS  把 GuGuBoard 的專案層檔案（AI 工具規則、AI Hooks、Git Hooks、CI Guard）套用到某個專案 repo。
.DESCRIPTION
  檔案來源是安裝資料夾裡的 project-templates\。可重複執行：
  - 內容相同：略過。
  - 目標已有不同內容的檔案：先備份成 .bak（已有 .bak 時用 .<時間>.bak），再寫入；每個檔案都會列出來。
  - 上次由本工具寫入、之後沒被改過的檔案：直接更新（不需備份）。
  - .cursor\hooks.json、.claude\settings.json：保留原本設定，把本套件的 hook 合併進去（原檔備份 .bak）。
  預設不做 git commit；加 -Commit 才會把寫入的檔案 commit（hooks 照常執行）。
.EXAMPLE   .\apply-project.ps1 -RepoPath D:\AIAD -Plan
.EXAMPLE   .\apply-project.ps1 -RepoPath D:\AIAD -Tools Cursor,Claude,Hooks,GitHooks
.EXAMPLE   .\apply-project.ps1 -RepoPath D:\AIAD -Remove
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$RepoPath,
  [ValidateSet('Cursor','Codex','Claude','Copilot','Windsurf','Gemini','Cline','Hooks','GitHooks','CIGuard')]
  [string[]]$Tools = @('Cursor','Codex','Claude','Copilot','Windsurf','Gemini','Cline','Hooks','GitHooks','CIGuard'),
  [string]$BoardPath = '',
  [switch]$Plan,
  [switch]$Commit,
  [switch]$Remove,
  [switch]$Json,
  [string]$Templates = ''
)
$ErrorActionPreference = 'Stop'
function ConvertTo-OsPath([string]$r) { $r -replace '\\', [IO.Path]::DirectorySeparatorChar }
if (-not $Templates) { $Templates = Join-Path $PSScriptRoot 'project-templates' }
$MergeFiles = @('.cursor\hooks.json', '.claude\settings.json')
$ManiName = '.ai-dev-skills-manifest.txt'
function Out-Result($o) { if ($Json) { $o | ConvertTo-Json -Depth 6 -Compress } else { $o } }
function Get-Sha([string]$p) { (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash }
function Get-TextSha([string]$t) { $sha = [Security.Cryptography.SHA256]::Create(); ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($t)))).Replace('-', '') }
function Merge-HookJson([string]$baseText, [string]$oursText) {
  $base = $baseText | ConvertFrom-Json; $ours = $oursText | ConvertFrom-Json
  foreach ($p in $ours.PSObject.Properties) { if ($p.Name -ne 'hooks' -and -not $base.PSObject.Properties[$p.Name]) { $base | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value } }
  if (-not $base.PSObject.Properties['hooks']) { $base | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) }
  foreach ($ev in $ours.hooks.PSObject.Properties) {
    $cur = @(); if ($base.hooks.PSObject.Properties[$ev.Name]) { $cur = @($base.hooks.($ev.Name)) }
    $seen = @($cur | ForEach-Object { $_ | ConvertTo-Json -Depth 20 -Compress })
    foreach ($e in @($ev.Value)) { if (($e | ConvertTo-Json -Depth 20 -Compress) -notin $seen) { $cur += $e } }
    $base.hooks | Add-Member -NotePropertyName $ev.Name -NotePropertyValue $cur -Force
  }
  $base | ConvertTo-Json -Depth 20
}
if (-not (Test-Path -LiteralPath $RepoPath -PathType Container)) { throw "找不到專案資料夾：$RepoPath" }
$target = (Resolve-Path -LiteralPath $RepoPath).Path.TrimEnd('\', '/')
$instRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\', '/')
if ($target -eq $instRoot) { throw "不能把專案檔套用到 GuGuBoard 安裝資料夾本身，請選專案的 repo 資料夾" }
$manifestPath = Join-Path $target $ManiName
$old = @(); if (Test-Path -LiteralPath $manifestPath) { $old = @(Get-Content -LiteralPath $manifestPath -Encoding UTF8) }
$prev = @{}; foreach ($l in $old) { if ($l -like 'F|*') { $x = $l.Substring(2) -split '\|'; $prev[$x[0]] = $(if ($x.Count -gt 1) { $x[1] } else { '' }) } }
$baks = @{}; foreach ($l in $old) { if ($l -like 'B|*') { $x = $l.Substring(2) -split '\|'; $baks[$x[0]] = $(if ($x.Count -gt 1) { $x[1] } else { $x[0] + '.bak' }) } }

# ---------- 移除 ----------
if ($Remove) {
  if (-not $old.Count) { return (Out-Result ([ordered]@{ ok = $true; repo = $target; removed = @(); restored = @(); message = '這個專案沒有套用紀錄' })) }
  $removed = @(); $restored = @(); $kept = @()
  foreach ($rel in $prev.Keys) {
    $p = Join-Path $target (ConvertTo-OsPath $rel)
    if (Test-Path -LiteralPath $p) {
      if ($prev[$rel] -and (Get-Sha $p) -ne $prev[$rel] -and -not $baks.ContainsKey($rel)) { $kept += $rel; continue }   # 套用後被改過：保留
      if (-not $Plan) { Remove-Item -LiteralPath $p -Force }; $removed += $rel
    }
  }
  foreach ($rel in $baks.Keys) { $b = Join-Path $target (ConvertTo-OsPath $baks[$rel]); if (Test-Path -LiteralPath $b) { if (-not $Plan) { Move-Item -LiteralPath $b -Destination (Join-Path $target (ConvertTo-OsPath $rel)) -Force }; $restored += $rel } }
  if (-not $Plan) {
    foreach ($rel in $removed) { $d = Split-Path (Join-Path $target (ConvertTo-OsPath $rel)); while ($d.Length -gt $target.Length) { if ((Test-Path -LiteralPath $d) -and -not (Get-ChildItem -LiteralPath $d -Force)) { Remove-Item -LiteralPath $d -Force }; $d = Split-Path $d } }
    if ($old -contains 'G|hooksPath') { $cur = (& git -C $target config --get core.hooksPath 2>$null); if ($cur -eq '.githooks') { & git -C $target config --unset core.hooksPath } }
    Remove-Item -LiteralPath $manifestPath -Force
  }
  return (Out-Result ([ordered]@{ ok = $true; repo = $target; plan = [bool]$Plan; removed = $removed; restored = $restored; kept = $kept }))
}

# ---------- 套用 ----------
if (-not (Test-Path -LiteralPath $Templates)) { throw "找不到專案範本資料夾：$Templates" }
$relBoard = ''
if ($BoardPath) {
  $fb = [IO.Path]::GetFullPath($BoardPath)
  if ($fb.StartsWith($target + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { $relBoard = $fb.Substring($target.Length + 1) -replace '\\', '/' }
}
$items = @()
foreach ($t in $Tools) {
  $root = Join-Path $Templates $t.ToLower()
  if (-not (Test-Path -LiteralPath $root)) { continue }
  foreach ($f in Get-ChildItem -LiteralPath $root -Recurse -File -Force) {
    $rel = $f.FullName.Substring($root.Length).TrimStart('\', '/') -replace '/', '\'
    $dest = Join-Path $target (ConvertTo-OsPath $rel)
    $text = $null
    if ($rel -eq '.ai-hooks\config.json' -and $relBoard -and $relBoard -ne '.ai-pm/board.json') {
      $text = ([IO.File]::ReadAllText($f.FullName)) -replace '"boardPath":\s*"[^"]*"', ('"boardPath": "' + $relBoard + '"')
    }
    $st = 'new'; $bak = ''
    if ($MergeFiles -contains $rel) {
      if (Test-Path -LiteralPath $dest) {
        if ($prev.ContainsKey($rel) -and $prev[$rel] -and (Get-Sha $dest) -eq $prev[$rel]) { $st = 'update' } else { $st = 'merge' }
      }
    } elseif (Test-Path -LiteralPath $dest) {
      $srcSha = $(if ($null -ne $text) { Get-TextSha $text } else { Get-Sha $f.FullName })
      $dSha = Get-Sha $dest
      if ($dSha -eq $srcSha) { $st = 'same' }
      elseif ($prev.ContainsKey($rel) -and $prev[$rel] -and $dSha -eq $prev[$rel]) { $st = 'update' }
      else { $st = 'backup' }
    }
    if ($st -eq 'backup' -or $st -eq 'merge') { $bak = "$rel.bak"; if (Test-Path -LiteralPath (Join-Path $target (ConvertTo-OsPath $bak))) { $bak = "$rel.$(Get-Date -Format yyyyMMddHHmmss).bak" } }
    $items += [pscustomobject]@{ tool = $t; path = $rel; status = $st; backup = $bak; src = $f.FullName; text = $text }
  }
}
$hooksPath = $null
if ($Tools -contains 'GitHooks') {
  $top = (& git -C $target rev-parse --show-toplevel 2>$null)
  if ($LASTEXITCODE -eq 0 -and $top -and ([IO.Path]::GetFullPath($top.Trim()).TrimEnd('\', '/') -eq $target)) {
    $cur = (& git -C $target config --get core.hooksPath 2>$null)
    if (-not $cur) { $hooksPath = 'set' } elseif ($cur -ne '.githooks') { $hooksPath = "keep:$cur" } else { $hooksPath = 'already' }
  } else { $hooksPath = 'not-repo' }
}
$summary = [ordered]@{ new = @($items | Where-Object status -eq 'new').Count; update = @($items | Where-Object status -eq 'update').Count; same = @($items | Where-Object status -eq 'same').Count; backup = @($items | Where-Object status -eq 'backup').Count; merge = @($items | Where-Object status -eq 'merge').Count }
$view = @($items | ForEach-Object { [ordered]@{ tool = $_.tool; path = $_.path; status = $_.status; backup = $_.backup } })
if ($Plan) { return (Out-Result ([ordered]@{ ok = $true; plan = $true; repo = $target; files = $view; summary = $summary; hooksPath = $hooksPath })) }

$lines = [Collections.Generic.List[string]]::new()
foreach ($k in $baks.Keys) { $lines.Add("B|$k|$($baks[$k])") }
foreach ($k in $prev.Keys) { if (-not ($items | Where-Object path -eq $k)) { $lines.Add("F|$k|$($prev[$k])") } }   # 這次沒選的工具，紀錄保留
if ($old -contains 'G|hooksPath') { $lines.Add('G|hooksPath') }
$written = @()
foreach ($it in $items) {
  $dest = Join-Path $target (ConvertTo-OsPath $it.path)
  if ($it.status -ne 'same') {
    New-Item -ItemType Directory -Force -Path (Split-Path $dest) | Out-Null
    if ($it.backup) { Copy-Item -LiteralPath $dest -Destination (Join-Path $target (ConvertTo-OsPath $it.backup)); if (-not $baks.ContainsKey($it.path)) { $lines.Add("B|$($it.path)|$($it.backup)"); $baks[$it.path] = $it.backup } }
    if ($MergeFiles -contains $it.path) {
      $ours = [IO.File]::ReadAllText($it.src); $txt = $ours
      if ($it.status -eq 'merge') { try { $txt = Merge-HookJson ([IO.File]::ReadAllText((Join-Path $target (ConvertTo-OsPath $it.backup)))) $ours } catch { Write-Warning "無法解析 $($it.path)，改用本套件設定；原檔在 $($it.backup)" } }
      elseif ($it.status -eq 'update' -and $baks.ContainsKey($it.path) -and (Test-Path -LiteralPath (Join-Path $target (ConvertTo-OsPath $baks[$it.path])))) { try { $txt = Merge-HookJson ([IO.File]::ReadAllText((Join-Path $target (ConvertTo-OsPath $baks[$it.path])))) $ours } catch {} }
      [IO.File]::WriteAllText($dest, $txt, [Text.UTF8Encoding]::new($false))
    } elseif ($null -ne $it.text) { [IO.File]::WriteAllText($dest, $it.text, [Text.UTF8Encoding]::new($false)) }
    else { Copy-Item -LiteralPath $it.src -Destination $dest -Force }
    $written += $it.path
  }
  $lines.Add("F|$($it.path)|$(Get-Sha $dest)")
}
if ($hooksPath -eq 'set') { & git -C $target config core.hooksPath .githooks; if (-not $lines.Contains('G|hooksPath')) { $lines.Add('G|hooksPath') } }
[IO.File]::WriteAllLines($manifestPath, $lines, [Text.UTF8Encoding]::new($false))
$commitRes = $null
if ($Commit) {
  $top = (& git -C $target rev-parse --show-toplevel 2>$null)
  if ($LASTEXITCODE -ne 0) { $commitRes = [ordered]@{ ok = $false; message = '不是 git repo，沒有 commit' } }
  else {
    $paths = @(@($items | ForEach-Object { $_.path -replace '\\', '/' }) + $ManiName)   # 這次選的所有檔案（含上次寫入但還沒 commit 的）；.bak 不 commit
    $o1 = & git -C $target add -- $paths 2>&1
    $o2 = & git -C $target commit -q -m 'chore: 套用 GuGuBoard 專案設定' -- $paths 2>&1   # hooks 照常執行，不用 --no-verify
    $code = $LASTEXITCODE; $msg = (@(@($o1) + @($o2)) | ForEach-Object { "$_" }) -join "`n"
    if ($code -ne 0 -and -not (& git -C $target diff --cached --name-only -- $paths)) { $commitRes = [ordered]@{ ok = $true; message = '沒有需要 commit 的變更' } }
    else { $commitRes = [ordered]@{ ok = ($code -eq 0); message = $msg } }
  }
}
Out-Result ([ordered]@{ ok = $true; plan = $false; repo = $target; files = $view; summary = $summary; written = $written; hooksPath = $hooksPath; commit = $commitRes })
if (-not $Json) {
  Write-Host "已套用到 $target：新增 $($summary.new)、更新 $($summary.update)、相同 $($summary.same)、備份後覆蓋 $($summary.backup)、合併 $($summary.merge)"
  foreach ($it in $items | Where-Object { $_.backup }) { Write-Host "  原檔備份：$($it.backup)" }
}
