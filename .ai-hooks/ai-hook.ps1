<#
 AI Dev Skills hooks（Cursor / Claude Code 共用）。Windows PowerShell 5.1 與 PowerShell 7 皆可。
 用法：ai-hook.ps1 -Tool cursor|claude -Event <事件名>，JSON 從 stdin 讀入。
 原則：快速、有上限、失敗不擋路（安全檢查除外）；hook 結果不等於驗收，驗收由獨立代理負責。
#>
param([ValidateSet('cursor','claude')][string]$Tool = 'claude', [string]$Event = '')
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch {}
$HookDir = $PSScriptRoot
$Root = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } elseif ($env:CURSOR_PROJECT_DIR) { $env:CURSOR_PROJECT_DIR } else { Split-Path $HookDir -Parent }

# ---- 設定（.ai-hooks/config.json，可改）----
$Cfg = @{ enabled = $true; blockDangerousShell = $true; protectSecrets = $true; formatOnEdit = $true; guardOnEdit = $true
          stopTests = $true; stopClippy = $false; testTimeoutSec = 300; toolTimeoutSec = 60; logMaxKB = 1024; testCommands = @()
          role = 'dev-agent'; boardPath = '.ai-pm/board.json'; boardGuard = $true; protectSpecs = $true; requireBoardUpdate = $true }
$cfgPath = Join-Path $HookDir 'config.json'
if (Test-Path -LiteralPath $cfgPath) {
  try { $j = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $j.PSObject.Properties) { if ($p.Name -notlike '_*') { $Cfg[$p.Name] = $p.Value } } } catch {}
}
$LogDir = Join-Path $HookDir 'logs'; $StateFile = Join-Path $LogDir 'pending.txt'
if ($env:AI_AGENT_ROLE -and $env:AI_AGENT_ROLE -in 'viewer','dev-agent','verifier','high-tier','admin') { $Cfg.role = $env:AI_AGENT_ROLE }   # 由啟動 agent 的人設定，agent 不應自行修改
$Privileged = $Cfg.role -in 'high-tier','admin'
. (Join-Path $HookDir 'validate-board.ps1') -Library

