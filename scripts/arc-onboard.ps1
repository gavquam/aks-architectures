#Requires -Version 7.0
<#
.SYNOPSIS
  Onboards an existing Kubernetes cluster to Azure Arc and prints the resource ID the
  arc-attach-existing architecture needs.

.DESCRIPTION
  The connectedCluster resource cannot be created by Resource Manager, because onboarding installs
  agents into the target cluster and Resource Manager has no kubeconfig. So the sequence is:

    1. this script          -> creates Microsoft.Kubernetes/connectedClusters and installs the agents
    2. AKS_EXISTING_CONNECTED_CLUSTER_ID=<printed id>
    3. deploy.ps1 -Architecture arc-attach-existing  -> layers monitoring, Defender and policy extensions

  Re-running is safe. If the cluster is already Connected the onboarding step is skipped.

.EXAMPLE
  ./arc-onboard.ps1 -ClusterName k3s-plant-01 -ResourceGroup rg-aks-arc-prod-wus3

.EXAMPLE
  ./arc-onboard.ps1 -ClusterName k3s-plant-01 -ResourceGroup rg-aks-arc-prod-wus3 `
    -KubeContext plant01 -ProxyHttps http://proxy.plant.local:3128 -ProxySkipRange '10.0.0.0/8,.plant.local'
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$ClusterName,
  [Parameter(Mandatory)][string]$ResourceGroup,
  [string]$Location = 'westus3',
  [string]$SubscriptionId = '',
  [string]$KubeContext = '',
  [string]$ProxyHttps = '',
  [string]$ProxyHttp = '',
  [string]$ProxySkipRange = '',
  [string]$Distribution = '',
  [string]$Infrastructure = '',
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/common.psm1') -Force
Assert-AzureCli
if ($SubscriptionId) { az account set --subscription $SubscriptionId -o none }

Write-Host ''
Write-Host 'AKS ARCHITECTURES - AZURE ARC ONBOARDING' -ForegroundColor Cyan
Write-Host ''

# ------------------------------------------------------------------------------------------------
# 1. Tooling
# ------------------------------------------------------------------------------------------------

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
  throw 'kubectl is not on PATH. Arc onboarding runs against the cluster, not against Azure, so kubectl is required.'
}

$extensions = Invoke-AzJson @('extension', 'list')
if (-not (@($extensions) | Where-Object { $_.name -eq 'connectedk8s' })) {
  Write-Host 'Installing the connectedk8s CLI extension...'
  az extension add --name connectedk8s --only-show-errors -o none
}
else {
  az extension update --name connectedk8s --only-show-errors -o none 2>$null
}

# ------------------------------------------------------------------------------------------------
# 2. Confirm the target cluster
#
# This writes agents into whatever kubeconfig context is active. Onboarding the wrong cluster is an
# unpleasant thing to undo on a plant floor, so the context is always shown and confirmed.
# ------------------------------------------------------------------------------------------------

$currentContext = if ($KubeContext) { $KubeContext } else { (kubectl config current-context 2>$null) }
if (-not $currentContext) {
  throw 'No kubectl context is selected and -KubeContext was not supplied. Run kubectl config use-context <name> first.'
}

$kubectlArgs = @('--context', $currentContext)
$serverUrl = (kubectl config view --minify -o "jsonpath={.clusters[0].cluster.server}" @kubectlArgs 2>$null)
$nodeCount = @(kubectl get nodes -o name @kubectlArgs 2>$null).Count
if ($nodeCount -eq 0) {
  throw "kubectl could not reach the cluster behind context '$currentContext'. Fix connectivity before onboarding."
}

Write-Host "  kube context : $currentContext"
Write-Host "  api server   : $serverUrl"
Write-Host "  nodes        : $nodeCount"
Write-Host "  arc resource : $ResourceGroup/$ClusterName in $Location"
Write-Host ''

if (-not $Force) {
  $answer = Read-Host "Onboard this cluster to Azure Arc? Type the cluster name '$ClusterName' to continue"
  if ($answer -ne $ClusterName) { Write-Host 'Aborted.' -ForegroundColor Yellow; exit 1 }
}

# ------------------------------------------------------------------------------------------------
# 3. Providers and resource group
# ------------------------------------------------------------------------------------------------

foreach ($ns in @('Microsoft.Kubernetes', 'Microsoft.KubernetesConfiguration', 'Microsoft.ExtendedLocation')) {
  $state = (az provider show -n $ns --query registrationState -o tsv 2>$null)
  if ($state -ne 'Registered') {
    Write-Host "Registering resource provider $ns..."
    az provider register -n $ns --wait -o none
  }
}

if ((az group exists -n $ResourceGroup) -ne 'true') {
  Write-Host "Creating resource group $ResourceGroup in $Location..."
  az group create -n $ResourceGroup -l $Location -o none
}

# ------------------------------------------------------------------------------------------------
# 4. Onboard
# ------------------------------------------------------------------------------------------------

$existing = Invoke-AzJson @('connectedk8s', 'show', '-n', $ClusterName, '-g', $ResourceGroup)
if ($existing -and $existing.connectivityStatus -eq 'Connected') {
  Write-Host "Cluster '$ClusterName' is already Connected. Skipping onboarding." -ForegroundColor Green
}
else {
  if ($existing) {
    Write-Host "Cluster '$ClusterName' exists with connectivityStatus '$($existing.connectivityStatus)'. Re-running connect to repair the agents." -ForegroundColor Yellow
  }

  $connectArgs = @('connectedk8s', 'connect', '-n', $ClusterName, '-g', $ResourceGroup, '-l', $Location,
    '--kube-context', $currentContext, '--only-show-errors')
  if ($ProxyHttps) { $connectArgs += @('--proxy-https', $ProxyHttps) }
  if ($ProxyHttp) { $connectArgs += @('--proxy-http', $ProxyHttp) }
  if ($ProxySkipRange) { $connectArgs += @('--proxy-skip-range', $ProxySkipRange) }
  if ($Distribution) { $connectArgs += @('--distribution', $Distribution) }
  if ($Infrastructure) { $connectArgs += @('--infrastructure', $Infrastructure) }

  Write-Host 'Running az connectedk8s connect. This installs the Arc agents and usually takes 5-10 minutes...'
  az @connectArgs -o none
  if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host 'Onboarding failed. The agents pull images from mcr.microsoft.com and call' -ForegroundColor Red
    Write-Host 'management.azure.com and login.microsoftonline.com on 443. If this site egresses through a' -ForegroundColor Red
    Write-Host 'proxy, re-run with -ProxyHttps / -ProxySkipRange. See docs/networking.md for the full list.' -ForegroundColor Red
    exit 1
  }
}

# ------------------------------------------------------------------------------------------------
# 5. Verify and hand off
# ------------------------------------------------------------------------------------------------

$cluster = Invoke-AzJson @('connectedk8s', 'show', '-n', $ClusterName, '-g', $ResourceGroup)
if (-not $cluster) { throw "Onboarding reported success but the connectedCluster resource could not be read." }

Write-Host ''
Write-Host "  connectivityStatus : $($cluster.connectivityStatus)"
Write-Host "  kubernetesVersion  : $($cluster.kubernetesVersion)"
Write-Host "  agentVersion       : $($cluster.agentVersion)"
Write-Host "  totalNodeCount     : $($cluster.totalNodeCount)"
Write-Host ''

if ($cluster.connectivityStatus -ne 'Connected') {
  Write-Host "Cluster is '$($cluster.connectivityStatus)', not yet 'Connected'. The agents may still be starting." -ForegroundColor Yellow
  Write-Host 'Check with: kubectl get pods -n azure-arc' -ForegroundColor Yellow
}

Write-Host 'Set this before deploying the arc-attach-existing architecture:' -ForegroundColor Cyan
Write-Host ''
Write-Host "  `$env:AKS_EXISTING_CONNECTED_CLUSTER_ID = '$($cluster.id)'"
Write-Host ''
Write-Host 'Then:' -ForegroundColor Cyan
Write-Host "  ./deploy.ps1 -Architecture arc-attach-existing -ResourceGroup $ResourceGroup -Location $Location"
Write-Host ''
