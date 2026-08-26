#Requires -Version 7.0
<#
.SYNOPSIS
  Proves that the governance controls this repo assigns are actually being ENFORCED, by asking the
  cluster to do the exact thing they exist to prevent.

.DESCRIPTION
  Assignment and enforcement are different facts. The Azure Policy compliance blade reports the
  first. Only an admission attempt reports the second, and the gap between them is where governance
  quietly stops being real: an assignment scoped to the wrong resource group, an add-on that was
  never enabled, or a constraint that failed to sync all look identical from the portal.

  Runs entirely through `az aks command invoke`, so it works against private clusters from any
  network and needs no local kubectl and no kubeconfig.

  Exit codes: 0 enforced or pending, 1 assigned but NOT enforced, 2 usage or could not run.

.EXAMPLE
  ./verify-policy.ps1 -ResourceGroup rg-aks-prod-wus3 -ClusterName aks-contoso-prod-wus3-01

.EXAMPLE
  ./verify-policy.ps1 -ResourceGroup rg-aks-prod-wus3 -ClusterName aks-contoso-prod-wus3-01 -WaitMinutes 20
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $ResourceGroup,

  [Parameter(Mandatory)]
  [Alias('Name')]
  [string] $ClusterName,

  [string] $SubscriptionId = '',

  # The Azure Policy add-on polls for assignments roughly every fifteen minutes, so a proof run
  # immediately after a deployment will normally find nothing. Waiting is the honest default; zero
  # is available for CI, where a PENDING result is fine and twenty minutes of billed runner time
  # is not.
  [ValidateRange(0, 120)]
  [int] $WaitMinutes = 15
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/common.psm1') -Force

Assert-AzureCli
if ($SubscriptionId) { $null = Invoke-AzJson @('account', 'set', '--subscription', $SubscriptionId) }

$proofScript = Join-Path $PSScriptRoot 'lib/policy-proof.sh'
if (-not (Test-Path $proofScript)) { throw "Missing $proofScript" }

Write-Host ''
Write-Host 'GOVERNANCE PROOF - internal load balancer Deny' -ForegroundColor Cyan
Write-Host "Cluster: $ClusterName  (resource group $ResourceGroup)" -ForegroundColor DarkGray
Write-Host ''

# `command invoke` schedules a pod on the cluster and streams its output back through the Azure
# control plane, so this reaches a private API server without any network path from here.
#
# The file must be in the CURRENT WORKING DIRECTORY and referenced by bare name - an absolute path
# in --file is not honoured. Hence the Push-Location rather than passing $proofScript directly.
$invokeArgs = @(
  'aks', 'command', 'invoke',
  '-g', $ResourceGroup,
  '-n', $ClusterName,
  '--command', 'bash policy-proof.sh',
  '--file', 'policy-proof.sh'
)

$deadline = (Get-Date).AddMinutes($WaitMinutes)
$attempt = 0
$result = ''
$detail = ''
$logs = ''

while ($true) {
  $attempt++
  Push-Location (Join-Path $PSScriptRoot 'lib')
  try { $invoke = Invoke-AzJson $invokeArgs } finally { Pop-Location }

  if ($null -eq $invoke) {
    Write-Host 'Could not run the proof on this cluster.' -ForegroundColor Red
    Write-Host 'The command needs Microsoft.ContainerService/managedClusters/runcommand/action, and the'
    Write-Host 'cluster must be Running. Verify with:'
    Write-Host "  az aks command invoke -g $ResourceGroup -n $ClusterName --command 'kubectl get nodes'"
    exit 2
  }

  $logs = if ($invoke.PSObject.Properties['logs']) { [string]$invoke.logs } else { [string]$invoke.text }
  $lines = $logs -split "`r?`n"
  $result = ($lines | Where-Object { $_ -like 'RESULT=*' } | Select-Object -Last 1) -replace '^RESULT=', ''
  $detail = ($lines | Where-Object { $_ -like 'DETAIL=*' } | Select-Object -Last 1) -replace '^DETAIL=', ''

  if ($result -ne 'pending') { break }
  if ((Get-Date) -ge $deadline) { break }

  $remaining = [Math]::Max(1, [int]($deadline - (Get-Date)).TotalMinutes)
  Write-Host "  Constraints have not synced yet (attempt $attempt). The Azure Policy add-on polls about"
  Write-Host "  every 15 minutes; waiting up to $remaining more minute(s)."
  Start-Sleep -Seconds 60
}

Write-Host ''
switch ($result) {
  'enforced' {
    Write-Host 'ENFORCED. A Service of type LoadBalancer with no internal annotation was REFUSED by the' -ForegroundColor Green
    Write-Host 'admission controller, which is the behaviour the assigned policy promises.' -ForegroundColor Green
    Write-Host "  $detail" -ForegroundColor DarkGray
    exit 0
  }
  'notenforced' {
    Write-Host '########################################################################' -ForegroundColor Red
    Write-Host '  GOVERNANCE NOT ENFORCED' -ForegroundColor Red
    Write-Host "  $detail" -ForegroundColor Red
    Write-Host '  The compliance blade will still show the assignment. Check that the' -ForegroundColor Red
    Write-Host '  Azure Policy add-on is enabled (features.azurePolicyAddon) and that the' -ForegroundColor Red
    Write-Host '  assignment scope covers this cluster:' -ForegroundColor Red
    Write-Host "    az aks show -g $ResourceGroup -n $ClusterName --query addonProfiles.azurepolicy" -ForegroundColor Red
    Write-Host "    az policy assignment list --disable-scope-strict-match -g $ResourceGroup -o table" -ForegroundColor Red
    Write-Host '########################################################################' -ForegroundColor Red
    exit 1
  }
  'pending' {
    Write-Host 'PENDING. Gatekeeper has not yet received the constraint, so nothing was proven either way.' -ForegroundColor Yellow
    Write-Host "  $detail" -ForegroundColor DarkGray
    Write-Host ''
    Write-Host 'This is normal shortly after a deployment. Re-run when the add-on has polled:'
    Write-Host "  ./verify-policy.ps1 -ResourceGroup $ResourceGroup -ClusterName $ClusterName -WaitMinutes 20"
    exit 0
  }
  default {
    Write-Host 'INCONCLUSIVE. The proof ran but did not return a result this script understands.' -ForegroundColor Yellow
    $shown = if ($detail) { $detail } else { $logs }
    Write-Host "  $shown" -ForegroundColor DarkGray
    exit 2
  }
}
