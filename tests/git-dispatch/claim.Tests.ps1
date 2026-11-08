# T-GIT-1 claim 競爭（S-GIT-1-1~3）
. (Join-Path $PSScriptRoot '_Helper.ps1')

Describe 'S-GIT-1 claim 競爭' {
  It 'S-GIT-1-1 兩台同時 claim 同一張：只有一台成功，origin 只有一筆 claim' {
    $fix = New-GitDispatchFixture @('T-1', 'T-2')
    try {
      $a = New-Runner $fix 'A'; $b = New-Runner $fix 'B'
      $ra = Invoke-GitClaim $a 'T-1' 'A'
      $rb = Invoke-GitClaim $b 'T-1' 'B'
      @(@($ra, $rb) | Where-Object { $_ -eq 'CLAIMED' }).Count | Should Be 1
      @(@($ra, $rb) | Where-Object { $_ -eq 'NOT_CLAIMED' }).Count | Should Be 1
      $c = Get-OriginClaim $fix 'T-1'; $c | Should Not BeNullOrEmpty
      $c.by | Should Be $(if ($ra -eq 'CLAIMED') { 'A' } else { 'B' })
    } finally { Remove-GitDispatchFixture $fix }
  }

  It 'S-GIT-1-2 claim 被拒且已被別台領：放棄（NOT_CLAIMED）' {
    $fix = New-GitDispatchFixture @('T-1')
    try {
      $a = New-Runner $fix 'A'; $b = New-Runner $fix 'B'
      (Invoke-GitClaim $a 'T-1' 'A') | Should Be 'CLAIMED'   # A 先領
      (Invoke-GitClaim $b 'T-1' 'B') | Should Be 'NOT_CLAIMED' # B 後來，發現已被領
      (Get-OriginClaim $fix 'T-1').by | Should Be 'A'
    } finally { Remove-GitDispatchFixture $fix }
  }

  It 'S-GIT-1-3 claim 被拒但別台領的是別張：重試後領到自己的' {
    $fix = New-GitDispatchFixture @('T-1', 'T-2')
    try {
      $a = New-Runner $fix 'A'; $b = New-Runner $fix 'B'
      (Invoke-GitClaim $a 'T-1' 'A') | Should Be 'CLAIMED'   # A 領 T-1
      (Invoke-GitClaim $b 'T-2' 'B') | Should Be 'CLAIMED'   # B 領 T-2（不同張，重試後成功）
      (Get-OriginClaim $fix 'T-1').by | Should Be 'A'
      (Get-OriginClaim $fix 'T-2').by | Should Be 'B'
    } finally { Remove-GitDispatchFixture $fix }
  }

  It 'S-GIT-1-1b 真並行搶同一張：push 被拒重試後仍只有一台領到' {
    $fix = New-GitDispatchFixture @('T-1')
    try {
      $a = New-Runner $fix 'A'; $b = New-Runner $fix 'B'; $sp = Join-Path $RepoScripts 'Git-Claim.ps1'
      $sb = { param($repo, $runner, $scriptPath) . $scriptPath; Invoke-GitClaim $repo 'T-1' $runner }
      $ja = Start-Job -ScriptBlock $sb -ArgumentList $a, 'A', $sp
      $jb = Start-Job -ScriptBlock $sb -ArgumentList $b, 'B', $sp
      $null = Wait-Job $ja, $jb -Timeout 60
      $res = @((Receive-Job $ja), (Receive-Job $jb)); Remove-Job $ja, $jb -Force
      @($res | Where-Object { $_ -eq 'CLAIMED' }).Count | Should Be 1   # 只有一台領到
      @($res | Where-Object { $_ -eq 'NOT_CLAIMED' }).Count | Should Be 1 # 另一台讓出
      (Get-OriginClaim $fix 'T-1') | Should Not BeNullOrEmpty
    } finally { Remove-GitDispatchFixture $fix }
  }
}
