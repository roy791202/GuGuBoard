# 執行 Git 派工測試：powershell -NoProfile -ExecutionPolicy Bypass -File tests\git-dispatch\Run-Tests.ps1
param([string]$Filter = '*')
Import-Module Pester -RequiredVersion 3.4.0 -ErrorAction Stop
$files = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter "$Filter.Tests.ps1" | ForEach-Object { $_.FullName })
$r = Invoke-Pester -Path $files -PassThru -Quiet
foreach ($t in $r.TestResult) {
  '{0,-7} {1} :: {2}' -f $t.Result, $t.Describe, $t.Name
  if ($t.FailureMessage) { '        ' + (($t.FailureMessage -split "`n")[0]) }
}
'passed={0} failed={1}' -f $r.PassedCount, $r.FailedCount
exit $(if ($r.FailedCount -eq 0 -and $r.PassedCount -gt 0) { 0 } else { 1 })
