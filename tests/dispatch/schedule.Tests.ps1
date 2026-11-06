# T-DL-1 派工開始時間閘門與並行上限
. (Join-Path $PSScriptRoot '_Helper.ps1')

function Get-IsoNow([int]$AddMinutes = 0) { (Get-Date).AddMinutes($AddMinutes).ToString('yyyy-MM-dd\THH\:mm\:sszzz', [Globalization.CultureInfo]::InvariantCulture) }
$req = [pscustomobject]@{ HttpMethod = 'POST'; IsLocal = $true; Headers = @{} }

Describe 'T-DL-1 開始時間閘門與並行上限' {
  AfterEach { Reset-Dispatch }

  It 'S-DL-1-1 notBefore 是未來時間：tick 不啟動任何執行' {
    $Pj = New-TestProject 'Todo' 'Gray'
    Enable-Dispatch $Pj (New-FakeProfile 'exit-code.ps1') @{ notBefore = (Get-IsoNow 60) }
    Invoke-Tick $Pj
    @(Get-ProjectRuns $Pj).Count | Should Be 0
  }

  It 'S-DL-1-2 notBefore 等於現在：依現有規則領取並啟動一張 Task' {
    $Pj = New-TestProject 'Todo' 'Gray'
    Enable-Dispatch $Pj (New-FakeProfile 'exit-code.ps1') @{ notBefore = (Get-IsoNow 0) }
    Invoke-Tick $Pj
    @(Get-ProjectRuns $Pj).Count | Should Be 1
    @(Get-ProjectRuns $Pj)[0].ticket | Should Be 'T-1'
  }

  It 'S-DL-1-3 notBefore 不含時區：回 400 E_BAD_TIME 且設定檔不變' {
    $Pj = New-TestProject 'Todo' 'Gray'
    Save-DispatchCfg $Pj.id (Get-DispatchCfg $Pj.id)
    $before = [IO.File]::ReadAllText((Get-DispatchFile $Pj.id))
    $T.Body = [pscustomobject]@{ notBefore = '2026-11-08T09:00:00'; intervalSec = 30 }
    Invoke-DispatchApi $req $null @{ role = 'admin' } $Pj '/dispatch/config'
    $T.Sent.code | Should Be 400
    $T.Sent.body.error | Should Be 'E_BAD_TIME'
    [IO.File]::ReadAllText((Get-DispatchFile $Pj.id)) | Should BeExactly $before
  }

  It 'notBefore 含時區：儲存成功；傳 null 則清除' {
    $Pj = New-TestProject 'Todo' 'Gray'
    $T.Body = [pscustomobject]@{ notBefore = '2026-11-08T09:00:00+08:00' }
    Invoke-DispatchApi $req $null @{ role = 'admin' } $Pj '/dispatch/config'
    $T.Sent.code | Should Be 200
    (Get-DispatchCfg $Pj.id).notBefore | Should Be '2026-11-08T09:00:00+08:00'
    $T.Body = [pscustomobject]@{ notBefore = $null }
    Invoke-DispatchApi $req $null @{ role = 'admin' } $Pj '/dispatch/config'
    $T.Sent.code | Should Be 200
    (Get-DispatchCfg $Pj.id).notBefore | Should Be $null
  }

  It 'S-DL-1-4 送出 maxConcurrent=3：存成 1' {
    $Pj = New-TestProject 'Todo' 'Gray'
    $T.Body = [pscustomobject]@{ maxConcurrent = 3 }
    Invoke-DispatchApi $req $null @{ role = 'admin' } $Pj '/dispatch/config'
    $T.Sent.code | Should Be 200
    (Get-DispatchCfg $Pj.id).maxConcurrent | Should Be 1
  }

  It '舊設定檔裡的 maxConcurrent=3 讀出來也是 1' {
    $Pj = New-TestProject 'Todo' 'Gray'
    $c = Get-DispatchCfg $Pj.id; $c.maxConcurrent = 3; ([pscustomobject]$c) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Get-DispatchFile $Pj.id) -Encoding UTF8
    (Get-DispatchCfg $Pj.id).maxConcurrent | Should Be 1
  }
}
