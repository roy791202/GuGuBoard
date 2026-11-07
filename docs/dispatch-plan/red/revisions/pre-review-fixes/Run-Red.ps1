param([string]$Task = '*', [switch]$Remaining)
$ErrorActionPreference = 'Stop'
$arguments = @("$PSScriptRoot/run_drivers.py", '--task', $Task)
if ($Remaining) { $arguments += '--remaining' }
& python @arguments
exit $LASTEXITCODE
