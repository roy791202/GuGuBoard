# T-DL-4 執行紀錄持久化與重啟後對帳
. (Join-Path $PSScriptRoot '_Helper.ps1')

function Get-RunsFile($Pj) { Join-Path $ConfigDir "runs-$($Pj.id).json" }
function Invoke-Restart { $runs.Clear(); $claims.Clear(); $DispState.resumed = $false }   # 模擬伺服器重啟：記憶體狀態消失

Describe 'T-DL-4 重啟後對帳' {
  AfterEach { Reset-Dispatch }

  It 'S-DL-4-1 有執行紀錄且程序仍在跑：程序樹被終止、工單暫停、token 撤銷、claim 釋放' {
    $Pj = New-TestProject 'Todo' 'Gray'; $pf = Join-Path $ConfigDir ([guid]::NewGuid().ToString('N') + '.pid')
    Enable-Dispatch $Pj (New-FakeProfile 'spawn-child.ps1' @('-PidFile', $pf))
    Invoke-Tick $Pj
    $r = @(Get-ProjectRuns $Pj)[0]; $parent = $r.proc.Id; $tok = $r.tokenId
    (Wait-Until { Test-Path -LiteralPath $pf }) | Should Be $true
    $child = [int](Get-Content -LiteralPath $pf)
    try {
      Test-Path -LiteralPath (Get-RunsFile $Pj) | Should Be $true
      Invoke-Restart
      Invoke-Tick $Pj
      Test-Alive $parent | Should Be $false
      Test-Alive $child | Should Be $false
      $it = Get-Ticket $Pj
      $it['paused'] | Should Be $true
      $it['pausedReason'] | Should Match 'interrupted'
      (Get-Claims $Pj.id).ContainsKey('T-1') | Should Be $false
      @(Read-AgentTokens | Where-Object { $_.id -eq $tok -and $_.revoked }).Count | Should Be 1
      @(Get-ProjectRuns $Pj | Where-Object { $_.status -eq 'running' }).Count | Should Be 0
    } finally { Stop-Process -Id $parent, $child -Force -ErrorAction SilentlyContinue }
  }

  It 'S-DL-4-2 紀錄的 PID 已被其他程序重用（StartTime 不同）：不終止該程序，只標 interrupted' {
    $Pj = New-TestProject 'Todo' 'Gray'
    $other = Start-Process -FilePath 'powershell' -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 120' -WindowStyle Hidden -PassThru
    try {
      $log = Join-Path $ConfigDir 'old-run.log'; [IO.File]::WriteAllText($log, "# old`n")
      $rec = @([ordered]@{ id = 'old-run'; project = $Pj.id; ticket = 'T-1'; pid = $other.Id; startTime = '2000-01-01T00:00:00.0000000+08:00'; log = $log; tokenId = 'none'; status = 'running' })
      ConvertTo-Json -InputObject $rec -Depth 4 | Set-Content -LiteralPath (Get-RunsFile $Pj) -Encoding UTF8
      Invoke-Restart
      Invoke-Tick $Pj
      Test-Alive $other.Id | Should Be $true
      $it = Get-Ticket $Pj
      $it['paused'] | Should Be $true
      $it['pausedReason'] | Should Match 'interrupted'
      [IO.File]::ReadAllText($log) | Should Match 'interrupted'
      @(Get-Content -LiteralPath (Get-RunsFile $Pj) -Raw | ConvertFrom-Json | Where-Object { $_ }).Count | Should Be 0
    } finally { Stop-Process -Id $other.Id -Force -ErrorAction SilentlyContinue }
  }

  It 'S-DL-4-3 沒有執行紀錄：不做任何變更' {
    $Pj = New-TestProject 'Todo' 'Gray'
    $text = [IO.File]::ReadAllText($Pj.json)
    Invoke-Restart
    Invoke-Tick $Pj
    [IO.File]::ReadAllText($Pj.json) | Should BeExactly $text
    @(Get-ProjectRuns $Pj).Count | Should Be 0
  }
}
