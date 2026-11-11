# T-DL-3 執行結束後核對工單狀態並阻止重派
. (Join-Path $PSScriptRoot '_Helper.ps1')

Describe 'T-DL-3 執行結束後核對工單' {
  AfterEach { Reset-Dispatch }

  It 'S-DL-3-1 exit 0 但工單仍是 In Progress：黃燈、paused、lightReason 含 exit code、追加 history' {
    $Pj = New-TestProject 'In Progress' 'Green'
    Add-TicketHistory $Pj '既有一筆 history'; Add-TicketNote $Pj '既有一筆 note'   # 真實工單通常已有 history／notes
    Enable-Dispatch $Pj (New-FakeProfile 'exit-code.ps1' @('-Code', '0'))
    Invoke-Tick $Pj
    $r = @(Get-ProjectRuns $Pj); $r.Count | Should Be 1
    (Wait-Until { $r[0].proc.HasExited }) | Should Be $true
    $before = @((Get-Ticket $Pj)['history']).Count
    Invoke-Tick $Pj
    $it = Get-Ticket $Pj
    $it['status'] | Should Be 'In Progress'
    $it['light'] | Should Be 'Yellow'
    $it['paused'] | Should Be $true
    $it['lightReason'] | Should Match 'exit=0'
    @($it['history']).Count | Should Be ($before + 1)
    @(Get-ProjectRuns $Pj | Where-Object { $_.status -eq 'running' }).Count | Should Be 0
  }

  It 'S-DL-3-2 逾時且工單仍是 Todo：paused 並寫 pausedReason，下一次 tick 不再派這張' {
    $Pj = New-TestProject 'Todo' 'Gray'
    $pidFile = Join-Path $ConfigDir ([guid]::NewGuid().ToString('N') + '.pid')
    Enable-Dispatch $Pj (New-FakeProfile 'spawn-child.ps1' @('-PidFile', $pidFile))
    try {
      Invoke-Tick $Pj
      $r = @(Get-ProjectRuns $Pj)[0]
      (Wait-Until { Test-Path -LiteralPath $pidFile }) | Should Be $true
      $r.start = (Get-Date).AddHours(-2)
      Invoke-Tick $Pj
      $it = Get-Ticket $Pj
      $it['status'] | Should Be 'Todo'
      $it['light'] | Should Be 'Gray'
      $it['paused'] | Should Be $true
      $it['pausedReason'] | Should Match 'timeout'
      Invoke-Tick $Pj
      @(Get-ProjectRuns $Pj | Where-Object { $_.status -eq 'running' }).Count | Should Be 0
    } finally { if (Test-Path -LiteralPath $pidFile) { Stop-Process -Id ([int](Get-Content -LiteralPath $pidFile)) -Force -ErrorAction SilentlyContinue } }
  }

  It 'S-DL-3-3 AI 已把工單移到 In Review：工單內容完全不變' {
    $Pj = New-TestProject 'In Progress' 'Green'
    Enable-Dispatch $Pj (New-FakeProfile 'exit-code.ps1' @('-Code', '0'))
    Invoke-Tick $Pj
    $r = @(Get-ProjectRuns $Pj)
    (Wait-Until { $r[0].proc.HasExited }) | Should Be $true
    Set-TicketStatus $Pj 'In Review' 'Green'
    $text = [IO.File]::ReadAllText($Pj.json)
    Invoke-Tick $Pj
    [IO.File]::ReadAllText($Pj.json) | Should BeExactly $text
  }

  It '失敗的結束碼也會暫停（exit=3）' {
    $Pj = New-TestProject 'In Progress' 'Green'
    Enable-Dispatch $Pj (New-FakeProfile 'exit-code.ps1' @('-Code', '3'))
    Invoke-Tick $Pj
    $r = @(Get-ProjectRuns $Pj)
    (Wait-Until { $r[0].proc.HasExited }) | Should Be $true
    Invoke-Tick $Pj
    $it = Get-Ticket $Pj
    $it['light'] | Should Be 'Yellow'
    $it['lightReason'] | Should Match 'exit=3'
    $it['lightReason'] | Should Match 'failed'
  }

  It '工單已有 history 與 notes 時仍能暫停（修正 Get-V 巢狀）' {
    $Pj = New-TestProject 'In Progress' 'Green'
    Add-TicketHistory $Pj '既有一筆'; Add-TicketNote $Pj '既有備註'
    Start-Sleep -Milliseconds 1100
    Set-TicketAfterRun $Pj 'T-1' 'failed' 1 'x.log'
    $it = Get-Ticket $Pj
    $it['paused'] | Should Be $true
    @($it['history']).Count | Should Be 2
    @($it['notes']).Count | Should Be 2
    # 再跑一次（人工取消暫停後又失敗）也要能寫入
    Set-TicketFields $Pj @{ paused = $false }
    Start-Sleep -Milliseconds 1100
    Set-TicketAfterRun $Pj 'T-1' 'failed' 1 'x.log'
    (Get-Ticket $Pj)['paused'] | Should Be $true
    @((Get-Ticket $Pj)['history']).Count | Should Be 3
  }

  It 'MAJOR-1：結束時工單是紅燈就保留紅燈與原因，不降成黃燈' {
    $Pj = New-TestProject 'In Progress' 'Green'
    Set-TicketFields $Pj @{ light = 'Red'; lightReason = 'AI：遇到阻礙需人協助'; pausedReason = 'AI：先暫停等人協助' }   # 模擬 AI 執行中設紅燈並自行暫停
    Start-Sleep -Milliseconds 1100
    Set-TicketAfterRun $Pj 'T-1' 'failed' 1 'x.log'
    $it = Get-Ticket $Pj
    $it['light'] | Should Be 'Red'
    $it['lightReason'] | Should Be 'AI：遇到阻礙需人協助'   # 不降成黃燈、不覆寫原因
    $it['paused'] | Should Be $true
    $it['pausedReason'] | Should Be 'AI：先暫停等人協助'   # 不覆寫 AI 已寫的 pausedReason
  }

  It 'MAJOR-2：寫看板丟例外時停掉派工器，下一次 tick 不再派同一張' {
    $Pj = New-TestProject 'In Progress' 'Green'
    Enable-Dispatch $Pj (New-FakeProfile 'exit-code.ps1' @('-Code', '0'))
    Invoke-Tick $Pj
    $r = @(Get-ProjectRuns $Pj); (Wait-Until { $r[0].proc.HasExited }) | Should Be $true
    Set-ItemProperty -LiteralPath $Pj.json -Name IsReadOnly -Value $true   # 讓寫入丟例外
    try {
      Invoke-Tick $Pj
      (Get-DispatchCfg $Pj.id).enabled | Should Be $false
      Invoke-Tick $Pj
      @(Get-ProjectRuns $Pj | Where-Object { $_.status -eq 'running' }).Count | Should Be 0
    } finally { Set-ItemProperty -LiteralPath $Pj.json -Name IsReadOnly -Value $false }
  }
}