function Write-Log([string]$msg) {
  try {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    $log = Join-Path $LogDir 'hooks.log'
    if ((Test-Path $log) -and ((Get-Item $log).Length -gt [int]$Cfg.logMaxKB * 1KB)) { Move-Item $log "$log.1" -Force }  # 只留一代，總量有上限
    if ($msg.Length -gt 2000) { $msg = $msg.Substring(0, 2000) + '…' }
    Add-Content -LiteralPath $log -Value ("{0} [{1}/{2}] {3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Tool, $Event, $msg) -Encoding UTF8
  } catch {}
}
function Out-Json($o) { [Console]::Out.Write(($o | ConvertTo-Json -Depth 6 -Compress)) }

# ---- 判斷規則 ----
$SecretPath = '(^|[\\/])\.env(\.(?!example$|sample$|template$)[^\\/]+)?$|\.(pem|key|pfx|p12|jks|keystore)$|(^|[\\/])id_(rsa|dsa|ecdsa|ed25519)$|(^|[\\/])(secrets?|credentials)\.(json|ya?ml|toml)$'
$Deny = @(
  @('\brm\s+(-[a-zA-Z]*\s+)*-[a-zA-Z]*[rR][a-zA-Z]*\s+(-[a-zA-Z]+\s+)*(/|~|\*|\$HOME|/\*)(\s|$)', '遞迴刪除根目錄/家目錄/全部檔案'),
  @('\bgit\s+push\b.*(\s--force(?!-with-lease)\b|\s-f\b)', 'git push --force 會覆寫遠端歷史'),
  @('\bgit\s+reset\s+--hard\b', 'git reset --hard 會丟失未提交變更'),
  @('\bformat(\.com)?\s+[a-zA-Z]:', '格式化磁碟'),
  @('\b(del|erase)\s+.*\/[sS]\b', 'del /s 遞迴刪除'),
  @('\b(rd|rmdir)\s+.*\/[sS]\b.*\/[qQ]|\b(rd|rmdir)\s+.*\/[qQ]\b.*\/[sS]', 'rd /s /q 靜默遞迴刪除'),
  @('Remove-Item\b.*-Recurse\b.*\s([a-zA-Z]:\\?|\\|/|~|\$HOME|\$env:USERPROFILE)(\s|$|")', '遞迴刪除磁碟根目錄或家目錄'),
  @('\b(curl|wget)\b[^|]*\|\s*(sudo\s+)?(ba|z)?sh\b|\b(iwr|irm|Invoke-WebRequest|Invoke-RestMethod)\b[^|]*\|\s*(iex|Invoke-Expression)\b', '下載後直接執行（curl|sh / iwr|iex）'),
  @('\b(cat|type|more|less|head|tail|Get-Content|gc|bat)\b[^|;&]*(\.env(?!\.(example|sample|template)\b)(\.\w+)?\b|\.pem\b|id_rsa|id_ed25519|secrets?\.(json|ya?ml|toml))', '讀取機密檔（.env/金鑰）')
)
$Ask = @(
  @('\bgit\s+push\b', 'git push（推送到遠端）'),
  @('\bgit\s+(clean\s+-[a-zA-Z]*f|checkout\s+--\s|restore\s+\.)', '會丟棄本機變更的 git 指令'),
  @('\b(npm|pnpm|yarn)\s+publish\b|\bcargo\s+publish\b', '發布套件'),
  @('\brm\s+(-[a-zA-Z]*\s+)*-[a-zA-Z]*[rR]|Remove-Item\b.*-Recurse', '遞迴刪除'),
  @('\b(DROP|TRUNCATE)\s+(TABLE|DATABASE)\b', '刪除資料表/資料庫'),
  @('\bchmod\s+(-R\s+)?777\b', 'chmod 777')
)
$Protected = '\.feature$|(^|[\\/])\.ai-hooks([\\/]|$)|(^|[\\/])\.cursor[\\/]hooks\.json$|(^|[\\/])\.claude[\\/]settings(\.local)?\.json$|(^|[\\/])\.github[\\/]workflows([\\/]|$)|(^|[\\/])\.githooks([\\/]|$)'
function Test-ProtectedPath([string]$p) { $Cfg.protectSpecs -and -not $Privileged -and $p -and ($p -replace '\\', '/') -match $Protected }
# .ai-pm/ 是 GuGuBoard 的工具資料夾：AI 只能用經過驗證的修改寫入 .ai-pm/board.json，其他檔案（project.json、README、backups）一律不可寫或刪
function Test-AiPmPath([string]$p) { $p -and ($p -replace '\\', '/') -match '(^|/)\.ai-pm(/|$)' -and ($p -replace '\\', '/') -notmatch '(^|/)\.ai-pm/board\.json$' }
function Test-BoardPath([string]$p) { $Cfg.boardGuard -and $p -and ([IO.Path]::GetFileName($p) -ieq 'board.json') }
function Get-OldBoard([string]$file) {   # 比對基準：git HEAD 版本；沒有 git 就用目前檔案
  try {
    $full = [IO.Path]::GetFullPath($file); $dir = Split-Path $full
    $top = (& git -C $dir rev-parse --show-toplevel 2>$null); if ($LASTEXITCODE -eq 0 -and $top) {
      $rel = $full.Substring(([IO.Path]::GetFullPath($top.Trim())).TrimEnd('\','/').Length).TrimStart('\','/') -replace '\\', '/'
      $txt = (& git -C $dir show "HEAD:$rel" 2>$null) -join "`n"; if ($LASTEXITCODE -eq 0 -and $txt) { return ,(Read-BoardJson $txt) } }
  } catch {}
  return $null
}
function Test-BoardText([string]$file, [string]$text, $old) {
  # 回傳錯誤清單；任何例外都當成錯誤（fail closed）
  try { $new = Read-BoardJson $text } catch { return @("board.json 無法解析：$($_.Exception.Message)") }
  $errs = @(Test-Board $new)
  if (-not $Privileged) { $errs += @(Test-BoardRole $old $new $Cfg.role) }
  if ($old) { $errs += @(Test-BoardBookkeeping $old $new); $errs += @(Test-BoardIntegrity $old $new) }
  return $errs
}
function Get-EditedText($ti, [string]$tool) {   # 算出 Edit / MultiEdit 之後的內容
  $file = [string]$ti.file_path
  if ($tool -eq 'Write') { return [string]$ti.content }
  $cur = if (Test-Path -LiteralPath $file) { [IO.File]::ReadAllText($file) } else { '' }
  $edits = if ($tool -eq 'MultiEdit') { @($ti.edits) } else { @($ti) }
  foreach ($ed in $edits) {
    $os = [string]$ed.old_string; $ns = [string]$ed.new_string
    if (-not $os) { $cur = $ns; continue }
    $ix = $cur.IndexOf($os, [StringComparison]::Ordinal); if ($ix -lt 0) { throw '找不到要取代的字串' }
    if ($ed.replace_all) { $cur = $cur.Replace($os, $ns) } else { $cur = $cur.Substring(0, $ix) + $ns + $cur.Substring($ix + $os.Length) }
  }
  return $cur
}
function Test-Shell([string]$cmd) {
  if (($cmd -replace '\\', '/') -match '\.ai-pm\b' -and $cmd -match '(>|\b(rm|rmdir|del|erase|rd|mv|move|cp|copy|Remove-Item|Move-Item|Rename-Item|Copy-Item|Set-Content|Add-Content|Out-File|Clear-Content|New-Item|tee|truncate|sed\s+-i|attrib)\b|\bgit\s+(rm|mv|checkout|restore|reset|clean|stash)\b)') { return @('deny', '不可用指令修改或刪除 .ai-pm/（board.json 請用編輯工具修改，會先經過驗證）') }
  if ($cmd -match '\bgit\b.*\s(--no-verify|-n)\b' -and $cmd -match '\bgit\s+(commit|push)\b') { return @('deny', '以 --no-verify 跳過 git hooks') }
  if (-not $Privileged -and $Cfg.protectSpecs -and ($cmd -replace '\\', '/') -match '(\.feature\b|\.ai-hooks/|\.cursor/hooks\.json|\.claude/settings|\.github/workflows|\.githooks|core\.hooksPath)' -and $cmd -match '(>|\b(Set-Content|Add-Content|Out-File|Remove-Item|Move-Item|Copy-Item|rm|mv|cp|del|sed\s+-i|tee|truncate|git\s+config)\b)') { return @('deny', '開發代理不可修改 BDD 情境（.feature）、hook 設定或 CI 流程') }
  if ($Cfg.blockDangerousShell) {
    foreach ($r in $Deny) { if ($cmd -match $r[0]) { return @('deny', $r[1]) } }
    foreach ($r in $Ask)  { if ($cmd -match $r[0]) { return @('ask',  $r[1]) } }
  }
  return @('allow', '')
}
function Test-SecretPath([string]$p) { return ($Cfg.protectSecrets -and $p -and ($p -match $SecretPath)) }

function Invoke-Bounded([string]$exe, [string[]]$argv, [int]$sec) {
  # 有逾時上限的外部程式呼叫；回傳 @(exitCode, output)
  $o = Join-Path $LogDir ("run-{0}.out" -f $PID); $e = "$o.err"
  New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
  $p = Start-Process -FilePath $exe -ArgumentList $argv -WorkingDirectory $script:WorkDir -NoNewWindow -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
  if (-not $p.WaitForExit($sec * 1000)) { try { $p.Kill() } catch {}; return @(124, "逾時 ${sec}s：$exe $($argv -join ' ')") }
  $txt = ((Get-Content $o -Raw -ErrorAction SilentlyContinue) + (Get-Content $e -Raw -ErrorAction SilentlyContinue))
  Remove-Item $o, $e -ErrorAction SilentlyContinue
  if ($txt.Length -gt 3000) { $txt = '…' + $txt.Substring($txt.Length - 3000) }
  return @($p.ExitCode, $txt)
}
function Find-Up([string]$start, [string]$name) {
  $d = $start
  while ($d -and $d.Length -ge $Root.Length) { if (Test-Path (Join-Path $d $name)) { return $d }; $d = Split-Path $d -Parent }
  return $null
}
function Get-Exe([string]$n) { $c = Get-Command $n -ErrorAction SilentlyContinue | Select-Object -First 1; if ($c) { $c.Source } else { $null } }

function Invoke-EditChecks([string]$file) {
  $findings = @()
  if (-not $file -or -not (Test-Path -LiteralPath $file)) { return $findings }
  $ext = [IO.Path]::GetExtension($file).ToLower(); $name = [IO.Path]::GetFileName($file)
  $isTest = $file -match '([\\/](tests?|__tests__|benches)[\\/])|(_test\.rs$)|(\.(test|spec)\.[jt]sx?$)'
  # 1) 只格式化這一個檔案（工具不存在就略過）
  if ($Cfg.formatOnEdit) {
    if ($ext -eq '.rs' -and ($rf = Get-Exe 'rustfmt')) { $script:WorkDir = Split-Path $file; $r = Invoke-Bounded $rf @('--edition','2021',"`"$file`"") $Cfg.toolTimeoutSec; if ($r[0] -ne 0) { $findings += "rustfmt 失敗：$($r[1])" } }
    if ($ext -in '.ts','.tsx','.js','.jsx','.mjs','.cjs','.vue','.svelte') {
      $nm = Find-Up (Split-Path $file) 'node_modules'
      if ($nm) {
        $script:WorkDir = $nm; $bin = Join-Path $nm 'node_modules\.bin'
        foreach ($t in @(@('prettier', @('--write')), @('eslint', @('--fix','--max-warnings=0')))) {
          $exe = @((Join-Path $bin "$($t[0]).cmd"), (Join-Path $bin $t[0])) | Where-Object { Test-Path $_ } | Select-Object -First 1
          if ($exe) { $r = Invoke-Bounded $exe ($t[1] + "`"$file`"") $Cfg.toolTimeoutSec; if ($r[0] -ne 0) { $findings += "$($t[0]) 回報問題：$($r[1])" } }
        }
      }
    }
  }
  # 2) 明確規則檢查
  if ($Cfg.guardOnEdit -and -not $isTest) {
    $lines = @(Get-Content -LiteralPath $file -Encoding UTF8 -ErrorAction SilentlyContinue)
    $n = 0
    foreach ($l in $lines) {
      $n++
      if ($ext -eq '.rs' -and $l -match '^\s*#\[cfg\(test\)\]') { break }   # 之後是測試模組
      if ($l -match '^\s*(//|\*|/\*)') { continue }
      if ($ext -eq '.rs' -and $l -match '\.(unwrap|expect)\s*\(') { $findings += "${name}:$n 產品程式使用 unwrap()/expect()，請改用 Result/? 或明確處理" }
      if ($ext -in '.ts','.tsx','.js','.jsx' -and $l -match '\bconsole\.log\s*\(') { $findings += "${name}:$n 殘留 console.log，請改用正式 logger 或移除" }
      if ($l -match '(?i)(api[_-]?key|secret|passw(or)?d|access[_-]?token|private[_-]?key)\s*[:=]\s*["''][^"''\s]{8,}["'']|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|\bgh[pousr]_[A-Za-z0-9]{30,}') { $findings += "${name}:$n 疑似寫死的機密，請改由設定/環境變數/金鑰庫讀取" }
      if ($findings.Count -ge 20) { $findings += '（超過 20 筆，其餘省略）'; break }
    }
  }
  if (Test-ProtectedPath $file) { $findings += "${name}：角色 $($Cfg.role) 不可修改 BDD 情境、hook 設定或 CI 流程，請用 git 還原這個檔案" }
  if (Test-BoardPath $file) {
    $be = try { @(Test-BoardText $file ([IO.File]::ReadAllText($file)) (Get-OldBoard $file)) } catch { @("無法驗證 board.json：$($_.Exception.Message)") }   # fail closed
    $findings += @($be | ForEach-Object { "board.json：$_" })
  }
  if ($findings.Count) {
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    Add-Content -LiteralPath $StateFile -Value ($findings | ForEach-Object { $_ -replace "`r?`n", ' ' }) -Encoding UTF8
  }
  Add-Content -LiteralPath (Join-Path $LogDir 'edited.txt') -Value $file -Encoding UTF8 -ErrorAction SilentlyContinue
  return $findings
}

function Invoke-StopChecks {
  $msgs = @()
  $edited = Join-Path $LogDir 'edited.txt'
  if (Test-Path $StateFile) { $msgs += @(Get-Content $StateFile -Encoding UTF8 | Select-Object -Unique -First 30); Remove-Item $StateFile -Force }
  $hadEdits = Test-Path $edited
  if ($hadEdits -and $Cfg.requireBoardUpdate -and $Cfg.role -eq 'dev-agent') {
    $files = @(Get-Content $edited -Encoding UTF8 -ErrorAction SilentlyContinue)
    $bp = Join-Path $Root $Cfg.boardPath
    if ((Test-Path -LiteralPath $bp) -and -not ($files | Where-Object { [IO.Path]::GetFileName($_) -ieq 'board.json' })) {
      $msgs += "這輪改了程式但沒有更新看板：請在 $($Cfg.boardPath) 把你的 Task 卡片更新 updatedAt、追加 history（from/to/by），必要時調整燈號與原因"
    }
  }
  Remove-Item $edited -ErrorAction SilentlyContinue
  if ($Cfg.stopTests -and $hadEdits) {     # 本輪沒改檔就不跑測試
    $cmds = @($Cfg.testCommands)
    if (-not $cmds.Count) {
      foreach ($d in @($Root, (Join-Path $Root 'src-tauri'))) { if (Test-Path (Join-Path $d 'Cargo.toml')) { $cmds += ,@($d, 'cargo', 'test --quiet'); if ($Cfg.stopClippy) { $cmds += ,@($d, 'cargo', 'clippy --quiet -- -D warnings') }; break } }
      $pj = Join-Path $Root 'package.json'
      if ((Test-Path $pj) -and ((Get-Content $pj -Raw) -match '"test"\s*:')) { $cmds += ,@($Root, $(if ($IsWindows -ne $false) { 'npm.cmd' } else { 'npm' }), 'test --silent') }
    }
    foreach ($c in $cmds) {
      if ($c -is [string]) { $c = @($Root, ($c -split ' ', 2)[0], ($c -split ' ', 2)[1]) }
      $exe = Get-Exe $c[1]; if (-not $exe) { Write-Log "略過：找不到 $($c[1])"; continue }
      $script:WorkDir = $c[0]
      $r = Invoke-Bounded $exe @($c[2]) $Cfg.testTimeoutSec
      Write-Log "測試 $($c[1]) $($c[2]) => exit $($r[0])"
      if ($r[0] -ne 0) { $msgs += "測試失敗（$($c[1]) $($c[2])，exit $($r[0])）：$($r[1])" }
    }
  }
  return $msgs
}

# ---- 主流程 ----
$raw = [Console]::In.ReadToEnd()
if (-not $Cfg.enabled) { if ($Tool -eq 'cursor' -and $Event -like 'before*') { Out-Json @{ permission = 'allow' } }; exit 0 }
try { $in = $raw | ConvertFrom-Json } catch { Write-Log "無法解析輸入"; if ($Tool -eq 'cursor' -and $Event -like 'before*') { Out-Json @{ permission = 'allow' } }; exit 0 }
$Note = '（hook 只是自動檢查，不代表驗收完成；驗收須由獨立的驗證代理執行）'

try {
  switch ("$Tool/$Event") {
    'cursor/beforeShellExecution' {
      $d = Test-Shell ([string]$in.command); Write-Log "$($d[0]) $($in.command)"
      if ($d[0] -eq 'allow') { Out-Json @{ permission = 'allow' } }
      else { Out-Json @{ permission = $d[0]; user_message = "AI Dev hook：$($d[1])"; agent_message = "此指令被專案 hook 判定為「$($d[1])」（$($d[0])）。不要繞過或停用 hook，請改用安全做法或請使用者手動執行。" } }
    }
    'cursor/beforeReadFile' {
      if (Test-SecretPath ([string]$in.file_path)) { Write-Log "deny read $($in.file_path)"; Out-Json @{ permission = 'deny'; user_message = "AI Dev hook：已阻擋讀取機密檔 $($in.file_path)" } }
      else { Out-Json @{ permission = 'allow' } }
    }
    'cursor/afterFileEdit' { $f = Invoke-EditChecks ([string]$in.file_path); Write-Log "edit $($in.file_path) 發現 $($f.Count) 項" }
    'cursor/stop' {
      $m = Invoke-StopChecks; Write-Log "stop status=$($in.status) 問題 $($m.Count) 項"
      if ($m.Count -and $in.status -eq 'completed') { Out-Json @{ followup_message = "自動檢查發現下列問題，請修正後再結束$Note：`n- " + ($m -join "`n- ") } } else { Out-Json @{} }
    }
    'claude/PreToolUse' {
      $ti = $in.tool_input
      if ($in.tool_name -in 'Bash','PowerShell') {
        $d = Test-Shell ([string]$ti.command); Write-Log "$($d[0]) $($ti.command)"
        if ($d[0] -ne 'allow') { Out-Json @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = $d[0]; permissionDecisionReason = "AI Dev hook：$($d[1])。不要繞過或停用 hook，請改用安全做法或請使用者手動執行。" } } }
      } elseif ($in.tool_name -in 'Edit','Write','MultiEdit','NotebookEdit' -and (Test-AiPmPath ([string]$ti.file_path))) {
        Write-Log "deny ai-pm $($ti.file_path)"
        Out-Json @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = "AI Dev hook：.ai-pm/ 只允許修改 .ai-pm/board.json（且需通過驗證），不可寫入 $($ti.file_path)。" } }
      } elseif ($in.tool_name -in 'Edit','Write','MultiEdit' -and (Test-ProtectedPath ([string]$ti.file_path))) {
        Write-Log "deny protected $($ti.file_path)"
        Out-Json @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = "AI Dev hook：角色 $($Cfg.role) 不可修改 $($ti.file_path)（BDD 情境、hook 設定與 CI 流程只能由高階模型或使用者修改；情境有問題請回報 SPEC_CONFLICT）。" } }
      } elseif ($in.tool_name -in 'Edit','Write','MultiEdit' -and (Test-BoardPath ([string]$ti.file_path))) {
        $errs = try { $txt = Get-EditedText $ti $in.tool_name; @(Test-BoardText ([string]$ti.file_path) $txt (Get-OldBoard ([string]$ti.file_path))) } catch { @("無法驗證 board.json 修改：$($_.Exception.Message)") }
        if ($errs.Count) { Write-Log "deny board $($errs.Count)"; Out-Json @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = "AI Dev hook：board.json 修改不符規則（未寫入）：`n- " + (($errs | Select-Object -First 15) -join "`n- ") } } }
      } elseif (Test-SecretPath ([string]$(if ($ti.file_path) { $ti.file_path } else { $ti.path }))) {
        Write-Log "deny $($in.tool_name) $($ti.file_path)$($ti.path)"
        Out-Json @{ hookSpecificOutput = @{ hookEventName = 'PreToolUse'; permissionDecision = 'deny'; permissionDecisionReason = 'AI Dev hook：禁止讀寫機密檔（.env、金鑰、憑證）。' } }
      }
    }
    'claude/PostToolUse' {
      $f = @(Invoke-EditChecks ([string]$in.tool_input.file_path)); Write-Log "edit $($in.tool_input.file_path) 發現 $($f.Count) 項"
      if ($f.Count) { Out-Json @{ decision = 'block'; reason = "自動檢查發現問題，請修正：`n- " + ($f -join "`n- ") } }
    }
    'claude/Stop' {
      if ($in.stop_hook_active) { Write-Log 'stop（已由 hook 續跑過，不再阻擋）'; exit 0 }
      $m = Invoke-StopChecks; Write-Log "stop 問題 $($m.Count) 項"
      if ($m.Count) { Out-Json @{ decision = 'block'; reason = "結束前自動檢查未通過，請修正$Note：`n- " + ($m -join "`n- ") } }
    }
    default { Write-Log 'event' }
  }
} catch {
  Write-Log "hook 例外：$($_.Exception.Message)"
  if ($Tool -eq 'cursor' -and $Event -like 'before*') { Out-Json @{ permission = 'allow' } }   # 非安全性錯誤不擋路
}
exit 0
