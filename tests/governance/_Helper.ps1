# T-GOV-1a 測試輔助：把 serve-board / serve-ext 的受測函式用 AST 抽進目前（測試）scope，
# 不執行其頂層程式、不啟 HttpListener。共用驗證規則走 validate-board.ps1 -Library。
# 提供假的 req/res/session、以 docs/board.json 複製出的測試 board，以及共用 mock 目標。
$ErrorActionPreference = 'Stop'
$script:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

# 共用驗證規則（Test-Board / Test-BoardBookkeeping / Test-BoardIntegrity / Read-BoardJson / IsObj / Get-V …）
. (Join-Path $RepoRoot 'validate-board.ps1') -Library

# 受測函式需要的 script 變數（對應 serve-board.ps1 頂層定義）
$ROLES = 'viewer', 'dev-agent', 'verifier', 'high-tier', 'admin'
$MAX_BODY = 4096
$BACKUP_KEEP = 30
$projects = @{}

# 只抽「函式定義」，在目前 scope 定義（不跑頂層、不啟 listener）
foreach ($srcFile in 'serve-ext.ps1', 'serve-board.ps1') {
  $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot $srcFile), [ref]$null, [ref]$null)
  foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    Invoke-Expression $fn.Extent.Text
  }
}

# 假的 HTTP 請求：body 以 UTF-8 InputStream 提供（對應 Invoke-SetScenario 讀 InputStream 的方式）
function New-Req([string]$json, [switch]$NullBody) {
  if ($NullBody) { return [pscustomobject]@{ ContentLength64 = [long]0; InputStream = [IO.MemoryStream]::new([byte[]]@()) } }
  $bytes = [Text.Encoding]::UTF8.GetBytes($json)
  [pscustomobject]@{ ContentLength64 = [long]$bytes.Length; InputStream = [IO.MemoryStream]::new($bytes) }
}
$script:RES = [pscustomobject]@{}   # Send-Json/Send-Err 已 mock，$res 不被實際使用

# 假 session：role 可注入；預設非 external、非 github 登入
function New-Session([string]$user, [string]$role, [string]$pid_ = 'GuGuBoard') {
  [pscustomobject]@{ user = $user; role = $role; allowed = @{ $pid_ = $role }; external = $false; ghLogin = $null; ghName = $null; ghId = $null }
}

# 測試用 board：複製真實 docs/board.json（保證合規），放到暫存檔；回傳假 $Pj（git=false → 不實際 commit）
function New-TestBoard {
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("gov-board-" + [Guid]::NewGuid().ToString('N') + ".json")
  Copy-Item -LiteralPath (Join-Path $RepoRoot 'docs/board.json') -Destination $tmp -Force
  # 真實 docs/board.json 本就合規；頂層 updatedAt 在近期過去，Write-BoardChecked 寫入時用「現在」不會倒退
  [pscustomobject]@{ id = 'GuGuBoard'; json = $tmp; rel = 'board.json'; dir = (Split-Path -Parent $tmp); git = $false; remote = $false; ghLogin = $null; lastText = [IO.File]::ReadAllText($tmp); lastTag = ''; dirtyAt = $null }
}
function Remove-TestBoard($Pj) { if ($Pj -and (Test-Path -LiteralPath $Pj.json)) { Remove-Item -LiteralPath $Pj.json -Force -ErrorAction SilentlyContinue } }
function Get-BoardObj($Pj) { Get-Content -LiteralPath $Pj.json -Raw -Encoding UTF8 | ConvertFrom-Json }
function Get-Scenario($b, [string]$sid) { ($b.items | Where-Object { $_.id -eq 'S-GOV-1-1' }).bdd | Where-Object { $_.id -eq $sid } }
# history 筆數：history 不存在時為 0（避免 @($null).Count 誤算成 1）
function HistCount($story) { @($story.history | Where-Object { $_ -ne $null }).Count }

# ---- 測試用 I/O stub：覆蓋 AST import 進來的真實函式。用真函式而非 Pester Mock，
# 避免 Pester 3.4 不套用 [int]$code 預設值（會綁成 0）造成成功回應 code 錯誤。 ----
$script:cap = $null; $script:pushEvents = @(); $script:sess = $null; $script:claims = @{}
function Get-Session($req) { $script:sess }
function Get-Claims([string]$pid_) { $script:claims }
function Send-Json($res, $obj, $code = 200) { $script:cap = @{ code = $code; body = $obj } }
function Send-Err($res, $code, $err) { $script:cap = @{ code = $code; body = @{ error = $err } } }
function Push-All($event, $obj, $projId) { $script:pushEvents += $event }
function Invoke-BoardEvents { }
function Backup-Board { }
function Invoke-Git($Pj, $a) { [pscustomobject]@{ Code = 0; Out = ''; Err = ''; Args = (@($a) -join ' ') } }
# 保留真實 Write-BoardChecked，另名保存，再以 wrapper 包起來：A16 用 $script:failWrite 注入規則錯誤，
# 取代 Pester Mock（Pester 3.4 It-scope Mock 會外洩到後續測試）。
$script:failWrite = $null
Set-Item function:Invoke-RealWriteBoardChecked (Get-Command Write-BoardChecked -CommandType Function).ScriptBlock
function Write-BoardChecked($Pj, $new, $role, $why) {
  if ($script:failWrite) { return @($script:failWrite) }
  Invoke-RealWriteBoardChecked $Pj $new $role $why
}
