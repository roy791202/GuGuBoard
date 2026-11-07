# 補測：Stop-Run 與 Resume-DispatchRuns 的 catch 也會停派工器（複驗 A2 指出 M3b／M3c 原本沒被鎖住）
. (Join-Path $PSScriptRoot '_Helper.ps1')

Describe 'MAJOR-2 延伸：例外時各路徑都停派工器' {
  AfterEach { Reset-Dispatch }

  It 'Stop-Run：stuck 核對丟例外時停掉派工器' {
    $Pj = New-TestProject 'In Progress' 'Green'
    $pf = Join-Path $ConfigDir ([guid]::NewGuid().ToString('N') + '.pid')
    Enable-Dispatch $Pj (New-FakeProfile 'spawn-child.ps1' @('-PidFile', $pf))
    Invoke-Tick $Pj
    $r = @(Get-ProjectRuns $Pj)[0]
    (Wait-Until { Test-Path -LiteralPath $pf }) | Should Be $true
    $child = [int](Get-Content -LiteralPath $pf)
    function Stop-RunTree($proc, [int]$waitMs = 10000) { $false }   # 模擬殺不掉 → 走 stuck + Set-TicketAfterRun
    Set-ItemProperty -LiteralPath $Pj.json -Name IsReadOnly -Value $true   # 寫入丟例外
    try {
      Stop-Run $r 'timeout'
      (Get-DispatchCfg $Pj.id).enabled | Should Be $false
    } finally {
      Set-ItemProperty -LiteralPath $Pj.json -Name IsReadOnly -Value $false
      Stop-Process -Id $child, $r.proc.Id -Force -ErrorAction SilentlyContinue
    }
  }

  It 'Resume-DispatchRuns：重啟核對丟例外時停掉派工器' {
    $Pj = New-TestProject 'In Progress' 'Green'
    Enable-Dispatch $Pj (New-FakeProfile 'exit-code.ps1')
    $log = Join-Path $ConfigDir 'old-run.log'; [IO.File]::WriteAllText($log, "# old`n")
    $rec = @([ordered]@{ id = 'old-run'; project = $Pj.id; ticket = 'T-1'; pid = 999999; startTime = '2000-01-01T00:00:00.0000000+08:00'; log = $log; tokenId = 'none'; status = 'running' })
    ConvertTo-Json -InputObject $rec -Depth 4 | Set-Content -LiteralPath (Join-Path $ConfigDir "runs-$($Pj.id).json") -Encoding UTF8
    $DispState.resumed = $false
    Set-ItemProperty -LiteralPath $Pj.json -Name IsReadOnly -Value $true   # 寫入丟例外
    try {
      Invoke-Tick $Pj   # 觸發 Resume → Set-TicketAfterRun(interrupted) → 唯讀丟例外 → catch → Disable
      (Get-DispatchCfg $Pj.id).enabled | Should Be $false
    } finally { Set-ItemProperty -LiteralPath $Pj.json -Name IsReadOnly -Value $false }
  }
}
