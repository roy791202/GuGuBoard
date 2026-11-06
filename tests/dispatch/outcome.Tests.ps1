# T-DL-3 執行結束後核對工單狀態並阻止重派
. (Join-Path $PSScriptRoot '_Helper.ps1')

Describe 'T-DL-3 執行結束後核對工單' {
  AfterEach { Reset-Dispatch }

  It 'S-DL-3-1 exit 0 但工單仍是 In Progress：黃燈、paused、lightReason 含 exit code、追加 history' {
    $Pj = New-TestProject 'In Progress' 'Green'
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
}
