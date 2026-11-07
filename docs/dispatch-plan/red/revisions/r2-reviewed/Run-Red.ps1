param([string]$Task = '*', [switch]$Remaining)
$ErrorActionPreference = 'Stop'
$arguments = @("$PSScriptRoot/run_drivers.py", '--task', $Task, '--mutations')
if ($Remaining) { $arguments += '--remaining' }
& python @arguments
exit $LASTEXITCODE
