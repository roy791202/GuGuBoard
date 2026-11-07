<#
 board.json 驗證器（與 board.html 的 validate() 規則相同，PowerShell 5.1 / 7 皆可，零相依）。
 用法：
   validate-board.ps1 -Path docs/board.json                  # 驗證格式與規則，錯誤時 exit 1
   validate-board.ps1 -Path new.json -OldPath old.json -Role dev-agent   # 另外檢查角色權限（開發代理不可設 Done/藍燈/Released/approvedBy）
   . validate-board.ps1 -Library                             # 只載入函式（Test-Board / Test-BoardRole / Read-BoardJson）
 結束碼：0 通過；1 規則不符；2 無法讀取或解析（呼叫端應視為失敗＝fail closed）。
#>
param([string]$Path, [string]$OldPath, [string]$Role = '', [switch]$Library, [switch]$AsJson)

function ConvertFrom-JsonElement($e) {
  switch ($e.ValueKind.ToString()) {
    'Object' { $h = [ordered]@{}; foreach ($p in $e.EnumerateObject()) { $h[$p.Name] = ConvertFrom-JsonElement $p.Value }; return $h }
    'Array'  { $a = [Collections.Generic.List[object]]::new(); foreach ($x in $e.EnumerateArray()) { $a.Add((ConvertFrom-JsonElement $x)) }; return ,($a.ToArray()) }
    'String' { return $e.GetString() }
    'Number' { return $e.GetDouble() }
    'True'   { return $true }
    'False'  { return $false }
    default  { return $null }
  }
}
function ConvertTo-Plain($o) {
  if ($null -eq $o) { return $null }
  if ($o -is [Management.Automation.PSCustomObject]) { $h = [ordered]@{}; foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = ConvertTo-Plain $p.Value }; return $h }
  if ($o -is [array]) { $a = @(foreach ($x in $o) { ,(ConvertTo-Plain $x) }); return ,$a }
  if ($o -is [int] -or $o -is [long] -or $o -is [decimal]) { return [double]$o }
  return $o
}
function Read-BoardJson([string]$text) {
  # PowerShell 7 的 ConvertFrom-Json 會把日期字串轉成 DateTime，所以優先用 System.Text.Json 保留原字串
  if ('System.Text.Json.JsonDocument' -as [type]) {
    $doc = [System.Text.Json.JsonDocument]::Parse($text); try { return ,(ConvertFrom-JsonElement $doc.RootElement) } finally { $doc.Dispose() }
  }
  return ,(ConvertTo-Plain ($text | ConvertFrom-Json))
}

$script:LEVELS = 'Epic','Feature','Story','Task','Deployment'
$script:COLS = 'Backlog','Todo','In Progress','In Review','Done'
$script:DSTAT = 'Planned','Deploying','Verifying','Released','Rolled Back'
$script:LIGHTS = 'Gray','Green','Yellow','Red','Blue'
$script:TDD = 'None','Red','Green'; $script:CI = 'None','Pending','Green','Red'
$script:ENVS = 'Dev','Staging','Prod'; $script:RTYPES = 'Major','Minor','Patch','Hotfix','RC'
$script:STRATS = 'Direct','Canary','Gradual','FeatureFlag'; $script:HEALTH = 'None','Pending','Green','Yellow','Red'
$script:SEMVER = '^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:alpha|beta|rc)\.(?:0|[1-9]\d*)))?$'
$script:ISO = '^\d{4}-\d\d-\d\dT\d\d:\d\d(:\d\d(\.\d+)?)?(Z|[+-]\d\d:\d\d)$'

function IsStr($v, [int]$max) { $v -is [string] -and $v.Length -le $max }
function IsNum($v) { $v -is [double] -or $v -is [int] -or $v -is [long] -or $v -is [decimal] }
function IsArr($v) { $v -is [array] }
function IsObj($v) { $v -is [Collections.IDictionary] }
function Has($o, [string]$k) { (IsObj $o) -and $o.Contains($k) -and $null -ne $o[$k] }
function Get-V($o, [string]$k) { if ((IsObj $o) -and $o.Contains($k)) { return ,$o[$k] } else { return $null } }
function ParseDate($v) { $r = [DateTimeOffset]::MinValue; if ((IsStr $v 40) -and [DateTimeOffset]::TryParse($v, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$r)) { return $r } ; return $null }
function IsIso($v) { (IsStr $v 40) -and ($v -cmatch $script:ISO) -and $null -ne (ParseDate $v) }
function IsDevAgent($v) { "$v" -match 'dev[-_ ]?agent|開發代理|開發者' }

