# T-GIT-2 board.json 併發 rebase 合併（S-GIT-2-1~3）
. (Join-Path $PSScriptRoot '_Helper.ps1')

Describe 'S-GIT-2 board.json 併發合併' {
  It 'S-GIT-2-1 兩台改不同工單：先後 push 自動合併、兩筆都在' {
    $fix = New-GitDispatchFixture @('T-1', 'T-2')
    try {
      $a = New-Runner $fix 'A'; $b = New-Runner $fix 'B'
      $ba = Get-TicketUpdatedAt $a 'T-1'; $bb = Get-TicketUpdatedAt $b 'T-2'
      (Invoke-GitReport $a 'T-1' $ba @{ note = 'A 做完' }) | Should Be 'REPORTED'
      (Invoke-GitReport $b 'T-2' $bb @{ note = 'B 做完' }) | Should Be 'REPORTED'
      $board = Get-OriginBoard $fix
      [string](($board.items | Where-Object { $_.id -eq 'T-1' }).notes[-1].text) | Should Match 'A 做完'
      [string](($board.items | Where-Object { $_.id -eq 'T-2' }).notes[-1].text) | Should Match 'B 做完'
    } finally { Remove-GitDispatchFixture $fix }
  }

  It 'S-GIT-2-2 兩台改同一工單：第二台偵測為衝突、停下交人工' {
    $fix = New-GitDispatchFixture @('T-1')
    try {
      $a = New-Runner $fix 'A'; $b = New-Runner $fix 'B'
      $base = Get-TicketUpdatedAt $a 'T-1'   # 兩台都基於同一版本
      (Invoke-GitReport $a 'T-1' $base @{ note = 'A 改' }) | Should Be 'REPORTED'
      (Invoke-GitReport $b 'T-1' $base @{ note = 'B 改' }) | Should Be 'CONFLICT'   # B 的 base 已過時
      @(((Get-OriginBoard $fix).items | Where-Object { $_.id -eq 'T-1' }).notes).Count | Should Be 1
    } finally { Remove-GitDispatchFixture $fix }
  }

  It 'S-GIT-2-3 套用後不符 L1–L7：擋下 push、回 INVALID' {
    $fix = New-GitDispatchFixture @('T-1')
    try {
      $a = New-Runner $fix 'A'; $base = Get-TicketUpdatedAt $a 'T-1'
      # Todo 的工單設成綠燈違反 L1（Backlog/Todo 只能 Gray）
      (Invoke-GitReport $a 'T-1' $base @{ light = 'Green' }) | Should Be 'INVALID'
      ((Get-OriginBoard $fix).items | Where-Object { $_.id -eq 'T-1' }).light | Should Be 'Gray'   # origin 沒被改
    } finally { Remove-GitDispatchFixture $fix }
  }

  It 'S-GIT-2-1b 真並行改不同工單：push 被拒重放後兩筆都在' {
    $fix = New-GitDispatchFixture @('T-1', 'T-2')
    try {
      $a = New-Runner $fix 'A'; $b = New-Runner $fix 'B'
      $ba = Get-TicketUpdatedAt $a 'T-1'; $bb = Get-TicketUpdatedAt $b 'T-2'; $rp = Join-Path $RepoScripts 'Git-Report.ps1'
      $sb = { param($repo, $ticket, $base, $note, $scriptPath) . $scriptPath; Invoke-GitReport $repo $ticket $base @{ note = $note } }
      $ja = Start-Job -ScriptBlock $sb -ArgumentList $a, 'T-1', $ba, 'A做完', $rp
      $jb = Start-Job -ScriptBlock $sb -ArgumentList $b, 'T-2', $bb, 'B做完', $rp
      $null = Wait-Job $ja, $jb -Timeout 60
      $res = @((Receive-Job $ja), (Receive-Job $jb)); Remove-Job $ja, $jb -Force
      @($res | Where-Object { $_ -eq 'REPORTED' }).Count | Should Be 2   # 兩台都成功（一台重放）
      $board = Get-OriginBoard $fix
      [string](($board.items | Where-Object { $_.id -eq 'T-1' }).notes[-1].text) | Should Match 'A做完'
      [string](($board.items | Where-Object { $_.id -eq 'T-2' }).notes[-1].text) | Should Match 'B做完'
    } finally { Remove-GitDispatchFixture $fix }
  }
}
