<#
.SYNOPSIS  本機進度看板伺服器（零相依，只聽 localhost），支援多專案。
  - 登入：PBKDF2-SHA256（60 萬次、16 byte 隨機鹽）。Argon2 不是 .NET / PowerShell 內建，為了零相依改用 PBKDF2。
    Session Cookie：32 byte 隨機值、HttpOnly、SameSite=Strict；伺服器只存它的 SHA-256。
  - 每個專案各自監看 board.json、自動 git commit 到該專案的 repo、可選 Git 遠端同步、可選 GitHub PR 通知。
  - 權限：每個帳號只看得到被授權的專案（admin 例外），所有 API 都檢查；專案只用 ID 指定，從不接受用戶端傳來的路徑。
.EXAMPLE  .\serve-board.ps1 -AddProject sgenaxis -Name "SGenAxis" -BoardPath D:\AIAD\.ai-pm\board.json -GitHubRepo kuan/sgenaxis
.EXAMPLE  .\serve-board.ps1 -AddUser kuan -Role admin
.EXAMPLE  .\serve-board.ps1 -AddUser rev -Role verifier -Project sgenaxis
.EXAMPLE  .\serve-board.ps1 -SetGitHubClientId Iv1.xxxxxxxx   # 設定 GitHub 登入（OAuth App 的 Client ID，需啟用 Device Flow）
.EXAMPLE  .\serve-board.ps1                       # 啟動，監看所有已登記的專案
.EXAMPLE  .\serve-board.ps1 -Json D:\AIAD\docs\board.json -NoAuth   # 舊用法：單一專案（ID = default）
#>
param(
  [int]$Port = 8765,
  [string]$Json = '',
  [string]$Html = (Join-Path $PSScriptRoot 'board.html'),
  [string]$ConfigDir = '',
  [int]$MaxClients = 20,
  [switch]$NoOpen,
  [switch]$NoAuth,
  [ValidateSet('on','off')][string]$AutoCommit = 'on',
  [int]$DebounceMs = 2000,
  [switch]$InitGit,
  [string]$AddUser, [string]$RemoveUser, [string]$ResetPassword, [string]$GrantUser,
  [ValidateSet('viewer','dev-agent','verifier','high-tier','admin')][string]$Role = 'viewer',
  [string[]]$Project = @(),
  [SecureString]$Password,
  [string]$AddProject, [string]$RemoveProject, [switch]$ListProjects,
  [string]$Name = '', [string]$BoardPath = '', [string]$GitRepo = '', [string]$GitHubRepo = '', [switch]$RemoteSync, [switch]$WithExample,
  [int]$GitHubInterval = 60,
  [int]$SyncInterval = 60,
  [string]$GitHubApi = 'https://api.github.com',
  [string]$GitHubWeb = 'https://github.com',
  [string]$SetGitHubClientId = '',
  [string]$ApplyToProject = '',
  [ValidateSet('Cursor','Codex','Claude','Copilot','Windsurf','Gemini','Cline','Hooks','GitHooks','CIGuard')][string[]]$Tools = @('Cursor','Codex','Claude','Copilot','Windsurf','Gemini','Cline','Hooks','GitHooks','CIGuard'),
  [switch]$ApplyPlan, [switch]$ApplyCommit, [switch]$ApplyRemove
)
$ErrorActionPreference = 'Stop'
$ApplyScript = Join-Path $PSScriptRoot 'apply-project.ps1'
if ($ApplyToProject) {   # 把專案層檔案套用到某個 repo（等同 apply-project.ps1）
  $ap = @{ RepoPath = $ApplyToProject; Tools = $Tools }; if ($BoardPath) { $ap.BoardPath = $BoardPath }; if ($ApplyPlan) { $ap.Plan = $true }; if ($ApplyCommit) { $ap.Commit = $true }; if ($ApplyRemove) { $ap.Remove = $true }
  $r = & $ApplyScript @ap; if ($ApplyPlan -or $ApplyRemove) { $r | ConvertTo-Json -Depth 6 }; return
}
$ITER = 600000; $IDLE_MIN = 480; $MAX_SESSIONS = 100; $MAX_FAIL = 5; $LOCK_MIN = 15; $MAX_BODY = 4096; $MAX_PROJECTS = 50
$NAME_RE = '^[A-Za-z0-9._-]{1,32}$'; $PID_RE = '^[a-z0-9][a-z0-9-]{0,39}$'; $REPO_RE = '^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$'
$ROLES = 'viewer','dev-agent','verifier','high-tier','admin'
if (-not $ConfigDir) { $ConfigDir = if ($Json) { Join-Path (Split-Path -Parent ([IO.Path]::GetFullPath($Json))) '.ai-board' } else { Join-Path $PSScriptRoot '.ai-board' } }
# 舊版把看板放在 docs\ai-dev-skills\board\，設定在那裡的 .ai-board；新位置沒有設定時自動搬過來
$oldCfg = Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot 'docs') 'ai-dev-skills') 'board') '.ai-board'
if (-not $Json -and $ConfigDir -eq (Join-Path $PSScriptRoot '.ai-board') -and -not (Test-Path -LiteralPath $ConfigDir) -and (Test-Path -LiteralPath $oldCfg)) {
  Copy-Item -LiteralPath $oldCfg -Destination $ConfigDir -Recurse; Write-Host "已把舊版設定 $oldCfg 搬到 $ConfigDir"
}
$Users = Join-Path $ConfigDir 'users.json'; $ProjFile = Join-Path $ConfigDir 'projects.json'
# 共用規則（與 hooks／pre-commit／CI 同一份 validate-board.ps1）與擴充功能；保留 CLI 的 -Role 參數值
$__role = $Role; . (Join-Path $PSScriptRoot 'validate-board.ps1') -Library; $Role = $__role
. (Join-Path $PSScriptRoot 'serve-ext.ps1')
function Initialize-ConfigDir { if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory $ConfigDir | Out-Null }; $gi = Join-Path $ConfigDir '.gitignore'; if (-not (Test-Path $gi)) { Set-Content -LiteralPath $gi -Value '*' -Encoding UTF8 } }

$OAuthFile = Join-Path $ConfigDir 'github-oauth.json'; $PendFile = Join-Path $ConfigDir 'pending.json'
$GH_SCOPE = 'read:user repo'
function Read-OAuth { if (Test-Path -LiteralPath $OAuthFile) { try { [string](Get-Content -LiteralPath $OAuthFile -Raw -Encoding UTF8 | ConvertFrom-Json).clientId } catch { '' } } else { '' } }
function Save-OAuth([string]$id) { if ($id -notmatch '^[A-Za-z0-9._-]{8,64}$') { throw 'Client ID 格式錯誤（應為 8–64 個英數字元）' }; Initialize-ConfigDir; @{ clientId = $id } | ConvertTo-Json | Set-Content -LiteralPath $OAuthFile -Encoding UTF8 }
if ($SetGitHubClientId) { Save-OAuth $SetGitHubClientId; Write-Host "已設定 GitHub OAuth Client ID → $OAuthFile"; return }
function Read-Pending { if (Test-Path -LiteralPath $PendFile) { @((Get-Content -LiteralPath $PendFile -Raw -Encoding UTF8 | ConvertFrom-Json).pending) } else { @() } }
function Save-Pending($list) { Initialize-ConfigDir; @{ pending = @($list) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $PendFile -Encoding UTF8 }

# ---------- 專案登記 ----------
function Read-Projects { if (Test-Path -LiteralPath $ProjFile) { @((Get-Content -LiteralPath $ProjFile -Raw -Encoding UTF8 | ConvertFrom-Json).projects) } else { @() } }
function Save-Projects($list) { Initialize-ConfigDir; @{ projects = @($list) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ProjFile -Encoding UTF8 }
if ($ListProjects) { Read-Projects | Format-Table id, name, boardPath, gitRepoPath, githubRepo, remoteSync -AutoSize; return }
function Get-NowIso { (Get-Date).ToString('yyyy-MM-dd\THH\:mm\:sszzz', [Globalization.CultureInfo]::InvariantCulture) }
# 新專案的 board.json 預設是空白看板；只有勾選「加入範例工單」或 -WithExample 才複製範例
function New-BoardFile([string]$bp, [string]$nm, [bool]$withEx) {
  $d = Split-Path -Parent $bp; if ($d -and -not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory $d -Force | Out-Null }
  if ($withEx) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'board.example.json') -Destination $bp; Write-Host "已由範例建立 $bp（含範例工單）"; return }
  if (-not $nm) { $nm = '新專案' }
  $o = [ordered]@{ version = 1; project = $nm; updatedAt = (Get-NowIso); items = @() }
  [IO.File]::WriteAllText($bp, ($o | ConvertTo-Json -Depth 3), [Text.UTF8Encoding]::new($false)); Write-Host "已建立空白看板 $bp"
}
# 範例工單：board.example.json 內每筆標 example:true；舊版複製出來的看板沒有標記，就用 id + 標題完全相同來比對
function Get-ExampleSig { $m = @{}; $ex = Join-Path $PSScriptRoot 'board.example.json'; if (Test-Path -LiteralPath $ex) { foreach ($i in @(([IO.File]::ReadAllText($ex) | ConvertFrom-Json).items)) { $m[[string]$i.id] = [string]$i.title } }; $m }
function Test-ExampleItem($i, $sig) {   # $i 是 Read-BoardJson 的字典
  if ((Get-V $i 'example') -is [bool] -and (Get-V $i 'example')) { return $true }
  $id = [string](Get-V $i 'id'); ($sig.ContainsKey($id) -and ([string](Get-V $i 'title')) -ceq $sig[$id])
}
function Register-Project([string]$id, [string]$nm, [string]$bpIn, [string]$repo, [string]$ghRepo, [bool]$remote, [bool]$withEx = $false) {
  if ($id -cnotmatch $PID_RE) { throw '專案 ID 只能用小寫英數與 -（1–40 字，英數開頭）' }
  if (-not $bpIn -or -not [IO.Path]::IsPathRooted($bpIn)) { throw 'board.json 路徑必須是絕對路徑' }
  if ($bpIn -notmatch '\.json$') { throw 'board.json 路徑必須以 .json 結尾' }
  # 舊專案：預設路徑 .ai-pm/board.json 還不存在、但 repo 已有 docs/board.json 時沿用舊檔（不另建一份分岔的看板），之後可在管理面板「搬到 .ai-pm/」
  if ((Split-Path (Split-Path $bpIn -Parent) -Leaf) -eq '.ai-pm' -and (Split-Path $bpIn -Leaf) -eq 'board.json' -and -not (Test-Path -LiteralPath $bpIn)) {
    $legacy = Join-Path (Join-Path (Split-Path (Split-Path $bpIn -Parent) -Parent) 'docs') 'board.json'; if (Test-Path -LiteralPath $legacy) { $bpIn = $legacy; Write-Host "沿用既有的 $legacy（可之後搬到 .ai-pm/）" } }
  if ($ghRepo -and $ghRepo -notmatch $REPO_RE) { throw 'GitHub repo 格式必須是 owner/repo' }
  $list = @(Read-Projects); if ($list | Where-Object id -eq $id) { throw "專案 $id 已存在" }
  if ($list.Count -ge $MAX_PROJECTS) { throw "最多 $MAX_PROJECTS 個專案" }
  $bp = [IO.Path]::GetFullPath($bpIn)
  if (-not (Test-Path -LiteralPath $bp)) { New-BoardFile $bp $(if ($nm) { $nm } else { $id }) $withEx }
  Initialize-AiPm $bp $id $(if ($nm) { $nm } else { $id })
  $rec = [ordered]@{ id = $id; name = $(if ($nm) { $nm } else { $id }); boardPath = $bp; gitRepoPath = $(if ($repo) { [IO.Path]::GetFullPath($repo) } else { '' }); githubRepo = $ghRepo; remoteSync = $remote }
  $list += $rec; Save-Projects $list; Write-Host "已登記專案 $id → $ProjFile"
  [pscustomobject]$rec
}
if ($AddProject) { $bpx = $BoardPath; if (-not $bpx -and $GitRepo) { $bpx = Join-Path (Join-Path $GitRepo '.ai-pm') 'board.json' }; [void](Register-Project $AddProject $Name $bpx $GitRepo $GitHubRepo ([bool]$RemoteSync) ([bool]$WithExample)); return }
if ($RemoveProject) { $list = @(Read-Projects); $n = @($list | Where-Object id -ne $RemoveProject); if ($n.Count -eq $list.Count) { throw "找不到 $RemoveProject" }; Save-Projects $n; Write-Host "已移除專案 $RemoveProject（board.json 與 git 歷史不動）"; return }

# ---------- 帳號檔 ----------
function Read-Users { if (Test-Path -LiteralPath $Users) { @((Get-Content -LiteralPath $Users -Raw -Encoding UTF8 | ConvertFrom-Json).users) } else { @() } }
function Save-Users($list) { Initialize-ConfigDir; [ordered]@{ version = 2; users = @($list) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Users -Encoding UTF8 }
function New-Salt { $b = [byte[]]::new(16); [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); $b }
function Get-Hash([byte[]]$pw, [byte[]]$salt, [int]$iter) {
  $k = [Security.Cryptography.Rfc2898DeriveBytes]::new($pw, $salt, $iter, [Security.Cryptography.HashAlgorithmName]::SHA256)
  try { $k.GetBytes(32) } finally { $k.Dispose() }
}
function Test-Equal([byte[]]$a, [byte[]]$b) { if ($a.Length -ne $b.Length) { return $false }; $r = 0; for ($i = 0; $i -lt $a.Length; $i++) { $r = $r -bor ($a[$i] -bxor $b[$i]) }; $r -eq 0 }
function Read-Pw([string]$who) {
  if ($Password) { $s = $Password } else {
    $s = Read-Host "輸入 $who 的密碼（至少 12 字）" -AsSecureString
    $s2 = Read-Host '再輸入一次' -AsSecureString
    if ([Net.NetworkCredential]::new('', $s).Password -ne [Net.NetworkCredential]::new('', $s2).Password) { throw '兩次密碼不一致' }
  }
  $p = [Net.NetworkCredential]::new('', $s).Password
  if ($p.Length -lt 12) { throw '密碼至少 12 字' }
  [Text.Encoding]::UTF8.GetBytes($p)
}
# ---------- 群組（groups.json）與帳號稽核紀錄 ----------
# 有效權限：全域角色 admin → 所有專案 admin；停用 → 沒有任何專案；其他人每個專案取「個人直接授權」與「所屬各群組授權」中最高的角色
#   角色高低：viewer < dev-agent < verifier < high-tier < admin。群組不能給全域 admin（只有個人的全域角色可以）
$GroupsFile = Join-Path $ConfigDir 'groups.json'; $AcctAudit = Join-Path $ConfigDir 'account-audit.jsonl'
$GID_RE = '^[a-z0-9][a-z0-9-]{0,39}$'
function Read-Groups { if (Test-Path -LiteralPath $GroupsFile) { @((Get-Content -LiteralPath $GroupsFile -Raw -Encoding UTF8 | ConvertFrom-Json).groups | Where-Object { $_ }) } else { @() } }
function Save-Groups($list) { Initialize-ConfigDir; [ordered]@{ version = 1; groups = @($list) } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $GroupsFile -Encoding UTF8 }
function Get-RoleRank([string]$r) { [array]::IndexOf([string[]]$ROLES, $r) }
function Get-Members($g) { @($g.members | Where-Object { $_ } | ForEach-Object { [string]$_ }) }
function Write-AcctAudit($s, [string]$act, $detail) {   # 不記錄密碼或 token
  Initialize-ConfigDir; $line = [ordered]@{ at = (Get-NowIso); by = [string]$s.user; action = $act; detail = $detail } | ConvertTo-Json -Depth 5 -Compress
  [IO.File]::AppendAllText($AcctAudit, $line + "`n", [Text.UTF8Encoding]::new($false))
}
function Read-AcctAudit([int]$n) { if (-not (Test-Path -LiteralPath $AcctAudit)) { return @() }; @(Get-Content -LiteralPath $AcctAudit -Encoding UTF8 -Tail $n | Where-Object { $_ } | ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } | Where-Object { $_ }) }
function Update-UserStore {   # 舊版 users.json 移轉：補 status，建立空的 groups.json
  $list = @(Read-Users); $ch = $false
  foreach ($u in $list) { if (-not $u.PSObject.Properties['status']) { $u | Add-Member -NotePropertyName status -NotePropertyValue 'active' -Force; $ch = $true } }
  if ($ch) { Copy-Item -LiteralPath $Users -Destination ($Users + '.bak') -Force; Save-Users $list; Write-Host "已移轉 users.json（補上 status；舊檔備份為 users.json.bak）" }
  if ($list.Count -and -not (Test-Path -LiteralPath $GroupsFile)) { Save-Groups @() }
}
function ConvertTo-ProjMap($u) { $m = [ordered]@{}; if ($u.projects) { $u.projects.PSObject.Properties | ForEach-Object { $m[$_.Name] = $_.Value } }; $m }
function New-Record($name, $role, [byte[]]$pw, $projects) { $s = New-Salt; [ordered]@{ name = $name; role = $role; alg = 'PBKDF2-SHA256'; iter = $ITER; salt = [Convert]::ToBase64String($s); hash = [Convert]::ToBase64String((Get-Hash $pw $s $ITER)); projects = $projects } }
if ($AddUser -or $RemoveUser -or $ResetPassword -or $GrantUser) {
  foreach ($p in $Project) { if ($p -cnotmatch $PID_RE) { throw "專案 ID 格式錯誤：$p" } }
  $list = @(Read-Users)
  if ($AddUser) {
    if ($AddUser -notmatch $NAME_RE) { throw '帳號只能用英數、. _ -（1–32 字）' }
    if ($list | Where-Object name -eq $AddUser) { throw "帳號 $AddUser 已存在" }
    $pm = [ordered]@{}; foreach ($p in $Project) { $pm[$p] = $Role }
    $list += (New-Record $AddUser $Role (Read-Pw $AddUser) $pm); Save-Users $list
    Write-Host "已新增 $AddUser（$Role；專案：$(if($Role -eq 'admin'){'全部'}elseif($Project){$Project -join ','}else{'無，請用 -GrantUser 授權'})）"
  } elseif ($GrantUser) {
    $u = $list | Where-Object name -eq $GrantUser; if (-not $u) { throw "找不到 $GrantUser" }
    $pm = ConvertTo-ProjMap $u; foreach ($p in $Project) { $pm[$p] = $Role }
    $u | Add-Member -NotePropertyName projects -NotePropertyValue $pm -Force; Save-Users $list; Write-Host "已授權 $GrantUser：$($Project -join ',') = $Role"
  } elseif ($RemoveUser) {
    $n = @($list | Where-Object name -ne $RemoveUser); if ($n.Count -eq $list.Count) { throw "找不到 $RemoveUser" }; Save-Users $n; Write-Host "已移除 $RemoveUser"
  } else {
    $u = $list | Where-Object name -eq $ResetPassword; if (-not $u) { throw "找不到 $ResetPassword" }
    $r = New-Record $u.name $u.role (Read-Pw $u.name) (ConvertTo-ProjMap $u)
    Save-Users @($list | ForEach-Object { if ($_.name -eq $ResetPassword) { $r } else { $_ } }); Write-Host "已重設 $ResetPassword 的密碼"
  }
  return
}

# ---------- Git（參數陣列，不組 shell 字串）----------
function Invoke-Proc([string]$exe, [string]$dir, [string[]]$a, [int]$max = 5MB) {
  $psi = [Diagnostics.ProcessStartInfo]::new($exe); if ($dir) { $psi.WorkingDirectory = $dir }
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.UseShellExecute = $false
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
  if ($psi.PSObject.Properties['ArgumentList']) { foreach ($x in $a) { $psi.ArgumentList.Add($x) } }
  else { $psi.Arguments = ($a | ForEach-Object { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }) -join ' ' }
  $p = [Diagnostics.Process]::Start($psi); $errTask = $p.StandardError.ReadToEndAsync()
  $buf = [Text.StringBuilder]::new(); $chunk = [char[]]::new(8192)
  while (($n = $p.StandardOutput.Read($chunk, 0, $chunk.Length)) -gt 0) { if ($buf.Length -lt $max) { [void]$buf.Append($chunk, 0, $n) } }
  if (-not $p.WaitForExit(60000)) { try { $p.Kill() } catch {} }
  [pscustomobject]@{ Code = $p.ExitCode; Out = $buf.ToString(); Err = $errTask.Result }
}
function Invoke-Git($Pj, [string[]]$a, [int]$max = 5MB) { Invoke-Proc 'git' $Pj.dir $a $max }

