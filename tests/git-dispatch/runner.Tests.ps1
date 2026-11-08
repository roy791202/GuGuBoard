# T-GIT-4 遠端 runner pull 迴圈（S-GIT-4-1~3）
. (Join-Path $PSScriptRoot '_Helper.ps1')

Describe 'S-GIT-4 遠端 runner pull 迴圈' {
  It 'S-GIT-4-1 有可領工單：pull→claim→執行→回報' {
    $fix = New-GitDispatchFixture @('T-1')
    try {
      $a = New-Runner $fix 'A'
      $exec = { param($r, $t) @{ note = "runner 執行 $t" } }
      (Invoke-GitRunnerOnce $a 'A' $exec) | Should Match 'REPORTED'
      (Get-OriginClaim $fix 'T-1').by | Should Be 'A'
      [string](((Get-OriginBoard $fix).items | Where-Object { $_.id -eq 'T-1' }).notes[-1].text) | Should Match 'runner 執行'
    } finally { Remove-GitDispatchFixture $fix }
  }

  It 'S-GIT-4-2 執行完回報狀態與 PR：其他端 pull 看得到' {
    $fix = New-GitDispatchFixture @('T-1')
    try {
      $a = New-Runner $fix 'A'
      $exec = { param($r, $t) @{ status = 'In Review'; light = 'Green'; tdd = 'Green'; prUrl = 'http://pr/1'; note = 'done' } }   # 移到 In Review 綠燈要附測試狀態（L6）
      (Invoke-GitRunnerOnce $a 'A' $exec) | Should Match 'REPORTED'
      $item = (Get-OriginBoard $fix).items | Where-Object { $_.id -eq 'T-1' }
      $item.status | Should Be 'In Review'
      $item.prUrl | Should Be 'http://pr/1'
    } finally { Remove-GitDispatchFixture $fix }
  }

  It 'S-GIT-4-3 沒有可領工單：進 idle' {
    $fix = New-GitDispatchFixture @('T-1')
    try {
      $a = New-Runner $fix 'A'; $b = New-Runner $fix 'B'
      (Invoke-GitClaim $a 'T-1' 'A') | Should Be 'CLAIMED'   # T-1 已被領
      (Invoke-GitRunnerOnce $b 'B' { param($r, $t) @{ note = 'x' } }) | Should Be 'IDLE'
    } finally { Remove-GitDispatchFixture $fix }
  }
}
