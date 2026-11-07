param([string]$Task = '*')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot/Skeleton.ps1"
$cases = @(Get-Content "$PSScriptRoot/cases.json" -Raw | ConvertFrom-Json -AsHashtable | Where-Object { $_.id -like "TDD-$Task-*" -or $Task -eq '*' })
if ($cases.Count -eq 0) { throw 'No selected cases: fixture/discovery error' }
$results = @()
foreach ($case in $cases) {
    $failures = @()
    try {
        # All doubles are inert. They provide injection seams, not reference behavior.
        $ports = @{ Clock = @{ Now = '2026-11-06T09:00:00+08:00' }; Store = @{ FailAt = $case.request['failPort']; Calls = @() }; Board = @{ Calls = @() }; Process = @{ Calls = @() }; Http = @{ Calls = @() }; Identity = @{ Developer = 'dev-1'; Verifier = 'qa-1'; Reviewer = 'review-1' } }
        $before = ConvertTo-Json $case.initialState -Depth 20 -Compress
        $request = @{} + $case.request
        $iterations = 1
        if ($request.ContainsKey('repeat')) { $iterations = [int]$request.repeat; $request.Remove('repeat') }
        $actual = $case.initialState
        for ($iteration = 0; $iteration -lt $iterations; $iteration++) {
            $actual = Invoke-DispatchContract -Operation $case.operation -Request $request -State $actual -Ports $ports
        }
        if ($before -cne (ConvertTo-Json $case.initialState -Depth 20 -Compress)) { throw 'Fixture mutated by skeleton' }
        if ($actual -isnot [hashtable]) { throw 'Invalid result contract' }
        foreach ($key in $case.expected.Keys) {
            $observed = if ($actual.ContainsKey($key)) { $actual[$key] } else { '<absent>' }
            if ((ConvertTo-Json $observed -Compress) -cne (ConvertTo-Json $case.expected[$key] -Compress)) {
                $failures += @{ field = $key; expected = $case.expected[$key]; actual = $observed }
            }
        }
        $results += @{ id = $case.id; bdd = $case.bdd; status = $(if ($failures.Count) { 'BEHAVIOR_RED' } else { 'PASS' }); assertions = $case.expected.Count; mismatches = $failures }
    } catch {
        $results += @{ id = $case.id; bdd = $case.bdd; status = 'INFRASTRUCTURE_OR_FIXTURE_FAILURE'; error = $_.Exception.Message }
    }
}
$report = @{ date = [DateTimeOffset]::Now.ToString('o'); layer = 'test-only contract skeleton'; independentAcceptance = 'NOT RUN'; productionCodeChanged = $false; results = $results; red = @($results | Where-Object status -eq 'BEHAVIOR_RED').Count; passed = @($results | Where-Object status -eq 'PASS').Count; invalid = @($results | Where-Object status -eq 'INFRASTRUCTURE_OR_FIXTURE_FAILURE').Count }
$reportName = if ($Task -eq '*') { 'red-results.json' } else { 'red-results-' + ($Task -replace '[^A-Za-z0-9-]', '') + '.json' }
$report | ConvertTo-Json -Depth 30 | Set-Content (Join-Path $PSScriptRoot $reportName) -Encoding utf8
$report | Select-Object red,passed,invalid,layer | Format-List
if ($report.invalid) { exit 2 }
if ($report.red) { exit 1 }
exit 0
