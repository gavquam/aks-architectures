#Requires -Version 7.0
<#
.SYNOPSIS
  Removes everything an architecture deployment created, including the artefacts that outlive the resource
  group: role assignments scoped outside it, private DNS zone links into other VNets, the
  subscription-scope policy definition, soft-deleted key vaults, and Arc agents on the cluster.

.DESCRIPTION
  Deleting the resource group on its own is not a clean teardown. It leaves behind:
    - role assignments whose scope is an existing VNet in another resource group
    - private DNS zone links pointing at VNets outside the group (the link object goes, but the
      target VNet keeps a stale reference until the zone is gone, and the zone will refuse to
      delete while links remain if you ever remove it individually)
    - the subscription-scope deny-public-IP policy definition, which is not a group resource
    - soft-deleted key vaults, which keep their names reserved for 90 days
    - connectedk8s agents running inside a non-Azure cluster, still pointed at a dead ARM resource

  This script removes all of them, in the order that actually works.

.EXAMPLE
  ./destroy.ps1 -ResourceGroup rg-aks-prod-wus3

.EXAMPLE
  ./destroy.ps1 -ResourceGroup rg-aks-dev -Force -PurgeKeyVaults
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $ResourceGroup,

  [string] $SubscriptionId = '',

  [ValidateSet('aks-public', 'aks-public-authorized-ip', 'aks-private-link',
    'aks-private-vnet-integration', 'aks-automatic', 'aks-arc-local', 'arc-attach-existing', '')]
  [string] $Architecture = '',

  [switch] $Force,

  [switch] $PurgeKeyVaults,

  [switch] $KeepPolicyDefinition,

  [switch] $KeepResourceGroup,

  [switch] $DryRun
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/common.psm1') -Force

Assert-AzureCli
if ($SubscriptionId) { $null = Invoke-AzJson @('account', 'set', '--subscription', $SubscriptionId) }

$subId = (Invoke-AzJson @('account', 'show')).id
$rgScope = "/subscriptions/$subId/resourceGroups/$ResourceGroup"
$actions = [System.Collections.Generic.List[string]]::new()

function Step([string] $message) { Write-Host "  $message" }
function Act([string] $description, [scriptblock] $body) {
  $actions.Add($description)
  if ($DryRun) { Write-Host "  [dry-run] $description" -ForegroundColor DarkGray; return }
  Write-Host "  $description"
  & $body
}

Write-Host ''
Write-Host 'AKS ARCHITECTURES - DESTROY' -ForegroundColor Cyan
Write-Host "Subscription:   $subId"
Write-Host "Resource group: $ResourceGroup"
Write-Host ''

$rg = Invoke-AzJson @('group', 'show', '-n', $ResourceGroup)
if (-not $rg) {
  Write-Host "Resource group '$ResourceGroup' does not exist. Continuing with subscription-scope cleanup only." -ForegroundColor Yellow
}

# ================================================================================================
# 1. Inventory, taken before anything is deleted
# ================================================================================================

Write-Host 'Taking inventory...' -ForegroundColor Cyan

$clusters = @()
$connected = @()
$dnsZones = @()
$identityPrincipalIds = @()
$keyVaultNames = @()
$vaultLocation = $rg.location

if ($rg) {
  $clusters = @(Invoke-AzJson @('aks', 'list', '-g', $ResourceGroup, '--query', '[].{name:name,id:id,nodeResourceGroup:nodeResourceGroup}'))
  $connected = @(Invoke-AzJson @('resource', 'list', '-g', $ResourceGroup, '--resource-type', 'Microsoft.Kubernetes/connectedClusters', '--query', '[].{name:name,id:id}'))
  $dnsZones = @(Invoke-AzJson @('network', 'private-dns', 'zone', 'list', '-g', $ResourceGroup, '--query', '[].name'))
  $identityPrincipalIds = @(Invoke-AzJson @('identity', 'list', '-g', $ResourceGroup, '--query', '[].principalId'))
  $keyVaultNames = @(Invoke-AzJson @('keyvault', 'list', '-g', $ResourceGroup, '--query', '[].name'))

  # AKS control plane and kubelet identities are the ones that get assignments outside the group.
  foreach ($c in $clusters) {
    $ids = Invoke-AzJson @('aks', 'show', '-g', $ResourceGroup, '-n', $c.name, '--query', '{cp:identity.principalId,kubelet:identityProfile.kubeletidentity.objectId}')
    if ($ids) {
      if ($ids.cp) { $identityPrincipalIds += $ids.cp }
      if ($ids.kubelet) { $identityPrincipalIds += $ids.kubelet }
    }
  }
}
$identityPrincipalIds = @($identityPrincipalIds | Where-Object { $_ } | Select-Object -Unique)

