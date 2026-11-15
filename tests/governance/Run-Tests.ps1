# E-GOV 治理測試執行器（Pester 3.4，Windows PowerShell 內建）。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\governance\Run-Tests.ps1
$ErrorActionPreference = 'Stop'
Import-Module Pester -RequiredVersion 3.4.0 -ErrorAction Stop
$r = Invoke-Pester -Path $PSScriptRoot -PassThru
exit $r.FailedCount
