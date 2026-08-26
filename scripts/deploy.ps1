#Requires -Version 7.0
<#
.SYNOPSIS
  Deploys one AKS architecture end to end: role resolution, policy definition, pre-flight gate, then the
  main deployment.

.DESCRIPTION
  Idempotent. Re-running against an existing environment converges rather than erroring.

  The pre-flight network validation is a required gate. -SkipPreflight exists for the case where
  you have already validated the path and are iterating on something unrelated; it prints a warning
  and is not appropriate for a first deployment into a new network.

.EXAMPLE
  ./deploy.ps1 -Architecture aks-private-link -ResourceGroup rg-aks-prod-wus3

.EXAMPLE
  ./deploy.ps1 -Architecture aks-public -ResourceGroup rg-aks-dev -WhatIf
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidateSet('aks-public', 'aks-public-authorized-ip', 'aks-private-link',
    'aks-private-vnet-integration', 'aks-automatic', 'aks-arc-local', 'arc-attach-existing')]
  [string] $Architecture,

  [Parameter(Mandatory)]
  [string] $ResourceGroup,

  [string] $Location = 'westus3',

  [Parameter(HelpMessage = 'Deploy this .bicepparam instead of the curated example for the architecture. This is how a wizard-generated plan is deployed.')]
  [string] $ParamFile = '',

  [string] $SubscriptionId = '',

  [Alias('WhatIf')]
  [switch] $Preview,

  [switch] $SkipPreflight,

  [switch] $SkipPolicyDefinition,

  [Parameter(HelpMessage = 'Do not attempt the post-deployment admission test that proves the assigned Deny rules are actually being enforced.')]
  [switch] $SkipPolicyProof,

  [switch] $SkipLivePreflightProbe,

  [Parameter(HelpMessage = 'Accept the cost estimate without prompting. Intended for CI.')]
  [switch] $Yes,

  [string[]] $OnPremisesCidrs = @(),

  [string] $DeploymentName = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/common.psm1') -Force

Assert-AzureCli
if ($SubscriptionId) { $null = Invoke-AzJson @('account', 'set', '--subscription', $SubscriptionId) }

$repoRoot = Get-RepoRoot
$mainBicep = Join-Path $repoRoot 'infra/main.bicep'
# A generated plan is deployed exactly like a curated one - same gates, same assertions - so there
# is no second, less-checked code path for the thing most people will actually run.
$paramFile = if ($ParamFile) { $ParamFile } else { Join-Path $repoRoot "infra/params/$Architecture.bicepparam" }
if (-not (Test-Path $paramFile)) { throw "No parameter file for architecture '$Architecture' at $paramFile" }

$account = Invoke-AzJson @('account', 'show')
Write-Host ''
Write-Host 'AKS ARCHITECTURES - DEPLOY' -ForegroundColor Cyan
Write-Host "Subscription:   $($account.name) ($($account.id))"
Write-Host "Architecture:         $Architecture"
Write-Host "Resource group: $ResourceGroup"
Write-Host "Region:         $Location"
Write-Host ''

# ================================================================================================
# 1. Resource group
# ================================================================================================

$existingRg = Invoke-AzJson @('group', 'show', '-n', $ResourceGroup)
if ($existingRg) {
  if ($existingRg.location -ne $Location) {
    Write-Host "NOTE: resource group already exists in $($existingRg.location); using that region instead of $Location." -ForegroundColor Yellow
    $Location = $existingRg.location
  }
}
elseif ($Preview) {
  throw "Resource group '$ResourceGroup' does not exist. Preview cannot run against a missing group; create it first or run without -Preview."
}
else {
  Write-Host "Creating resource group $ResourceGroup in $Location..."
  $null = Invoke-AzJson @('group', 'create', '-n', $ResourceGroup, '-l', $Location)
}

# ================================================================================================
# 2. Role definition IDs
#
# Managed and CSP tenants do not use the published built-in role GUIDs for every role. Hardcoding
# them produces RoleDefinitionDoesNotExist at deploy time, so they are resolved by display name here
# and handed to Bicep as parameters.
# ================================================================================================

