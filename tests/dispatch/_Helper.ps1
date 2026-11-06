# 派工器測試共用環境：載入 validate-board.ps1 與 serve-ext.ps1，伺服器其他部分以最小替身取代。
# 由各 *.Tests.ps1 dot-source；Pester 3.4（Windows PowerShell 5.1 內建）與 Pester 5 皆可。
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Fixtures = Join-Path $PSScriptRoot 'fixtures'
$ConfigDir = Join-Path ([IO.Path]::GetTempPath()) ('gugu-disp-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $ConfigDir | Out-Null
$Port = 0
$projects = @{}
$T = @{ Sent = $null; Body = $null }   # 替身狀態（用 hashtable 避開 Pester 的變數範圍差異）

function Find-RepoFile([string]$name) {   # validate-board.ps1 未納入版控時（例如在 git worktree 裡），改用主工作目錄的那一份
  $p = Join-Path $RepoRoot $name; if (Test-Path -LiteralPath $p) { return $p }
  $main = (& git -C $RepoRoot worktree list --porcelain | Select-Object -First 1) -replace '^worktree ', ''
  $q = Join-Path $main $name; if (Test-Path -LiteralPath $q) { return $q }
  throw "找不到 $name"
}
. (Find-RepoFile 'validate-board.ps1') -Library
function Initialize-ConfigDir { if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory $ConfigDir | Out-Null } }
function Get-NowIso { (Get-Date).ToString('yyyy-MM-dd\THH\:mm\:sszzz', [Globalization.CultureInfo]::InvariantCulture) }
function Push-All { }
function Get-Tag($Pj) { 'tag' }
function Write-AcctAudit { }
function Read-Groups { @() }
function Get-Members($g) { @() }
function New-Token { [guid]::NewGuid().ToString('N') }
function Get-Key([string]$s) { $s }
. (Join-Path $RepoRoot 'serve-ext.ps1')
function Send-Notify { }
function Send-Json($res, $obj, [int]$code = 200) { $T.Sent = @{ code = $code; body = $obj } }
function Send-Err($res, [int]$code, [string]$err) { Send-Json $res @{ error = $err } $code }
function Read-BodyMax($req, [int]$max) { $T.Body }

function New-TestProject([string]$Status = 'Todo', [string]$Light = 'Gray') {
  $dir = Join-Path $ConfigDir ('proj-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory (Join-Path $dir 'docs') -Force | Out-Null
  $now = Get-NowIso
  $b = [ordered]@{ version = 1; project = 'test'; updatedAt = $now; items = @(
      [ordered]@{ id = 'T-1'; level = 'Task'; title = 'test task'; status = $Status; light = $Light; estimate = @{ hours = 1 }; createdAt = $now; updatedAt = $now; history = @() }) }
  $json = Join-Path $dir 'docs\board.json'
  [IO.File]::WriteAllText($json, ($b | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
  $id = 'p' + [guid]::NewGuid().ToString('N').Substring(0, 6)
  $Pj = @{ id = $id; name = 'Test'; json = $json; dir = $dir; lastText = $null; lastTag = $null; dirtyAt = $null; dispNext = $null }
  $projects.Clear(); $projects[$id] = $Pj
  $Pj
}
function Get-Ticket($Pj) { Find-Item (Read-BoardObj $Pj) 'T-1' }
function Set-TicketStatus($Pj, [string]$Status, [string]$Light) {
  $b = Read-BoardObj $Pj; $it = Find-Item $b 'T-1'; $it['status'] = $Status; $it['light'] = $Light
  [IO.File]::WriteAllText($Pj.json, (ConvertTo-BoardText $b), [Text.UTF8Encoding]::new($false))
}
function New-FakeProfile([string]$Script, [string[]]$ScriptArgs = @(), [int]$TimeoutMin = 30) {
  [ordered]@{ id = 'fake'; label = 'fake'; exe = 'powershell'; args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Fixtures $Script)) + $ScriptArgs; role = 'dev-agent'; timeoutMin = $TimeoutMin }
}
function Enable-Dispatch($Pj, $Prof, [hashtable]$Extra = @{}) {
  $c = Get-DispatchCfg $Pj.id; $c.enabled = $true; $c.profiles = @($Prof); $c.profile = $Prof.id
  foreach ($k in $Extra.Keys) { $c[$k] = $Extra[$k] }
  Save-DispatchCfg $Pj.id $c; $Pj.dispNext = $null
}
function Invoke-Tick($Pj) { $Pj.dispNext = $null; Update-DispatchTick }
function Get-ProjectRuns($Pj) { @($runs.Values | Where-Object { $_.project -eq $Pj.id }) }
function Wait-Until([scriptblock]$Cond, [int]$Ms = 15000) { $d = (Get-Date).AddMilliseconds($Ms); while ((Get-Date) -lt $d) { if (& $Cond) { return $true }; Start-Sleep -Milliseconds 200 }; $false }
function Test-Alive([int]$ProcId) { [bool](Get-Process -Id $ProcId -ErrorAction SilentlyContinue) }
function Reset-Dispatch {
  foreach ($r in @($runs.Values)) { try { if (-not $r.proc.HasExited) { $r.proc.Kill() } } catch {} }
  $runs.Clear(); $claims.Clear(); if (Get-Variable DispState -ErrorAction SilentlyContinue) { $DispState.resumed = $true }
}
