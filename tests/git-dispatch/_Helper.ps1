# Git 派工測試共用：建一個 bare origin 與多個 clone（模擬多台 runner），全部在暫存目錄
$ErrorActionPreference = 'Stop'
$RepoScripts = (Resolve-Path (Join-Path $PSScriptRoot '..\..\scripts\git-dispatch')).Path
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $RepoScripts 'Git-Claim.ps1')
. (Join-Path $RepoScripts 'Git-Report.ps1')
. (Join-Path $RepoScripts 'Git-Heartbeat.ps1')
. (Join-Path $RepoScripts 'Git-Runner.ps1')
# validate-board.ps1 可能只在主 repo（git worktree 的 working tree 不一定有），往主 worktree 找
function Get-ValidateBoardPath {
  $p = Join-Path $RepoRoot 'validate-board.ps1'; if (Test-Path -LiteralPath $p) { return $p }
  $main = (git -C $RepoRoot worktree list --porcelain 2>$null | Select-Object -First 1) -replace '^worktree ', ''
  if ($main) { $q = Join-Path ($main -replace '/', '\') 'validate-board.ps1'; if (Test-Path -LiteralPath $q) { return $q } }
  throw '找不到 validate-board.ps1'
}

function Initialize-GitRepo([string]$Dir) { git -C $Dir config user.email 't@t' | Out-Null; git -C $Dir config user.name 'tester' | Out-Null }

function New-GitDispatchFixture([string[]]$Tickets = @('T-1', 'T-2')) {
  $root = Join-Path ([IO.Path]::GetTempPath()) ('gitdisp-' + [guid]::NewGuid().ToString('N'))
  $origin = Join-Path $root 'origin.git'; New-Item -ItemType Directory $origin -Force | Out-Null
  git -C $origin init --bare -q -b main | Out-Null
  $seed = Join-Path $root 'seed'; git clone -q $origin $seed | Out-Null; Initialize-GitRepo $seed
  New-Item -ItemType Directory (Join-Path $seed 'claims') -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $seed 'claims\.gitkeep'), '', [Text.UTF8Encoding]::new($false))
  $b = [ordered]@{ version = 1; project = 'test'; updatedAt = '2026-11-08T00:00:00+08:00'; items = @($Tickets | ForEach-Object { [ordered]@{ id = $_; level = 'Task'; title = $_; status = 'Todo'; light = 'Gray'; estimate = @{ hours = 1 }; updatedAt = '2026-11-08T00:00:00+08:00' } }) }
  [IO.File]::WriteAllText((Join-Path $seed 'board.json'), ($b | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
  Copy-Item (Get-ValidateBoardPath) (Join-Path $seed 'validate-board.ps1')   # runner 端要能自己驗 L1–L7
  git -C $seed add -A | Out-Null; git -C $seed commit -q -m 'init' | Out-Null; git -C $seed push -q origin main | Out-Null
  @{ root = $root; origin = $origin }
}
function New-Runner($fix, [string]$name) { $d = Join-Path $fix.root $name; git clone -q $fix.origin $d | Out-Null; Initialize-GitRepo $d; (git -C $d config user.name $name) | Out-Null; $d }
function Get-OriginClaim($fix, [string]$ticket) {
  $t = Join-Path $fix.root ('inspect-' + [guid]::NewGuid().ToString('N').Substring(0, 6)); git clone -q $fix.origin $t | Out-Null
  $f = Join-Path $t "claims\$ticket.json"; $r = if (Test-Path $f) { Get-Content $f -Raw | ConvertFrom-Json } else { $null }
  Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue; $r
}
function Get-OriginBoard($fix) {
  $t = Join-Path $fix.root ('insp-' + [guid]::NewGuid().ToString('N').Substring(0, 6)); git clone -q $fix.origin $t | Out-Null
  $b = ConvertFrom-JsonKeepDates (Get-Content (Join-Path $t 'board.json') -Raw -Encoding UTF8)   # 與受測碼同一套日期處理，updatedAt 斷言才看得到完整 ISO
  Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue; $b
}
function Get-TicketUpdatedAt($repo, $ticket) {
  git -C $repo fetch -q origin main | Out-Null; git -C $repo reset -q --hard origin/main | Out-Null
  # 必須和 Git-Report／Git-Runner 讀 board 用同一套（KeepDates）；否則 pwsh7 下 base 被截到秒、與 item 完整 ISO 一比就誤判 CONFLICT
  $b = ConvertFrom-JsonKeepDates (Get-Content (Join-Path $repo 'board.json') -Raw -Encoding UTF8)
  [string]($b.items | Where-Object { $_.id -eq $ticket }).updatedAt
}
function Expire-OriginClaim($fix, [string]$ticket) {   # 把 origin 的某張 claim until 改到過去，模擬 runner 失聯逾期
  $t = Join-Path $fix.root ('exp-' + [guid]::NewGuid().ToString('N').Substring(0, 6)); git clone -q $fix.origin $t | Out-Null; Initialize-GitRepo $t
  $f = Join-Path $t "claims\$ticket.json"; $c = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
  $c.until = ([DateTimeOffset]::Now.AddMinutes(-1)).ToString('o')
  [IO.File]::WriteAllText($f, ($c | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
  git -C $t add -A | Out-Null; git -C $t commit -q -m 'expire' | Out-Null; git -C $t push -q origin HEAD:main | Out-Null
  Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue
}
function Edit-OriginBoard($fix, [scriptblock]$Mutator) {   # clone origin、用 mutator 改 board 物件、push 回去（測試 setup 用，不經 validate）
  $t = Join-Path $fix.root ('edit-' + [guid]::NewGuid().ToString('N').Substring(0, 6)); git clone -q $fix.origin $t | Out-Null; Initialize-GitRepo $t
  $bp = Join-Path $t 'board.json'; $b = Get-Content $bp -Raw -Encoding UTF8 | ConvertFrom-Json
  & $Mutator $b
  [IO.File]::WriteAllText($bp, ($b | ConvertTo-Json -Depth 40), [Text.UTF8Encoding]::new($false))
  git -C $t add -A | Out-Null; git -C $t commit -q -m 'edit board' | Out-Null; git -C $t push -q origin HEAD:main | Out-Null
  Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue
}
function Corrupt-OriginClaim($fix, [string]$ticket) {   # 在 origin 放一個損毀的 claims/<ticket>.json
  $t = Join-Path $fix.root ('cor-' + [guid]::NewGuid().ToString('N').Substring(0, 6)); git clone -q $fix.origin $t | Out-Null; Initialize-GitRepo $t
  New-Item -ItemType Directory (Join-Path $t 'claims') -Force | Out-Null
  [IO.File]::WriteAllText((Join-Path $t "claims\$ticket.json"), '{ this is not json', [Text.UTF8Encoding]::new($false))
  git -C $t add -A | Out-Null; git -C $t commit -q -m 'corrupt claim' | Out-Null; git -C $t push -q origin HEAD:main | Out-Null
  Remove-Item $t -Recurse -Force -ErrorAction SilentlyContinue
}
function Sync-Runner($repo) { git -C $repo fetch -q origin main | Out-Null; git -C $repo reset -q --hard origin/main | Out-Null }
function Remove-GitDispatchFixture($fix) { Remove-Item $fix.root -Recurse -Force -ErrorAction SilentlyContinue }
