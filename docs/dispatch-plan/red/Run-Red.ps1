param([string]$Task = '*', [switch]$Remaining)
$ErrorActionPreference = 'Stop'
& python -B "$PSScriptRoot/fixture_contract_tests.py"
if ($LASTEXITCODE -ne 0) { exit 2 }
$arguments = @("$PSScriptRoot/run_drivers.py", '--task', $Task, '--mutations')
if ($Remaining) { $arguments += '--remaining' }
& python -B @arguments
exit $LASTEXITCODE
