# T-GIT-3 heartbeat 續租與逾期重領（S-GIT-3-1~3）
. (Join-Path $PSScriptRoot '_Helper.ps1')

Describe 'S-GIT-3 heartbeat 續租與逾期重領' {
  It 'S-GIT-3-1 續租：until 往後延，回 RENEWED' {
    $fix = New-GitDispatchFixture @('T-1')
    try {
      $a = New-Runner $fix 'A'
      (Invoke-GitClaim $a 'T-1' 'A') | Should Be 'CLAIMED'
      $before = [DateTimeOffset](Get-OriginClaim $fix 'T-1').until
      Start-Sleep -Seconds 2
      (Invoke-GitHeartbeat $a 'T-1' 'A') | Should Be 'RENEWED'
      $after = [DateTimeOffset](Get-OriginClaim $fix 'T-1').until
      ($after -gt $before) | Should Be $true
    } finally { Remove-GitDispatchFixture $fix }
  }

  It 'S-GIT-3-2 逾期可被別台重領' {
    $fix = New-GitDispatchFixture @('T-1')
    try {
      $a = New-Runner $fix 'A'; $b = New-Runner $fix 'B'
      (Invoke-GitClaim $a 'T-1' 'A') | Should Be 'CLAIMED'
      Expire-OriginClaim $fix 'T-1'   # A 失聯，claim 過期
      (Invoke-GitClaim $b 'T-1' 'B') | Should Be 'CLAIMED'   # B 接手
      (Get-OriginClaim $fix 'T-1').by | Should Be 'B'
    } finally { Remove-GitDispatchFixture $fix }
  }

  It 'S-GIT-3-3 claim 被接手後原 runner 續租失敗、不搶回' {
    $fix = New-GitDispatchFixture @('T-1')
    try {
      $a = New-Runner $fix 'A'; $b = New-Runner $fix 'B'
      (Invoke-GitClaim $a 'T-1' 'A') | Should Be 'CLAIMED'
      Expire-OriginClaim $fix 'T-1'
      (Invoke-GitClaim $b 'T-1' 'B') | Should Be 'CLAIMED'   # B 接手
      (Invoke-GitHeartbeat $a 'T-1' 'A') | Should Be 'LOST'  # A 續租發現不是自己的
      (Get-OriginClaim $fix 'T-1').by | Should Be 'B'        # 不被 A 搶回
    } finally { Remove-GitDispatchFixture $fix }
  }
}
