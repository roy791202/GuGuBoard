param([Parameter(Mandatory)][string]$SkeletonPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. $SkeletonPath
function Invoke-TestPort {
    param([string]$Port, [string]$Method, $Arguments)
    [Console]::WriteLine((@{kind='port';port=$Port;method=$Method;arguments=$Arguments} | ConvertTo-Json -Compress -Depth 30))
    $line = [Console]::ReadLine()
    if (-not $line) { throw 'Test port RPC disconnected' }
    $response = ConvertFrom-Json -InputObject $line -AsHashtable
    if ($response['error']) { throw [System.IO.IOException]::new([string]$response.error) }
    return $response['value']
}
try {
    $packet = ConvertFrom-Json -InputObject ([Console]::ReadLine()) -AsHashtable
    $ports = @{}
    foreach ($name in @('Clock','Store','Http','Board','Process','Identity','Secrets','PullRequest','Workspace')) {
        $portName = $name
        $ports[$name] = { param($Method,$Arguments) Invoke-TestPort -Port $portName -Method $Method -Arguments $Arguments }.GetNewClosure()
    }
    $result = Invoke-DispatchContract -Operation $packet.operation -Request $packet.request -State $packet.state -Ports $ports
    @{kind='result';value=$result} | ConvertTo-Json -Depth 30 -Compress | Write-Output
} catch {
    @{kind='exception';type=$_.Exception.GetType().FullName;message=$_.Exception.Message} | ConvertTo-Json -Compress | Write-Output
    exit 0
}