Write-Host 'Resolving built-in role definition IDs...'
$roleMap = [ordered]@{
  AKS_ROLE_ACR_PULL                    = @{ Name = 'AcrPull'; Fallback = '7f951dda-4ed3-4680-a7ca-43fe172d538d' }
  AKS_ROLE_NETWORK_CONTRIBUTOR         = @{ Name = 'Network Contributor'; Fallback = '4d97b98b-1d4f-4787-a291-c67834d212e7' }
  AKS_ROLE_PRIVATE_DNS_ZONE_CONTRIBUTOR = @{ Name = 'Private DNS Zone Contributor'; Fallback = 'b12aa53e-6015-4669-85d0-8515ebb3ae7f' }
  AKS_ROLE_MONITORING_METRICS_PUBLISHER = @{ Name = 'Monitoring Metrics Publisher'; Fallback = '3913510d-42f4-4e42-8a64-420c390055eb' }
  AKS_ROLE_RBAC_CLUSTER_ADMIN          = @{ Name = 'Azure Kubernetes Service RBAC Cluster Admin'; Fallback = 'b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b' }
  AKS_ROLE_KEY_VAULT_SECRETS_USER      = @{ Name = 'Key Vault Secrets User'; Fallback = '4633458b-17de-408a-b874-0445c86b69e6' }
  AKS_ROLE_GRAFANA_ADMIN               = @{ Name = 'Grafana Admin'; Fallback = '22926164-76b3-42b3-bc55-97df8dab3e41' }
  AKS_ROLE_MONITORING_DATA_READER      = @{ Name = 'Monitoring Data Reader'; Fallback = 'b0d8363b-8ddd-447d-831f-62ca05bff136' }
  AKS_ROLE_MANAGED_IDENTITY_OPERATOR   = @{ Name = 'Managed Identity Operator'; Fallback = 'f1a07417-d97a-45cb-824c-7a7467783830' }
}
foreach ($key in $roleMap.Keys) {
  $id = Resolve-AzRoleId -DisplayName $roleMap[$key].Name -Fallback $roleMap[$key].Fallback
  [Environment]::SetEnvironmentVariable($key, $id, 'Process')
}

# ================================================================================================
# 3. Identity of the caller, so the deployment is usable the moment it finishes
# ================================================================================================

if (-not $env:AKS_DEPLOYMENT_PRINCIPAL_ID) {
  $signedIn = Invoke-AzJson @('account', 'show', '--query', 'user')
  if ($signedIn) {
    if ($signedIn.type -eq 'servicePrincipal') {
      $sp = Invoke-AzJson @('ad', 'sp', 'show', '--id', $signedIn.name, '--query', '{id:id}')
      if ($sp) {
        $env:AKS_DEPLOYMENT_PRINCIPAL_ID = $sp.id
        $env:AKS_DEPLOYMENT_PRINCIPAL_TYPE = 'ServicePrincipal'
      }
    }
    else {
      $me = Invoke-AzJson @('ad', 'signed-in-user', 'show', '--query', '{id:id}')
      if ($me) {
        $env:AKS_DEPLOYMENT_PRINCIPAL_ID = $me.id
        $env:AKS_DEPLOYMENT_PRINCIPAL_TYPE = 'User'
      }
    }
  }
}
if ($env:AKS_DEPLOYMENT_PRINCIPAL_ID) {
  Write-Host "Deployment principal: $($env:AKS_DEPLOYMENT_PRINCIPAL_ID) ($($env:AKS_DEPLOYMENT_PRINCIPAL_TYPE))"
}
else {
  Write-Host 'WARNING: could not determine the caller object ID. Cluster admin and Grafana admin role assignments will be skipped, and you may not be able to reach the cluster after deployment.' -ForegroundColor Yellow
  Write-Host '  Set AKS_DEPLOYMENT_PRINCIPAL_ID and AKS_DEPLOYMENT_PRINCIPAL_TYPE explicitly to fix this.' -ForegroundColor Yellow
}

# ================================================================================================
# 4. Custom deny-public-IP policy definition
#
# Policy definitions cannot live at resource group scope, so this is a separate subscription-scope
# deployment. Lacking Resource Policy Contributor is a governance gap, not a reason to block the
# whole deployment, so it warns rather than failing.
# ================================================================================================

if ($SkipPolicyDefinition) {
  Write-Host 'Skipping the custom deny-public-IP policy definition (-SkipPolicyDefinition).' -ForegroundColor Yellow
}
elseif (-not (Select-String -Path $paramFile -Pattern 'denyPublicIpPolicyDefinitionId' -Quiet)) {
  # The parameter file is the source of truth for whether this architecture assigns the policy. Creating a
  # subscription-scope definition that nothing consumes leaves an orphan behind and prints a
  # reassuring governance message for a control that is not actually in force.
  Write-Host "Architecture '$Architecture' does not assign the custom deny-public-IP policy; skipping the definition."
}
elseif (-not $env:AKS_DENY_PUBLIC_IP_POLICY_ID) {
  Write-Host 'Deploying the custom deny-public-IP policy definition at subscription scope...'
  $policyDeployment = Invoke-AzJson @(
    'deployment', 'sub', 'create',
    '--name', "aks-architectures-policy-$(Get-Date -Format yyyyMMddHHmmss)",
    '--location', $Location,
    '--template-file', (Join-Path $repoRoot 'infra/subscription-policy.bicep'),
    '--parameters', "namePrefix=$Architecture"
  )

  if ($policyDeployment -and $policyDeployment.properties.outputs.definitionId.value) {
    $env:AKS_DENY_PUBLIC_IP_POLICY_ID = $policyDeployment.properties.outputs.definitionId.value
    Write-Host "  Definition: $($env:AKS_DENY_PUBLIC_IP_POLICY_ID)"
  }
  else {
    Write-Host 'WARNING: could not create the custom deny-public-IP policy definition.' -ForegroundColor Yellow
    Write-Host '  This usually means the caller lacks Resource Policy Contributor at subscription scope.' -ForegroundColor Yellow
    Write-Host '  Deployment continues. The built-in internal-load-balancer policy is still assigned;' -ForegroundColor Yellow
    Write-Host '  only the custom public-IP denial is missing. See docs/governance.md.' -ForegroundColor Yellow
  }
}

