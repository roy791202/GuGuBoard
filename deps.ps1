# SPDX-License-Identifier: Apache-2.0
<#
 GuGuBoard 外部工具：偵測，缺少就自動安裝（不再只印安裝說明）。
 用法一（其他腳本）：. (Join-Path $PSScriptRoot 'deps.ps1'); $exe = Use-GgTool cloudflared
 用法二（背景安裝，看板的「自動安裝」按鈕用）：deps.ps1 -Install cloudflared -StatusFile <json> -ConfigDir <dir>
 安裝順序：
  Windows：winget（靜默）→ 官方 GitHub release 直接下載（SHA256 驗證）到 <安裝資料夾>\tools，不需要系統管理員
  macOS：brew → 官方 release 下載；Linux：apt／dnf（只在不用輸入密碼時）→ 官方 release 下載到 ~/.local/share/guguboard/tools
 AI CLI（claude、codex、cursor-agent、gemini）只回報有沒有裝，不自動安裝（要登入、要付費，應由使用者決定）。
 關閉自動安裝：看板「⚙ 設定 → 外部工具」，或環境變數 GUGUBOARD_NO_AUTO_INSTALL=1。
#>
# 參數名稱加 Gg 前綴：這個檔會被其他腳本 dot-source，參數會變成呼叫端的變數，不能蓋掉它們的 $ConfigDir 等
param([Alias('Install')][string]$GgInstallTool = '', [Alias('StatusFile')][string]$GgStatusFile = '', [Alias('ConfigDir')][string]$GgConfigArg = '', [Alias('Yes')][switch]$GgYesFlag, [Alias('Report')][switch]$GgReportFlag)

