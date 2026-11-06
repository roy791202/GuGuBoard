# T-DL-2 逾時與停止時終止整個程序樹
. (Join-Path $PSScriptRoot '_Helper.ps1')

function Start-SpawnRun($Pj, [string]$PidFile) {
  Enable-Dispatch $Pj (New-FakeProfile 'spawn-child.ps1' @('-PidFile', $PidFile))
  Invoke-Tick $Pj
  $r = @(Get-ProjectRuns $Pj)[0]
  if (-not (Wait-Until { Test-Path -LiteralPath $PidFile })) { throw '子程序沒有啟動' }
  $c = Get-DispatchCfg $Pj.id; $c.enabled = $false; Save-DispatchCfg $Pj.id $c   # 之後只測結束流程，不再派新單
  @{ run = $r; parent = $r.proc.Id; child = [int](Get-Content -LiteralPath $PidFile) }
}
$req = [pscustomobject]@{ HttpMethod = 'POST'; IsLocal = $true; Headers = @{} }

Describe 'T-DL-2 終止整個程序樹' {
  AfterEach { Reset-Dispatch }

  It 'S-DL-2-1 達到 timeoutMin：父子程序都已結束，claim 釋放' {
    $Pj = New-TestProject 'Todo' 'Gray'; $pf = Join-Path $ConfigDir ([guid]::NewGuid().ToString('N') + '.pid')
    $x = Start-SpawnRun $Pj $pf
    try {
      $x.run.start = (Get-Date).AddHours(-2)
      Invoke-Tick $Pj
      $x.run.status | Should Be 'timeout'
      Test-Alive $x.parent | Should Be $false
      Test-Alive $x.child | Should Be $false
      (Get-Claims $Pj.id).ContainsKey('T-1') | Should Be $false
    } finally { Stop-Process -Id $x.child -Force -ErrorAction SilentlyContinue }
  }

  It 'S-DL-2-2 管理者呼叫 /dispatch/kill：父子程序都已結束，狀態 killed' {
    $Pj = New-TestProject 'Todo' 'Gray'; $pf = Join-Path $ConfigDir ([guid]::NewGuid().ToString('N') + '.pid')
    $x = Start-SpawnRun $Pj $pf
    try {
      $T.Body = [pscustomobject]@{ run = $x.run.id }
      Invoke-DispatchApi $req $null @{ role = 'admin' } $Pj '/dispatch/kill'
      $T.Sent.code | Should Be 200
      $x.run.status | Should Be 'killed'
      Test-Alive $x.parent | Should Be $false
      Test-Alive $x.child | Should Be $false
    } finally { Stop-Process -Id $x.child -Force -ErrorAction SilentlyContinue }
  }

  It 'S-DL-2-3 程序樹無法結束：狀態 stuck，claim 保留，下一次 tick 不會再派這張' {
    $Pj = New-TestProject 'Todo' 'Gray'; $pf = Join-Path $ConfigDir ([guid]::NewGuid().ToString('N') + '.pid')
    $x = Start-SpawnRun $Pj $pf
    try {
      function Stop-RunTree($proc, [int]$waitMs = 10000) { $false }   # 模擬無法終止
      $x.run.start = (Get-Date).AddHours(-2)
      Invoke-Tick $Pj
      $x.run.status | Should Be 'stuck'
      (Get-Claims $Pj.id).ContainsKey('T-1') | Should Be $true
      $c = Get-DispatchCfg $Pj.id; $c.enabled = $true; Save-DispatchCfg $Pj.id $c
      Invoke-Tick $Pj
      @(Get-ProjectRuns $Pj).Count | Should Be 1
    } finally { Stop-Process -Id $x.parent, $x.child -Force -ErrorAction SilentlyContinue }
  }
}