# ================================================================================================
# 5. Cost gate
#
# Nobody should find an Azure Firewall on their invoice. Everything that bills continuously is
# itemised before anything is created, and the components that dominate the bill need an explicit
# yes. -Yes skips the prompt for CI.
# ================================================================================================

$costTier = if ($env:AKS_COST_TIER) { $env:AKS_COST_TIER.ToLowerInvariant() } else { 'lean' }
$validTiers = @('lean', 'standard', 'full')
if ($costTier -notin $validTiers) {
  throw "AKS_COST_TIER is '$costTier'. Valid values: $($validTiers -join ', '). See docs/costs.md."
}

$resolvedParams = Resolve-BicepParamFile -Path $paramFile
$architectureSpec = (Get-ArchitectureMatrix).architectures.$Architecture
$estimate = Get-CostEstimate -Params $resolvedParams -Architecture $architectureSpec
Write-CostEstimate -Estimate $estimate -Tier $costTier

if ($estimate.HasExpensive -and -not $Preview -and -not $Yes) {
  $answer = Read-Host 'Deploy these components? [y/N]'
  if ($answer -notmatch '^(y|yes)$') {
    Write-Host 'Aborted. Re-run with AKS_COST_TIER=lean, or see docs/costs.md to turn off individual items.' -ForegroundColor Yellow
    exit 1
  }
}

# ================================================================================================
# 6. Pre-flight gate
# ================================================================================================

if ($SkipPreflight) {
  Write-Host ''
  Write-Host '########################################################################' -ForegroundColor Yellow
  Write-Host '  WARNING: pre-flight network validation was SKIPPED (-SkipPreflight).' -ForegroundColor Yellow
  Write-Host '  Address overlaps, quota shortfalls, NSG denies and broken egress will' -ForegroundColor Yellow
  Write-Host '  not surface until the node pool fails to register, typically 20-40' -ForegroundColor Yellow
  Write-Host '  minutes into the deployment and with an opaque error.' -ForegroundColor Yellow
  Write-Host '########################################################################' -ForegroundColor Yellow
  Write-Host ''
}
else {
  Write-Host ''
  Write-Host 'Running pre-flight network validation...' -ForegroundColor Cyan
  $preflightArgs = @(
    '-NoProfile', '-File', (Join-Path $PSScriptRoot 'preflight.ps1'),
    '-ParamFile', $paramFile,
    '-ResourceGroup', $ResourceGroup,
    '-Location', $Location,
    '-JsonOutputPath', (Join-Path (Get-Location) "preflight-$Architecture.json")
  )
  if ($SkipLivePreflightProbe) { $preflightArgs += '-SkipLiveProbe' }
  foreach ($cidr in $OnPremisesCidrs) { $preflightArgs += @('-OnPremisesCidrs', $cidr) }

  & pwsh @preflightArgs
  if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host 'Deployment aborted: pre-flight validation failed.' -ForegroundColor Red
    Write-Host 'Fix the items above, or re-run with -SkipPreflight if you accept the risk.' -ForegroundColor Red
    exit 1
  }
}

# ================================================================================================
# 7. Main deployment
# ================================================================================================

if (-not $DeploymentName) { $DeploymentName = "aks-architectures-$Architecture-$(Get-Date -Format yyyyMMddHHmmss)" }

if ($Preview) {
  Write-Host ''
  Write-Host 'Previewing changes (what-if)...' -ForegroundColor Cyan
  & az @('deployment', 'group', 'what-if', '-g', $ResourceGroup, '-n', $DeploymentName,
    '--template-file', $mainBicep, '--parameters', $paramFile)
  exit $LASTEXITCODE
}

Write-Host ''
Write-Host "Deploying $Architecture. A first private cluster with a firewall takes roughly 25 minutes." -ForegroundColor Cyan

# Run az directly rather than through Invoke-AzJson: on failure the CLI error text is the most
# useful thing on screen and Invoke-AzJson discards stderr.
$raw = az @('deployment', 'group', 'create', '-g', $ResourceGroup, '-n', $DeploymentName,
  '--template-file', $mainBicep, '--parameters', $paramFile, '-o', 'json')
