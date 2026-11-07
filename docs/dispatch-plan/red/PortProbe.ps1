# Infrastructure control target only: deliberately exercises RPC, never used for BDD results.
function Invoke-DispatchContract {
 param([string]$Operation,[hashtable]$Request,[hashtable]$State,[hashtable]$Ports)
 $value = & $Ports[$Request.port] $Request.method $Request.arguments
 return @{ probeValue=$value }
}