Step "AKS clusters:            $($clusters.Count)"
Step "Connected clusters:      $($connected.Count)"
Step "Private DNS zones:       $($dnsZones.Count)"
Step "Managed identities:      $($identityPrincipalIds.Count)"
Step "Key vaults:              $($keyVaultNames.Count)"

# Role assignments held by those identities anywhere in the subscription. Anything scoped inside
# the group disappears with it; anything outside has to be deleted by hand or it becomes an
# orphaned assignment with an unresolvable principal.
$externalAssignments = @()
foreach ($principalId in $identityPrincipalIds) {
  $found = Invoke-AzJson @('role', 'assignment', 'list', '--assignee-object-id', $principalId,
    '--all', '--query', '[].{id:id,scope:scope,role:roleDefinitionName}')
  foreach ($a in @($found)) {
    if ($a.scope -notlike "$rgScope*") { $externalAssignments += $a }
  }
}
Step "Role assignments outside the group: $($externalAssignments.Count)"

# Private DNS zone links whose target VNet lives outside this group. The link object is a child of
# the zone, so it dies with the group, but listing them here makes the blast radius explicit and
# lets --dry-run show exactly which foreign networks are about to lose name resolution.
$externalLinks = @()
foreach ($zone in $dnsZones) {
  $links = Invoke-AzJson @('network', 'private-dns', 'link', 'vnet', 'list', '-g', $ResourceGroup,
    '-z', $zone, '--query', '[].{name:name,vnet:virtualNetwork.id}')
  foreach ($l in @($links)) {
    if ($l.vnet -notlike "$rgScope/*") { $externalLinks += [pscustomobject]@{ Zone = $zone; Name = $l.name; Vnet = $l.vnet } }
  }
}
Step "DNS links into foreign VNets:      $($externalLinks.Count)"

$policyAssignments = @()
if ($rg) {
  $policyAssignments = @(Invoke-AzJson @('policy', 'assignment', 'list', '--scope', $rgScope, '--query', '[].{name:name,id:id,def:policyDefinitionId}'))
}
Step "Policy assignments at group scope: $($policyAssignments.Count)"

$policyDefinitions = @()
if (-not $KeepPolicyDefinition) {
  $architectures = if ($Architecture) { @($Architecture) } else {
    @('aks-public', 'aks-public-authorized-ip', 'aks-private-link',
      'aks-private-vnet-integration', 'aks-automatic', 'aks-arc-local', 'arc-attach-existing')
  }
  foreach ($f in $architectures) {
    $def = Invoke-AzJson @('policy', 'definition', 'show', '-n', "$f-deny-public-ip", '--query', '{id:id,name:name}')
    if ($def) { $policyDefinitions += $def }
  }
}
Step "Custom policy definitions:         $($policyDefinitions.Count)"

# ================================================================================================
# 2. Confirmation
# ================================================================================================

if (-not $Force -and -not $DryRun) {
  Write-Host ''
  Write-Host "This permanently deletes resource group '$ResourceGroup' and everything above." -ForegroundColor Yellow
  $answer = Read-Host "Type the resource group name to confirm"
  if ($answer -ne $ResourceGroup) { Write-Host 'Aborted.'; exit 1 }
}

Write-Host ''
Write-Host 'Tearing down...' -ForegroundColor Cyan

# ================================================================================================
# 3. Arc agents, before the ARM resource disappears
#
# `az connectedk8s delete` also removes the agents from the cluster itself. Deleting only the ARM
# resource leaves azure-arc pods running and retrying against a resource that no longer exists.
# ================================================================================================