function Test-Board($d) {
  $e = [Collections.Generic.List[string]]::new()
  if (-not (IsObj $d)) { return @('根節點必須是物件') }
  if (-not ((IsNum $d['version']) -and $d['version'] -eq 1)) { $e.Add('version 必須是 1') }
  if (-not (IsStr (Get-V $d 'project') 200)) { $e.Add('project 必須是字串') }
  if (-not (IsStr (Get-V $d 'updatedAt') 40) -or $null -eq (ParseDate $d['updatedAt'])) { $e.Add('updatedAt 必須是 ISO 時間') }
  $items = Get-V $d 'items'
  if (-not (IsArr $items)) { $e.Add('items 必須是陣列'); return $e.ToArray() }
  if ($items.Count -gt 2000) { $e.Add('items 超過 2000 筆') }
  $ids = [Collections.Generic.HashSet[string]]::new()
  for ($i = 0; $i -lt $items.Count; $i++) {
    $it = $items[$i]
    $p = "items[$i]" + $(if ((IsObj $it) -and (Get-V $it 'id')) { "($($it['id']))" } else { '' }) + ': '
    if (-not (IsObj $it)) { $e.Add($p + '必須是物件'); continue }
    $id = Get-V $it 'id'; $lv = Get-V $it 'level'; $st = Get-V $it 'status'; $lt = Get-V $it 'light'
    if (-not (IsStr $id 40) -or $id -cnotmatch '^[A-Za-z0-9._-]+$') { $e.Add($p + 'id 格式錯誤') } elseif (-not $ids.Add($id)) { $e.Add($p + 'id 重複') }
    if ($lv -cnotin $script:LEVELS) { $e.Add($p + 'level 必須是 ' + ($script:LEVELS -join '/')) }
    if (-not (IsStr (Get-V $it 'title') 300)) { $e.Add($p + 'title 必須是字串（≤300）') }
    if ($lv -ceq 'Deployment') { if ($st -cnotin $script:DSTAT) { $e.Add($p + 'Deployment status 必須是 ' + ($script:DSTAT -join '/')) } }
    elseif ($st -cnotin $script:COLS) { $e.Add($p + 'status 必須是 ' + ($script:COLS -join '/')) }
    if ($lt -cnotin $script:LIGHTS) { $e.Add($p + 'light 必須是 ' + ($script:LIGHTS -join '/')) }
    $lr = Get-V $it 'lightReason'
    if (($lt -ceq 'Yellow' -or $lt -ceq 'Red') -and -not ((IsStr $lr 200) -and $lr.Trim())) { $e.Add($p + '黃燈／紅燈必須填 lightReason') }
    if ($lv -ceq 'Deployment') {
      if ($st -ceq 'Released' -and $lt -cne 'Blue') { $e.Add($p + 'Released 必須是藍燈') }
      if ($lt -ceq 'Blue' -and $st -cne 'Released') { $e.Add($p + '藍燈只能在 Released') }
      if ($st -ceq 'Rolled Back' -and $lt -cne 'Red') { $e.Add($p + 'Rolled Back 必須是紅燈') }
      $ver = Get-V $it 'version'; $sv = $null; if ((IsStr $ver 40) -and $ver -cmatch $script:SEMVER) { $sv = $Matches.Clone() }
      $rt = Get-V $it 'releaseType'; $env_ = Get-V $it 'environment'
      if (-not $sv) { $e.Add($p + 'version 必須是 SemVer（例如 v1.3.0 或 v1.3.0-rc.1）') }
      if ($rt -cnotin $script:RTYPES) { $e.Add($p + 'releaseType 必須是 ' + ($script:RTYPES -join '/')) }
      if ($env_ -cnotin $script:ENVS) { $e.Add($p + 'environment 必須是 ' + ($script:ENVS -join '/')) }
      if ((Has $it 'strategy') -and $it['strategy'] -cnotin $script:STRATS) { $e.Add($p + 'strategy 必須是 ' + ($script:STRATS -join '/')) }
      if ((Has $it 'rolloutPercent') -and -not ((IsNum $it['rolloutPercent']) -and $it['rolloutPercent'] -ge 0 -and $it['rolloutPercent'] -le 100)) { $e.Add($p + 'rolloutPercent 必須是 0～100') }
      if ((Has $it 'healthChecks') -and $it['healthChecks'] -cnotin $script:HEALTH) { $e.Add($p + 'healthChecks 必須是 ' + ($script:HEALTH -join '/')) }
      if ($sv -and (($rt -ceq 'RC') -ne [bool]$sv[4])) { $e.Add($p + '含 -rc/-beta 的版本 releaseType 必須是 RC，反之亦然') }
      if ($rt -ceq 'Hotfix' -and $sv -and $sv[3] -eq '0') { $e.Add($p + 'Hotfix 必須是 Patch 版本（PATCH > 0）') }
      $rp = Get-V $it 'rollbackPlan'; $ab = Get-V $it 'approvedBy'
      if ($env_ -ceq 'Prod') {
        if (-not ((IsStr $rp 2000) -and $rp.Trim())) { $e.Add($p + 'Prod 必須填 rollbackPlan') }
        if (-not ((IsStr $ab 100) -and $ab.Trim())) { $e.Add($p + 'Prod 必須填 approvedBy（高階模型或使用者）') }
      }
      if (IsDevAgent $ab) { $e.Add($p + 'approvedBy 不可以是開發代理') }
      if ($st -ceq 'Released' -and (Has $it 'healthChecks') -and $it['healthChecks'] -cne 'Green') { $e.Add($p + 'Released 時 healthChecks 必須是 Green') }
      foreach ($k in 'gitRef','commitSha','rollbackRef','approvedBy') { if ((Has $it $k) -and -not (IsStr $it[$k] 100)) { $e.Add($p + "$k 必須是字串") } }
      if ((Has $it 'commitSha') -and "$($it['commitSha'])" -notmatch '^[0-9a-fA-F]{7,40}$') { $e.Add($p + 'commitSha 必須是 7～40 位十六進位') }
      if ((Has $it 'rollbackPlan') -and -not (IsStr $rp 2000)) { $e.Add($p + 'rollbackPlan 最多 2000 字') }
      foreach ($k in 'changelogUrl','buildUrl') { if ((Has $it $k) -and -not ((IsStr $it[$k] 500) -and $it[$k] -match '^https?://')) { $e.Add($p + "$k 必須是 http(s) 網址") } }
      foreach ($k in 'featureFlags','includes') { if ((Has $it $k) -and -not ((IsArr $it[$k]) -and $it[$k].Count -le 100 -and -not ($it[$k] | Where-Object { -not (IsStr $_ 60) }))) { $e.Add($p + "$k 必須是字串陣列（最多 100）") } }
      if ((Has $it 'deployedAt') -and -not ((IsStr $it['deployedAt'] 40) -and $it['deployedAt'] -match '(Z|[+-]\d\d:\d\d)$' -and $null -ne (ParseDate $it['deployedAt']))) { $e.Add($p + 'deployedAt 必須是含時區的 ISO 8601 時間') }
    } else {
      if ($st -ceq 'Done' -and $lt -cne 'Blue') { $e.Add($p + 'Done 必須是藍燈') }
      if ($lt -ceq 'Blue' -and $st -cne 'Done') { $e.Add($p + '藍燈只能在 Done') }
    }
    if (Has $it 'estimate') { $s = $it['estimate']
      if (-not (IsObj $s)) { $e.Add($p + 'estimate 必須是物件') }
      else {
        if ($lv -ceq 'Task' -and $s.Contains('storyPoints')) { $e.Add($p + 'Task 不可有 storyPoints（用 hours）') }
        if ($lv -ceq 'Story' -and $s.Contains('hours')) { $e.Add($p + 'Story 不可有 hours（用 storyPoints）') }
        foreach ($k in 'storyPoints','hours') { if ($s.Contains($k) -and -not ((IsNum $s[$k]) -and $s[$k] -ge 0)) { $e.Add($p + "$k 必須是非負數字") } }
      } }
    foreach ($k in 'owner','role','sprint','lightReason') { if ((Has $it $k) -and -not (IsStr $it[$k] 200)) { $e.Add($p + "$k 必須是字串") } }
    if ((Has $it 'parentId') -and -not (IsStr $it['parentId'] 40)) { $e.Add($p + 'parentId 必須是字串或 null') }
    if ((Has $it 'tdd') -and $it['tdd'] -cnotin $script:TDD) { $e.Add($p + 'tdd 必須是 ' + ($script:TDD -join '/')) }
    if ((Has $it 'ci') -and $it['ci'] -cnotin $script:CI) { $e.Add($p + 'ci 必須是 ' + ($script:CI -join '/')) }
    if ((Has $it 'prUrl') -and -not ((IsStr $it['prUrl'] 500) -and $it['prUrl'] -match '^https?://')) { $e.Add($p + 'prUrl 必須是 http(s) 網址') }
    if (Has $it 'bdd') { $bdd = $it['bdd']
      if (-not (IsArr $bdd) -or $bdd.Count -gt 50) { $e.Add($p + 'bdd 必須是陣列（最多 50）') }
      else {
        for ($k = 0; $k -lt $bdd.Count; $k++) { $sc = $bdd[$k]; $q = $p + "bdd[$k] "
          if (-not (IsObj $sc)) { $e.Add($q + '必須是物件'); continue }
          if (-not (IsStr (Get-V $sc 'id') 40) -or $sc['id'] -cnotmatch '^[A-Za-z0-9._-]+$') { $e.Add($q + 'id 格式錯誤') }
          if (-not (IsStr (Get-V $sc 'title') 500)) { $e.Add($q + 'title 必須是字串') }
          if ((Has $sc 'tests') -and -not ((IsArr $sc['tests']) -and $sc['tests'].Count -le 50 -and -not ($sc['tests'] | Where-Object { -not (IsStr $_ 200) }))) { $e.Add($q + 'tests 必須是字串陣列') }
          if ((Get-V $sc 'status') -cnotin $script:TDD) { $e.Add($q + 'status 必須是 ' + ($script:TDD -join '/')) }
        }
        if ($lv -ceq 'Story' -and $st -cin 'In Review','Done' -and -not ($bdd.Count -and -not ($bdd | Where-Object { -not ((IsObj $_) -and $_['status'] -ceq 'Green') }))) { $e.Add($p + "Story 在 $st 時 BDD 情境必須全部 Green") }
      } }
    if ($lv -ceq 'Story' -and $st -cin 'In Review','Done' -and -not (Has $it 'bdd') -and -not ((IsArr (Get-V $it 'acceptance')) -and $it['acceptance'].Count)) { $e.Add($p + "Story 在 $st 時必須有 BDD 情境") }
    if ((Has $it 'scenarioIds') -and -not ((IsArr $it['scenarioIds']) -and $it['scenarioIds'].Count -le 50 -and -not ($it['scenarioIds'] | Where-Object { -not (IsStr $_ 40) }))) { $e.Add($p + 'scenarioIds 必須是字串陣列') }
    if ((Has $it 'remark') -and -not (IsStr $it['remark'] 2000)) { $e.Add($p + 'remark 必須是字串（最多 2000 字）') }
    if (Has $it 'notes') { $ns = $it['notes']
      if (-not (IsArr $ns) -or $ns.Count -gt 100) { $e.Add($p + 'notes 必須是陣列（最多 100）') }
      else { for ($k = 0; $k -lt $ns.Count; $k++) { $n = $ns[$k]; $q = $p + "notes[$k] "
        if (-not (IsObj $n)) { $e.Add($q + '必須是物件'); continue }
        if (-not (IsStr (Get-V $n 'text') 2000) -or -not $n['text']) { $e.Add($q + 'text 必須是 1～2000 字') }
        if ((Has $n 'by') -and -not (IsStr $n['by'] 100)) { $e.Add($q + 'by 必須是字串') }
        if ((Has $n 'at') -and -not ((IsStr $n['at'] 40) -and $null -ne (ParseDate $n['at']))) { $e.Add($q + 'at 必須是 ISO 時間') } } } }
    foreach ($k in 'createdAt','updatedAt','startedAt','completedAt') { if ((Has $it $k) -and -not (IsIso $it[$k])) { $e.Add($p + "$k 必須是含時區的 ISO 8601 時間") } }
    if ((IsIso (Get-V $it 'startedAt')) -and (IsIso (Get-V $it 'completedAt')) -and (ParseDate $it['completedAt']) -lt (ParseDate $it['startedAt'])) { $e.Add($p + 'completedAt 不可早於 startedAt') }
    if ((IsIso (Get-V $it 'createdAt')) -and (IsIso (Get-V $it 'updatedAt')) -and (ParseDate $it['updatedAt']) -lt (ParseDate $it['createdAt'])) { $e.Add($p + 'updatedAt 不可早於 createdAt') }
    if (Has $it 'history') { $hs = $it['history']
      if (-not (IsArr $hs) -or $hs.Count -gt 200) { $e.Add($p + 'history 必須是陣列（最多 200）') }
      else { for ($k = 0; $k -lt $hs.Count; $k++) { $x = $hs[$k]; $q = $p + "history[$k] "
        if (-not (IsObj $x)) { $e.Add($q + '必須是物件'); continue }
        if (-not (IsIso (Get-V $x 'at'))) { $e.Add($q + 'at 必須是含時區的 ISO 8601 時間') }
        foreach ($f in 'from','to','by') { if ((Has $x $f) -and -not (IsStr $x[$f] 100)) { $e.Add($q + "$f 必須是字串") } }
        if ((Has $x 'note') -and -not (IsStr $x['note'] 1000)) { $e.Add($q + 'note 最多 1000 字') } } } }
    if ((Has $it 'acceptance') -and -not ((IsArr $it['acceptance']) -and -not ($it['acceptance'] | Where-Object { -not (IsStr $_ 500) }))) { $e.Add($p + 'acceptance 必須是字串陣列') }
  }
  $scm = @{}; foreach ($it in $items) { if ((IsObj $it) -and (IsArr (Get-V $it 'bdd'))) { foreach ($s in $it['bdd']) { if ((IsObj $s) -and (Get-V $s 'id')) { $scm[[string]$s['id']] = $s['status'] } } } }
  foreach ($it in $items) {
    if (-not (IsObj $it) -or (Get-V $it 'level') -cne 'Task' -or -not (IsArr (Get-V $it 'scenarioIds'))) { continue }
    foreach ($s in $it['scenarioIds']) { if (-not $scm.ContainsKey([string]$s)) { $e.Add("$($it['id']): scenarioIds $s 不存在") } elseif ($it['tdd'] -ceq 'Green' -and $scm[[string]$s] -cne 'Green') { $e.Add("$($it['id']): TDD Green 但涵蓋的情境 $s 不是 Green") } }
  }
  $ds = @($items | Where-Object { (IsObj $_) -and (Get-V $_ 'level') -ceq 'Deployment' -and (IsStr (Get-V $_ 'version') 40) -and $_['version'] -cmatch $script:SEMVER })
  $seen = @{}
  foreach ($it in $ds) { $k = ($it['version'] -replace '^v', '') + '@' + $it['environment']; if ($seen.ContainsKey($k)) { $e.Add("$($it['id']): 版本 $($it['version']) 在 $($it['environment']) 重複") }; $seen[$k] = 1 }
  $pv = { param($v) $null = $v -cmatch $script:SEMVER; ,@([int]$Matches[1], [int]$Matches[2], [int]$Matches[3]) }
  $fm = [ordered]@{}; foreach ($it in ($ds | Where-Object { $_['releaseType'] -cne 'RC' })) { $fm[($it['version'] -replace '^v', '')] = $it }
  $fin = @($fm.Values | Sort-Object { $a = & $pv $_['version']; '{0:D6}{1:D6}{2:D6}' -f $a[0], $a[1], $a[2] })
  for ($k = 1; $k -lt $fin.Count; $k++) {
    $a = & $pv $fin[$k - 1]['version']; $b = & $pv $fin[$k]['version']; $t = $fin[$k]['releaseType']
    $ok = if ($t -ceq 'Major') { $b[0] -gt $a[0] -and $b[1] -eq 0 -and $b[2] -eq 0 } elseif ($t -ceq 'Minor') { $b[0] -eq $a[0] -and $b[1] -gt $a[1] -and $b[2] -eq 0 } else { $b[0] -eq $a[0] -and $b[1] -eq $a[1] -and $b[2] -gt $a[2] }
    if (-not $ok) { $e.Add("$($fin[$k]['id']): releaseType $t 與版本 $($fin[$k-1]['version']) → $($fin[$k]['version']) 的升版不符") }
  }
  foreach ($it in $items) { if ((IsObj $it) -and (Get-V $it 'parentId') -and -not $ids.Contains([string]$it['parentId'])) { $e.Add("$(if(Get-V $it 'id'){$it['id']}else{'?'}): parentId $($it['parentId']) 不存在") } }
  return @($e | Select-Object -First 30)
}

