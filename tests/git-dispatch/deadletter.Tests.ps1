# T-GIT-5 死信隔離（S-GIT-5）
# 同一工單連續 N 次 INVALID → 寫 deadletters/<ticket>.json（git 同步、不經 board 驗證）→
# 所有 runner 的 Select 自此跳過；成功回報或人工清檔則歸零。
. (Join-Path $PSScriptRoot '_Helper.ps1')

Describe 'S-GIT-5 死信隔離' {

  It 'S-GIT-5-1 executor 固定回 INVALID：連續 N 次後該工單被跳過（done-definition）' {
    $fix = New-GitDispatchFixture @('T-1')
    try {
      $a = New-Runner $fix 'A'
      # Todo 的工單被設綠燈違反 L1 → Git-Report 永遠回 INVALID
      $bad = { param($r, $t) @{ light = 'Green' } }
      # N=2：前兩輪 INVALID 累計、第三輪起被 Select 跳過（第 N+1 輪）
      (Invoke-GitRunnerOnce $a 'A' $bad -MaxInvalid 2) | Should Match '^INVALID:T-1$'
      (Invoke-GitRunnerOnce $a 'A' $bad -MaxInvalid 2) | Should Match '^DEADLETTER:T-1$'
      (Invoke-GitRunnerOnce $a 'A' $bad -MaxInvalid 2) | Should Be 'IDLE'   # 第 3 輪：已死信，不再挑
      $dl = Get-OriginDeadLetter $fix 'T-1'
      [int]$dl.failCount | Should Be 2
      $dl.blocked | Should Be $true
      # 工單留 note 交人工
      [string](((Get-OriginBoard $fix).items | Where-Object { $_.id -eq 'T-1' }).notes[-1].text) | Should Match '死信'
    } finally { Remove-GitDispatchFixture $fix }
  }

  It 'S-GIT-5-2 Add-GitDeadLetterFail 累計並在 origin 持久、Test 在門檻翻轉' {
    $fix = New-GitDispatchFixture @('T-1')
    try {
      $a = New-Runner $fix 'A'
      (Add-GitDeadLetterFail $a 'T-1' 'A' '測試' 2) | Should Be 'COUNTED'
      (Test-GitDeadLettered $a 'T-1' 2) | Should Be $false
      [int](Get-OriginDeadLetter $fix 'T-1').failCount | Should Be 1
      (Add-GitDeadLetterFail $a 'T-1' 'A' '測試' 2) | Should Be 'DEAD'
      (Test-GitDeadLettered $a 'T-1' 2) | Should Be $true
      [int](Get-OriginDeadLetter $fix 'T-1').failCount | Should Be 2
    } finally { Remove-GitDispatchFixture $fix }
  }

  It 'S-GIT-5-3 死信後所有 runner（含另一台）的 Select 都跳過' {
    $fix = New-GitDispatchFixture @('T-1', 'T-2')
    try {
      $a = New-Runner $fix 'A'; $b = New-Runner $fix 'B'
      (Add-GitDeadLetterFail $a 'T-1' 'A' 'x' 1) | Should Be 'DEAD'   # N=1：一次就死信
      Sync-Runner $b
      (Select-ClaimableTicket $b 1) | Should Be 'T-2'   # 跳過 T-1，改挑 T-2
    } finally { Remove-GitDispatchFixture $fix }
  }

  It 'S-GIT-5-4 人工 Clear-GitDeadLetter 後工單可再被挑' {
    $fix = New-GitDispatchFixture @('T-1')
    try {
      $a = New-Runner $fix 'A'
      (Add-GitDeadLetterFail $a 'T-1' 'A' 'x' 1) | Should Be 'DEAD'
      (Select-ClaimableTicket $a 1) | Should Be $null
      (Clear-GitDeadLetter $a 'T-1') | Should Be 'CLEARED'
      (Get-OriginDeadLetter $fix 'T-1') | Should Be $null
      (Select-ClaimableTicket $a 1) | Should Be 'T-1'   # 歸零後可再挑
    } finally { Remove-GitDispatchFixture $fix }
  }

  It 'S-GIT-5-5 成功回報會把連續計數歸零（REPORTED → Clear）' {
    $fix = New-GitDispatchFixture @('T-1')
    try {
      $a = New-Runner $fix 'A'
      $bad = { param($r, $t) @{ light = 'Green' } }   # 違反 L1 → INVALID
      (Invoke-GitRunnerOnce $a 'A' $bad -MaxInvalid 3) | Should Match '^INVALID:T-1$'
      [int](Get-OriginDeadLetter $fix 'T-1').failCount | Should Be 1
      $ok = { param($r, $t) @{ note = 'runner ok' } }   # note-only → REPORTED
      (Invoke-GitRunnerOnce $a 'A' $ok -MaxInvalid 3) | Should Match '^REPORTED:T-1$'
      (Get-OriginDeadLetter $fix 'T-1') | Should Be $null   # 連續計數歸零
    } finally { Remove-GitDispatchFixture $fix }
  }
}