# ---------- 載入專案 ----------
$projects = [ordered]@{}
function Add-LoadedProject($d) {
  if ($d.id -cnotmatch $PID_RE) { Write-Warning "略過格式錯誤的專案 ID：$($d.id)"; return $null }
  if (-not (Test-Path -LiteralPath $d.boardPath)) { Write-Warning "專案 $($d.id) 找不到 $($d.boardPath)，略過"; return $null }
  $bp = (Resolve-Path -LiteralPath $d.boardPath).Path
  $Pj = @{ id = $d.id; name = [string]$d.name; json = $bp; dir = $(if ($d.gitRepoPath) { $d.gitRepoPath } else { Split-Path -Parent $bp }); git = $false; rel = $null
          lastTag = $null; dirtyAt = $null; remote = [bool]$d.remoteSync; syncError = $null; nextSync = Get-Date; gh = $null }
  try {
    $r = Invoke-Git $Pj @('rev-parse', '--show-toplevel')
    if ($r.Code -ne 0 -and $InitGit) { [void](Invoke-Git $Pj @('init', '-q')); $r = Invoke-Git $Pj @('rev-parse', '--show-toplevel') }
    if ($r.Code -eq 0) {
      $top = [IO.Path]::GetFullPath($r.Out.Trim()).TrimEnd('\', '/')
      if (-not $bp.StartsWith($top, [StringComparison]::OrdinalIgnoreCase)) { Write-Warning "專案 $($d.id)：board.json 不在 $top 裡，版本歷史停用" }
      else { $Pj.dir = $top; $Pj.rel = $bp.Substring($top.Length).TrimStart('\', '/') -replace '\\', '/'; $Pj.git = $true }
    } else { Write-Warning "專案 $($d.id)：board.json 不在 git repo 裡，版本歷史停用（可加 -InitGit）" }
  } catch { Write-Warning '找不到 git，版本歷史停用'; $Pj.git = $false }
  if ($d.githubRepo) {
    if ($d.githubRepo -notmatch $REPO_RE) { Write-Warning "專案 $($d.id)：githubRepo 格式錯誤，PR 通知停用" }
    else { $Pj.gh = @{ repo = $d.githubRepo; etag = $null; prs = @{}; base = $false; next = Get-Date; lastList = @() } }
  }
  $projects[$d.id] = $Pj
  $Pj
}
if (-not $NoAuth) { Update-UserStore }
$defs = @(Read-Projects)
if ($Json) {
  $Json = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Json)
  if (-not (Test-Path -LiteralPath $Json)) { New-BoardFile $Json '預設專案' ([bool]$WithExample); Write-Host "board.json 不存在，已建立：$Json$(if ($WithExample) { '（含範例工單）' } else { '（空白，-WithExample 可加入範例）' })" }
  $defs = @([pscustomobject]@{ id = 'default'; name = '預設專案'; boardPath = (Resolve-Path $Json).Path; gitRepoPath = ''; githubRepo = $GitHubRepo; remoteSync = [bool]$RemoteSync }) + @($defs | Where-Object id -ne 'default')
}
foreach ($d in ($defs | Select-Object -First $MAX_PROJECTS)) { [void](Add-LoadedProject $d) }
$InstallRoot = $PSScriptRoot   # 看板執行檔放在安裝根目錄
$DefaultBoard = ''   # 新專案的 board.json 預設放在專案 repo 的 .ai-pm\board.json（由新增專案表單決定），不放在 GuGuBoard 安裝資料夾
if (-not $projects.Count) { Write-Warning '目前沒有專案：登入後由管理者在網頁上新增（或用 -AddProject）' }
if (-not $NoAuth -and -not (Read-Users).Count) { Write-Warning '還沒有任何帳號：第一次開啟網頁時會請你建立管理員帳號' }
if ($NoAuth) { Write-Warning '-NoAuth：不需登入，任何能連到本機的人都看得到所有專案。只在單人本機使用。' }
if ($GitHubApi -notmatch '^https?://[^\s/]+(:\d+)?(/[^\s]*)?$') { throw '-GitHubApi 必須是 http(s) 網址' }
$useGhCli = (-not $env:GITHUB_TOKEN) -and [bool](Get-Command gh -ErrorAction SilentlyContinue) -and $GitHubApi -eq 'https://api.github.com'
$ghInterval = [Math]::Max(15, $GitHubInterval)
$autoOn = $AutoCommit -eq 'on'

# ---------- SSE ----------
$clients = [System.Collections.Generic.List[object]]::new()
function Push-All([string]$event, $obj, [string]$projId) {
  $msg = if ($event) { "event: $event`ndata: " + ($obj | ConvertTo-Json -Compress -Depth 4) + "`n`n" } else { $obj }
  $b = [Text.Encoding]::UTF8.GetBytes($msg)
  for ($i = $clients.Count - 1; $i -ge 0; $i--) {
    $c = $clients[$i]
    if ($projId -and -not $c.allowed.ContainsKey($projId)) { continue }   # 只推給有權限的 session
    try { $c.res.OutputStream.Write($b, 0, $b.Length); $c.res.OutputStream.Flush() }
    catch { try { $c.res.Abort() } catch {}; $clients.RemoveAt($i) }
  }
}

# ---------- 自動 commit 與遠端同步 ----------
function Get-Summary([string]$oldText, [string]$newText) {
  try { $o = @{}; if ($oldText) { ($oldText | ConvertFrom-Json).items | ForEach-Object { $o[$_.id] = $_ } }
        $n = @{}; ($newText | ConvertFrom-Json).items | ForEach-Object { $n[$_.id] = $_ } } catch { return $null }
  $parts = [Collections.Generic.List[string]]::new()
  foreach ($id in $n.Keys) {
    if ($id -notmatch '^[A-Za-z0-9._-]{1,40}$') { continue }
    if (-not $o.ContainsKey($id)) { $parts.Add("+$id"); continue }
    $f = @(); $a = $o[$id].PSObject.Properties; $b = $n[$id].PSObject.Properties
    foreach ($k in (@($a.Name) + @($b.Name) | Select-Object -Unique)) { if (($a[$k].Value | ConvertTo-Json -Depth 8 -Compress) -ne ($b[$k].Value | ConvertTo-Json -Depth 8 -Compress)) { if ($k -match '^[A-Za-z]{1,30}$') { $f += $k } } }
    if ($f.Count) { $parts.Add("$id(" + ($f -join ',') + ')') }
  }
  foreach ($id in $o.Keys) { if (-not $n.ContainsKey($id) -and $id -match '^[A-Za-z0-9._-]{1,40}$') { $parts.Add("-$id") } }
  $s = ($parts | Sort-Object) -join ' '; if ($s.Length -gt 400) { $s = $s.Substring(0, 400) + '…' }
  if ($s) { "board: $s" } else { 'board: 格式調整' }
}
function Set-SyncError($Pj, $code) { if ($Pj.syncError -ne $code) { $Pj.syncError = $code; Push-All 'sync' @{ p = $Pj.id; error = $code } $Pj.id; if ($code) { Write-Warning "專案 $($Pj.id) 同步問題：$code" } } }
function Save-Commit($Pj) {
  $gdx = (Invoke-Git $Pj @('rev-parse', '--absolute-git-dir')).Out.Trim()
  if ($gdx -and ((Test-Path -LiteralPath (Join-Path $gdx 'rebase-merge')) -or (Test-Path -LiteralPath (Join-Path $gdx 'rebase-apply')) -or (Test-Path -LiteralPath (Join-Path $gdx 'MERGE_HEAD')) -or (Test-Path -LiteralPath (Join-Path $gdx 'CHERRY_PICK_HEAD')) -or (Test-Path -LiteralPath (Join-Path $gdx 'REVERT_HEAD')))) { $Pj.dirtyAt = Get-Date; return $false }   # merge／rebase 進行中不自動 commit
  $st = Invoke-Git $Pj @('status', '--porcelain', '--', $Pj.rel); if (-not $st.Out.Trim()) { return $false }
  $newText = [IO.File]::ReadAllText($Pj.json)
  $old = Invoke-Git $Pj @('show', "HEAD:$($Pj.rel)"); $oldText = if ($old.Code -eq 0) { $old.Out } else { '' }
  $msg = Get-Summary $oldText $newText
  if (-not $msg) { Write-Warning "專案 $($Pj.id)：board.json 不是合法 JSON，暫不 commit"; return $false }
  [void](Invoke-Git $Pj @('add', '--', $Pj.rel))
  $an = 'file-watch'; $ae = 'file-watch@ai-board.local'
  $ed = $null; if ($sessions) { $ed = $sessions.Values | Where-Object { $_.ghLogin -and $_.allowed.ContainsKey($Pj.id) -and $_.allowed[$Pj.id] -ne 'viewer' } | Sort-Object { $_.last } -Descending | Select-Object -First 1 }
  if ($ed) { $an = ($ed.ghName -replace '[<>\r\n]', ''); $ae = "$($ed.ghId)+$($ed.ghLogin)@users.noreply.github.com" }
  $c = Invoke-Git $Pj @('-c', "user.name=$an", '-c', "user.email=$ae", 'commit', '-q', '-m', $msg, '--', $Pj.rel)
  if ($c.Code -ne 0) { return $false }
  Write-Host "$(Get-Date -f HH:mm:ss) [$($Pj.id)] 已 commit：$msg"
  if ($Pj.remote) { $r = Invoke-Git $Pj @('push', '--quiet'); if ($r.Code -ne 0) { Set-SyncError $Pj 'E_PUSH_REJECTED' } else { Set-SyncError $Pj $null } }   # 不 force push
  $true
}
function Sync-Remote($Pj) {
  if (-not ($Pj.remote -and $Pj.git) -or (Get-Date) -lt $Pj.nextSync) { return }
  $Pj.nextSync = (Get-Date).AddSeconds([Math]::Max(15, $SyncInterval))
  $r = Invoke-Git $Pj @('pull', '--ff-only', '--quiet')
  if ($r.Code -ne 0) { Set-SyncError $Pj 'E_PULL_CONFLICT'; return }   # 不能快轉就停下來等人處理，不自動合併
  if ($Pj.syncError -eq 'E_PUSH_REJECTED') { $r = Invoke-Git $Pj @('push', '--quiet'); if ($r.Code -ne 0) { return } }
  Set-SyncError $Pj $null
}

# ---------- GitHub PR 通知（Token 只從環境變數 GITHUB_TOKEN 讀，不送到瀏覽器、不寫日誌）----------
function Invoke-GitHub($Pj, [string]$path, [switch]$UseEtag) {
  if ($useGhCli) { $r = Invoke-Proc 'gh' '' @('api', $path.TrimStart('/')) 2MB; if ($r.Code -ne 0) { return $null }; return @{ code = 200; body = $r.Out } }
  $h = @{ 'Accept' = 'application/vnd.github+json'; 'User-Agent' = 'ai-board'; 'X-GitHub-Api-Version' = '2022-11-28' }
  if ($env:GITHUB_TOKEN) { $h['Authorization'] = 'Bearer ' + $env:GITHUB_TOKEN }
  if ($UseEtag -and $Pj.gh.etag) { $h['If-None-Match'] = $Pj.gh.etag }
  try {
    $w = Invoke-WebRequest -Uri ($GitHubApi.TrimEnd('/') + $path) -Headers $h -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
    $rem = "$($w.Headers['X-RateLimit-Remaining'])"; if ($rem -match '^\d+$' -and [int]$rem -lt 5) { $Pj.gh.next = (Get-Date).AddMinutes(15) }
    if ($UseEtag) { $Pj.gh.etag = "$($w.Headers['ETag'])" }
    return @{ code = 200; body = $w.Content }
  } catch {
    $sc = 0; try { $sc = [int]$_.Exception.Response.StatusCode } catch {}
    if ($sc -eq 304) { return @{ code = 304 } }
    if ($sc -in 403, 429) { $Pj.gh.next = (Get-Date).AddMinutes(15) }
    return $null
  }
}
function Get-Ci($Pj, [string]$sha) {
  if ($sha -notmatch '^[0-9a-f]{40}$') { return 'None' }
  $r = Invoke-GitHub $Pj "/repos/$($Pj.gh.repo)/commits/$sha/check-runs?per_page=50"; if (-not $r -or $r.code -ne 200) { return $null }
  $runs = @(($r.body | ConvertFrom-Json).check_runs); if (-not $runs.Count) { return 'None' }
  if ($runs | Where-Object { $_.conclusion -in 'failure', 'timed_out', 'cancelled', 'action_required' }) { return 'Red' }
  if ($runs | Where-Object { $_.status -ne 'completed' }) { return 'Pending' }
  'Green'
}
function Get-PrEvent($Pj, $p, [string]$kind, [string]$ci) {
  $u = [string]$p.html_url; if ($u -notmatch '^https?://') { $u = '' }
  $t = [string]$p.title; if ($t.Length -gt 300) { $t = $t.Substring(0, 300) }
  $b = [string]$p.head.ref; if ($b.Length -gt 200) { $b = $b.Substring(0, 200) }
  $a = [string]$p.user.login; if ($a.Length -gt 100) { $a = $a.Substring(0, 100) }
  [ordered]@{ p = $Pj.id; kind = $kind; number = [int]$p.number; title = $t; url = $u; branch = $b; author = $a; ci = $ci; at = (Get-Date).ToString('o') }
}
function Update-GitHub($Pj) {
  $g = $Pj.gh; if ((Get-Date) -lt $g.next) { return }
  $g.next = (Get-Date).AddSeconds($ghInterval)
  $out = [Collections.Generic.List[object]]::new()
  $r = Invoke-GitHub $Pj "/repos/$($g.repo)/pulls?state=all&sort=updated&direction=desc&per_page=30" -UseEtag
  if ($r -and $r.code -eq 200) {
    $list = @($r.body | ConvertFrom-Json | Select-Object -First 30)
    foreach ($p in $list) {
      $n = [int]$p.number; $old = $g.prs[$n]; $merged = [bool]$p.merged_at; $state = [string]$p.state
      if ($g.base) {
        if (-not $old -and $state -eq 'open') { $out.Add((Get-PrEvent $Pj $p 'new' $null)) }
        elseif ($old -and $merged -and -not $old.merged) { $out.Add((Get-PrEvent $Pj $p 'merged' $null)) }
        elseif ($old -and $state -eq 'closed' -and $old.state -eq 'open' -and -not $merged) { $out.Add((Get-PrEvent $Pj $p 'closed' $null)) }
      }
      $g.prs[$n] = @{ state = $state; merged = $merged; ci = $(if ($old) { $old.ci } else { $null }) }
    }
    if ($g.prs.Count -gt 300) { foreach ($k in @($g.prs.Keys | Sort-Object | Select-Object -First ($g.prs.Count - 300))) { $g.prs.Remove($k) } }
    $g.lastList = @($list | Where-Object state -eq 'open' | Select-Object -First 20)
  }
  foreach ($p in @($g.lastList)) {
    $s = $g.prs[[int]$p.number]; if (-not $s) { continue }
    $ci = Get-Ci $Pj ([string]$p.head.sha); if (-not $ci) { continue }
    if ($g.base -and $s.ci -and $s.ci -ne $ci) { $out.Add((Get-PrEvent $Pj $p 'ci' $ci)) }
    $s.ci = $ci
  }
  $g.base = $true
  foreach ($e in $out) { Push-All 'pr' $e $Pj.id; Invoke-PrEvent $Pj $e; Write-Host "$(Get-Date -f HH:mm:ss) [$($Pj.id)] PR #$($e.number) $($e.kind)" }
}

# ---------- Session / 權限 ----------
$sessions = @{}; $fails = @{}
function New-Token { $b = [byte[]]::new(32); [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b); [Convert]::ToBase64String($b).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
function Get-Key([string]$t) { $h = [Security.Cryptography.SHA256]::Create(); try { [Convert]::ToBase64String($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($t))) } finally { $h.Dispose() } }
function Get-Allowed($u) {   # 預設拒絕；admin 看全部；其他人取個人與群組授權中最高的角色（見上方說明）
  $m = @{}
  if ([string]$u.status -eq 'disabled') { return $m }
  if ($u.role -eq 'admin') { foreach ($k in $projects.Keys) { $m[$k] = 'admin' }; return $m }
  $srcs = @(); if ($u.projects) { $srcs += , $u.projects }
  foreach ($g in @(Read-Groups)) { if ((Get-Members $g) -ccontains [string]$u.name -and $g.projects) { $srcs += , $g.projects } }
  foreach ($src in $srcs) { foreach ($pp in $src.PSObject.Properties) { $r = [string]$pp.Value
    if ($projects.Contains($pp.Name) -and $r -in $ROLES -and ((-not $m.ContainsKey($pp.Name)) -or (Get-RoleRank $r) -gt (Get-RoleRank $m[$pp.Name]))) { $m[$pp.Name] = $r } } }
  $m
}
function Update-AllSessions { $ul = @(Read-Users); foreach ($k in @($sessions.Keys)) { $u = $ul | Where-Object name -eq $sessions[$k].user | Select-Object -First 1; if ($u -and [string]$u.status -ne 'disabled') { $sessions[$k].role = $u.role; $sessions[$k].allowed = (Get-Allowed $u) } elseif (-not $NoAuth) { $sessions.Remove($k) } } }
function Get-Session($req) {
  if ($NoAuth) { $m = @{}; foreach ($k in $projects.Keys) { $m[$k] = 'admin' }; return @{ user = 'local'; role = 'admin'; allowed = $m } }
  $c = $req.Cookies['aib_sid']; if (-not $c -or $c.Value.Length -gt 100) { return $null }
  $k = Get-Key $c.Value; $s = $sessions[$k]; if (-not $s) { return $null }
  if (((Get-Date) - $s.last).TotalMinutes -gt $IDLE_MIN) { $sessions.Remove($k); return $null }
  $s.last = Get-Date
  if ($s.role -eq 'admin') { foreach ($k in $projects.Keys) { $s.allowed[$k] = 'admin' } }
  $s
}
function Send-Bytes($res, [byte[]]$b, [string]$type, [int]$code = 200) {
  $res.StatusCode = $code; $res.ContentType = $type; $res.ContentLength64 = $b.Length
  $res.Headers['Cache-Control'] = 'no-store'; $res.Headers['X-Content-Type-Options'] = 'nosniff'; $res.Headers['Referrer-Policy'] = 'no-referrer'
  $res.OutputStream.Write($b, 0, $b.Length); $res.Close()
}
function Send-Json($res, $obj, [int]$code = 200) { Send-Bytes $res ([Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 6 -Compress))) 'application/json; charset=utf-8' $code }
function Send-Err($res, [int]$code, [string]$err) { Send-Json $res @{ error = $err } $code }
function Test-Csrf($req) {
  if ($req.Headers['X-Board-Request'] -ne '1') { return $false }
  $o = $req.Headers['Origin']; $pu = ''; $x = Get-Sec (Read-Integ) 'external'; if ($x -and $x.enabled -and $x.publicUrl) { $pu = ([string]$x.publicUrl).TrimEnd('/') }
  if ($o -and $o -ne "http://localhost:$Port" -and $o -ne "http://127.0.0.1:$Port" -and -not ($pu -and $o -eq $pu)) { return $false }
  $true
}
function Invoke-Login($req, $res) {
  if ($req.ContentLength64 -gt $MAX_BODY) { return Send-Err $res 413 'E_TOO_LARGE' }
  $sr = [IO.StreamReader]::new($req.InputStream, [Text.Encoding]::UTF8); $body = $sr.ReadToEnd(); $sr.Dispose()
  try { $in = $body | ConvertFrom-Json } catch { return Send-Err $res 400 'E_BAD_REQUEST' }
  $name = [string]$in.username; $pw = [string]$in.password
  if ($name -notmatch $NAME_RE -or -not $pw -or $pw.Length -gt 256) { return Send-Err $res 401 'E_AUTH' }
  if ($fails.Count -gt 1000) { $fails.Clear() }
  $f = $fails[$name]; if ($f -and $f.until -and $f.until -gt (Get-Date)) { return Send-Err $res 429 'E_LOCKED' }
  $u = Read-Users | Where-Object { $_.name -eq $name -and $_.hash } | Select-Object -First 1
  $salt = if ($u) { [Convert]::FromBase64String($u.salt) } else { New-Salt }
  $calc = Get-Hash ([Text.Encoding]::UTF8.GetBytes($pw)) $salt $(if ($u) { [int]$u.iter } else { $ITER })   # 帳號不存在也算一次，避免時間差洩漏
  if (-not $u -or -not (Test-Equal $calc ([Convert]::FromBase64String($u.hash)))) {
    if (-not $f) { $f = @{ n = 0; until = $null }; $fails[$name] = $f }
    $f.n++; if ($f.n -ge $MAX_FAIL) { $f.until = (Get-Date).AddMinutes($LOCK_MIN); $f.n = 0; Write-Warning "帳號 $name 連續登入失敗，鎖定 $LOCK_MIN 分鐘" }
    return Send-Err $res 401 'E_AUTH'
  }
  $fails.Remove($name)
  if ($sessions.Count -ge $MAX_SESSIONS) { $old = $sessions.GetEnumerator() | Sort-Object { $_.Value.last } | Select-Object -First 1; $sessions.Remove($old.Key) }
  New-Session $res $u $null
}
function New-Session($res, $u, $gh) {   # $gh = @{ token; login; name; id }；token 只留在伺服器記憶體，不寫檔、不送到瀏覽器
  if ($sessions.Count -ge $MAX_SESSIONS) { $old = $sessions.GetEnumerator() | Sort-Object { $_.Value.last } | Select-Object -First 1; $sessions.Remove($old.Key) }
  if ([string]$u.status -eq 'disabled') { return Send-Err $res 403 'E_DISABLED' }
  $ul = @(Read-Users); $ux = $ul | Where-Object name -eq $u.name | Select-Object -First 1; if ($ux) { $ux | Add-Member -NotePropertyName lastLogin -NotePropertyValue (Get-NowIso) -Force; if ($gh) { $ux | Add-Member -NotePropertyName lastLoginVia -NotePropertyValue 'github' -Force } else { $ux | Add-Member -NotePropertyName lastLoginVia -NotePropertyValue 'local' -Force }; Save-Users $ul }
  $t = New-Token; $s = @{ user = $u.name; role = $u.role; allowed = (Get-Allowed $u); last = Get-Date; ghToken = $null; ghLogin = $null; ghName = $null; ghId = $null }
  if ($gh) { $s.ghToken = $gh.token; $s.ghLogin = $gh.login; $s.ghName = $gh.name; $s.ghId = $gh.id }
  $sessions[(Get-Key $t)] = $s
  $res.Headers.Add('Set-Cookie', "aib_sid=$t; Path=/; HttpOnly; SameSite=Strict; Max-Age=$($IDLE_MIN*60)")
  Send-Json $res @{ user = $u.name; role = $u.role }
}
function Update-UserSessions($name) {
  $u = Read-Users | Where-Object name -eq $name | Select-Object -First 1
  foreach ($k in @($sessions.Keys)) { if ($sessions[$k].user -eq $name) { if ($u -and [string]$u.status -ne 'disabled') { $sessions[$k].role = $u.role; $sessions[$k].allowed = (Get-Allowed $u) } else { $sessions.Remove($k) } } }
}
# ---------- GitHub 登入（OAuth Device Flow，只需 Client ID）----------
$flows = @{}
function Invoke-GhForm([string]$url, $form) {
  $w = Invoke-WebRequest -Method Post -Uri $url -Body $form -ContentType 'application/x-www-form-urlencoded' -Headers @{ Accept = 'application/json'; 'User-Agent' = 'ai-board' } -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop
  $w.Content | ConvertFrom-Json
}
function Invoke-GhStart($req, $res) {
  $cid = Read-OAuth; if (-not $cid) { return Send-Err $res 409 'E_NO_CLIENT_ID' }
  if ($flows.Count -ge 50) { foreach ($k in @($flows.Keys)) { if ($flows[$k].expires -lt (Get-Date)) { $flows.Remove($k) } }; if ($flows.Count -ge 50) { return Send-Err $res 503 'E_BUSY' } }
  try { $d = Invoke-GhForm ($GitHubWeb.TrimEnd('/') + '/login/device/code') @{ client_id = $cid; scope = $GH_SCOPE } } catch { return Send-Err $res 502 'E_GITHUB_UNREACHABLE' }
  if (-not $d.device_code) { return Send-Json $res @{ error = 'E_GITHUB'; message = [string]$d.error_description } 502 }
  $iv = 5; if ([string]$d.interval -match '^\d{1,3}$') { $iv = [Math]::Max(1, [int]$d.interval) }
  $ex = 900; if ([string]$d.expires_in -match '^\d{1,5}$') { $ex = [int]$d.expires_in }
  $fid = New-Token; $flows[$fid] = @{ device = [string]$d.device_code; interval = $iv; next = (Get-Date).AddSeconds($iv); expires = (Get-Date).AddSeconds($ex); local = $req.IsLocal }
  $vu = [string]$d.verification_uri; if ($vu -notmatch '^https?://') { $vu = 'https://github.com/login/device' }
  Send-Json $res @{ flow = $fid; userCode = [string]$d.user_code; verificationUri = $vu; interval = $iv; expiresIn = $ex }
}
function Invoke-GhPoll($req, $res) {
  $in = Read-Body $req; if (-not $in) { return Send-Err $res 400 'E_BAD_REQUEST' }
  $fid = [string]$in.flow; if ($fid.Length -gt 100) { return Send-Err $res 400 'E_BAD_REQUEST' }
  $f = $flows[$fid]; if (-not $f) { return Send-Err $res 404 'E_FLOW' }
  if ($f.expires -lt (Get-Date)) { $flows.Remove($fid); return Send-Err $res 410 'E_EXPIRED' }
  if ((Get-Date) -lt $f.next) { return Send-Json $res @{ status = 'pending' } }
  $f.next = (Get-Date).AddSeconds($f.interval)
  try { $t = Invoke-GhForm ($GitHubWeb.TrimEnd('/') + '/login/oauth/access_token') @{ client_id = (Read-OAuth); device_code = $f.device; grant_type = 'urn:ietf:params:oauth:grant-type:device_code' } } catch { return Send-Json $res @{ status = 'pending' } }
  if (-not $t.access_token) {
    switch ([string]$t.error) {
      'authorization_pending' { return Send-Json $res @{ status = 'pending' } }
      'slow_down' { $f.interval += 5; $f.next = (Get-Date).AddSeconds($f.interval); return Send-Json $res @{ status = 'pending' } }
      'expired_token' { $flows.Remove($fid); return Send-Err $res 410 'E_EXPIRED' }
      'access_denied' { $flows.Remove($fid); return Send-Err $res 403 'E_DENIED' }
      default { $flows.Remove($fid); return Send-Json $res @{ error = 'E_GITHUB'; message = [string]$t.error } 502 }
    }
  }
  $flows.Remove($fid); $tok = [string]$t.access_token
  try { $w = Invoke-WebRequest -Uri ($GitHubApi.TrimEnd('/') + '/user') -Headers @{ Authorization = "Bearer $tok"; Accept = 'application/vnd.github+json'; 'User-Agent' = 'ai-board' } -TimeoutSec 15 -UseBasicParsing -ErrorAction Stop; $gu = $w.Content | ConvertFrom-Json } catch { return Send-Err $res 502 'E_GITHUB_USER' }
  $login = [string]$gu.login; $gid = [string]$gu.id
  if ($login -notmatch '^[A-Za-z0-9-]{1,39}$' -or $gid -notmatch '^\d{1,20}$') { return Send-Err $res 502 'E_GITHUB_USER' }
  $dn = [string]$gu.name; if (-not $dn) { $dn = $login }; if ($dn.Length -gt 100) { $dn = $dn.Substring(0, 100) }
  $gh = @{ token = $tok; login = $login; name = $dn; id = $gid }
  $list = @(Read-Users)
  $u = $list | Where-Object { ([string]$_.githubId -and [string]$_.githubId -eq $gid) -or ((-not [string]$_.githubId) -and [string]$_.github -and ([string]$_.github).ToLower() -eq $login.ToLower()) } | Select-Object -First 1
  if ($u) {
    if (-not [string]$u.githubId) { $u | Add-Member -NotePropertyName githubId -NotePropertyValue $gid -Force; $u | Add-Member -NotePropertyName github -NotePropertyValue $login -Force; Save-Users $list }
    Write-Host "$(Get-Date -f HH:mm:ss) GitHub 登入：$login"; return New-Session $res $u $gh
  }
  if (-not $list.Count -and -not $NoAuth) {   # 第一個 GitHub 使用者成為管理者（只限本機）
    if (-not $f.local) { return Send-Err $res 403 'E_NOT_LOCAL' }
    $nu = [ordered]@{ name = $login; role = 'admin'; github = $login; githubId = $gid; projects = [ordered]@{} }
    Save-Users @($nu); Write-Host "$(Get-Date -f HH:mm:ss) 第一個 GitHub 使用者 $login 已成為管理者"
    return New-Session $res ([pscustomobject]$nu) $gh
  }
  $pend = @(Read-Pending)
  if (-not ($pend | Where-Object { [string]$_.githubId -eq $gid })) { if ($pend.Count -ge 200) { $pend = @($pend | Select-Object -Last 199) }; $pend += [ordered]@{ github = $login; githubId = $gid; name = $dn; at = (Get-Date).ToString('o') }; Save-Pending $pend; Write-Host "$(Get-Date -f HH:mm:ss) GitHub 使用者 $login 申請使用，等待管理者核准" }
  Send-Json $res @{ error = 'E_PENDING'; login = $login } 403
}
function Invoke-SetClientId($req, $res) {
  $s = Get-Session $req
  $ok = ($s -and $s.role -eq 'admin') -or ((Test-NeedSetup) -and $req.IsLocal)
  if (-not $ok) { return Send-Err $res 403 'E_FORBIDDEN' }
  $in = Read-Body $req; if (-not $in) { return Send-Err $res 400 'E_BAD_REQUEST' }
  try { Save-OAuth ([string]$in.clientId) } catch { return Send-Json $res @{ error = 'E_BAD_CLIENT_ID'; message = $_.Exception.Message } 400 }
  Send-Json $res @{ ok = $true }
}
# ---------- 管理者：帳號與核准 ----------
function Get-ProjMapFromIds($ids, [string]$role) { $m = [ordered]@{}; foreach ($p in @($ids)) { $p = [string]$p; if ($p -cmatch $PID_RE -and $projects.Contains($p)) { $m[$p] = $role } }; $m }
function Invoke-AdminUsers($req, $res, [bool]$post) {
  $s = Get-Session $req; if (-not $s) { return Send-Err $res 401 'E_UNAUTHENTICATED' }
  if ($s.role -ne 'admin') { return Send-Err $res 403 'E_FORBIDDEN' }
  if ($post) {
    $in = Read-Body $req; if (-not $in) { return Send-Err $res 400 'E_BAD_REQUEST' }
    $act = [string]$in.action; $role = [string]$in.role
    if ($act -in 'approve', 'update' -and $role -notin $ROLES) { return Send-Err $res 400 'E_BAD_ROLE' }
    $list = @(Read-Users); $glist = @(Read-Groups)
    $activeAdmins = @($list | Where-Object { $_.role -eq 'admin' -and [string]$_.status -ne 'disabled' }).Count
    $gFind = { param($gid) $glist | Where-Object { [string]$_.id -ceq [string]$gid } | Select-Object -First 1 }
    switch ($act) {
      'approve' {
        $pend = @(Read-Pending); $gid = [string]$in.githubId; $pe = $pend | Where-Object { [string]$_.githubId -eq $gid } | Select-Object -First 1
        if (-not $pe) { return Send-Err $res 404 'E_NOT_FOUND' }
        $nm = [string]$pe.github; if ($list | Where-Object name -eq $nm) { $nm = "gh-$nm" }
        if ($nm.Length -gt 40 -or ($list | Where-Object name -eq $nm)) { return Send-Err $res 409 'E_NAME_TAKEN' }
        $list += [ordered]@{ name = $nm; role = $role; github = [string]$pe.github; githubId = $gid; projects = (Get-ProjMapFromIds $in.projects $role) }
        Save-Users $list; Save-Pending @($pend | Where-Object { [string]$_.githubId -ne $gid }); Write-AcctAudit $s 'approve' @{ name = $nm; github = [string]$pe.github; role = $role }; Write-Host "$(Get-Date -f HH:mm:ss) $($s.user) 核准 GitHub 使用者 $($pe.github)（$role）"
      }
      'reject' { $gid = [string]$in.githubId; Save-Pending @(Read-Pending | Where-Object { [string]$_.githubId -ne $gid }); Write-AcctAudit $s 'reject' @{ githubId = $gid } }
      'update' {
        $u = $list | Where-Object name -eq ([string]$in.name) | Select-Object -First 1; if (-not $u) { return Send-Err $res 404 'E_NOT_FOUND' }
        if ($u.role -eq 'admin' -and $role -ne 'admin' -and [string]$u.status -ne 'disabled' -and $activeAdmins -le 1) { return Send-Err $res 409 'E_LAST_ADMIN' }
        $pm = Get-ProjMapFromIds $in.projects $role
        if ($in.projectRoles) { $pm = [ordered]@{}; foreach ($pp in $in.projectRoles.PSObject.Properties) { if ($pp.Name -cmatch $PID_RE -and $projects.Contains($pp.Name) -and [string]$pp.Value -in $ROLES) { $pm[$pp.Name] = [string]$pp.Value } } }
        $u | Add-Member -NotePropertyName role -NotePropertyValue $role -Force
        $u | Add-Member -NotePropertyName projects -NotePropertyValue $pm -Force
        Save-Users $list; Update-UserSessions $u.name; Write-AcctAudit $s 'update' @{ name = [string]$u.name; role = $role; projects = $pm }
      }
      'remove' {
        $nm = [string]$in.name; if ($nm -eq $s.user) { return Send-Err $res 409 'E_SELF' }
        $u = $list | Where-Object name -eq $nm | Select-Object -First 1; if (-not $u) { return Send-Err $res 404 'E_NOT_FOUND' }
        if ($u.role -eq 'admin' -and [string]$u.status -ne 'disabled' -and $activeAdmins -le 1) { return Send-Err $res 409 'E_LAST_ADMIN' }
        Save-Users @($list | Where-Object name -ne $nm); Update-UserSessions $nm
        foreach ($g in $glist) { $g.members = @(Get-Members $g | Where-Object { $_ -cne $nm }) }; Save-Groups $glist
        Write-AcctAudit $s 'remove' @{ name = $nm }
      }
      { $_ -in 'disable', 'enable' } {
        $nm = [string]$in.name; $u = $list | Where-Object name -eq $nm | Select-Object -First 1; if (-not $u) { return Send-Err $res 404 'E_NOT_FOUND' }
        if ($act -eq 'disable') { if ($nm -eq $s.user) { return Send-Err $res 409 'E_SELF' }; if ($u.role -eq 'admin' -and [string]$u.status -ne 'disabled' -and $activeAdmins -le 1) { return Send-Err $res 409 'E_LAST_ADMIN' } }
        $u | Add-Member -NotePropertyName status -NotePropertyValue $(if ($act -eq 'disable') { 'disabled' } else { 'active' }) -Force
        Save-Users $list; Update-UserSessions $nm; Write-AcctAudit $s $act @{ name = $nm }
      }
      'resetPassword' {   # 敏感操作：只限本機
        if (-not $req.IsLocal) { return Send-Err $res 403 'E_NOT_LOCAL' }
        $nm = [string]$in.name; $pw = [string]$in.password; $u = $list | Where-Object name -eq $nm | Select-Object -First 1; if (-not $u) { return Send-Err $res 404 'E_NOT_FOUND' }
        if ($pw.Length -lt 12 -or $pw.Length -gt 256) { return Send-Err $res 400 'E_WEAK_PASSWORD' }
        $r = New-Record $u.name $u.role ([Text.Encoding]::UTF8.GetBytes($pw)) $null
        foreach ($k in 'alg', 'iter', 'salt', 'hash') { $u | Add-Member -NotePropertyName $k -NotePropertyValue $r[$k] -Force }
        Save-Users $list; $fails.Remove($nm); foreach ($k in @($sessions.Keys)) { if ($sessions[$k].user -eq $nm -and $nm -ne $s.user) { $sessions.Remove($k) } }
        Write-AcctAudit $s 'resetPassword' @{ name = $nm }
      }
      'groupCreate' {
        $gid = [string]$in.id; $gn = [string]$in.name
        if ($gid -cnotmatch $GID_RE) { return Send-Err $res 400 'E_BAD_GROUP_ID' }; if (-not $gn -or $gn.Length -gt 60) { return Send-Err $res 400 'E_BAD_GROUP_NAME' }
        if (& $gFind $gid) { return Send-Err $res 409 'E_GROUP_EXISTS' }; if ($glist.Count -ge 100) { return Send-Err $res 409 'E_TOO_MANY' }
        $glist += [pscustomobject][ordered]@{ id = $gid; name = $gn; members = @(); projects = [pscustomobject]@{} }; Save-Groups $glist; Write-AcctAudit $s $act @{ id = $gid; name = $gn }
      }
      'groupRename' {
        $g = & $gFind $in.id; if (-not $g) { return Send-Err $res 404 'E_NOT_FOUND' }; $gn = [string]$in.name; if (-not $gn -or $gn.Length -gt 60) { return Send-Err $res 400 'E_BAD_GROUP_NAME' }
        $old = [string]$g.name; $g.name = $gn; Save-Groups $glist; Write-AcctAudit $s $act @{ id = [string]$g.id; from = $old; to = $gn }
      }
      'groupDelete' {
        $g = & $gFind $in.id; if (-not $g) { return Send-Err $res 404 'E_NOT_FOUND' }
        Save-Groups @($glist | Where-Object { [string]$_.id -cne [string]$g.id }); Update-AllSessions; Write-AcctAudit $s $act @{ id = [string]$g.id; name = [string]$g.name }
      }
      'groupSet' {   # 成員與每個專案的角色
        $g = & $gFind $in.id; if (-not $g) { return Send-Err $res 404 'E_NOT_FOUND' }
        $mem = @(@($in.members) | Where-Object { $_ } | ForEach-Object { [string]$_ } | Select-Object -Unique)
        foreach ($m in $mem) { if (-not ($list | Where-Object { [string]$_.name -ceq $m })) { return Send-Err $res 400 'E_BAD_MEMBER' } }
        $pm = [ordered]@{}; if ($in.projects) { foreach ($pp in $in.projects.PSObject.Properties) { if ($pp.Name -cmatch $PID_RE -and $projects.Contains($pp.Name) -and [string]$pp.Value -in $ROLES) { $pm[$pp.Name] = [string]$pp.Value } } }
        $g | Add-Member -NotePropertyName members -NotePropertyValue $mem -Force; $g | Add-Member -NotePropertyName projects -NotePropertyValue ([pscustomobject]$pm) -Force
        Save-Groups $glist; Update-AllSessions; Write-AcctAudit $s $act @{ id = [string]$g.id; members = $mem; projects = $pm }
      }
      default { return Send-Err $res 400 'E_BAD_ACTION' }
    }
  }
  $gl = @(Read-Groups)
  $ul = @(Read-Users | ForEach-Object { $pm = ConvertTo-ProjMap $_; $nm = [string]$_.name; $st = [string]$_.status; if (-not $st) { $st = 'active' }
    [ordered]@{ name = $nm; role = [string]$_.role; status = $st; github = [string]$_.github; local = [bool]$_.hash; lastLogin = [string]$_.lastLogin; lastLoginVia = [string]$_.lastLoginVia; projects = @($pm.Keys); projectRoles = $pm
      groups = @($gl | Where-Object { (Get-Members $_) -ccontains $nm } | ForEach-Object { [string]$_.id }); effective = (Get-Allowed $_) } })
  $glo = @($gl | ForEach-Object { [ordered]@{ id = [string]$_.id; name = [string]$_.name; members = @(Get-Members $_); projects = (ConvertTo-ProjMap $_) } })
  $pl = @(Read-Pending | ForEach-Object { [ordered]@{ github = [string]$_.github; githubId = [string]$_.githubId; name = [string]$_.name; at = $(if ($_.at -is [datetime]) { $_.at.ToUniversalTime().ToString('o') } else { [string]$_.at }) } })
  $pj = @($projects.Values | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name; repo = $_.dir; boardPath = $_.json; applied = (Test-Path -LiteralPath (Join-Path $_.dir '.ai-dev-skills-manifest.txt')) } })
  Send-Json $res @{ users = $ul; pending = $pl; projects = $pj; groups = $glo; audit = @(Read-AcctAudit 100); clientId = [bool](Read-OAuth); local = [bool]$req.IsLocal; me = [string]$s.user }
}
# ---------- Git 分頁（唯讀）----------
function Invoke-GhApi([string]$path, [string]$token) {
  if (-not $token) { $token = $env:GITHUB_TOKEN }
  if (-not $token -and $useGhCli) { $r = Invoke-Proc 'gh' '' @('api', $path.TrimStart('/')) 2MB; if ($r.Code -ne 0) { return $null }; return $r.Out }
  $h = @{ 'Accept' = 'application/vnd.github+json'; 'User-Agent' = 'ai-board'; 'X-GitHub-Api-Version' = '2022-11-28' }
  if ($token) { $h['Authorization'] = 'Bearer ' + $token }
  try { (Invoke-WebRequest -Uri ($GitHubApi.TrimEnd('/') + $path) -Headers $h -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop).Content } catch { $null }
}
function Get-RepoSlug($Pj) {
  if ($Pj.gh) { return $Pj.gh.repo }
  if (-not $Pj.git) { return $null }
  $r = Invoke-Git $Pj @('remote', 'get-url', 'origin'); if ($r.Code -ne 0) { return $null }
  if ($r.Out.Trim() -match 'github\.com[:/]([A-Za-z0-9_.-]{1,100})/([A-Za-z0-9_.-]{1,100}?)(\.git)?/?$') { return "$($Matches[1])/$($Matches[2])" }
  $null
}
function Clip([string]$x, [int]$n) { if ($x.Length -gt $n) { $x.Substring(0, $n) } else { $x } }
function Get-IsoDate($v) { if ($v -is [datetime]) { $v.ToUniversalTime().ToString('o') } else { [string]$v } }
function Get-MainRef($Pj) {
  $r = Invoke-Git $Pj @('symbolic-ref', '-q', '--short', 'refs/remotes/origin/HEAD'); if ($r.Code -eq 0 -and $r.Out.Trim()) { return $r.Out.Trim() }
  foreach ($c in 'main', 'master', 'origin/main', 'origin/master', 'develop') { $r = Invoke-Git $Pj @('rev-parse', '--verify', '-q', "$c^{commit}"); if ($r.Code -eq 0) { return $c } }
  $null
}
function Get-GitBranches($Pj) {
  $fmt = '--format=' + ('%(refname)|%(refname:short)|%(HEAD)|%(upstream:short)|%(upstream:track)|%(objectname)|%(committerdate:iso-strict)|%(authorname)|%(subject)' -replace '\|', '%1F')
  $r = Invoke-Git $Pj @('for-each-ref', $fmt, 'refs/heads', 'refs/remotes') 1MB
  $main = Get-MainRef $Pj; $merged = @{}
  if ($main) { $m = Invoke-Git $Pj @('for-each-ref', '--merged', $main, '--format=%(refname)', 'refs/heads', 'refs/remotes'); foreach ($l in ($m.Out -split "`n")) { if ($l) { $merged[$l.Trim()] = $true } } }
  $rows = @(); $k = 0
  foreach ($line in ($r.Out -split "`n")) {
    if (-not $line) { continue }; $x = $line -split [char]0x1f; if ($x.Count -lt 9) { continue }
    if ($x[0] -like 'refs/remotes/*/HEAD') { continue }
    $ah = 0; $bh = 0; if ($x[4] -match 'ahead (\d+)') { $ah = [int]$Matches[1] }; if ($x[4] -match 'behind (\d+)') { $bh = [int]$Matches[1] }
    $am = $null; $bm = $null
    if ($main -and $k -lt 100 -and $x[1] -ne $main) { $k++; $c = Invoke-Git $Pj @('rev-list', '--left-right', '--count', "$main...$($x[5])"); if ($c.Code -eq 0 -and $c.Out.Trim() -match '^(\d+)\s+(\d+)$') { $bm = [int]$Matches[1]; $am = [int]$Matches[2] } }
    $rows += [ordered]@{ name = $x[1]; remote = ($x[0] -like 'refs/remotes/*'); current = ($x[2] -eq '*'); upstream = $x[3]; ahead = $ah; behind = $bh; gone = ($x[4] -match 'gone'); sha = $x[5]; at = $x[6]; author = (Clip $x[7] 100); subject = (Clip $x[8] 200)
      aheadMain = $am; behindMain = $bm; merged = $(if ($main) { [bool]$merged[$x[0]] } else { $null }); isMain = ($x[1] -eq $main) }
  }
  $rm = Invoke-Git $Pj @('remote')
  $cur = Invoke-Git $Pj @('rev-parse', '--abbrev-ref', 'HEAD')
  @{ branches = $rows; remotes = @($rm.Out -split "`n" | Where-Object { $_ }); head = $cur.Out.Trim(); main = $main }
}
function Get-GitOverview($Pj) {
  $o = [ordered]@{}
  $o.branch = (Invoke-Git $Pj @('rev-parse', '--abbrev-ref', 'HEAD')).Out.Trim()
  $h = Invoke-Git $Pj @('rev-parse', 'HEAD'); $o.head = $(if ($h.Code -eq 0) { $h.Out.Trim() } else { $null })
  $u = Invoke-Git $Pj @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}'); $o.upstream = $null; $o.ahead = 0; $o.behind = 0
  if ($u.Code -eq 0) { $o.upstream = $u.Out.Trim(); $c = Invoke-Git $Pj @('rev-list', '--left-right', '--count', 'HEAD...@{u}'); if ($c.Out.Trim() -match '^(\d+)\s+(\d+)$') { $o.ahead = [int]$Matches[1]; $o.behind = [int]$Matches[2] } }
  $st = Invoke-Git $Pj @('status', '--porcelain=v1') 1MB
  $files = @($st.Out -split "`n" | Where-Object { $_.Length -gt 3 } | ForEach-Object { [ordered]@{ code = $_.Substring(0, 2); path = (Clip $_.Substring(3) 300) } })
  $o.changes = $files.Count; $o.changedFiles = @($files | Select-Object -First 200)
  $o.stash = @((Invoke-Git $Pj @('stash', 'list')).Out -split "`n" | Where-Object { $_ }).Count
  $gd = (Invoke-Git $Pj @('rev-parse', '--absolute-git-dir')).Out.Trim(); $o.lastFetch = $null
  if ($gd) { $fh = Join-Path $gd 'FETCH_HEAD'; if (Test-Path -LiteralPath $fh) { $o.lastFetch = (Get-Item -LiteralPath $fh).LastWriteTimeUtc.ToString('o') } }
  $rv = Invoke-Git $Pj @('remote', '-v')
  $o.remotes = @($rv.Out -split "`n" | Where-Object { $_ -match '\(fetch\)$' } | ForEach-Object { $y = $_ -split '\s+'; [ordered]@{ name = $y[0]; url = (Clip ($y[1] -replace '://[^/@\s]+@', '://') 300) } })
  $tg = Invoke-Git $Pj @('for-each-ref', '--sort=-creatordate', '--count=100', ('--format=' + ('%(refname:short)|%(creatordate:iso-strict)|%(objectname)|%(*objectname)' -replace '\|', '%1F')), 'refs/tags')
  $o.tags = @($tg.Out -split "`n" | Where-Object { $_ } | ForEach-Object { $y = $_ -split [char]0x1f; [ordered]@{ name = (Clip $y[0] 100); at = $y[1]; sha = $(if ($y.Count -gt 3 -and $y[3]) { $y[3] } else { $y[2] }) } })
  $since = (Get-Date).Date.AddDays(-29)
  $lg = Invoke-Git $Pj @('log', '--branches', '--remotes', '--tags', "--since=$($since.ToString('yyyy-MM-dd'))", '--format=%an%x1f%aI', '--max-count=5000') 2MB
  $auth = @{}; $days = [ordered]@{}; for ($i = 0; $i -lt 30; $i++) { $days[$since.AddDays($i).ToString('yyyy-MM-dd')] = 0 }
  foreach ($l in ($lg.Out -split "`n")) {
    if (-not $l) { continue }; $y = $l -split [char]0x1f; if ($y.Count -lt 2) { continue }
    $a = Clip $y[0] 100; if ($auth.ContainsKey($a)) { $auth[$a]++ } else { $auth[$a] = 1 }
    try { $d = ([DateTimeOffset]::Parse($y[1])).LocalDateTime.ToString('yyyy-MM-dd'); if ($days.Contains($d)) { $days[$d]++ } } catch {}
  }
  $o.contributors = @($auth.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 20 | ForEach-Object { [ordered]@{ name = $_.Key; commits = $_.Value } })
  $o.activity = @($days.GetEnumerator() | ForEach-Object { [ordered]@{ day = $_.Key; n = $_.Value } })
  $o.main = Get-MainRef $Pj
  $o
}
function Get-GitGraph($Pj, $q) {
  $lim = 200; $skip = 0
  if ($q['limit'] -match '^\d{1,3}$') { $lim = [Math]::Min(500, [Math]::Max(1, [int]$q['limit'])) }
  if ($q['skip'] -match '^\d{1,6}$') { $skip = [int]$q['skip'] }
  $a = @('log', '--topo-order', "--max-count=$($lim+1)", "--skip=$skip", '--format=%H%x1f%P%x1f%an%x1f%ae%x1f%aI%x1f%cn%x1f%cI%x1f%s%x1f%D')
  $au = [string]$q['author']; if ($au) { if ($au.Length -gt 100) { return $null }; $a += @('-F', '-i', "--author=$au") }
  $ref = [string]$q['ref']
  if ($ref) { if ($ref -notmatch '^[A-Za-z0-9._/-]{1,200}$' -or $ref.StartsWith('-') -or $ref.Contains('..')) { return $null }; $a += $ref }
  elseif ($q['all'] -eq '1') { $a += @('--branches', 'HEAD'); if ($q['remotes'] -eq '1') { $a += '--remotes' }; if ($q['tags'] -eq '1') { $a += '--tags' } }
  else { $a += 'HEAD' }
  $a += '--'
  $r = Invoke-Git $Pj $a 4MB
  $rows = @()
  foreach ($l in ($r.Out -split "`n")) {
    if (-not $l) { continue }; $x = $l -split [char]0x1f; if ($x.Count -lt 9) { continue }
    $rows += [ordered]@{ sha = $x[0]; parents = @($x[1] -split ' ' | Where-Object { $_ }); author = (Clip $x[2] 100); email = (Clip $x[3] 200); at = $x[4]; committer = (Clip $x[5] 100); committedAt = $x[6]; subject = (Clip $x[7] 300); refs = @($x[8] -split ', ' | Where-Object { $_ } | ForEach-Object { Clip $_ 200 } | Select-Object -First 30) }
  }
  @{ commits = @($rows | Select-Object -First $lim); more = ($rows.Count -gt $lim); skip = $skip }
}
function Get-CommitInfo($Pj, [string]$sha) {
  $r = Invoke-Git $Pj @('show', '-s', '--format=%H%x1f%P%x1f%an%x1f%ae%x1f%aI%x1f%cn%x1f%ce%x1f%cI%x1f%D%x1f%B', $sha, '--') 1MB
  if ($r.Code -ne 0) { return $null }
  $x = $r.Out -split [char]0x1f, 10; if ($x.Count -lt 10) { return $null }
  $full = $x[0].Trim(); $par = @($x[1] -split ' ' | Where-Object { $_ })
  $br = Invoke-Git $Pj @('branch', '-a', '--contains', $full, '--format=%(refname:short)')
  $tg = Invoke-Git $Pj @('tag', '--contains', $full)
  if ($par.Count) { $ns = Invoke-Git $Pj @('diff', '--name-status', '-M', $par[0], $full, '--') 2MB; $nm = Invoke-Git $Pj @('diff', '--numstat', '-M', $par[0], $full, '--') 2MB }
  else { $ns = Invoke-Git $Pj @('diff-tree', '--root', '-r', '-M', '--no-commit-id', '--name-status', $full) 2MB; $nm = Invoke-Git $Pj @('diff-tree', '--root', '-r', '-M', '--no-commit-id', '--numstat', $full) 2MB }
  $nsl = @($ns.Out -split "`n" | Where-Object { $_ }); $nml = @($nm.Out -split "`n" | Where-Object { $_ })
  $files = @(); $ti = 0; $td = 0
  for ($i = 0; $i -lt [Math]::Min(500, $nsl.Count); $i++) {
    $y = $nsl[$i] -split "`t"; $st = $y[0].Substring(0, 1); $path = $y[$y.Count - 1]; $old = $(if ($y.Count -gt 2) { $y[1] } else { $null })
    $ins = $null; $del = $null; if ($i -lt $nml.Count) { $z = $nml[$i] -split "`t"; if ($z[0] -match '^\d+$') { $ins = [int]$z[0]; $ti += $ins }; if ($z[1] -match '^\d+$') { $del = [int]$z[1]; $td += $del } }
    $files += [ordered]@{ status = $st; path = (Clip $path 400); oldPath = $old; insertions = $ins; deletions = $del }
  }
  [ordered]@{ sha = $full; parents = $par; author = $x[2]; email = $x[3]; at = $x[4]; committer = $x[5]; committerEmail = $x[6]; committedAt = $x[7]; refs = @($x[8] -split ', ' | Where-Object { $_ }); message = (Clip $x[9].Trim() 20000)
    branches = @($br.Out -split "`n" | Where-Object { $_ } | Select-Object -First 50); tags = @($tg.Out -split "`n" | Where-Object { $_ } | Select-Object -First 50)
    files = $files; fileCount = $nsl.Count; insertions = $ti; deletions = $td }
}
function Get-FileDiff($Pj, [string]$sha, [string]$path, [string]$old) {
  if (-not $path -or $path.Length -gt 400 -or $path -match '[\x00-\x1f]') { return $null }
  $specs = @($path); if ($old -and $old.Length -le 400 -and $old -notmatch '[\x00-\x1f]' -and $old -ne $path) { $specs += $old }
  $p = Invoke-Git $Pj @('rev-parse', "$sha^@"); $par = @($p.Out -split "`n" | Where-Object { $_ })
  if ($par.Count) { $r = Invoke-Git $Pj (@('diff', '--no-color', '-M', $par[0], $sha, '--') + $specs) 1MB } else { $r = Invoke-Git $Pj @('show', '--no-color', '--format=', $sha, '--', $path) 1MB }
  if ($r.Code -ne 0) { return $null }; $r.Out
}
function Get-GitLog($Pj, $q) {
  $lim = 30; $skip = 0
  if ($q['limit'] -match '^\d{1,3}$') { $lim = [Math]::Min(100, [Math]::Max(1, [int]$q['limit'])) }
  if ($q['skip'] -match '^\d{1,6}$') { $skip = [int]$q['skip'] }
  $a = @('log', "--max-count=$($lim+1)", "--skip=$skip", '--shortstat', '--format=%x1e%H%x1f%aI%x1f%an%x1f%s')
  $ref = [string]$q['ref']; if ($ref) { if ($ref -notmatch '^[A-Za-z0-9._/-]{1,200}$' -or $ref.StartsWith('-') -or $ref.Contains('..')) { return $null }; $a += @($ref, '--') }
  $r = Invoke-Git $Pj $a 2MB
  $rows = @()
  foreach ($chunk in ($r.Out -split [char]0x1e)) {
    $chunk = $chunk.Trim(); if (-not $chunk) { continue }
    $lines = $chunk -split "`n"; $x = $lines[0] -split [char]0x1f; if ($x.Count -lt 4) { continue }
    $st = ($lines | Select-Object -Skip 1) -join ' '; $fc = 0; $ins = 0; $del = 0
    if ($st -match '(\d+) files? changed') { $fc = [int]$Matches[1] }; if ($st -match '(\d+) insertion') { $ins = [int]$Matches[1] }; if ($st -match '(\d+) deletion') { $del = [int]$Matches[1] }
    $rows += [ordered]@{ sha = $x[0]; at = $x[1]; author = $x[2]; message = $(if ($x[3].Length -gt 500) { $x[3].Substring(0, 500) } else { $x[3] }); files = $fc; insertions = $ins; deletions = $del }
  }
  @{ commits = @($rows | Select-Object -First $lim); more = ($rows.Count -gt $lim); empty = ($r.Code -ne 0) }
}
function Get-GitPrs($Pj, $s) {
  $slug = Get-RepoSlug $Pj; if (-not $slug) { return @{ repo = $null; error = 'E_NO_GITHUB_REPO'; prs = @() } }
  $tk = $s.ghToken; $ck = $(if ($tk) { 'u:' + $s.ghLogin } else { 'p' })
  if (-not $Pj.prCache) { $Pj.prCache = @{} }
  $c = $Pj.prCache[$ck]; if ($c -and ((Get-Date) - $c.at).TotalSeconds -lt 60) { return $c.data }
  $body = Invoke-GhApi "/repos/$slug/pulls?state=all&sort=updated&direction=desc&per_page=30" $tk
  if (-not $body) { return @{ repo = $slug; error = 'E_GITHUB'; prs = @() } }
  $out = @(); $n = 0
  foreach ($p in @($body | ConvertFrom-Json)) {
    $state = [string]$p.state; if ($p.merged_at) { $state = 'merged' }
    $ci = $null; $checks = @(); $reviews = @(); $mergeable = $null; $mstate = $null
    if ($state -eq 'open' -and $n -lt 10 -and [string]$p.head.sha -match '^[0-9a-f]{40}$') {
      $n++; $cb = Invoke-GhApi "/repos/$slug/commits/$($p.head.sha)/check-runs?per_page=50" $tk
      if ($cb) { $runs = @(($cb | ConvertFrom-Json).check_runs); if (-not $runs.Count) { $ci = 'None' } elseif ($runs | Where-Object { $_.conclusion -in 'failure', 'timed_out', 'cancelled', 'action_required' }) { $ci = 'Red' } elseif ($runs | Where-Object { $_.status -ne 'completed' }) { $ci = 'Pending' } else { $ci = 'Green' }
        $checks = @($runs | Select-Object -First 30 | ForEach-Object { [ordered]@{ name = (Clip ([string]$_.name) 100); status = [string]$_.status; conclusion = [string]$_.conclusion } }) }
      $rb = Invoke-GhApi "/repos/$slug/pulls/$([int]$p.number)/reviews?per_page=100" $tk
      if ($rb) { $last = [ordered]@{}; foreach ($rv in @($rb | ConvertFrom-Json)) { $lg = [string]$rv.user.login; $rs = [string]$rv.state; if ($lg) { if ($rs -ne 'COMMENTED' -or -not $last.Contains($lg)) { $last[$lg] = $rs } } }; $reviews = @($last.Keys | Where-Object { $_ } | ForEach-Object { [ordered]@{ login = (Clip $_ 39); state = $last[$_] } }) }
      $pb = Invoke-GhApi "/repos/$slug/pulls/$([int]$p.number)" $tk
      if ($pb) { $pd = $pb | ConvertFrom-Json; if ($null -ne $pd.mergeable) { $mergeable = [bool]$pd.mergeable }; $mstate = [string]$pd.mergeable_state }
    }
    $u = [string]$p.html_url; if ($u -notmatch '^https?://') { $u = '' }
    $t = [string]$p.title; if ($t.Length -gt 300) { $t = $t.Substring(0, 300) }
    $out += [ordered]@{ number = [int]$p.number; title = $t; state = $state; url = $u; branch = [string]$p.head.ref; author = [string]$p.user.login; ci = $ci; updatedAt = (Get-IsoDate $p.updated_at)
      draft = [bool]$p.draft; labels = @($p.labels | Select-Object -First 20 | ForEach-Object { [ordered]@{ name = (Clip ([string]$_.name) 50); color = $(if ([string]$_.color -match '^[0-9a-fA-F]{6}$') { [string]$_.color } else { 'cccccc' }) } })
      requested = @($p.requested_reviewers | Select-Object -First 20 | ForEach-Object { Clip ([string]$_.login) 39 }); reviews = $reviews; checks = $checks; mergeable = $mergeable; mergeableState = $mstate
      mergeSha = [string]$p.merge_commit_sha; headSha = [string]$p.head.sha; avatar = $(if ([string]$p.user.avatar_url -match '^https://avatars\.githubusercontent\.com/') { [string]$p.user.avatar_url } else { '' }) }
  }
  $data = @{ repo = $slug; prs = $out; via = $(if ($tk) { 'user' } elseif ($env:GITHUB_TOKEN) { 'GITHUB_TOKEN' } elseif ($useGhCli) { 'gh' } else { 'anonymous' }) }
  $Pj.prCache[$ck] = @{ at = Get-Date; data = $data }; $data
}
function Read-Body($req) {
  if ($req.ContentLength64 -gt $MAX_BODY) { return $null }
  $sr = [IO.StreamReader]::new($req.InputStream, [Text.Encoding]::UTF8); $body = $sr.ReadToEnd(); $sr.Dispose()
  if ($body.Length -gt $MAX_BODY) { return $null }
  try { $body | ConvertFrom-Json } catch { $null }
}
function Test-NeedSetup { (-not $NoAuth) -and (-not @(Read-Users).Count) }
function Invoke-Setup($req, $res) {
  if (-not $req.IsLocal) { return Send-Err $res 403 'E_NOT_LOCAL' }
  if (-not (Test-NeedSetup)) { return Send-Err $res 409 'E_ALREADY_SETUP' }
  $in = Read-Body $req; if (-not $in) { return Send-Err $res 400 'E_BAD_REQUEST' }
  $name = [string]$in.username; $pw = [string]$in.password
  if ($name -notmatch $NAME_RE) { return Send-Err $res 400 'E_BAD_NAME' }
  if ($pw.Length -lt 12 -or $pw.Length -gt 256) { return Send-Err $res 400 'E_WEAK_PASSWORD' }
  if ([string]$in.confirm -ne $pw) { return Send-Err $res 400 'E_MISMATCH' }
  $rec = New-Record $name 'admin' ([Text.Encoding]::UTF8.GetBytes($pw)) ([ordered]@{})
  if (-not (Test-NeedSetup)) { return Send-Err $res 409 'E_ALREADY_SETUP' }
  Save-Users @($rec); Write-Host "$(Get-Date -f HH:mm:ss) 已建立管理員帳號 $name"
  Send-Json $res @{ ok = $true; user = $name }
}
function Invoke-AddProject($req, $res) {
  $s = Get-Session $req; if (-not $s) { return Send-Err $res 401 'E_UNAUTHENTICATED' }
  if ($s.role -ne 'admin') { return Send-Err $res 403 'E_FORBIDDEN' }
  $in = Read-Body $req; if (-not $in) { return Send-Err $res 400 'E_BAD_REQUEST' }
  $repo = [string]$in.repoPath; $bp = [string]$in.boardPath
  if ($repo) { if (-not [IO.Path]::IsPathRooted($repo) -or -not (Test-Path -LiteralPath $repo -PathType Container)) { return Send-Json $res @{ error = 'E_PROJECT'; message = '專案 repo 資料夾不存在（請填絕對路徑）' } 400 }; $repo = (Resolve-Path -LiteralPath $repo).Path.TrimEnd('\', '/') }
  if (-not $bp -and $repo) { $bp = Join-Path (Join-Path $repo '.ai-pm') 'board.json' }
  if (-not $bp) { return Send-Json $res @{ error = 'E_PROJECT'; message = '請填專案的 repo 資料夾' } 400 }
  if (Test-InInstall $bp) { return Send-Json $res @{ error = 'E_PROJECT'; message = 'board.json 不能放在 GuGuBoard 安裝資料夾裡，請放在專案 repo 內（預設 <repo>\.ai-pm\board.json）' } 400 }
  if ($repo -and -not ([IO.Path]::GetFullPath($bp)).StartsWith($repo + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { return Send-Json $res @{ error = 'E_PROJECT'; message = 'board.json 必須在專案 repo 資料夾裡' } 400 }
  $nm = [string]$in.name; if ($nm.Length -gt 100) { $nm = $nm.Substring(0, 100) }
  try { $d = Register-Project ([string]$in.id) $nm $bp $repo ([string]$in.githubRepo) $false ($in.withExample -eq $true) } catch { return Send-Json $res @{ error = 'E_PROJECT'; message = $_.Exception.Message } 400 }
  $Pj = Add-LoadedProject $d
  if (-not $Pj) { return Send-Err $res 500 'E_PROJECT_LOAD' }
  $Pj.lastTag = Get-Tag $Pj; $Pj.lastText = [IO.File]::ReadAllText($Pj.json)
  if ($Pj.git -and $autoOn) { try { [void](Save-Commit $Pj) } catch { Write-Warning "[$($Pj.id)] 自動 commit 失敗" } }
  foreach ($k in @($sessions.Keys)) { if ($sessions[$k].role -eq 'admin') { $sessions[$k].allowed[$Pj.id] = 'admin' } }
  Send-Json $res @{ ok = $true; id = $Pj.id; git = $Pj.git; repo = $Pj.dir }
}
# 清除範例工單（管理者）：confirm 不為 true 時只回報會刪哪些；只刪範例工單並留下 removed 紀錄（reason = example），其他工單的 parentId 若指到被刪的卡就改成 null
function Invoke-ClearExamples($req, $res, [string]$id) {
  $s = Get-Session $req; if (-not $s) { return Send-Err $res 401 'E_UNAUTHENTICATED' }
  if ($s.external) { return Send-Err $res 403 'E_READ_ONLY' }
  if ($s.role -ne 'admin' -or -not $s.allowed.ContainsKey($id)) { return Send-Err $res 403 'E_FORBIDDEN' }
  $Pj = $projects[$id]; if (-not $Pj) { return Send-Err $res 404 'E_NOT_FOUND' }
  $in = Read-Body $req; if (-not $in) { return Send-Err $res 400 'E_BAD_REQUEST' }
  try { $d = Read-BoardObj $Pj } catch { return Send-Json $res @{ error = 'E_BAD_JSON'; message = 'board.json 不是合法 JSON，無法清除' } 409 }
  $sig = Get-ExampleSig; $keep = [Collections.ArrayList]::new(); $gone = [Collections.Generic.List[string]]::new(); $tomb = [Collections.ArrayList]::new()
  if (IsArr (Get-V $d 'removed')) { foreach ($x in $d['removed']) { [void]$tomb.Add($x) } }
  foreach ($i in @($d['items'])) { if (-not (IsObj $i)) { continue }; if (Test-ExampleItem $i $sig) { $gone.Add([string]$i['id']); [void]$tomb.Add([ordered]@{ id = [string]$i['id']; title = [string]$i['title']; at = (Get-NowIso); by = [string]$s.user; reason = 'example' }) } else { [void]$keep.Add($i) } }
  if ($in.confirm -ne $true -or -not $gone.Count) { return Send-Json $res @{ ok = $true; count = $gone.Count; ids = @($gone); done = $false } }
  foreach ($i in $keep) { if ((Get-V $i 'parentId') -and $gone.Contains([string]$i['parentId'])) { $i['parentId'] = $null } }
  $d['items'] = @($keep.ToArray()); $d['removed'] = @($tomb.ToArray())
  if (-not $Pj.git) { Copy-Item -LiteralPath $Pj.json -Destination ($Pj.json + '.bak') -Force }   # 沒有 git 就再多備份一份
  $errs = @(Write-BoardChecked $Pj $d $null 'clear-examples')
  if ($errs.Count) { return Send-Json $res @{ error = 'E_RULES'; message = '清除後的看板不符規則，未寫入'; errors = $errs } 422 }
  $committed = $false
  if ($Pj.git -and $in.commit -eq $true) {
    $an = ($s.user -replace '[<>\r\n]', ''); $ae = 'board-admin@ai-board.local'
    if ($s.ghLogin) { $an = ($s.ghName -replace '[<>\r\n]', ''); $ae = "$($s.ghId)+$($s.ghLogin)@users.noreply.github.com" }
    $msg = "chore(board): 清除範例工單（$($gone.Count) 筆）`n`n" + (($gone | Sort-Object) -join ' ')
    [void](Invoke-Git $Pj @('add', '--', $Pj.rel))
    $c = Invoke-Git $Pj @('-c', "user.name=$an", '-c', "user.email=$ae", 'commit', '-q', '-m', $msg, '--', $Pj.rel)
    $committed = ($c.Code -eq 0)
    if ($committed -and $Pj.remote) { $r = Invoke-Git $Pj @('push', '--quiet'); if ($r.Code -ne 0) { Set-SyncError $Pj 'E_PUSH_REJECTED' } }   # 不 force push
  }
  if ($committed) { $Pj.dirtyAt = $null; Push-All 'history' @{ p = $id } $id }
  Write-Host "$(Get-Date -f HH:mm:ss) [$id] $($s.user) 清除範例工單 $($gone.Count) 筆$(if ($committed) { '（已 commit）' })"
  Send-Json $res @{ ok = $true; count = $gone.Count; ids = @($gone); done = $true; committed = $committed }
}
function Test-InInstall([string]$p) { $f = [IO.Path]::GetFullPath($p); $r = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\', '/'); $f -eq $r -or $f.StartsWith($r + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) }
# 套用到專案：寫入 AI 工具規則、hooks、CI guard（只限管理者、本機；先 plan 再寫入；既有檔案先備份 .bak）
function Invoke-ApplyProject($req, $res) {
  $s = Get-Session $req; if (-not $s) { return Send-Err $res 401 'E_UNAUTHENTICATED' }
  if ($s.role -ne 'admin') { return Send-Err $res 403 'E_FORBIDDEN' }
  if (-not $req.IsLocal) { return Send-Err $res 403 'E_NOT_LOCAL' }
  $in = Read-Body $req; if (-not $in) { return Send-Err $res 400 'E_BAD_REQUEST' }
  $repo = [string]$in.repoPath
  if ($in.project) { $pp = $projects[[string]$in.project]; if (-not $pp) { return Send-Err $res 404 'E_NOT_FOUND' }; $repo = $pp.dir }
  if (-not $repo -or -not [IO.Path]::IsPathRooted($repo) -or $repo.Contains('"') -or -not (Test-Path -LiteralPath $repo -PathType Container)) { return Send-Json $res @{ error = 'E_APPLY'; message = '專案 repo 資料夾不存在（請填絕對路徑）' } 400 }
  if (Test-InInstall $repo) { return Send-Json $res @{ error = 'E_APPLY'; message = '不能套用到 GuGuBoard 安裝資料夾本身' } 400 }
  $all = 'Cursor', 'Codex', 'Claude', 'Copilot', 'Windsurf', 'Gemini', 'Cline', 'Hooks', 'GitHooks', 'CIGuard'
  $tl = @(@($in.tools) | ForEach-Object { [string]$_ } | Where-Object { $_ -in $all } | Select-Object -Unique)
  if (-not $tl.Count) { return Send-Json $res @{ error = 'E_APPLY'; message = '至少勾選一項' } 400 }
  $ap = @{ RepoPath = $repo; Tools = $tl; Json = $true }
  if ([bool]$in.plan) { $ap.Plan = $true }; if ([bool]$in.commit) { $ap.Commit = $true }; if ([bool]$in.remove) { $ap.Remove = $true }
  if ($in.boardPath) { $ap.BoardPath = [string]$in.boardPath } elseif ($in.project) { $ap.BoardPath = $projects[[string]$in.project].json }
  try { $out = (& $ApplyScript @ap 3>$null) -join '' ; $o = $out | ConvertFrom-Json } catch { return Send-Json $res @{ error = 'E_APPLY'; message = $_.Exception.Message } 422 }
  if (-not [bool]$in.plan) { Write-Host "[apply] $($s.user) → $repo（$($tl -join ',')）" }
  Send-Json $res $o
}
# ---------- Git 寫入操作（只限本機、CSRF 檢查、單執行緒依序執行、稽核紀錄；永不 force push）----------
$AuditFile = Join-Path $ConfigDir 'git-audit.log'
$BR_RE = '^[A-Za-z0-9][A-Za-z0-9._/-]{0,199}$'; $SHA_RE = '^[0-9a-fA-F]{7,40}$'
$CC_RE = '^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([A-Za-z0-9._/-]+\))?!?: \S.{0,99}$'
$CC_OK = '^(Merge |Revert "|board: |fixup! |squash! )'
$SEMVER_RE = '^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(-(rc|alpha|beta)\.(0|[1-9]\d*))?$'
$GIT_OP_MAX = 2MB
function Test-BranchName([string]$n) {
  if ($n -notmatch $BR_RE -or $n.Contains('..') -or $n.EndsWith('.lock') -or $n.EndsWith('/') -or $n.EndsWith('.') -or $n.Contains('//') -or $n.Contains('/.') -or $n.Contains('@{')) { return $false }
  $true
}
function Test-Rev([string]$r) {
  if (-not $r -or $r.Length -gt 220 -or $r -notmatch '^(.+?)((?:[~^]\d{0,3}){0,5})$') { return $false }
  $b = $Matches[1]; ($b -eq 'HEAD') -or ($b -match $SHA_RE) -or (Test-BranchName $b)
}
function Test-RelPath([string]$p) {
  if (-not $p -or $p.Length -gt 400 -or $p -match '[\x00-\x1f]' -or [IO.Path]::IsPathRooted($p) -or $p.StartsWith('/') -or $p.StartsWith('\')) { return $false }
  foreach ($seg in ($p -split '[\\/]')) { if ($seg -eq '..' -or $seg -eq '.git') { return $false } }
  $true
}
function Read-BodyMax($req, [int]$max) {
  if ($req.ContentLength64 -gt $max) { return $null }
  $sr = [IO.StreamReader]::new($req.InputStream, [Text.Encoding]::UTF8); $body = $sr.ReadToEnd(); $sr.Dispose()
  if ($body.Length -gt $max) { return $null }
  try { $body | ConvertFrom-Json } catch { $null }
}
function Get-GitIdentity($s) {
  if ($s.ghLogin) { return @{ name = ($s.ghName -replace '[<>\r\n]', ''); email = "$($s.ghId)+$($s.ghLogin)@users.noreply.github.com" } }
  @{ name = [string]$s.user; email = "$($s.user)@ai-board.local" }
}
function Invoke-GitW($Pj, [string[]]$a, $s, [bool]$asAuthor, [hashtable]$extra, [int]$ms = 120000) {
  $psi = [Diagnostics.ProcessStartInfo]::new('git'); $psi.WorkingDirectory = $Pj.dir
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true; $psi.UseShellExecute = $false
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
  $ev = $psi.EnvironmentVariables
  $ev['GIT_TERMINAL_PROMPT'] = '0'; $ev['GIT_EDITOR'] = 'true'; $ev['GIT_MERGE_AUTOEDIT'] = 'no'; $ev['LANGUAGE'] = 'en'; $ev['GIT_ASKPASS'] = ''
  $id = Get-GitIdentity $s
  $ev['GIT_COMMITTER_NAME'] = $id.name; $ev['GIT_COMMITTER_EMAIL'] = $id.email
  if ($asAuthor) { $ev['GIT_AUTHOR_NAME'] = $id.name; $ev['GIT_AUTHOR_EMAIL'] = $id.email }
  if ($extra) { foreach ($k in $extra.Keys) { $ev[$k] = [string]$extra[$k] } }
  $all = @('-c', 'core.quotepath=false', '-c', 'merge.conflictStyle=diff3', '-c', 'rebase.abbreviateCommands=false', '-c', 'advice.detachedHead=false') + $a
  if ($psi.PSObject.Properties['ArgumentList']) { foreach ($x in $all) { $psi.ArgumentList.Add($x) } }
  else { $psi.Arguments = ($all | ForEach-Object { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }) -join ' ' }
  $p = [Diagnostics.Process]::Start($psi); $p.StandardInput.Close()
  $ot = $p.StandardOutput.ReadToEndAsync(); $et = $p.StandardError.ReadToEndAsync()
  $timeout = $false
  if (-not $p.WaitForExit($ms)) { $timeout = $true; try { $p.Kill() } catch {}; [void]$p.WaitForExit(5000) }
  $o = ''; $e = ''; try { $o = $ot.Result } catch {}; try { $e = $et.Result } catch {}
  if ($o.Length -gt 200000) { $o = $o.Substring(0, 200000) + "`n…" }; if ($e.Length -gt 50000) { $e = $e.Substring(0, 50000) + "`n…" }
  [pscustomobject]@{ Code = $(if ($timeout) { -1 } else { $p.ExitCode }); Out = $o; Err = $e; Timeout = $timeout; Args = ($a -join ' ') }
}
function Get-GitDir($Pj) { (Invoke-Git $Pj @('rev-parse', '--absolute-git-dir')).Out.Trim() }
function Get-RepoState($Pj) {
  $gd = Get-GitDir $Pj; if (-not $gd) { return $null }
  if ((Test-Path -LiteralPath (Join-Path $gd 'rebase-merge')) -or (Test-Path -LiteralPath (Join-Path $gd 'rebase-apply'))) { return 'rebase' }
  if (Test-Path -LiteralPath (Join-Path $gd 'MERGE_HEAD')) { return 'merge' }
  if (Test-Path -LiteralPath (Join-Path $gd 'CHERRY_PICK_HEAD')) { return 'cherry-pick' }
  if (Test-Path -LiteralPath (Join-Path $gd 'REVERT_HEAD')) { return 'revert' }
  $null
}
function Get-CurBranch($Pj) { $r = Invoke-Git $Pj @('symbolic-ref', '-q', '--short', 'HEAD'); if ($r.Code -eq 0) { $r.Out.Trim() } else { $null } }
function Test-Protected($Pj, [string]$b) {
  if (-not $b) { return $true }
  $m = Get-MainRef $Pj; $mm = $null; if ($m) { $mm = $m; $i = $m.IndexOf('/'); if ($i -gt 0 -and (Invoke-Git $Pj @('rev-parse', '--verify', '-q', "refs/remotes/$m")).Code -eq 0) { $mm = $m.Substring($i + 1) } }
  ($b -in 'main', 'master', 'develop', 'trunk') -or ($mm -and $b -eq $mm) -or $b -like 'release/*'
}
function Get-Role($s, $Pj) { $r = $s.allowed[$Pj.id]; if ($s.role -eq 'admin') { 'admin' } else { [string]$r } }
# 回傳 $null＝允許；否則錯誤碼
function Test-GitPerm($s, $Pj, [string]$op, [string]$branch) {
  $role = Get-Role $s $Pj
  if (-not $role -or $role -eq 'viewer') { return 'E_ROLE_VIEWER' }
  if ($role -in 'high-tier', 'admin') { return $null }
  if ($op -in 'fetch', 'switch') { return $null }
  if ($op -in 'tag', 'tagPush') { return 'E_ROLE_NO_TAG' }
  if ($role -eq 'dev-agent') { if (-not $branch -or $branch -notlike 'feature/*') { return 'E_ROLE_FEATURE_ONLY' }; return $null }
  if ($role -eq 'verifier') { if (Test-Protected $Pj $branch) { return 'E_ROLE_PROTECTED' }; return $null }
  'E_ROLE'
}
function Get-Unpushed($Pj) { $h = @{}; $r = Invoke-Git $Pj @('rev-list', 'HEAD', '--not', '--remotes'); foreach ($l in ($r.Out -split "`n")) { if ($l) { $h[$l.Trim()] = $true } }; $h }
function Test-RangeUnpushed($Pj, [string]$base) {
  $u = Get-Unpushed $Pj; $r = Invoke-Git $Pj @('rev-list', "$base..HEAD")
  foreach ($l in ($r.Out -split "`n")) { if ($l -and -not $u.ContainsKey($l.Trim())) { return $false } }
  $true
}
function Resolve-Sha($Pj, [string]$rev) { if (-not (Test-Rev $rev)) { return $null }; $r = Invoke-Git $Pj @('rev-parse', '--verify', '-q', "$rev^{commit}"); if ($r.Code -eq 0) { $r.Out.Trim() } else { $null } }
function Get-Conflicts($Pj) { @((Invoke-Git $Pj @('-c', 'core.quotepath=false', 'diff', '--name-only', '--diff-filter=U')).Out -split "`n" | Where-Object { $_ } | ForEach-Object { $_.Trim() }) }
function Test-HooksMsg($Pj) {
  $hp = (Invoke-Git $Pj @('config', '--get', 'core.hooksPath')).Out.Trim(); $gd = Get-GitDir $Pj
  $dir = $(if ($hp) { if ([IO.Path]::IsPathRooted($hp)) { $hp } else { Join-Path $Pj.dir $hp } } else { Join-Path $gd 'hooks' })
  Test-Path -LiteralPath (Join-Path $dir 'commit-msg')
}
function Test-CommitMsg([string]$m) { $first = ($m -split "`n")[0].Trim(); ($first -match $CC_RE) -or ($first -match $CC_OK) }
function Get-TmpDir { $d = Join-Path $ConfigDir 'tmp'; if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory $d -Force | Out-Null }; $d }
function New-TmpFile([string]$text) { $f = Join-Path (Get-TmpDir) ('t' + [guid]::NewGuid().ToString('N') + '.txt'); [IO.File]::WriteAllText($f, $text, [Text.UTF8Encoding]::new($false)); $f }
function Write-Audit($s, $Pj, [string]$op, $argsObj, $r, [string]$err) {
  try {
    Initialize-ConfigDir
    $line = [ordered]@{ at = (Get-Date).ToString('o'); user = [string]$s.user; github = [string]$s.ghLogin; project = $Pj.id; op = $op; args = $argsObj; ok = ($r -and $r.Code -eq 0 -and -not $err); code = $(if ($r) { $r.Code } else { $null }); error = $(if ($err) { $err } elseif ($r -and $r.Code -ne 0) { Clip (($r.Err + ' ' + $r.Out).Trim()) 300 } else { $null }) } | ConvertTo-Json -Compress -Depth 5
    [IO.File]::AppendAllText($AuditFile, $line + "`n", [Text.UTF8Encoding]::new($false))
  } catch { Write-Warning "稽核紀錄寫入失敗：$($_.Exception.Message)" }
}
function Get-Audit($Pj) {
  if (-not (Test-Path -LiteralPath $AuditFile)) { return @() }
  $lines = @([IO.File]::ReadAllLines($AuditFile, [Text.Encoding]::UTF8) | Select-Object -Last 2000)
  $out = @(); for ($i = $lines.Count - 1; $i -ge 0 -and $out.Count -lt 200; $i--) { try { $o = $lines[$i] | ConvertFrom-Json; if ($o.project -eq $Pj.id) { $o.at = Get-IsoDate $o.at; $out += $o } } catch {} }
  $out
}
function Get-WorkStatus($Pj, $s) {
  $o = [ordered]@{}
  $o.state = Get-RepoState $Pj; $o.branch = Get-CurBranch $Pj
  $h = Invoke-Git $Pj @('rev-parse', '-q', '--verify', 'HEAD'); $o.head = $(if ($h.Code -eq 0) { $h.Out.Trim() } else { $null })
  $u = Invoke-Git $Pj @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}'); $o.upstream = $(if ($u.Code -eq 0) { $u.Out.Trim() } else { $null }); $o.ahead = 0; $o.behind = 0
  if ($o.upstream) { $c = Invoke-Git $Pj @('rev-list', '--left-right', '--count', 'HEAD...@{u}'); if ($c.Out.Trim() -match '^(\d+)\s+(\d+)$') { $o.ahead = [int]$Matches[1]; $o.behind = [int]$Matches[2] } }
  $st = Invoke-Git $Pj @('-c', 'core.quotepath=false', 'status', '--porcelain=v1', '-z', '-uall') 2MB
  $parts = $st.Out -split [char]0; $staged = @(); $unstaged = @(); $untracked = @(); $conf = @()
  for ($i = 0; $i -lt $parts.Count; $i++) {
    $e = $parts[$i]; if ($e.Length -lt 4) { continue }
    $x = $e[0]; $y = $e[1]; $pth = $e.Substring(3); $old = $null
    if ($x -eq 'R' -or $x -eq 'C') { $i++; $old = $parts[$i] }
    $xy = "$x$y"
    if ($xy -eq '??') { $untracked += [ordered]@{ path = $pth; code = '??' }; continue }
    if ($xy -in 'DD', 'AU', 'UD', 'UA', 'DU', 'AA', 'UU') { $conf += [ordered]@{ path = $pth; code = $xy }; continue }
    if ($x -ne ' ') { $staged += [ordered]@{ path = $pth; code = [string]$x; old = $old } }
    if ($y -ne ' ') { $unstaged += [ordered]@{ path = $pth; code = [string]$y } }
  }
  $o.staged = @($staged | Select-Object -First 500); $o.unstaged = @($unstaged | Select-Object -First 500); $o.untracked = @($untracked | Select-Object -First 500); $o.conflicted = @($conf | Select-Object -First 500)
  $sl = Invoke-Git $Pj @('stash', 'list', '--format=%gd%x1f%gs%x1f%cI')
  $o.stashes = @($sl.Out -split "`n" | Where-Object { $_ } | ForEach-Object { $y = $_ -split [char]0x1f; [ordered]@{ ref = $y[0]; message = (Clip $y[1] 200); at = $y[2] } })
  $o.headPushed = $false; if ($o.head) { $o.headPushed = -not (Get-Unpushed $Pj).ContainsKey($o.head) }
  $o.hooksCommitMsg = Test-HooksMsg $Pj
  $o.protected = Test-Protected $Pj $o.branch
  $o.role = Get-Role $s $Pj
  $o.identity = Get-GitIdentity $s
  if ($o.state -eq 'rebase') { $gd = Get-GitDir $Pj; foreach ($d in 'rebase-merge', 'rebase-apply') { $f = Join-Path (Join-Path $gd $d) 'head-name'; if (Test-Path -LiteralPath $f) { $o.rebaseHead = ([IO.File]::ReadAllText($f)).Trim() -replace '^refs/heads/', '' }; $f2 = Join-Path (Join-Path $gd $d) 'onto'; if (Test-Path -LiteralPath $f2) { $o.rebaseOnto = ([IO.File]::ReadAllText($f2)).Trim() } } }
  $o.remotes = @((Invoke-Git $Pj @('remote')).Out -split "`n" | Where-Object { $_ })
  $o
}
function Get-WorkDiff($Pj, [string]$path, [bool]$staged) {
  if (-not (Test-RelPath $path)) { return $null }
  $a = @('-c', 'core.quotepath=false', 'diff', '--no-color', '-U3'); if ($staged) { $a += '--cached' }; $a += @('--', $path)
  (Invoke-Git $Pj $a 1MB).Out
}
function Get-ConflictFile($Pj, [string]$path) {
  if (-not (Test-RelPath $path)) { return $null }
  if ($path -notin (Get-Conflicts $Pj)) { return $null }
  $o = [ordered]@{ path = $path; state = (Get-RepoState $Pj) }
  foreach ($k in @(@('base', 1), @('ours', 2), @('theirs', 3))) { $r = Invoke-Git $Pj @('show', ":$($k[1]):$path") 1MB; $o[$k[0]] = $(if ($r.Code -eq 0) { $r.Out } else { $null }) }
  $full = Join-Path $Pj.dir $path; $o.working = $(if (Test-Path -LiteralPath $full) { [IO.File]::ReadAllText($full) } else { $null })
  $o.crlf = [bool]($o.working -and $o.working.Contains("`r`n"))
  $o
}
function Get-RebasePlan($Pj, [string]$onto) {
  $os = Resolve-Sha $Pj $onto; if (-not $os) { return @{ error = 'E_BAD_REF' } }
  $mb = (Invoke-Git $Pj @('merge-base', $os, 'HEAD')).Out.Trim(); if (-not $mb) { return @{ error = 'E_NO_BASE' } }
  $r = Invoke-Git $Pj @('log', '--reverse', '--topo-order', '--no-merges', '--format=%H%x1f%an%x1f%aI%x1f%s', "$mb..HEAD")
  $rows = @($r.Out -split "`n" | Where-Object { $_ } | ForEach-Object { $x = $_ -split [char]0x1f; [ordered]@{ sha = $x[0]; author = $x[1]; at = $x[2]; subject = (Clip $x[3] 300) } })
  $mg = @((Invoke-Git $Pj @('rev-list', '--merges', "$mb..HEAD")).Out -split "`n" | Where-Object { $_ }).Count
  @{ onto = $os; base = $mb; commits = @($rows | Select-Object -First 200); hasMerges = ($mg -gt 0); unpushed = (Test-RangeUnpushed $Pj $mb); branch = (Get-CurBranch $Pj) }
}
$GIT_ERRS = @{
  E_ROLE_VIEWER = '檢視者（viewer）不能執行 Git 操作'
  E_ROLE_FEATURE_ONLY = '開發代理（dev-agent）只能操作 feature/* 分支'
  E_ROLE_PROTECTED = '驗證者（verifier）不能操作主線或受保護分支'
  E_ROLE_NO_TAG = '只有 high-tier 或管理者可以建立或推送標籤'
  E_ROLE_NOT_OWNER = '開發代理不能刪除或改名別人的分支（分支最新 commit 不是你的）'
  E_PUSHED_REWRITE = '這些 commit 已經推送到遠端。改寫它們（rebase／amend／reset）之後只能 force push，而看板永遠不 force push，所以不允許。請改用 merge 或 revert。'
  E_DIRTY = '工作目錄有未提交的變更。請先 commit，或選擇「先 stash 再切換」。'
  E_PROTECTED = '不能刪除或改名主線、受保護分支或目前所在的分支'
  E_UNMERGED = '這個分支還沒合併進主線；要刪除請輸入分支名稱確認（commit 可能遺失）'
  E_CONFIRM = '危險操作：確認文字不正確'
  E_IN_PROGRESS = '目前有進行中的 merge／rebase／cherry-pick／revert，請先完成（continue）或中止（abort）'
  E_NO_STATE = '沒有進行中的 merge／rebase／cherry-pick／revert'
  E_CONFLICTS_LEFT = '還有衝突檔案沒解決，請先解決並標記完成'
  E_MARKERS = '內容還有衝突標記（<<<<<<< ======= >>>>>>>），請先處理完；若確定要保留請勾選「仍要標記完成」'
  E_COMMIT_FORMAT = 'commit 訊息不符合這個 repo hooks 要求的 Conventional Commits 格式（例如 feat(scope): 說明、fix: 說明）'
  E_BAD_TAG = '標籤必須是 SemVer，例如 v1.2.3 或 v1.3.0-rc.1'
  E_TAG_EXISTS = '標籤已存在'
  E_NOT_ANCESTOR = '只能 reset 到目前分支的上層 commit'
  E_NO_UPSTREAM = '目前分支沒有上游分支，請先「推送並設定上游」'
  E_NON_FF = '推送被拒絕：遠端有你本機沒有的 commit（non-fast-forward）。請先 pull（ff-only／merge／rebase 未推送的 commit）再推送。看板永遠不 force push。'
  E_DETACHED = '目前不在任何分支上（detached HEAD）'
  E_LOCKED = 'repo 正在被其他 git 程式使用（index.lock 存在），請稍後再試'
  E_BAD_TODO = '互動式 rebase 清單不正確（必須包含範圍內每個 commit 各一次；第一個不能是 squash／fixup）'
  E_HAS_MERGES = '範圍內有 merge commit，互動式 rebase 會把它們攤平，不支援'
  E_TIMEOUT = 'git 執行逾時，已中止'
  E_BAD_PATH = '檔案路徑不正確（只能是 repo 內的相對路徑，不能含 .. 或 .git）'
  E_BAD_BRANCH = '分支名稱不正確（英數與 . _ / -，不能以 - 開頭、不能含 ..）'
  E_BAD_REF = '找不到這個 commit 或分支'
  E_BAD_MODE = '只支援 reset --soft 或 --mixed（不提供 --hard；要捨棄未提交變更請用「捨棄」）'
  E_BAD_MESSAGE = 'commit 訊息不能空白（最多 5000 字）'
  E_BAD_HUNK = '找不到這個區塊，請重新整理'
  E_BAD_STASH = 'stash 編號不正確'
  E_NOT_FOUND = '找不到分支'
  E_BRANCH_EXISTS = '本機已有同名分支'
  E_NO_REMOTE = '沒有設定 git remote'
  E_NOT_FF_PULL = '本機與遠端已分岔，無法 fast-forward。請改選「pull（merge）」或「pull（rebase 未推送的 commit）」。'
  E_MIRROR = '這個 remote 設定成 mirror（等同 force push），看板拒絕推送'
  E_BAD_OP = '不支援的操作'
}
function Send-GitErr($res, [int]$code, [string]$err, [string]$detail) { Send-Json $res @{ error = $err; message = $(if ($GIT_ERRS.ContainsKey($err)) { $GIT_ERRS[$err] } else { $err }); detail = $detail } $code }
function Invoke-GitOpReq($req, $res, [string]$pid_) {
  $s = Get-Session $req; if (-not $s) { return Send-Err $res 401 'E_UNAUTHENTICATED' }
  if ($pid_ -cnotmatch $PID_RE -or -not $projects.Contains($pid_) -or -not $s.allowed.ContainsKey($pid_)) { return Send-Err $res 403 'E_FORBIDDEN' }
  if (-not $req.IsLocal) { return Send-Err $res 403 'E_NOT_LOCAL' }
  $Pj = $projects[$pid_]; if (-not $Pj.git) { return Send-Err $res 503 'E_GIT_DISABLED' }
  $in = Read-BodyMax $req $GIT_OP_MAX; if (-not $in) { return Send-Err $res 400 'E_BAD_REQUEST' }
  $op = [string]$in.op; if ($op -notmatch '^[a-zA-Z]{2,30}$') { return Send-Err $res 400 'E_BAD_OP' }
  $gd = Get-GitDir $Pj; if (Test-Path -LiteralPath (Join-Path $gd 'index.lock')) { return Send-GitErr $res 409 'E_LOCKED' '' }
  $cur = Get-CurBranch $Pj; $state = Get-RepoState $Pj
  $auditArgs = [ordered]@{}; foreach ($p in $in.PSObject.Properties) { if ($p.Name -notin 'op', 'content', 'todo', 'message') { $auditArgs[$p.Name] = $p.Value } }
  if ($in.message) { $auditArgs.message = Clip (([string]$in.message -split "`n")[0]) 120 }
  if ($in.todo) { $auditArgs.todo = @($in.todo | ForEach-Object { "$([string]$_.action) $(Clip ([string]$_.sha) 10)" }) }
  $script:opErr = $null
  $fail = { param($code, $err, $detail) $script:opErr = $err; Write-Audit $s $Pj $op $auditArgs $null $err; Send-GitErr $res $code $err $detail }
  $perm = { param($b) $e = Test-GitPerm $s $Pj $op $b; if ($e) { & $fail 403 $e ''; return $false }; $true }
  $paths = @(); if ($in.paths) { foreach ($x in @($in.paths)) { $x = [string]$x; if (-not (Test-RelPath $x)) { return (& $fail 400 'E_BAD_PATH' $x) }; $paths += $x } }
  $noState = @('stage', 'unstage', 'stageHunk', 'discard', 'discardAll', 'commit', 'stashPush', 'stashPop', 'stashApply', 'stashDrop', 'pull', 'push', 'switch', 'merge', 'cherryPick', 'revert', 'reset', 'rebase', 'rebaseInteractive', 'branchRename')
  if ($state -and $op -in $noState -and -not ($op -in 'stage', 'unstage', 'stageHunk')) { return (& $fail 409 'E_IN_PROGRESS' $state) }
  $r = $null; $net = 300000
  switch ($op) {
    'fetch' { if (-not (& $perm $cur)) { return }; $r = Invoke-GitW $Pj @('fetch', '--all', '--prune') $s $false $null $net }
    'stage' { if (-not (& $perm $cur)) { return }; if (-not $paths.Count) { return (& $fail 400 'E_BAD_PATH' '') }; $r = Invoke-GitW $Pj (@('add', '--') + $paths) $s $false $null }
    'unstage' {
      if (-not (& $perm $cur)) { return }; if (-not $paths.Count) { return (& $fail 400 'E_BAD_PATH' '') }
      $hasHead = (Invoke-Git $Pj @('rev-parse', '-q', '--verify', 'HEAD')).Code -eq 0
      if ($hasHead) { $r = Invoke-GitW $Pj (@('restore', '--staged', '--') + $paths) $s $false $null } else { $r = Invoke-GitW $Pj (@('rm', '--cached', '-q', '--') + $paths) $s $false $null }
    }
    'stageHunk' {
      if (-not (& $perm $cur)) { return }
      $pth = [string]$in.path; if (-not (Test-RelPath $pth)) { return (& $fail 400 'E_BAD_PATH' $pth) }
      $rev = [bool]$in.unstage; $hi = [int]$in.hunk
      $d = Get-WorkDiff $Pj $pth $rev; $lines = $d -split "`n"; $hdr = @(); $hunks = @(); $curH = $null
      foreach ($l in $lines) { if ($l.StartsWith('@@')) { if ($curH) { $hunks += , $curH }; $curH = [Collections.Generic.List[string]]::new(); $curH.Add($l) } elseif ($curH) { $curH.Add($l) } else { $hdr += $l } }
      if ($curH) { $hunks += , $curH }
      if ($hi -lt 0 -or $hi -ge $hunks.Count) { return (& $fail 400 'E_BAD_HUNK' "$hi") }
      $body = @($hunks[$hi]); while ($body.Count -gt 1 -and $body[$body.Count - 1] -eq '') { $body = $body[0..($body.Count - 2)] }
      $patch = (($hdr + $body) -join "`n") + "`n"
      $tf = New-TmpFile $patch
      $a = @('apply', '--cached', '--whitespace=nowarn'); if ($rev) { $a += '--reverse' }; $a += $tf
      $r = Invoke-GitW $Pj $a $s $false $null; Remove-Item -LiteralPath $tf -Force -ErrorAction SilentlyContinue
    }
    'discard' {
      if (-not (& $perm $cur)) { return }; if (-not $paths.Count) { return (& $fail 400 'E_BAD_PATH' '') }
      $want = $(if ($paths.Count -eq 1) { $paths[0] } else { "$($paths.Count) 個檔案" }); if ([string]$in.confirm -ne $want) { return (& $fail 400 'E_CONFIRM' $want) }
      $unt = @{}; foreach ($u in ((Invoke-Git $Pj (@('-c', 'core.quotepath=false', 'ls-files', '--others', '--exclude-standard', '--') + $paths)).Out -split "`n")) { if ($u) { $unt[$u.Trim()] = $true } }
      $tr = @($paths | Where-Object { -not $unt.ContainsKey($_) }); $un = @($paths | Where-Object { $unt.ContainsKey($_) })
      $r = [pscustomobject]@{ Code = 0; Out = ''; Err = ''; Timeout = $false }
      if ($tr.Count) { $r = Invoke-GitW $Pj (@('restore', '--staged', '--worktree', '--source=HEAD', '--') + $tr) $s $false $null }
      if ($r.Code -eq 0 -and $un.Count) { $r = Invoke-GitW $Pj (@('clean', '-f', '-q', '--') + $un) $s $false $null }
    }
    'discardAll' {
      if (-not (& $perm $cur)) { return }; $want = $(if ($cur) { $cur } else { 'HEAD' }); if ([string]$in.confirm -ne $want) { return (& $fail 400 'E_CONFIRM' $want) }
      $r = Invoke-GitW $Pj @('reset', '--hard', '-q', 'HEAD') $s $false $null   # 只捨棄未提交變更（本機），不移動分支
    }
    'commit' {
      if (-not $cur -and -not [bool]$in.amend) { if (-not (& $perm $null)) { return } } elseif (-not (& $perm $cur)) { return }
      $msg = ([string]$in.message).Replace("`r`n", "`n").Trim(); if (-not $msg -or $msg.Length -gt 5000) { return (& $fail 400 'E_BAD_MESSAGE' '') }
      if ((Test-HooksMsg $Pj) -and -not (Test-CommitMsg $msg)) { return (& $fail 400 'E_COMMIT_FORMAT' (($msg -split "`n")[0])) }
      $a = @('commit', '-q')
      if ([bool]$in.amend) { $h = (Invoke-Git $Pj @('rev-parse', 'HEAD')).Out.Trim(); if (-not (Get-Unpushed $Pj).ContainsKey($h)) { return (& $fail 409 'E_PUSHED_REWRITE' 'amend') }; $a += '--amend' }
      $tf = New-TmpFile ($msg + "`n"); $a += @('-F', $tf)   # 不加 --no-verify：pre-commit／commit-msg hooks 一定會執行
      $r = Invoke-GitW $Pj $a $s $true $null; Remove-Item -LiteralPath $tf -Force -ErrorAction SilentlyContinue
    }
    'stashPush' { if (-not (& $perm $cur)) { return }; $a = @('stash', 'push'); if ([bool]$in.untracked) { $a += '-u' }; $m = Clip ([string]$in.message) 200; if ($m) { $a += @('-m', $m) }; $r = Invoke-GitW $Pj $a $s $false $null }
    { $_ -in 'stashPop', 'stashApply', 'stashDrop' } {
      if (-not (& $perm $cur)) { return }
      $ix = [string]$in.index; if ($ix -notmatch '^\d{1,4}$') { return (& $fail 400 'E_BAD_STASH' $ix) }; $ref = "stash@{$ix}"
      if ($op -eq 'stashDrop' -and [string]$in.confirm -ne $ref) { return (& $fail 400 'E_CONFIRM' $ref) }
      $verb = @{ stashPop = 'pop'; stashApply = 'apply'; stashDrop = 'drop' }[$op]
      $r = Invoke-GitW $Pj @('stash', $verb, '-q', $ref) $s $false $null
    }
    'pull' {
      if (-not $cur) { return (& $fail 409 'E_DETACHED' '') }; if (-not (& $perm $cur)) { return }
      if ((Invoke-Git $Pj @('rev-parse', '--abbrev-ref', '@{u}')).Code -ne 0) { return (& $fail 409 'E_NO_UPSTREAM' '') }
      $mode = [string]$in.mode
      switch ($mode) { 'merge' { $a = @('pull', '--no-rebase', '--no-edit') } 'rebase' { $a = @('pull', '--rebase') } default { $mode = 'ff-only'; $a = @('pull', '--ff-only') } }
      $r = Invoke-GitW $Pj $a $s $false $null $net
      if ($r.Code -ne 0 -and $mode -eq 'ff-only' -and $r.Err -match 'Diverging|Not possible to fast-forward|fast-forward') { Write-Audit $s $Pj $op $auditArgs $r 'E_NOT_FF_PULL'; return (Send-GitErr $res 409 'E_NOT_FF_PULL' $r.Err) }
    }
    'push' {
      if (-not $cur) { return (& $fail 409 'E_DETACHED' '') }; if (-not (& $perm $cur)) { return }
      $ur = Invoke-Git $Pj @('rev-parse', '--abbrev-ref', '--symbolic-full-name', '@{u}'); $remote = 'origin'; $dst = $cur; $setUp = $false
      if ($ur.Code -eq 0) { $up = $ur.Out.Trim(); $rmn = (Invoke-Git $Pj @('config', '--get', "branch.$cur.remote")).Out.Trim(); if ($rmn) { $remote = $rmn }; $mr = (Invoke-Git $Pj @('config', '--get', "branch.$cur.merge")).Out.Trim(); if ($mr -match '^refs/heads/(.+)$') { $dst = $Matches[1] } }
      else { $setUp = $true; $rms = @((Invoke-Git $Pj @('remote')).Out -split "`n" | Where-Object { $_ }); if (-not $rms.Count) { return (& $fail 409 'E_NO_REMOTE' '') }; if ('origin' -notin $rms) { $remote = $rms[0] } }
      if (-not (Test-BranchName $dst) -or $remote -notmatch '^[A-Za-z0-9._-]{1,100}$') { return (& $fail 400 'E_BAD_REF' $dst) }
      if ((Invoke-Git $Pj @('config', '--get', "remote.$remote.mirror")).Out.Trim() -eq 'true') { return (& $fail 409 'E_MIRROR' $remote) }
      if ((Get-Role $s $Pj) -eq 'dev-agent' -and (Test-Protected $Pj $dst)) { return (& $fail 403 'E_ROLE_FEATURE_ONLY' $dst) }
      $a = @('push'); if ($setUp) { $a += '--set-upstream' }; $a += @('--', $remote, "refs/heads/${cur}:refs/heads/$dst")   # refspec 沒有 +，永不 force
      $r = Invoke-GitW $Pj $a $s $false $null $net
      if ($r.Code -ne 0 -and ($r.Err -match 'non-fast-forward|\[rejected\]|fetch first|stale info')) { Write-Audit $s $Pj $op $auditArgs $r 'E_NON_FF'; Push-All 'git' @{ p = $Pj.id } $Pj.id; return (Send-GitErr $res 409 'E_NON_FF' $r.Err) }
    }
    'tagPush' {
      if (-not (& $perm $cur)) { return }
      $tn = [string]$in.name; if ($tn -notmatch $SEMVER_RE) { return (& $fail 400 'E_BAD_TAG' $tn) }
      $remote = [string]$in.remote; if (-not $remote) { $remote = 'origin' }; if ($remote -notmatch '^[A-Za-z0-9._-]{1,100}$') { return (& $fail 400 'E_BAD_REF' $remote) }
      $r = Invoke-GitW $Pj @('push', '--', $remote, "refs/tags/${tn}:refs/tags/$tn") $s $false $null $net
      if ($r.Code -ne 0 -and $r.Err -match 'rejected|already exists') { Write-Audit $s $Pj $op $auditArgs $r 'E_TAG_EXISTS'; return (Send-GitErr $res 409 'E_TAG_EXISTS' $r.Err) }
    }
    'tag' {
      if (-not (& $perm $cur)) { return }
      $tn = [string]$in.name; if ($tn -notmatch $SEMVER_RE) { return (& $fail 400 'E_BAD_TAG' $tn) }
      if ((Invoke-Git $Pj @('rev-parse', '-q', '--verify', "refs/tags/$tn")).Code -eq 0) { return (& $fail 409 'E_TAG_EXISTS' $tn) }
      $sha = Resolve-Sha $Pj $(if ([string]$in.sha) { [string]$in.sha } else { 'HEAD' }); if (-not $sha) { return (& $fail 400 'E_BAD_REF' ([string]$in.sha)) }
      $m = Clip ([string]$in.message) 2000; if (-not $m) { $m = $tn }; $tf = New-TmpFile $m
      $r = Invoke-GitW $Pj @('tag', '-a', $tn, '-F', $tf, $sha) $s $true $null; Remove-Item -LiteralPath $tf -Force -ErrorAction SilentlyContinue
    }
    'branchCreate' {
      $bn = [string]$in.name; if (-not (Test-BranchName $bn) -or $bn -like 'origin/*') { return (& $fail 400 'E_BAD_BRANCH' $bn) }
      if ((Invoke-Git $Pj @('check-ref-format', '--branch', $bn)).Code -ne 0) { return (& $fail 400 'E_BAD_BRANCH' $bn) }
      if (-not (& $perm $bn)) { return }
      $from = [string]$in.from; if (-not $from) { $from = 'HEAD' }; $sha = $(if ($from -eq 'HEAD') { 'HEAD' } else { Resolve-Sha $Pj $from }); if (-not $sha) { return (& $fail 400 'E_BAD_REF' $from) }
      if ([bool]$in.checkout) {
        if ($state) { return (& $fail 409 'E_IN_PROGRESS' $state) }
        $r = Invoke-GitW $Pj @('switch', '-c', $bn, $sha) $s $false $null
      } else { $r = Invoke-GitW $Pj @('branch', $bn, $sha) $s $false $null }
    }
    'switch' {
      $bn = [string]$in.name; if (-not (Test-BranchName $bn)) { return (& $fail 400 'E_BAD_BRANCH' $bn) }
      if (-not (& $perm $bn)) { return }
      $isLocal = (Invoke-Git $Pj @('rev-parse', '-q', '--verify', "refs/heads/$bn")).Code -eq 0
      $isRemote = (-not $isLocal) -and (Invoke-Git $Pj @('rev-parse', '-q', '--verify', "refs/remotes/$bn")).Code -eq 0
      if (-not $isLocal -and -not $isRemote) { return (& $fail 404 'E_NOT_FOUND' $bn) }
      $loc = $bn; if ($isRemote) { $loc = $bn.Substring($bn.IndexOf('/') + 1); if (-not (Test-BranchName $loc)) { return (& $fail 400 'E_BAD_BRANCH' $loc) }; if ((Invoke-Git $Pj @('rev-parse', '-q', '--verify', "refs/heads/$loc")).Code -eq 0) { return (& $fail 409 'E_BRANCH_EXISTS' $loc) } }
      $dirty = (Invoke-Git $Pj @('status', '--porcelain', '-uno')).Out.Trim()
      if ($dirty -and -not [bool]$in.stash) { return (& $fail 409 'E_DIRTY' $dirty) }
      if ($dirty) { $r0 = Invoke-GitW $Pj @('stash', 'push', '-m', "自動 stash：切換到 $loc 前") $s $false $null; if ($r0.Code -ne 0) { $r = $r0; break } }
      if ($isLocal) { $r = Invoke-GitW $Pj @('switch', $bn) $s $false $null } else { $r = Invoke-GitW $Pj @('switch', '-c', $loc, '--track', $bn) $s $false $null }
    }
    { $_ -in 'branchRename', 'branchDelete' } {
      $bn = [string]$in.name; if (-not (Test-BranchName $bn) -or (Invoke-Git $Pj @('rev-parse', '-q', '--verify', "refs/heads/$bn")).Code -ne 0) { return (& $fail 400 'E_BAD_BRANCH' $bn) }
      if ((Test-Protected $Pj $bn) -or ($op -eq 'branchDelete' -and $bn -eq $cur)) { return (& $fail 409 'E_PROTECTED' $bn) }
      if (-not (& $perm $bn)) { return }
      if ((Get-Role $s $Pj) -eq 'dev-agent') { $em = (Invoke-Git $Pj @('log', '-1', '--format=%ae', "refs/heads/$bn")).Out.Trim(); if ($em -ne (Get-GitIdentity $s).email) { return (& $fail 403 'E_ROLE_NOT_OWNER' $bn) } }
      if ($op -eq 'branchRename') {
        $nn = [string]$in.newName; if (-not (Test-BranchName $nn) -or (Invoke-Git $Pj @('check-ref-format', '--branch', $nn)).Code -ne 0) { return (& $fail 400 'E_BAD_BRANCH' $nn) }
        if (Test-Protected $Pj $nn) { return (& $fail 409 'E_PROTECTED' $nn) }; $e2 = Test-GitPerm $s $Pj $op $nn; if ($e2) { return (& $fail 403 $e2 $nn) }
        $r = Invoke-GitW $Pj @('branch', '-m', $bn, $nn) $s $false $null
      } else {
        $main = Get-MainRef $Pj; $into = $(if ($main) { $main } else { 'HEAD' })
        $merged = (Invoke-Git $Pj @('merge-base', '--is-ancestor', "refs/heads/$bn", $into)).Code -eq 0
        if (-not $merged -and [string]$in.confirm -ne $bn) { return (& $fail 409 'E_UNMERGED' $bn) }
        $r = Invoke-GitW $Pj @('branch', $(if ($merged) { '-d' } else { '-D' }), $bn) $s $false $null
        if ($merged -and $r.Code -ne 0 -and $r.Err -match 'not fully merged') { $r = Invoke-GitW $Pj @('branch', '-D', $bn) $s $false $null }   # 已併入主線但未併入目前分支
      }
    }
    'merge' {
      if (-not $cur) { return (& $fail 409 'E_DETACHED' '') }; if (-not (& $perm $cur)) { return }
      $src = [string]$in.branch; $sha = Resolve-Sha $Pj $src; if (-not $sha) { return (& $fail 400 'E_BAD_REF' $src) }
      $mode = [string]$in.mode; $a = @('merge')
      switch ($mode) { 'no-ff' { $a += @('--no-ff', '--no-edit') } 'squash' { $a += '--squash' } 'ff-only' { $a += '--ff-only' } default { $mode = 'ff'; $a += @('--ff', '--no-edit') } }
      $a += @('-m', "Merge branch '$src' into $cur"); if ($mode -eq 'squash') { $a = @('merge', '--squash') }
      $a += $src
      $r = Invoke-GitW $Pj $a $s $true $null
    }
    { $_ -in 'cherryPick', 'revert' } {
      if (-not $cur) { return (& $fail 409 'E_DETACHED' '') }; if (-not (& $perm $cur)) { return }
      $sha = Resolve-Sha $Pj ([string]$in.sha); if (-not $sha) { return (& $fail 400 'E_BAD_REF' ([string]$in.sha)) }
      $np = @((Invoke-Git $Pj @('rev-parse', "$sha^@")).Out -split "`n" | Where-Object { $_ }).Count
      $a = $(if ($op -eq 'cherryPick') { @('cherry-pick', '-x') } else { @('revert', '--no-edit') }); if ($np -gt 1) { $a += @('-m', '1') }; $a += $sha
      $r = Invoke-GitW $Pj $a $s ($op -eq 'revert') $null
    }
    'reset' {
      if (-not $cur) { return (& $fail 409 'E_DETACHED' '') }; if (-not (& $perm $cur)) { return }
      $mode = [string]$in.mode; if ($mode -notin 'soft', 'mixed') { return (& $fail 400 'E_BAD_MODE' $mode) }   # 不提供 --hard
      $sha = Resolve-Sha $Pj ([string]$in.sha); if (-not $sha) { return (& $fail 400 'E_BAD_REF' ([string]$in.sha)) }
      if ((Invoke-Git $Pj @('merge-base', '--is-ancestor', $sha, 'HEAD')).Code -ne 0) { return (& $fail 409 'E_NOT_ANCESTOR' $sha) }
      if (-not (Test-RangeUnpushed $Pj $sha)) { return (& $fail 409 'E_PUSHED_REWRITE' 'reset') }
      $r = Invoke-GitW $Pj @('reset', "--$mode", '-q', $sha) $s $false $null
    }
    { $_ -in 'rebase', 'rebaseInteractive' } {
      if (-not $cur) { return (& $fail 409 'E_DETACHED' '') }; if (-not (& $perm $cur)) { return }
      $plan = Get-RebasePlan $Pj ([string]$in.onto); if ($plan.error) { return (& $fail 400 $plan.error ([string]$in.onto)) }
      if (-not $plan.unpushed) { return (& $fail 409 'E_PUSHED_REWRITE' 'rebase') }
      if ((Invoke-Git $Pj @('status', '--porcelain', '-uno')).Out.Trim()) { return (& $fail 409 'E_DIRTY' '') }
      if ($op -eq 'rebase') { $r = Invoke-GitW $Pj @('rebase', $plan.onto) $s $false $null }
      else {
        if ($plan.hasMerges) { return (& $fail 409 'E_HAS_MERGES' '') }
        $want = @{}; foreach ($c in $plan.commits) { $want[$c.sha] = $true }
        $todo = @($in.todo); $seen = @{}; $lines = @(); $ix = 0
        foreach ($t in $todo) {
          $sh = [string]$t.sha; $ac = [string]$t.action
          if (-not $want.ContainsKey($sh) -or $seen.ContainsKey($sh) -or $ac -notin 'pick', 'reword', 'squash', 'fixup', 'drop') { return (& $fail 400 'E_BAD_TODO' "$ac $sh") }
          if ($ix -eq 0 -and $ac -in 'squash', 'fixup') { return (& $fail 400 'E_BAD_TODO' 'first') }
          $seen[$sh] = $true; $ix++
          if ($ac -eq 'reword') {
            $m = ([string]$t.message).Replace("`r`n", "`n").Trim(); if (-not $m) { return (& $fail 400 'E_BAD_MESSAGE' $sh) }
            if ((Test-HooksMsg $Pj) -and -not (Test-CommitMsg $m)) { return (& $fail 400 'E_COMMIT_FORMAT' (($m -split "`n")[0])) }
            $mf = (New-TmpFile ($m + "`n")) -replace '\\', '/'
            $lines += "pick $sh"; $lines += "exec git commit --amend -q -F `"$mf`""
          } else { $lines += "$ac $sh" }
        }
        if ($seen.Count -ne $want.Count) { return (& $fail 400 'E_BAD_TODO' 'count') }
        $tf = (New-TmpFile (($lines -join "`n") + "`n")) -replace '\\', '/'
        $r = Invoke-GitW $Pj @('rebase', '-i', $plan.onto) $s $false @{ GIT_SEQUENCE_EDITOR = "cp `"$tf`"" }
      }
    }
    'resolve' {
      if (-not (& $perm $(if ($cur) { $cur } else { [string](Get-WorkStatus $Pj $s).rebaseHead }))) { return }
      $pth = [string]$in.path; if (-not (Test-RelPath $pth) -or $pth -notin (Get-Conflicts $Pj)) { return (& $fail 400 'E_BAD_PATH' $pth) }
      $full = [IO.Path]::GetFullPath((Join-Path $Pj.dir $pth)); $top = [IO.Path]::GetFullPath($Pj.dir).TrimEnd('\', '/')
      if (-not $full.StartsWith($top + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { return (& $fail 400 'E_BAD_PATH' $pth) }
      $side = [string]$in.side
      if ($side -in 'ours', 'theirs') { $r = Invoke-GitW $Pj @('checkout', "--$side", '--', $pth) $s $false $null }
      elseif ($side -eq 'delete') { $r = Invoke-GitW $Pj @('rm', '-q', '--', $pth) $s $false $null; break }
      else {
        $ct = [string]$in.content; if ($ct.Length -gt $GIT_OP_MAX) { return (& $fail 413 'E_TOO_LARGE' '') }
        if (-not [bool]$in.force -and $ct -match '(?m)^(<{7}|>{7})( |$)') { return (& $fail 400 'E_MARKERS' $pth) }
        $ct = $ct.Replace("`r`n", "`n"); if ([bool]$in.crlf) { $ct = $ct.Replace("`n", "`r`n") }
        [IO.File]::WriteAllText($full, $ct, [Text.UTF8Encoding]::new($false)); $r = [pscustomobject]@{ Code = 0; Out = ''; Err = ''; Timeout = $false }
      }
      if ($r.Code -eq 0) { $r = Invoke-GitW $Pj @('add', '--', $pth) $s $false $null }
    }
    { $_ -in 'continue', 'skip', 'abort' } {
      if (-not $state) { return (& $fail 409 'E_NO_STATE' '') }
      $bperm = $cur; if (-not $bperm -and $state -eq 'rebase') { $bperm = [string](Get-WorkStatus $Pj $s).rebaseHead }
      if ($op -ne 'abort' -and -not (& $perm $bperm)) { return }
      if ($op -eq 'abort' -and (Get-Role $s $Pj) -eq 'viewer') { return (& $fail 403 'E_ROLE_VIEWER' '') }
      if ($op -eq 'continue' -and (Get-Conflicts $Pj).Count) { return (& $fail 409 'E_CONFLICTS_LEFT' '') }
      if ($op -eq 'skip' -and $state -eq 'merge') { return (& $fail 400 'E_BAD_OP' 'merge 沒有 skip') }
      $verb = @{ rebase = 'rebase'; merge = 'merge'; 'cherry-pick' = 'cherry-pick'; revert = 'revert' }[$state]
      $r = Invoke-GitW $Pj @($verb, "--$op") $s ($state -in 'merge', 'revert') $null
    }
    default { return (Send-Err $res 400 'E_BAD_OP') }
  }
  if (-not $r) { return }
  if ($r.Timeout) { Write-Audit $s $Pj $op $auditArgs $r 'E_TIMEOUT'; return (Send-GitErr $res 504 'E_TIMEOUT' ($r.Err + $r.Out)) }
  Write-Audit $s $Pj $op $auditArgs $r $null
  $Pj.prCache = @{}; Push-All 'git' @{ p = $Pj.id; op = $op } $Pj.id
  $st2 = Get-RepoState $Pj; $cf = @(Get-Conflicts $Pj)
  Write-Host "$(Get-Date -f HH:mm:ss) [$($Pj.id)] git $op（$($s.user)）→ $($r.Code)"
  Send-Json $res @{ ok = ($r.Code -eq 0); code = $r.Code; out = (Clip $r.Out 20000); err = (Clip $r.Err 20000); state = $st2; conflicts = $cf; args = $r.Args } $(if ($r.Code -eq 0) { 200 } elseif ($cf.Count) { 409 } else { 422 })
}
function Get-Tag($Pj) { $i = Get-Item -LiteralPath $Pj.json; '"' + $i.LastWriteTimeUtc.Ticks.ToString('x') + '-' + $i.Length.ToString('x') + '"' }

# ---------- HTTP ----------
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
$url = "http://localhost:$Port/"
Write-Host "看板：$url   登入：$(if($NoAuth){'關閉'}else{'開啟'})   設定：$ConfigDir   （Ctrl+C 結束）"
foreach ($Pj in $projects.Values) {
  Write-Host ("  [{0}] {1}  git:{2}  自動commit:{3}  遠端同步:{4}  PR通知:{5}" -f $Pj.id, $Pj.json, $Pj.git, ($Pj.git -and $autoOn), $Pj.remote, $(if ($Pj.gh) { $Pj.gh.repo } else { '-' }))
  $Pj.lastTag = Get-Tag $Pj; try { $Pj.lastText = [IO.File]::ReadAllText($Pj.json) } catch {}
  if ($Pj.git -and $autoOn) { try { [void](Save-Commit $Pj) } catch { Write-Warning "[$($Pj.id)] 自動 commit 失敗" } }
}
if ($projects.Values | Where-Object { $_.gh }) { Write-Host "GitHub 驗證：$(if($env:GITHUB_TOKEN){'GITHUB_TOKEN'}elseif($useGhCli){'gh CLI'}else{'未驗證（每小時 60 次上限）'})" }
if (-not $NoOpen -and $IsWindows -ne $false) { Start-Process $url }

$tick = 0
try {
  $pending = $listener.GetContextAsync()
  while ($listener.IsListening) {
    if (-not $pending.Wait(500)) {
      $tick++
      foreach ($Pj in $projects.Values) {
        try { $t = Get-Tag $Pj } catch { $t = $Pj.lastTag }
        if ($t -ne $Pj.lastTag) { $Pj.lastTag = $t; $Pj.dirtyAt = Get-Date; Push-All 'board' @{ p = $Pj.id } $Pj.id; Write-Host "$(Get-Date -f HH:mm:ss) [$($Pj.id)] board.json 已變更"
          try { $nt = [IO.File]::ReadAllText($Pj.json); if ($Pj.lastText -and $nt -ne $Pj.lastText) { [void](Backup-Board $Pj $Pj.lastText 'before-change'); $o1 = $null; $n1 = $null; try { $o1 = Read-BoardJson $Pj.lastText; $n1 = Read-BoardJson $nt } catch {}; Invoke-BoardEvents $Pj $o1 $n1 }; $Pj.lastText = $nt } catch { Write-Warning "[$($Pj.id)] 備份失敗：$($_.Exception.Message)" } }
        if ($autoOn -and $Pj.git -and $Pj.dirtyAt -and ((Get-Date) - $Pj.dirtyAt).TotalMilliseconds -ge $DebounceMs) {
          $Pj.dirtyAt = $null; try { if (Save-Commit $Pj) { Push-All 'history' @{ p = $Pj.id } $Pj.id } } catch { Write-Warning "[$($Pj.id)] 自動 commit 失敗" }
        }
        try { Sync-Remote $Pj } catch { Set-SyncError $Pj 'E_SYNC' }
        if ($Pj.gh) { try { Update-GitHub $Pj } catch { Write-Warning "[$($Pj.id)] GitHub 輪詢失敗" } }
      }
      try { Update-DispatchTick } catch { Write-Warning "派工器：$($_.Exception.Message)" }
      if ($tick % 4 -eq 0) { try { Update-SheetsTick } catch { Write-Warning "Google Sheets：$($_.Exception.Message)" } }
      if ($tick % 30 -eq 0) { Push-All $null ": ping`n`n" $null }
      if ($tick % 120 -eq 0) { foreach ($k in @($sessions.Keys)) { if (((Get-Date) - $sessions[$k].last).TotalMinutes -gt $IDLE_MIN) { $sessions.Remove($k) } } }
      continue
    }
    $ctx = $pending.Result; $pending = $listener.GetContextAsync()
    $req = $ctx.Request; $res = $ctx.Response; $path = $req.Url.AbsolutePath
    try {
      if ($path -match '^/api/agent/v1(/[A-Za-z0-9._/-]{0,80})$') {   # Agent API：Bearer token（不用 cookie，所以不需要 CSRF）
        $sub = $Matches[1]; if (Test-External $req) { Send-Err $res 403 'E_READ_ONLY'; continue }
        $ag = Get-AgentAuth $req; if ($ag -eq 'RATE') { Send-Err $res 429 'E_RATE_LIMIT'; continue }; if (-not $ag) { Send-Err $res 401 'E_AGENT_TOKEN'; continue }
        Invoke-AgentApi $req $res $ag $sub; continue
      }
      if ((Test-External $req) -and -not (Test-ExternalGate $req $res $path)) { continue }
      if ($req.HttpMethod -eq 'GET' -and $path -eq '/api/google/start') { Invoke-GoogleStart $req $res; continue }
      if ($req.HttpMethod -eq 'GET' -and $path -eq '/api/google/callback') { Invoke-GoogleCallback $req $res; continue }
      if ($req.HttpMethod -eq 'POST') {
        if (-not (Test-Csrf $req)) { Send-Err $res 403 'E_CSRF'; continue }
        if ($path -match '^/api/p/([^/]{1,64})/(restore|migrate-aipm|agent-tokens|agent/prompt|dispatch/config|dispatch/kill)$') {
          $sx = Get-Session $req; $pp = $Matches[1]; $op = $Matches[2]
          if (-not $sx) { Send-Err $res 401 'E_UNAUTHENTICATED'; continue }
          if ($sx.external) { Send-Err $res 403 'E_READ_ONLY'; continue }
          if (-not $projects.Contains($pp) -or -not $sx.allowed.ContainsKey($pp)) { Send-Err $res 403 'E_FORBIDDEN'; continue }
          $PjX = $projects[$pp]
          switch ($op) { 'restore' { Invoke-Restore $req $res $sx $PjX } 'migrate-aipm' { Invoke-MigrateAiPm $req $res $sx $PjX } 'agent-tokens' { Invoke-AgentTokensAdmin $req $res $sx $PjX $true } 'agent/prompt' { Invoke-AgentPrompt $req $res $sx $PjX } default { Invoke-DispatchApi $req $res $sx $PjX ('/' + $op) } }
          continue
        }
        if ($path -in '/api/me/prefs', '/api/admin/integrations') { $sx = Get-Session $req; if (-not $sx) { Send-Err $res 401 'E_UNAUTHENTICATED'; continue }; if ($sx.external -and $path -ne '/api/me/prefs') { Send-Err $res 403 'E_READ_ONLY'; continue }
          if ($path -eq '/api/me/prefs') { Invoke-Prefs $req $res $sx } else { Invoke-IntegAdmin $req $res $sx $true }; continue }
        $sx = Get-Session $req; if ($sx -and $sx.external -and $path -ne '/api/logout') { Send-Err $res 403 'E_READ_ONLY'; continue }
        if ($path -match '^/api/p/([^/]{1,64})/git/op$') { Invoke-GitOpReq $req $res $Matches[1]; continue }
        if ($path -match '^/api/p/([^/]{1,64})/clear-examples$') { Invoke-ClearExamples $req $res $Matches[1]; continue }
        switch ($path) {
          '/api/login' { if ($NoAuth) { Send-Json $res @{ user = 'local'; role = 'admin' } } else { Invoke-Login $req $res } }
          '/api/setup' { Invoke-Setup $req $res }
          '/api/setup/github' { Invoke-SetClientId $req $res }
          '/api/gh/start' { Invoke-GhStart $req $res }
          '/api/gh/poll' { Invoke-GhPoll $req $res }
          '/api/admin/users' { Invoke-AdminUsers $req $res $true }
          '/api/projects' { Invoke-AddProject $req $res }
          '/api/admin/apply' { Invoke-ApplyProject $req $res }
          '/api/logout' { $c = $req.Cookies['aib_sid']; if ($c) { $sessions.Remove((Get-Key $c.Value)) }; $res.Headers.Add('Set-Cookie', 'aib_sid=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0'); Send-Json $res @{ ok = $true } }
          default { Send-Err $res 404 'E_NOT_FOUND' }
        }
        continue
      }
      if ($req.HttpMethod -ne 'GET') { Send-Err $res 405 'E_METHOD'; continue }
      if ($path -in '/', '/board.html') { Send-Bytes $res ([IO.File]::ReadAllBytes($Html)) 'text/html; charset=utf-8'; continue }
      if ($path -eq '/api/status') { $xg = Get-Sec (Read-Integ) 'external'; Send-Json $res @{ setup = [bool](Test-NeedSetup); noAuth = [bool]$NoAuth; github = [bool](Read-OAuth); external = [bool](Test-External $req); google = [bool]($xg -and $xg.enabled -and $xg.googleClientId) }; continue }
      $s = Get-Session $req
      if (-not $s) { Send-Err $res 401 'E_UNAUTHENTICATED'; continue }
      if ($path -eq '/board.json') { $first = @($s.allowed.Keys | Where-Object { $projects.Contains($_) })[0]; if (-not $first) { Send-Err $res 403 'E_FORBIDDEN'; continue }; $path = "/api/p/$first/board.json" }   # 舊網址相容
      if ($path -eq '/api/admin/users') { Invoke-AdminUsers $req $res $false; continue }
      if ($path -eq '/api/admin/integrations') { Invoke-IntegAdmin $req $res $s $false; continue }
      if ($path -eq '/api/me') {
        $list = @($projects.Values | Where-Object { $s.allowed.ContainsKey($_.id) } | ForEach-Object { [ordered]@{ id = $_.id; name = $_.name; role = $s.allowed[$_.id]; git = $_.git; autoCommit = ($_.git -and $autoOn); github = [bool]$_.gh; remoteSync = $_.remote; syncError = $_.syncError } })
        Send-Json $res @{ user = $s.user; role = $s.role; noAuth = [bool]$NoAuth; prefs = (Get-Prefs $s.user); external = [bool]$s.external; local = ($req.IsLocal -and -not (Test-External $req)); projects = $list; github = $s.ghLogin; pending = $(if ($s.role -eq 'admin') { @(Read-Pending).Count } else { 0 }); defaultBoardPath = $(if ($s.role -eq 'admin') { $DefaultBoard } else { '' }) }; continue
      }
      if ($path -eq '/events') {
        if ($clients.Count -ge $MaxClients) { Send-Err $res 503 'E_BUSY'; continue }
        $res.ContentType = 'text/event-stream'; $res.Headers['Cache-Control'] = 'no-store'; $res.SendChunked = $true
        $b = [Text.Encoding]::UTF8.GetBytes("retry: 3000`n`n"); $res.OutputStream.Write($b, 0, $b.Length); $res.OutputStream.Flush()
        $clients.Add(@{ res = $res; allowed = $s.allowed }); continue
      }
      if ($path -notmatch '^/api/p/([^/]{1,64})(/.*)$') { Send-Err $res 404 'E_NOT_FOUND'; continue }
      $pid_ = $Matches[1]; $sub = $Matches[2]
      if ($pid_ -cnotmatch $PID_RE) { Send-Err $res 400 'E_BAD_PROJECT'; continue }
      if (-not $projects.Contains($pid_) -or -not $s.allowed.ContainsKey($pid_)) { Send-Err $res 403 'E_FORBIDDEN'; continue }   # 不存在與無權限一律 403，不洩漏專案是否存在
      $Pj = $projects[$pid_]
      switch -Regex ($sub) {
        '^/board\.json$' {
          $tag = Get-Tag $Pj; $res.Headers['ETag'] = $tag
          if ($req.Headers['If-None-Match'] -eq $tag) { $res.StatusCode = 304; $res.Close() }
          else { Send-Bytes $res ([IO.File]::ReadAllBytes($Pj.json)) 'application/json; charset=utf-8' }
        }
        '^/backups$' { Invoke-Backups $req $res $s $Pj }
        '^/agent-tokens$' { Invoke-AgentTokensAdmin $req $res $s $Pj $false }
        '^/(dispatch|dispatch/log/[A-Za-z0-9._-]{1,120}\.log)$' { Invoke-DispatchApi $req $res $s $Pj $sub }
        '^/agent/bootstrap$' { Send-Json $res (Get-Bootstrap $Pj $(if ($s.allowed[$Pj.id] -in $AGENT_ROLES) { $s.allowed[$Pj.id] } else { 'dev-agent' }) "http://localhost:$Port") }
        '^/claims$' { $cl = Get-Claims $Pj.id; Send-Json $res @{ claims = @($cl.Keys | ForEach-Object { [ordered]@{ ticket = $_; by = $cl[$_].name; until = $cl[$_].until.ToString('o') } }) } }
        '^/people$' {   # 這個專案可指派的人與群組（只給名稱，不含帳號細節）
          $ul = @(Read-Users | Where-Object { [string]$_.status -ne 'disabled' -and (Get-Allowed $_).ContainsKey($Pj.id) } | ForEach-Object { [string]$_.name })
          $gl = @(Read-Groups | Where-Object { $_.projects -and $_.projects.PSObject.Properties[$Pj.id] } | ForEach-Object { [ordered]@{ id = [string]$_.id; name = [string]$_.name; members = @(Get-Members $_) } })
          Send-Json $res @{ users = $ul; groups = $gl }
        }
        '^/history$' {
          if (-not $Pj.git) { Send-Err $res 503 'E_GIT_DISABLED'; break }
          $q = $req.QueryString; $lim = 30; $skip = 0
          if ($q['limit'] -match '^\d{1,3}$') { $lim = [Math]::Min(100, [Math]::Max(1, [int]$q['limit'])) }
          if ($q['skip'] -match '^\d{1,6}$') { $skip = [int]$q['skip'] }
          $a = @('log', "--max-count=$($lim+1)", "--skip=$skip", '--format=%H%x1f%aI%x1f%an%x1f%s')
          if ($q['id']) { if ($q['id'] -notmatch '^[A-Za-z0-9._-]{1,40}$') { Send-Err $res 400 'E_BAD_ID'; break }; $a += @('-F', "--grep=$($q['id'])") }
          $r = Invoke-Git $Pj ($a + @('--', $Pj.rel)) 1MB
          $rows = @($r.Out -split "`n" | Where-Object { $_ } | ForEach-Object { $x = $_ -split [char]0x1f; [ordered]@{ sha = $x[0]; at = $x[1]; author = $x[2]; message = $x[3] } })
          Send-Json $res @{ commits = @($rows | Select-Object -First $lim); more = ($rows.Count -gt $lim) }
        }
        '^/history/([0-9a-fA-F]{7,40})$' {
          if (-not $Pj.git) { Send-Err $res 503 'E_GIT_DISABLED'; break }
          $r = Invoke-Git $Pj @('show', "$($Matches[1]):$($Pj.rel)")
          if ($r.Code -ne 0) { Send-Err $res 404 'E_NOT_FOUND' } else { Send-Bytes $res ([Text.Encoding]::UTF8.GetBytes($r.Out)) 'application/json; charset=utf-8' }
        }
        '^/git/branches$' { if (-not $Pj.git) { Send-Err $res 503 'E_GIT_DISABLED'; break }; Send-Json $res (Get-GitBranches $Pj) }
        '^/git/log$' { if (-not $Pj.git) { Send-Err $res 503 'E_GIT_DISABLED'; break }; $lg = Get-GitLog $Pj $req.QueryString; if (-not $lg) { Send-Err $res 400 'E_BAD_REF' } else { Send-Json $res $lg } }
        '^/git/commit/([0-9a-fA-F]{7,40})$' {
          if (-not $Pj.git) { Send-Err $res 503 'E_GIT_DISABLED'; break }
          $r = Invoke-Git $Pj @('show', '--no-color', '--stat', '--patch', '--format=commit %H%nAuthor: %an <%ae>%nDate:   %aI%n%n%B', $Matches[1], '--') 1MB
          if ($r.Code -ne 0) { Send-Err $res 404 'E_NOT_FOUND' } else { $tx = $r.Out; if ($tx.Length -ge 1MB) { $tx += "`n… 內容過長，已截斷" }; Send-Bytes $res ([Text.Encoding]::UTF8.GetBytes($tx)) 'text/plain; charset=utf-8' }
        }
        '^/git/prs$' { Send-Json $res (Get-GitPrs $Pj $s) }
        '^/git/status$' { if (-not $Pj.git) { Send-Err $res 503 'E_GIT_DISABLED'; break }; Send-Json $res (Get-WorkStatus $Pj $s) }
        '^/git/workdiff$' { if (-not $Pj.git) { Send-Err $res 503 'E_GIT_DISABLED'; break }; $wd = Get-WorkDiff $Pj ([string]$req.QueryString['path']) ($req.QueryString['staged'] -eq '1'); if ($null -eq $wd) { Send-Err $res 400 'E_BAD_PATH' } else { Send-Bytes $res ([Text.Encoding]::UTF8.GetBytes($wd)) 'text/plain; charset=utf-8' } }
        '^/git/conflict$' { if (-not $Pj.git) { Send-Err $res 503 'E_GIT_DISABLED'; break }; $cfx = Get-ConflictFile $Pj ([string]$req.QueryString['path']); if (-not $cfx) { Send-Err $res 404 'E_NOT_FOUND' } else { Send-Json $res $cfx } }
        '^/git/rebase-plan$' { if (-not $Pj.git) { Send-Err $res 503 'E_GIT_DISABLED'; break }; Send-Json $res (Get-RebasePlan $Pj ([string]$req.QueryString['onto'])) }
        '^/git/audit$' { Send-Json $res @{ entries = @(Get-Audit $Pj) } }
        '^/git/overview$' { if (-not $Pj.git) { Send-Err $res 503 'E_GIT_DISABLED'; break }; Send-Json $res (Get-GitOverview $Pj) }
        '^/git/graph$' { if (-not $Pj.git) { Send-Err $res 503 'E_GIT_DISABLED'; break }; $g = Get-GitGraph $Pj $req.QueryString; if (-not $g) { Send-Err $res 400 'E_BAD_REF' } else { Send-Json $res $g } }
        '^/git/info/([0-9a-fA-F]{7,40})$' { if (-not $Pj.git) { Send-Err $res 503 'E_GIT_DISABLED'; break }; $ci_ = Get-CommitInfo $Pj $Matches[1]; if (-not $ci_) { Send-Err $res 404 'E_NOT_FOUND' } else { Send-Json $res $ci_ } }
        '^/git/filediff/([0-9a-fA-F]{7,40})$' { if (-not $Pj.git) { Send-Err $res 503 'E_GIT_DISABLED'; break }; $fd = Get-FileDiff $Pj $Matches[1] ([string]$req.QueryString['path']) ([string]$req.QueryString['old']); if ($null -eq $fd) { Send-Err $res 404 'E_NOT_FOUND' } else { Send-Bytes $res ([Text.Encoding]::UTF8.GetBytes($fd)) 'text/plain; charset=utf-8' } }
        default { Send-Err $res 404 'E_NOT_FOUND' }
      }
    } catch { try { Send-Err $res 500 'E_INTERNAL' } catch { try { $res.Abort() } catch {} } }
  }
} finally {
  foreach ($c in $clients) { try { $c.res.Abort() } catch {} }
  $listener.Stop(); $listener.Close()
}