# 角色權限：開發代理不可把卡片設成 Done、藍燈、Released，也不可填或改 approvedBy（只比較有變更的項目）
function Test-BoardRole($old, $new, [string]$role) {
  $e = [Collections.Generic.List[string]]::new()
  if ($role -notin 'dev-agent', '') { return @() }
  $om = @{}; if ((IsObj $old) -and (IsArr (Get-V $old 'items'))) { foreach ($it in $old['items']) { if ((IsObj $it) -and (Get-V $it 'id')) { $om[[string]$it['id']] = $it } } }
  if (-not ((IsObj $new) -and (IsArr (Get-V $new 'items')))) { return @() }
  foreach ($it in $new['items']) {
    if (-not (IsObj $it)) { continue }; $o = $om[[string](Get-V $it 'id')]; $id = Get-V $it 'id'
    $was = { param($k, $v) $o -and (Get-V $o $k) -ceq $v }
    if ((Get-V $it 'status') -ceq 'Done' -and -not (& $was 'status' 'Done')) { $e.Add("${id}: 開發代理不可把卡片移到 Done（由驗證／高階模型移動）") }
    if ((Get-V $it 'light') -ceq 'Blue' -and -not (& $was 'light' 'Blue')) { $e.Add("${id}: 開發代理不可設定藍燈") }
    if ((Get-V $it 'status') -ceq 'Released' -and -not (& $was 'status' 'Released')) { $e.Add("${id}: 開發代理不可把佈署設成 Released") }
    $ab = Get-V $it 'approvedBy'; if ($ab -and -not ($o -and (Get-V $o 'approvedBy') -ceq $ab)) { $e.Add("${id}: 開發代理不可填寫或修改 approvedBy") }
  }
  return @($e)
}