foreach ($cc in $connected) {
  Act "Disconnecting Arc cluster $($cc.name) (removes in-cluster agents)" {
    az connectedk8s delete -g $ResourceGroup -n $cc.name --yes --force 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Write-Host "    WARNING: connectedk8s delete failed. If your kubeconfig no longer points at that cluster, run 'az connectedk8s delete --force' from a host that can reach it, or uninstall the azure-arc Helm release manually." -ForegroundColor Yellow
      az resource delete --ids $cc.id 2>&1 | Out-Null
    }
  }
}

# ================================================================================================
# 4. AKS clusters, before the VNet
#
# The cluster owns NICs, load balancer rules and private link services that live in the node
# resource group but attach to subnets in this one. Deleting the group with the cluster still in it
# usually works but can strand the VNet in a Deleting state for a long time; removing the cluster
# first is consistently faster.
# ================================================================================================

foreach ($c in $clusters) {
  Act "Deleting AKS cluster $($c.name) (node group $($c.nodeResourceGroup))" {
    az aks delete -g $ResourceGroup -n $c.name --yes 2>&1 | Out-Null
  }
}

# ================================================================================================
# 5. Private DNS links into foreign VNets
# ================================================================================================

foreach ($l in $externalLinks) {
  Act "Unlinking $($l.Zone) from $(($l.Vnet -split '/')[-1])" {
    az network private-dns link vnet delete -g $ResourceGroup -z $l.Zone -n $l.Name --yes 2>&1 | Out-Null
  }
}

# ================================================================================================
# 6. Role assignments outside the group
# ================================================================================================

foreach ($a in $externalAssignments) {
  Act "Removing '$($a.role)' at $($a.scope)" {
    az role assignment delete --ids $a.id 2>&1 | Out-Null
  }
}

# ================================================================================================
# 7. Policy assignments, then the group, then the definition
#
# A policy definition cannot be deleted while an assignment still references it, and the
# assignments live at group scope, so the ordering here is not optional.
# ================================================================================================

foreach ($p in $policyAssignments) {
  Act "Removing policy assignment $($p.name)" {
    az policy assignment delete --name $p.name --scope $rgScope 2>&1 | Out-Null
  }
}

if ($rg -and -not $KeepResourceGroup) {
  Act "Deleting resource group $ResourceGroup (this blocks until it is gone)" {
    az group delete -n $ResourceGroup --yes 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host '    WARNING: resource group deletion reported a failure. Re-run this script; deletion is idempotent.' -ForegroundColor Yellow }
  }
}

foreach ($d in $policyDefinitions) {
  Act "Deleting policy definition $($d.name)" {
    az policy definition delete -n $d.name 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Host "    WARNING: could not delete $($d.name). It may still be assigned at another scope, or the caller lacks Resource Policy Contributor." -ForegroundColor Yellow }
  }
}

# ================================================================================================
# 8. Soft-deleted key vaults
#
# Purge protection is off by default in these templates specifically so this is possible; a soft-deleted vault
# otherwise holds its name for 90 days and a redeploy into the same names fails.
# ================================================================================================

if ($PurgeKeyVaults) {
  foreach ($kv in $keyVaultNames) {
    Act "Purging soft-deleted key vault $kv" {
      az keyvault purge -n $kv --location $vaultLocation 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) { Write-Host "    WARNING: purge failed for $kv. If purge protection is enabled it cannot be purged and the name stays reserved until retention expires." -ForegroundColor Yellow }
    }
  }
}
elseif ($keyVaultNames.Count -gt 0) {
  Write-Host ''
  Write-Host "  NOTE: $($keyVaultNames.Count) key vault(s) are now soft-deleted and keep their names reserved." -ForegroundColor Yellow
  Write-Host '  Re-run with -PurgeKeyVaults to remove them completely.' -ForegroundColor Yellow
}

Write-Host ''
if ($DryRun) {
  Write-Host "DRY RUN - $($actions.Count) action(s) would have been taken. Nothing was deleted." -ForegroundColor Cyan
}
else {
  Write-Host "TEARDOWN COMPLETE - $($actions.Count) action(s)." -ForegroundColor Green
}
Write-Host ''
