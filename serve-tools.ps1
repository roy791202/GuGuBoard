# SPDX-License-Identifier: Apache-2.0
<#
 外部工具與外部監看通道（只有 admin、只限本機）：
  GET  /api/admin/deps  → 各工具有沒有裝、背景安裝進度、通道狀態
  POST /api/admin/deps  → {action:'install', tool} 背景自動安裝；{action:'tunnel-start'|'tunnel-stop'}；{action:'auto', autoInstall}
 安裝在另一個程序跑（下載可能要幾十秒，伺服器是單執行緒，不能卡住看板）。
#>
$tunnel = @{ proc = $null; log = ''; url = ''; out = $null; err = $null }
function Get-DepStatusFile([string]$n) { if (-not (Test-Path -LiteralPath $ConfigDir)) { [void](New-Item -ItemType Directory -Force -Path $ConfigDir) }; Join-Path $ConfigDir "deps-$n.json" }
function Read-DepJob([string]$n) { $f = Get-DepStatusFile $n; if (Test-Path -LiteralPath $f) { try { return (Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {} }; $null }
function Get-TunnelState {
  if ($tunnel.proc -and $tunnel.proc.HasExited) { $tunnel.proc = $null }
  if ($tunnel.proc -and -not $tunnel.url -and $tunnel.log -and (Test-Path -LiteralPath $tunnel.log)) {
    try { $t = [IO.File]::ReadAllText($tunnel.log); if ($t -match 'https://[a-z0-9-]+\.trycloudflare\.com') { $tunnel.url = $Matches[0] } } catch {}
  }
  @{ running = [bool]$tunnel.proc; url = $tunnel.url }
}
function Start-GgTunnel {
  $cf = Find-GgTool cloudflared; if (-not $cf) { return @{ error = 'E_DEP_MISSING'; tool = 'cloudflared'; message = '找不到 cloudflared，請先按「自動安裝」' } }
  if ($tunnel.proc -and -not $tunnel.proc.HasExited) { return (Get-TunnelState) }
  $tunnel.log = Join-Path $ConfigDir 'tunnel.log'; Remove-Item -LiteralPath $tunnel.log -ErrorAction SilentlyContinue; $tunnel.url = ''
  # HttpListener 只接受 Host=localhost，公開主機名稱會被回 400 Invalid Hostname，所以讓 cloudflared 改寫 Host 標頭
  $a = @('tunnel', '--no-autoupdate', '--http-host-header', "localhost:$Port", '--url', "http://localhost:$Port", '--logfile', $tunnel.log)
  $psi = [Diagnostics.ProcessStartInfo]::new($cf); $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.Arguments = ($a | ForEach-Object { '"' + $_ + '"' }) -join ' '
  $p = [Diagnostics.Process]::Start($psi); $tunnel.proc = $p; $tunnel.out = $p.StandardOutput.ReadToEndAsync(); $tunnel.err = $p.StandardError.ReadToEndAsync()
  Get-TunnelState
}
function Invoke-DepsApi($req, $res, $s, [bool]$post) {
  if ($s.role -ne 'admin') { return Send-Err $res 403 'E_FORBIDDEN' }
  if (-not $req.IsLocal -or (Test-External $req)) { return Send-Err $res 403 'E_NOT_LOCAL' }
  if ($post) {
    $in = Read-Body $req; if (-not $in) { return Send-Err $res 400 'E_BAD_REQUEST' }
    switch ([string]$in.action) {
      'install' {
        $n = [string]$in.tool; if (-not $GG_TOOLS.Contains($n)) { return Send-Json $res @{ error = 'E_BAD_TOOL'; message = "$n 不能自動安裝（AI CLI 請自行安裝並登入）" } 400 }
        if (-not (Get-GgAutoInstall)) { return Send-Json $res @{ error = 'E_AUTO_INSTALL_OFF'; message = '自動安裝已關閉' } 409 }
        $j = Read-DepJob $n; if ($j -and $j.state -eq 'running' -and ((Get-Date) - [datetime]::Parse([string]$j.at)).TotalMinutes -lt 15) { return Send-Json $res @{ ok = $true; job = $j } }
        $f = Get-DepStatusFile $n; [IO.File]::WriteAllText($f, (@{ tool = $n; state = 'running'; lines = @('準備安裝…'); at = (Get-Date).ToString('o') } | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        $me_ = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $psi = [Diagnostics.ProcessStartInfo]::new($me_); $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $al = @('-NoProfile', '-NonInteractive'); if ($env:OS -eq 'Windows_NT') { $al += @('-ExecutionPolicy', 'Bypass') }
        $al += @('-File', (Join-Path $PSScriptRoot 'deps.ps1'), '-Install', $n, '-StatusFile', $f, '-ConfigDir', $ConfigDir)
        $psi.Arguments = ($al | ForEach-Object { '"' + $_ + '"' }) -join ' '; $psi.EnvironmentVariables['GUGUBOARD_AUDIT_USER'] = [string]$s.user
        [void][Diagnostics.Process]::Start($psi)
        Write-AcctAudit $s 'deps.install.start' @{ tool = $n }
        return Send-Json $res @{ ok = $true; job = (Read-DepJob $n) }
      }
      'tunnel-start' { $r = Start-GgTunnel; if ($r.error) { return Send-Json $res $r 409 }; Write-AcctAudit $s 'tunnel.start' @{ provider = 'cloudflare' }; return Send-Json $res @{ ok = $true; tunnel = $r } }
      'tunnel-stop' { if ($tunnel.proc -and -not $tunnel.proc.HasExited) { try { $tunnel.proc.Kill() } catch {} }; $tunnel.proc = $null; $tunnel.url = ''; Write-AcctAudit $s 'tunnel.stop' @{}; return Send-Json $res @{ ok = $true; tunnel = (Get-TunnelState) } }
      'auto' { $cur = Merge-Integ (Read-Integ) ([pscustomobject]@{ deps = [pscustomobject]@{ autoInstall = ($in.autoInstall -eq $true) } }); Save-Integ $cur; Write-AcctAudit $s 'deps.autoInstall' @{ on = ($in.autoInstall -eq $true) } }
      default { return Send-Err $res 400 'E_BAD_ACTION' }
    }
  }
  $jobs = @{}; foreach ($n in $GG_TOOLS.Keys) { $j = Read-DepJob $n; if ($j) { $jobs[$n] = $j } }
  Send-Json $res @{ autoInstall = (Get-GgAutoInstall); tools = @(Get-GgReport); jobs = $jobs; tunnel = (Get-TunnelState) }
}