if ($LASTEXITCODE -ne 0) {
  Write-Host ''
  Write-Host 'Deployment failed.' -ForegroundColor Red
  Write-Host "Collect evidence with:  ./diagnose.ps1 -ResourceGroup $ResourceGroup -DeploymentName $DeploymentName" -ForegroundColor Red
  exit 1
}
$deployment = ($raw -join "`n") | ConvertFrom-Json

$out = $deployment.properties.outputs

# ================================================================================================
# 8. Post-deployment assertions
#
# The route table has to be created before the firewall exists, so its next hop is a computed
# prediction of the firewall private IP. If the prediction is wrong, every node egresses into a
# black hole and the failure looks like a random timeout much later.
# ================================================================================================

function Get-Output([string] $name) {
  if ($out.PSObject.Properties[$name]) { return $out.$name.value }
  return ''
}

$expectedFw = Get-Output 'expectedFirewallPrivateIp'
$actualFw = Get-Output 'actualFirewallPrivateIp'
if ($expectedFw -and $actualFw -and $expectedFw -ne $actualFw) {
  Write-Host ''
  Write-Host '########################################################################' -ForegroundColor Red
  Write-Host '  ROUTE TABLE / FIREWALL MISMATCH' -ForegroundColor Red
  Write-Host "  Route table next hop:  $expectedFw" -ForegroundColor Red
  Write-Host "  Actual firewall IP:    $actualFw" -ForegroundColor Red
  Write-Host '  Every node egress packet is being sent to an address the firewall does' -ForegroundColor Red
  Write-Host '  not hold. Nodes will fail to register or will hang mid-provisioning.' -ForegroundColor Red
  Write-Host '  Fix addressing.firewallSubnetPrefix so the fourth address of the subnet' -ForegroundColor Red
  Write-Host '  is the firewall private IP, then redeploy.' -ForegroundColor Red
  Write-Host '########################################################################' -ForegroundColor Red
  exit 1
}

Write-Host ''
Write-Host 'DEPLOYMENT SUCCEEDED' -ForegroundColor Green
Write-Host ('=' * 78)
foreach ($name in @('architectureApplied', 'networkProfileApplied', 'egressApplied', 'outboundTypeApplied',
    'clusterName', 'clusterFqdn', 'nodeResourceGroup', 'vnetName', 'nodeSubnetId',
    'egressPublicIpAddress', 'dnsResolverInboundIp', 'containerRegistryLoginServer',
    'keyVaultUri', 'grafanaEndpoint')) {
  $value = Get-Output $name
  if ($value) { Write-Host ("  {0,-30} {1}" -f $name, $value) }
}
Write-Host ('=' * 78)

$ranges = Get-Output 'apiServerAuthorizedIpRanges'
if ($ranges) { Write-Host "  API server authorized IP ranges: $($ranges -join ', ')" }

# ================================================================================================
# 9. Governance proof
#
# Assignment is not enforcement. The compliance blade reports that a Deny was assigned; only an
# admission attempt reports that it is actually refusing anything. This runs the attempt so the
# proof ships with the deployment rather than living in a runbook nobody opens.
#
# The wait is zero here on purpose. The Azure Policy add-on polls roughly every fifteen minutes, so
# a fresh cluster almost always reports PENDING, and blocking the deploy for fifteen minutes to
# learn that would be a poor trade. The re-run command is printed instead.
# ================================================================================================

if (-not $SkipPolicyProof -and (Get-Output 'policyInClusterEnforcement') -eq $true) {
  Write-Host ''
  & (Join-Path $PSScriptRoot 'verify-policy.ps1') `
    -ResourceGroup $ResourceGroup -ClusterName (Get-Output 'clusterName') -WaitMinutes 0
  # A cluster that accepts what its own policy forbids is a real finding, so it fails the deploy.
  # Anything else - pending, or the proof could not run - is reported and does not.
  if ($LASTEXITCODE -eq 1) { exit 1 }
}

$kubectl = Get-Output 'kubectlCredentialCommand'
if ($kubectl) {
  Write-Host ''
  Write-Host 'Get credentials:' -ForegroundColor Cyan
  Write-Host "  $kubectl"
  if ($Architecture -eq 'aks-private-link') {
    Write-Host ''
    Write-Host 'This is a private cluster. kubectl only works from a network that can resolve and' -ForegroundColor Yellow
    Write-Host 'reach the API server private endpoint. From outside that network, use:' -ForegroundColor Yellow
    Write-Host "  az aks command invoke -g $ResourceGroup -n $(Get-Output 'clusterName') --command 'kubectl get nodes'" -ForegroundColor Yellow
  }
}
Write-Host ''