$GG_IS_WIN = ($env:OS -eq 'Windows_NT')
$GG_IS_MAC = (-not $GG_IS_WIN) -and ((& uname 2>$null) -eq 'Darwin')
$GG_ARCH = $(if ($GG_IS_WIN) { if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' } } else { $m = [string](& uname -m 2>$null); if ($m -match 'arm64|aarch64') { 'arm64' } else { 'amd64' } })
$GG_HOME = $(if ($env:USERPROFILE) { $env:USERPROFILE } else { $env:HOME })

# 每個工具：套件管理器的名稱、官方 release 的檔名規則（{a}=架構）、解開後執行檔的位置
$GG_TOOLS = [ordered]@{
  cloudflared = @{ purpose = '外部監看（Cloudflare Tunnel）'; winget = 'Cloudflare.cloudflared'; brew = 'cloudflared'; apt = ''; dnf = ''; repo = 'cloudflare/cloudflared'
    asset = @{ win = 'cloudflared-windows-{a}\.exe$'; mac = 'cloudflared-darwin-{a}\.tgz$'; linux = 'cloudflared-linux-{a}$' } }
  git = @{ purpose = '版本歷史、Git 分頁、套用到專案'; winget = 'Git.Git'; brew = 'git'; apt = 'git'; dnf = 'git'; repo = 'git-for-windows/git'
    asset = @{ win = '^MinGit-[\d.]+-64-bit\.zip$' }; exe = @{ win = 'cmd\git.exe' } }
  gh = @{ purpose = 'GitHub PR 通知（選用；也可用 GITHUB_TOKEN）'; winget = 'GitHub.cli'; brew = 'gh'; apt = 'gh'; dnf = 'gh'; repo = 'cli/cli'
    asset = @{ win = '^gh_[\d.]+_windows_{a}\.zip$'; mac = '^gh_[\d.]+_macOS_{a}\.zip$'; linux = '^gh_[\d.]+_linux_{a}\.tar\.gz$' } }
  pwsh = @{ purpose = 'macOS／Linux 執行看板'; winget = 'Microsoft.PowerShell'; brew = 'powershell'; apt = 'powershell'; dnf = 'powershell'; repo = 'PowerShell/PowerShell'; cask = $true
    asset = @{ win = '^PowerShell-[\d.]+-win-{x}\.zip$'; mac = '^powershell-[\d.]+-osx-{x}\.tar\.gz$'; linux = '^powershell-[\d.]+-linux-{x}\.tar\.gz$' } }
  tailscale = @{ purpose = '外部監看（Tailscale Funnel）'; winget = 'Tailscale.Tailscale'; brew = 'tailscale'; apt = 'tailscale'; dnf = 'tailscale'; repo = '' }
}
$GG_AI_CLIS = 'claude', 'codex', 'cursor-agent', 'gemini'

function Get-GgToolsDir {
  if ($env:GUGUBOARD_TOOLS_DIR) { return $env:GUGUBOARD_TOOLS_DIR }
  if ($GG_IS_WIN) {
    $d = Join-Path $PSScriptRoot 'tools'   # 例如 D:\AI_PM\tools
    try { New-Item -ItemType Directory -Force -Path $d -ErrorAction Stop | Out-Null; $t = Join-Path $d '.w'; [IO.File]::WriteAllText($t, ''); Remove-Item -LiteralPath $t; return $d } catch { return Join-Path $env:LOCALAPPDATA 'GuGuBoard\tools' }
  }
  Join-Path $GG_HOME '.local/share/guguboard/tools'
}
function Get-GgConfigDir { if ($script:GgConfigDir) { return $script:GgConfigDir }; if ($env:GUGUBOARD_CONFIG) { return $env:GUGUBOARD_CONFIG }; Join-Path $PSScriptRoot '.ai-board' }

# 安裝完不用重開視窗：把系統與使用者 PATH、winget Links、tools 資料夾重新讀進這個工作階段
function Update-GgPath {
  $parts = [Collections.Generic.List[string]]::new()
  foreach ($p in ($env:PATH -split [IO.Path]::PathSeparator)) { if ($p) { $parts.Add($p) } }
  if ($GG_IS_WIN) {
    foreach ($scope in 'Machine', 'User') { foreach ($p in ([string][Environment]::GetEnvironmentVariable('Path', $scope) -split ';')) { if ($p) { $parts.Add([Environment]::ExpandEnvironmentVariables($p)) } } }
    $parts.Add((Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Links'))
  } else { foreach ($p in '/opt/homebrew/bin', '/usr/local/bin', (Join-Path $GG_HOME '.local/bin')) { $parts.Add($p) } }
  $td = Get-GgToolsDir; if (Test-Path -LiteralPath $td) { foreach ($d in Get-ChildItem -LiteralPath $td -Directory -ErrorAction SilentlyContinue) { $parts.Add($d.FullName); foreach ($s in 'cmd', 'bin') { $parts.Add((Join-Path $d.FullName $s)) } } }
  $seen = @{}; $env:PATH = (@($parts | Where-Object { $k = $_.TrimEnd('\', '/').ToLower(); if ($seen.ContainsKey($k)) { $false } else { $seen[$k] = 1; $true } }) -join [IO.Path]::PathSeparator)
}

function Find-GgTool([string]$name) {
  $exe = $(if ($GG_IS_WIN) { "$name.exe" } else { $name })
  $c = Get-Command $exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1; if ($c) { return $c.Source }
  $cands = [Collections.Generic.List[string]]::new()
  $td = Get-GgToolsDir; if (Test-Path -LiteralPath $td) { foreach ($f in Get-ChildItem -LiteralPath $td -Recurse -Filter $exe -File -ErrorAction SilentlyContinue) { $cands.Add($f.FullName) } }
  if ($GG_IS_WIN) {
    foreach ($b in $env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Programs')) { if ($b) { foreach ($s in $name, "$name\bin", 'Git\cmd', 'GitHub CLI', 'PowerShell\7', 'Tailscale') { $cands.Add((Join-Path (Join-Path $b $s) $exe)) } } }
    $cands.Add((Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\$exe"))
    $wp = Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages'; if (Test-Path -LiteralPath $wp) { foreach ($f in Get-ChildItem -LiteralPath $wp -Recurse -Filter $exe -File -ErrorAction SilentlyContinue) { $cands.Add($f.FullName) } }
  } else { foreach ($b in '/opt/homebrew/bin', '/usr/local/bin', '/usr/bin', (Join-Path $GG_HOME '.local/bin'), '/Applications/Tailscale.app/Contents/MacOS') { $cands.Add((Join-Path $b $exe)) } }
  foreach ($p in $cands) { if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { return $p } }
  $null
}

function Get-GgAutoInstall {
  if ("$env:GUGUBOARD_NO_AUTO_INSTALL" -match '^(1|true|yes)$') { return $false }
  $f = Join-Path (Get-GgConfigDir) 'integrations.json'
  if (Test-Path -LiteralPath $f) { try { $o = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json; if ($o.deps -and $o.deps.PSObject.Properties['autoInstall'] -and $o.deps.autoInstall -eq $false) { return $false } } catch {} }
  $true
}
function Write-GgAudit([string]$action, $detail) {
  try {
    $d = Get-GgConfigDir; if (-not (Test-Path -LiteralPath $d)) { return }
    $line = [ordered]@{ at = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK'); by = $(if ($env:GUGUBOARD_AUDIT_USER) { $env:GUGUBOARD_AUDIT_USER } else { 'system' }); action = $action; detail = $detail } | ConvertTo-Json -Depth 5 -Compress
    [IO.File]::AppendAllText((Join-Path $d 'account-audit.jsonl'), $line + "`n", [Text.UTF8Encoding]::new($false))
  } catch {}
}

function Invoke-GgWeb([string]$url, [string]$outFile) {
  $ProgressPreference = 'SilentlyContinue'   # Windows PowerShell 5.1 顯示進度條會讓下載慢很多
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  $h = @{ 'User-Agent' = 'GuGuBoard'; 'Accept' = 'application/vnd.github+json' }
  if ($outFile) { Invoke-WebRequest -Uri $url -OutFile $outFile -Headers $h -UseBasicParsing -TimeoutSec 600 | Out-Null; return }
  (Invoke-WebRequest -Uri $url -Headers $h -UseBasicParsing -TimeoutSec 60).Content
}
function Get-GgSha256([string]$f) { (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash.ToLower() }

# 從官方 GitHub release 下載：SHA256 先用 GitHub 提供的 digest，沒有就找 checksums 檔或 release 說明裡的雜湊；都找不到就不安裝
function Install-GgFromRelease([string]$name, $spec, [scriptblock]$say) {
  if (-not $spec.repo -or -not $spec.asset) { throw "$name 沒有可直接下載的官方版本" }
  $os = $(if ($GG_IS_WIN) { 'win' } elseif ($GG_IS_MAC) { 'mac' } else { 'linux' }); $pat = $spec.asset[$os]; if (-not $pat) { throw "$name 在這個作業系統沒有可直接下載的官方版本" }
  $x = $(if ($GG_ARCH -eq 'arm64') { 'arm64' } else { 'x64' }); $pat = $pat.Replace('{a}', $GG_ARCH).Replace('{x}', $x)
  $api = $(if ($env:GUGUBOARD_DEPS_API) { $env:GUGUBOARD_DEPS_API.TrimEnd('/') } else { 'https://api.github.com' })
  & $say "查詢 $name 最新版本…"
  $rel = Invoke-GgWeb "$api/repos/$($spec.repo)/releases/latest" '' | ConvertFrom-Json
  $asset = @($rel.assets | Where-Object { $_.name -match $pat -and $_.name -notmatch 'busybox' }) | Select-Object -First 1
  if (-not $asset) { throw "官方 release $($rel.tag_name) 找不到符合 $pat 的檔案" }
  $want = ''
  if ($asset.PSObject.Properties['digest'] -and [string]$asset.digest -match '^sha256:([0-9a-fA-F]{64})$') { $want = $Matches[1].ToLower() }
  if (-not $want) { $ck = @($rel.assets | Where-Object { $_.name -match 'checksums|sha256' }) | Select-Object -First 1; if ($ck) { $t = Invoke-GgWeb $ck.browser_download_url ''; if ($t -is [byte[]]) { $t = [Text.Encoding]::UTF8.GetString($t) }; foreach ($l in ($t -split "`n")) { if ($l -match '^([0-9a-fA-F]{64})\s+\*?(\S+)' -and $Matches[2] -eq $asset.name) { $want = $Matches[1].ToLower() } } } }
  if (-not $want -and $rel.body) { $esc = [regex]::Escape($asset.name); if ([string]$rel.body -match "$esc\W{0,6}([0-9a-fA-F]{64})" -or [string]$rel.body -match "([0-9a-fA-F]{64})\W{0,6}$esc") { $want = $Matches[1].ToLower() } }
  if (-not $want) { throw "找不到 $($asset.name) 的官方 SHA256，為了安全不安裝" }
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("gg-" + [guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  try {
    $dl = Join-Path $tmp $asset.name; & $say "下載 $($asset.name)（$([Math]::Round([double]$asset.size / 1MB, 1)) MB）…"
    Invoke-GgWeb $asset.browser_download_url $dl
    $got = Get-GgSha256 $dl; if ($got -ne $want) { throw "SHA256 不符（預期 $want，實際 $got），已刪除下載檔" }
    & $say 'SHA256 驗證通過，安裝中…'
    $dest = Join-Path (Get-GgToolsDir) $name; if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }; New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $exe = $(if ($GG_IS_WIN) { "$name.exe" } else { $name })
    if ($asset.name -match '\.zip$') { Expand-Archive -LiteralPath $dl -DestinationPath $dest -Force }
    elseif ($asset.name -match '\.(tgz|tar\.gz)$') { & tar -xzf $dl -C $dest; if ($LASTEXITCODE) { throw '解壓縮失敗' } }
    else { Copy-Item -LiteralPath $dl -Destination (Join-Path $dest $exe) }
    $p = $null; if ($spec.exe -and $spec.exe[$os]) { $p = Join-Path $dest $spec.exe[$os] } else { $f = Get-ChildItem -LiteralPath $dest -Recurse -Filter $exe -File | Select-Object -First 1; if ($f) { $p = $f.FullName } }
    if (-not $p -or -not (Test-Path -LiteralPath $p)) { throw "解開後找不到 $exe" }
    if (-not $GG_IS_WIN) { & chmod 755 $p }
    [IO.File]::WriteAllText((Join-Path $dest 'SOURCE.txt'), "$($spec.repo) $($rel.tag_name) $($asset.name) sha256=$want`n", [Text.UTF8Encoding]::new($false))
    @{ path = $p; version = [string]$rel.tag_name; sha256 = $want }
  } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

function Install-GgFromPackageManager([string]$name, $spec, [scriptblock]$say) {
  if ("$env:GUGUBOARD_DEPS_NO_PKG" -eq '1') { return $false }
  if ($GG_IS_WIN) {
    if (-not $spec.winget -or -not (Get-Command winget -ErrorAction SilentlyContinue)) { return $false }
    & $say "用 winget 安裝 $name…"
    & winget install --id $spec.winget -e --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq -1978335189)   # 後者＝已經安裝
  }
  if (Get-Command brew -ErrorAction SilentlyContinue) { if ($spec.brew) { & $say "用 Homebrew 安裝 $name…"; if ($spec.cask) { & brew install --cask $spec.brew 2>&1 | Out-Null } else { & brew install $spec.brew 2>&1 | Out-Null }; return ($LASTEXITCODE -eq 0) } }
  $root = ((& id -u 2>$null) -eq '0'); $sudo = @(); if (-not $root) { & sudo -n true 2>$null; if ($LASTEXITCODE -ne 0) { return $false }; $sudo = @('sudo', '-n') }   # 需要輸入密碼就改用直接下載
  foreach ($pm in 'apt-get', 'dnf') {
    $pkg = $(if ($pm -eq 'apt-get') { $spec.apt } else { $spec.dnf }); if (-not $pkg -or -not (Get-Command $pm -ErrorAction SilentlyContinue)) { continue }
    & $say "用 $pm 安裝 $name…"
    if ($sudo.Count) { & sudo -n $pm install -y $pkg 2>&1 | Out-Null } else { & $pm install -y $pkg 2>&1 | Out-Null }
    return ($LASTEXITCODE -eq 0)
  }
  $false
}

function Install-GgTool([string]$name, [scriptblock]$OnProgress) {
  $say = $(if ($OnProgress) { $OnProgress } else { { param($m) Write-Host "  $m" -ForegroundColor Cyan } })
  if ($GG_AI_CLIS -contains $name) { return @{ ok = $false; message = "$name 是 AI 工具，需要你自己安裝並登入，GuGuBoard 不會自動安裝" } }
  $spec = $GG_TOOLS[$name]; if (-not $spec) { return @{ ok = $false; message = "不認識的工具：$name" } }
  $method = ''; $err = ''
  try { if (Install-GgFromPackageManager $name $spec $say) { Update-GgPath; if (Find-GgTool $name) { $method = 'package-manager' } } } catch { $err = $_.Exception.Message }
  if (-not $method) { try { $r = Install-GgFromRelease $name $spec $say; Update-GgPath; $method = "release $($r.version)" } catch { $err = $_.Exception.Message } }
  $p = Find-GgTool $name
  Write-GgAudit 'deps.install' ([ordered]@{ tool = $name; ok = [bool]$p; method = $method; path = [string]$p; error = $(if ($p) { '' } else { $err }) })
  if ($p) { & $say "✔ $name 已安裝：$p"; return @{ ok = $true; path = $p; method = $method } }
  @{ ok = $false; message = "自動安裝 $name 失敗：$err" }
}

function Test-GgInteractive { try { [Environment]::UserInteractive -and -not [Console]::IsInputRedirected -and $Host.Name -eq 'ConsoleHost' } catch { $false } }

# 給其他腳本用：找得到就回傳路徑；找不到就（問一次後）自動安裝，再回傳路徑；失敗回傳 $null
function Use-GgTool([string]$name, [switch]$Quiet) {
  Update-GgPath; $p = Find-GgTool $name; if ($p) { return $p }
  $spec = $GG_TOOLS[$name]; $why = $(if ($spec) { "（$($spec.purpose)）" } else { '' })
  if (-not (Get-GgAutoInstall)) { Write-Host "找不到 $name$why，自動安裝已關閉（看板「⚙ 設定 → 外部工具」可開啟）。" -ForegroundColor Yellow; return $null }
  if ((Test-GgInteractive) -and -not $script:GgYes) {
    $a = Read-Host "找不到 $name$why，要現在自動安裝嗎？[Y/n]"
    if ($a -match '^(n|no|否)$') { Write-Host "已略過安裝 $name。" -ForegroundColor Yellow; return $null }
  } elseif (-not $Quiet) { Write-Host "找不到 $name$why，自動安裝中…" -ForegroundColor Cyan }
  $r = Install-GgTool $name
  if ($r.ok) { return $r.path }
  Write-Host $r.message -ForegroundColor Red; $null
}

function Get-GgReport {
  Update-GgPath
  $l = @(foreach ($n in $GG_TOOLS.Keys) { $p = Find-GgTool $n; [ordered]@{ name = $n; purpose = $GG_TOOLS[$n].purpose; found = [bool]$p; path = [string]$p; autoInstall = [bool]($GG_TOOLS[$n].repo -or $GG_TOOLS[$n].winget) } })
  $l += @(foreach ($n in $GG_AI_CLIS) { $p = Find-GgTool $n; [ordered]@{ name = $n; purpose = 'AI CLI（只回報，不自動安裝）'; found = [bool]$p; path = [string]$p; autoInstall = $false } })
  $l
}

# ---- 背景安裝模式：看板按「自動安裝」時由伺服器啟動，進度寫到 StatusFile ----
if ($GgInstallTool -and $MyInvocation.InvocationName -ne '.') {
  if ($GgConfigArg) { $script:GgConfigDir = $GgConfigArg }
  $u8 = [Text.UTF8Encoding]::new($false); $lines = [Collections.ArrayList]::new()
  $save = { param($state, $extra) if (-not $GgStatusFile) { return }; $o = [ordered]@{ tool = $GgInstallTool; state = $state; lines = @($lines); at = (Get-Date).ToString('o') }; if ($extra) { foreach ($k in $extra.Keys) { $o[$k] = $extra[$k] } }; [IO.File]::WriteAllText($GgStatusFile, ($o | ConvertTo-Json -Depth 4), $u8) }
  $prog = { param($m) [void]$lines.Add($m); Write-Host $m; & $save 'running' $null }
  & $save 'running' $null
  $r = Install-GgTool $GgInstallTool $prog
  if ($r.ok) { & $save 'done' @{ path = $r.path; method = $r.method }; exit 0 }
  [void]$lines.Add($r.message); & $save 'error' @{ message = $r.message }; exit 1
}
if ($GgYesFlag) { $script:GgYes = $true }
if ($GgReportFlag -and $MyInvocation.InvocationName -ne '.') {
  foreach ($t in Get-GgReport) { Write-Host ('{0,-13} {1,-4} {2}' -f $t.name, $(if ($t.found) { 'OK' } else { '缺少' }), $(if ($t.found) { $t.path } else { $t.purpose })) }
}
