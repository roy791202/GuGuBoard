# T-GOV-1a — 後端 scenario endpoint（Invoke-SetScenario）。涵蓋情境 S-GOV-1-1-1 ~ 6。
. (Join-Path $PSScriptRoot '_Helper.ps1')

function Body($storyId, $scenarioId, $status, $reason) {
  (@{ storyId = $storyId; scenarioId = $scenarioId; status = $status; reason = $reason } | ConvertTo-Json -Compress)
}
function Call($json, [switch]$NullBody) {
  $script:cap = $null
  if ($NullBody) { Invoke-SetScenario (New-Req -NullBody) $RES 'GuGuBoard' }
  elseif ($null -eq $json) { Invoke-SetScenario (New-Req '{bad json') $RES 'GuGuBoard' }
  else { Invoke-SetScenario (New-Req $json) $RES 'GuGuBoard' }
  $script:cap
}

Describe 'T-GOV-1a Invoke-SetScenario' {
  BeforeEach {
    $script:Pj = New-TestBoard
    $projects['GuGuBoard'] = $script:Pj
    $script:sess = New-Session 'carol' 'verifier'
    $script:claims = @{}
    $script:cap = $null
    $script:pushEvents = @()
    $script:failWrite = $null
  }
  AfterEach { Remove-TestBoard $script:Pj }

  # ---- 正常 / Happy path ----
  It 'A1 (S-GOV-1-1-1) verifier 設 Green 回 200 並寫入 bdd 狀態' {
    $r = Call (Body 'S-GOV-1-1' 'S-GOV-1-1-1' 'Green' '獨立驗收通過')
    $r.code | Should Be 200
    $r.body.ok | Should Be $true
    $r.body.status | Should Be 'Green'
    (Get-Scenario (Get-BoardObj $script:Pj) 'S-GOV-1-1-1').status | Should Be 'Green'
  }
  It 'A2 (S-GOV-1-1-1) 成功會追加 Story history 並更新 updatedAt' {
    $before = Get-BoardObj $script:Pj
    $st0 = $before.items | Where-Object { $_.id -eq 'S-GOV-1-1' }
    $h0 = HistCount $st0
    Call (Body 'S-GOV-1-1' 'S-GOV-1-1-1' 'Green' 'ok') | Out-Null
    $st1 = (Get-BoardObj $script:Pj).items | Where-Object { $_.id -eq 'S-GOV-1-1' }
    (HistCount $st1) | Should Be ($h0 + 1)
    $last = @($st1.history)[-1]
    $last.from | Should Be 'bdd:S-GOV-1-1-1:None'
    $last.to | Should Be 'bdd:S-GOV-1-1-1:Green'
    ([string]$last.by) | Should Match 'carol'
    $st1.updatedAt | Should Not Be $st0.updatedAt
  }
  It 'A3 (S-GOV-1-1-1) 端點不碰 Task.tdd' {
    $t0 = (Get-BoardObj $script:Pj).items | Where-Object { $_.id -eq 'T-GOV-1a' }
    Call (Body 'S-GOV-1-1' 'S-GOV-1-1-1' 'Green' 'ok') | Out-Null
    $t1 = (Get-BoardObj $script:Pj).items | Where-Object { $_.id -eq 'T-GOV-1a' }
    ([string]$t1.tdd) | Should Be ([string]$t0.tdd)
  }
  It 'A4 (S-GOV-1-1-1) 成功後回 committed 並觸發 Push-All history' {
    $script:Pj.git = $true
    $r = Call (Body 'S-GOV-1-1' 'S-GOV-1-1-1' 'Green' 'ok')
    $r.code | Should Be 200
    ($r.body.committed -is [bool]) | Should Be $true
    (@($script:pushEvents) -contains 'history') | Should Be $true
  }

  # ---- 角色門禁 ----
  It 'A5 (S-GOV-1-1-2) dev-agent 設情境硬擋 403 且狀態不變' {
    $script:sess = New-Session 'dave' 'dev-agent'
    $r = Call (Body 'S-GOV-1-1' 'S-GOV-1-1-1' 'Green' 'ok')
    $r.code | Should Be 403
    (Get-Scenario (Get-BoardObj $script:Pj) 'S-GOV-1-1-1').status | Should Be 'None'
    # 縱深防禦：即使把 dev-agent 當成最高 rank（若只有 rank 判斷會放行），硬擋仍先生效 → 403
    $saved = $ROLES
    try {
      $script:ROLES = 'viewer', 'verifier', 'high-tier', 'admin', 'dev-agent'
      (Get-RoleRank 'dev-agent') | Should Be 4
      ((Get-RoleRank 'dev-agent') -ge (Get-RoleRank 'verifier')) | Should Be $true
      (Call (Body 'S-GOV-1-1' 'S-GOV-1-1-1' 'Green' 'ok')).code | Should Be 403
    } finally { $script:ROLES = $saved }
  }
  It 'A6 (S-GOV-1-1-3) viewer（rank<verifier）回 403 E_FORBIDDEN 且不變' {
    $script:sess = New-Session 'vic' 'viewer'
    $r = Call (Body 'S-GOV-1-1' 'S-GOV-1-1-1' 'Green' 'ok')
    $r.code | Should Be 403
    $r.body.error | Should Be 'E_FORBIDDEN'
    (Get-Scenario (Get-BoardObj $script:Pj) 'S-GOV-1-1-1').status | Should Be 'None'
  }
  It 'A7 verifier 為允許的最低角色（門檻正確）' {
    (Get-RoleRank 'verifier') | Should Be 2
    $script:sess = New-Session 'carol' 'verifier'
    (Call (Body 'S-GOV-1-1' 'S-GOV-1-1-2' 'Green' 'ok')).code | Should Be 200
  }
  It 'A8 (S-GOV-1-1-2) 未登入回 401；external 回 403 E_READ_ONLY' {
    $script:sess = $null
    (Call (Body 'S-GOV-1-1' 'S-GOV-1-1-1' 'Green' 'ok')).code | Should Be 401
    $s2 = New-Session 'carol' 'verifier'; $s2.external = $true; $script:sess = $s2
    $r = Call (Body 'S-GOV-1-1' 'S-GOV-1-1-1' 'Green' 'ok')
    $r.code | Should Be 403
    $r.body.error | Should Be 'E_READ_ONLY'
  }

  # ---- 身分門禁（dev≠verify，主驗收點 S-GOV-1-1-6）----
  It 'A9 (S-GOV-1-1-6) 開發者本人標自己 Task 情境 Green 被 403 且不變' {
    $script:sess = New-Session 'alice' 'verifier'
    $script:claims = @{ 'T-GOV-1a' = @{ name = 'alice' } }
    $r = Call (Body 'S-GOV-1-1' 'S-GOV-1-1-1' 'Green' 'ok')
    $r.code | Should Be 403
    (Get-Scenario (Get-BoardObj $script:Pj) 'S-GOV-1-1-1').status | Should Be 'None'
  }
  It 'A9b (S-GOV-1-1-6) 身分門禁比對 history by：以該 Task 歷史開發者身分標 Green 被 403' {
    # 真實 board 的 T-GOV-1a history by = mcp-11092318（dev-agent）；同一人以 verifier 角色登入（claims 空）
    # 標自己 Task 的情境 Green 仍被身分門禁擋 → 證明「history by」這個來源獨立生效（非靠 claim）
    $script:sess = New-Session 'mcp-11092318' 'verifier'
    $script:claims = @{}
    $r = Call (Body 'S-GOV-1-1' 'S-GOV-1-1-1' 'Green' 'ok')
    $r.code | Should Be 403
    (Get-Scenario (Get-BoardObj $script:Pj) 'S-GOV-1-1-1').status | Should Be 'None'
  }
  It 'A9c (S-GOV-1-1-6) 身分門禁比對 git 身分名（ghName≠session user）標 Green 被 403' {
    # session user=bob（不在開發者清單），但 git 身分名（ghName）=alice=該 Task 的 claim 開發者
    # → 經 Get-GitIdentity.name 命中被 403，證明「git 身分名」來源獨立於 session user 生效
    $s9 = New-Session 'bob' 'verifier'; $s9.ghLogin = 'gh'; $s9.ghName = 'alice'; $s9.ghId = '1'
    $script:sess = $s9
    $script:claims = @{ 'T-GOV-1a' = @{ name = 'alice' } }
    $r = Call (Body 'S-GOV-1-1' 'S-GOV-1-1-1' 'Green' 'ok')
    $r.code | Should Be 403
    (Get-Scenario (Get-BoardObj $script:Pj) 'S-GOV-1-1-1').status | Should Be 'None'
  }
  It 'A10 (S-GOV-1-1-6) 非開發者的 verifier 標同一情境成功' {
    $script:sess = New-Session 'bob' 'verifier'
    $script:claims = @{ 'T-GOV-1a' = @{ name = 'alice' } }
    $r = Call (Body 'S-GOV-1-1' 'S-GOV-1-1-1' 'Green' 'ok')
    $r.code | Should Be 200
    (Get-Scenario (Get-BoardObj $script:Pj) 'S-GOV-1-1-1').status | Should Be 'Green'
  }
  It 'A11 設 Red/None 不受身分門禁限制（只擋 Green）' {
    $script:sess = New-Session 'alice' 'verifier'
    $script:claims = @{ 'T-GOV-1a' = @{ name = 'alice' } }
    (Call (Body 'S-GOV-1-1' 'S-GOV-1-1-1' 'Red' 'r')).code | Should Be 200
    (Call (Body 'S-GOV-1-1' 'S-GOV-1-1-1' 'None' 'r')).code | Should Be 200
  }

  # ---- 非法輸入 / 失敗 ----
  It 'A12 (S-GOV-1-1-4) scenarioId 不存在回 404 E_NOT_FOUND' {
    $r = Call (Body 'S-GOV-1-1' 'S-GOV-1-1-99' 'Green' 'ok')
    $r.code | Should Be 404
    $r.body.error | Should Be 'E_NOT_FOUND'
  }
  It 'A13 (S-GOV-1-1-4) 請求本體非 JSON 回 409 E_BAD_JSON' {
    $r = Call $null
    $r.code | Should Be 409
    $r.body.error | Should Be 'E_BAD_JSON'
  }
  It 'A14 (S-GOV-1-1-4) 缺 storyId 或 status 非三值回 400 E_BAD_REQUEST' {
    (Call (Body '' 'S-GOV-1-1-1' 'Green' 'ok')).code | Should Be 400
    (Call (Body 'S-GOV-1-1' 'S-GOV-1-1-1' 'green' 'ok')).code | Should Be 400
    (Call -NullBody).code | Should Be 400
  }
  It 'A15 (S-GOV-1-1-4) reason 空或超過 500 回 400；恰 500 可接受' {
    (Call (Body 'S-GOV-1-1' 'S-GOV-1-1-1' 'Green' '')).code | Should Be 400
    (Call (Body 'S-GOV-1-1' 'S-GOV-1-1-1' 'Green' ('x' * 501))).code | Should Be 400
    (Call (Body 'S-GOV-1-1' 'S-GOV-1-1-1' 'Green' ('x' * 500))).code | Should Be 200
  }
  It 'A16 (S-GOV-1-1-4) validate 不過回 422 E_RULES 且不寫入' {
    $script:failWrite = @('人工注入的規則錯誤')
    $r = Call (Body 'S-GOV-1-1' 'S-GOV-1-1-1' 'Green' 'ok')
    $r.code | Should Be 422
    $r.body.error | Should Be 'E_RULES'
    (Get-Scenario (Get-BoardObj $script:Pj) 'S-GOV-1-1-1').status | Should Be 'None'
  }
  It 'A17 (S-GOV-1-1-5) Green→Red→None 逐次成功且各留一筆 history' {
    $h0 = HistCount ((Get-BoardObj $script:Pj).items | Where-Object { $_.id -eq 'S-GOV-1-1' })
    (Call (Body 'S-GOV-1-1' 'S-GOV-1-1-1' 'Green' 'g')).code | Should Be 200
    (Call (Body 'S-GOV-1-1' 'S-GOV-1-1-1' 'Red' 'r')).code | Should Be 200
    (Call (Body 'S-GOV-1-1' 'S-GOV-1-1-1' 'None' 'n')).code | Should Be 200
    $b = Get-BoardObj $script:Pj
    (Get-Scenario $b 'S-GOV-1-1-1').status | Should Be 'None'
    (HistCount ($b.items | Where-Object { $_.id -eq 'S-GOV-1-1' })) | Should Be ($h0 + 3)
  }
  It 'A18 storyId 與 scenarioId 不相符（情境在別的 story）回 404' {
    $r = Call (Body 'S-GOV-1-1' 'S-ACC-3-1-1' 'Green' 'ok')
    $r.code | Should Be 404
  }
}