# 記帳檢查：狀態或燈號有變的卡片，必須同時更新 updatedAt 並追加 history
function Test-BoardBookkeeping($old, $new) {
  $e = [Collections.Generic.List[string]]::new()
  if (-not ((IsObj $old) -and (IsArr (Get-V $old 'items')) -and (IsObj $new) -and (IsArr (Get-V $new 'items')))) { return @() }
  $om = @{}; foreach ($it in $old['items']) { if ((IsObj $it) -and (Get-V $it 'id')) { $om[[string]$it['id']] = $it } }
  foreach ($it in $new['items']) {
    if (-not (IsObj $it)) { continue }; $o = $om[[string](Get-V $it 'id')]; if (-not $o) { continue }
    if ((Get-V $it 'status') -ceq (Get-V $o 'status') -and (Get-V $it 'light') -ceq (Get-V $o 'light')) { continue }
    if ((Get-V $it 'updatedAt') -ceq (Get-V $o 'updatedAt')) { $e.Add("$($it['id']): 狀態或燈號變了，但 updatedAt 沒更新") }
    $hn = if (IsArr (Get-V $it 'history')) { $it['history'].Count } else { 0 }; $ho = if (IsArr (Get-V $o 'history')) { $o['history'].Count } else { 0 }
    if ($hn -le $ho) { $e.Add("$($it['id']): 狀態或燈號變了，但 history 沒有追加一筆 {at, from, to, by}") }
  }
  return @($e)
}

if ($Library) { return }
if (-not $Path) { Write-Error '用法：validate-board.ps1 -Path board.json [-OldPath old.json -Role dev-agent]'; exit 2 }
try { $new = Read-BoardJson ([IO.File]::ReadAllText($Path)) } catch { Write-Output "board.json 無法解析：$($_.Exception.Message)"; exit 2 }
$errs = @(Test-Board $new)
if ($OldPath -and $Role) {
  $old = $null; if (Test-Path -LiteralPath $OldPath) { try { $old = Read-BoardJson ([IO.File]::ReadAllText($OldPath)) } catch { $old = $null } }
  $errs += @(Test-BoardRole $old $new $Role)
}
if ($AsJson) { ConvertTo-Json -InputObject @($errs) -Compress } else { $errs | ForEach-Object { Write-Output "✗ $_" } }
if ($errs.Count) { exit 1 } else { if (-not $AsJson) { Write-Output '✓ board.json 驗證通過' }; exit 0 }
