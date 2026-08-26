#Requires -Version 7.0
<#
.SYNOPSIS
  Deallocates ("pauses") the Azure Firewall in an architecture deployment and allocates it back, without
  destroying anything. Stops the firewall's hourly meter while keeping the policy, rules, public IP
  and every other resource in place.

.DESCRIPTION
  Azure Firewall has no portal stop button. The supported way to stop paying for it is to strip its
  IP configuration, which deallocates the running service but preserves the resource and its policy
  association. Reattaching the subnet and public IP starts it again. This script does that over ARM
  so it needs nothing but the Azure CLI - no Az PowerShell module.

  Two things make this more than a one-liner in this repo:

    1. The udr-firewall egress model points 0.0.0.0/0 at the firewall's PRIVATE IP. A deallocated
       firewall means that next hop is gone and every packet leaving the node subnet is black-holed.
       Nodes cannot pull images, refresh tokens or reach Azure Monitor. So by default this also
       stops the AKS clusters in the group, which is the larger saving anyway.

    2. Azure does not guarantee the same private IP when the firewall is allocated again. If it
       moves, the route table is silently stale and egress stays broken after resume. This script
       records the old address, compares it after allocation, and rewrites any matching route.

  The configuration needed to allocate the firewall again is stored on the firewall's own tags, so
  resume works from a different machine and survives losing this shell.

.EXAMPLE
  ./pause.ps1 -ResourceGroup rg-aks-private-link

.EXAMPLE
  ./pause.ps1 -ResourceGroup rg-aks-private-link -Resume

.EXAMPLE
  ./pause.ps1 -ResourceGroup rg-aks-private-link -FirewallOnly -DryRun
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [string] $ResourceGroup,

  [string] $SubscriptionId = '',

  [switch] $Resume,

  [switch] $FirewallOnly,

  [switch] $Force,

  [switch] $DryRun,

  [int] $TimeoutMinutes = 45
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/common.psm1') -Force

$apiVersion = '2025-05-01'
$tagPip = 'aksarchitectures-paused-pip'
$tagSubnet = 'aksarchitectures-paused-subnet'
$tagIpConfig = 'aksarchitectures-paused-ipconfig'
$tagPrivateIp = 'aksarchitectures-paused-privateip'
$tagPausedAt = 'aksarchitectures-paused-at'

Assert-AzureCli | Out-Null
if ($SubscriptionId) { $null = Invoke-AzJson @('account', 'set', '--subscription', $SubscriptionId) }
$subId = (Invoke-AzJson @('account', 'show')).id

function Get-Prop {
  param([object] $Object, [string] $Name)
  if ($null -eq $Object) { return $null }
  $p = $Object.PSObject.Properties[$Name]
  if ($null -eq $p) { return $null }
  return $p.Value
}

function Invoke-ArmGet {
  param([Parameter(Mandatory)][string] $Id)
  $out = az rest --method get --url "https://management.azure.com$($Id)?api-version=$apiVersion" -o json 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($out -join ''))) { return $null }
  return ($out -join "`n") | ConvertFrom-Json
}

function Invoke-ArmPut {
  param([Parameter(Mandatory)][string] $Id, [Parameter(Mandatory)][object] $Body)
  # The body goes through a temp file on purpose: the az.cmd shim on Windows mangles inline JSON.
  $tmp = [System.IO.Path]::GetTempFileName()
  try {
    ($Body | ConvertTo-Json -Depth 60) | Set-Content -LiteralPath $tmp -Encoding utf8
    $out = az rest --method put --url "https://management.azure.com$($Id)?api-version=$apiVersion" --body "@$tmp" -o json 2>&1
    if ($LASTEXITCODE -ne 0) { throw "ARM PUT failed for $Id`n$($out -join "`n")" }
  }
  finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

function Wait-Firewall {
  param(
    [Parameter(Mandatory)][string] $Id,
    [Parameter(Mandatory)][string] $Verb,
    [Parameter(Mandatory)][int] $Minutes
  )
  $deadline = (Get-Date).AddMinutes($Minutes)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 20
    $fw = Invoke-ArmGet -Id $Id
    if ($null -eq $fw) { continue }
    $state = Get-Prop $fw.properties 'provisioningState'
    if ($state -eq 'Succeeded') { Write-Host "    $Verb complete." -ForegroundColor Green; return $fw }
    if ($state -in @('Failed', 'Canceled')) { throw "Firewall $Verb ended in provisioningState '$state'." }
    Write-Host "    still $state..." -ForegroundColor DarkGray
  }
  throw "Timed out after $Minutes minutes waiting for the firewall to $Verb."
}

function ConvertTo-PutBody {
  param([Parameter(Mandatory)][object] $Firewall, [object[]] $IpConfigurations, [hashtable] $Tags)
  # Round-trip the whole GET response so SKU, zones, policy link and DNS settings survive untouched;
  # this mirrors what Set-AzFirewall does. Only the read-only fields are stripped.
  $body = $Firewall | ConvertTo-Json -Depth 60 | ConvertFrom-Json
  foreach ($n in @('etag', 'id', 'name', 'type')) { $body.PSObject.Properties.Remove($n) }
  foreach ($n in @('provisioningState', 'hubIPAddresses', 'ipGroups')) { $body.properties.PSObject.Properties.Remove($n) }
  $body.properties.ipConfigurations = $IpConfigurations
  $body | Add-Member -NotePropertyName tags -NotePropertyValue $Tags -Force
  return $body
}

function Get-FirewallTagMap {
  param([Parameter(Mandatory)][object] $Firewall)
  $t = @{}
  $existing = Get-Prop $Firewall 'tags'
  if ($existing) { foreach ($p in $existing.PSObject.Properties) { $t[$p.Name] = [string]$p.Value } }
  return $t
}

function Get-ClusterInventory {
  $clusters = Invoke-AzJson @('aks', 'list', '-g', $ResourceGroup)
  if (-not $clusters) { return @() }
  return @($clusters | ForEach-Object { [pscustomobject]@{ Name = $_.name; Power = (Get-Prop (Get-Prop $_ 'powerState') 'code') } })
}

$action = if ($Resume) { 'RESUME' } else { 'PAUSE' }

Write-Host ''
Write-Host "AKS ARCHITECTURES - $action" -ForegroundColor Cyan
Write-Host "Subscription:   $subId"
Write-Host "Resource group: $ResourceGroup"
Write-Host ''

$firewalls = Invoke-AzJson @('network', 'firewall', 'list', '-g', $ResourceGroup)
if (-not $firewalls) {
  Write-Host "No Azure Firewall in '$ResourceGroup'. Only the udr-firewall egress model deploys one." -ForegroundColor Yellow
  exit 0
}

$clusters = Get-ClusterInventory

Write-Host 'Plan:' -ForegroundColor Cyan
foreach ($fw in $firewalls) {
  $allocated = @(Get-Prop $fw 'ipConfigurations').Count -gt 0
  $state = if ($allocated) { 'allocated' } else { 'deallocated' }
  Write-Host "  firewall $($fw.name) is currently $state"
}
if (-not $FirewallOnly) {
  foreach ($c in $clusters) { Write-Host "  cluster  $($c.Name) is currently $($c.Power)" }
}
Write-Host ''

if (-not $Force -and -not $DryRun) {
  $warning = if ($Resume) {
    'Allocating the firewall restarts its hourly charge.'
  }
  else {
    'While the firewall is deallocated, 0.0.0.0/0 has no next hop and the node subnet has NO egress.'
  }
  Write-Host $warning -ForegroundColor Yellow
  $answer = Read-Host "Proceed with $action on '$ResourceGroup'? (y/N)"
  if ($answer -notmatch '^[Yy]') { Write-Host 'Aborted.'; exit 1 }
  Write-Host ''
}

# ================================================================================================
# Pause: stop the clusters first, so nodes are not left running without a route out.
# ================================================================================================

if (-not $Resume -and -not $FirewallOnly) {
  foreach ($c in $clusters) {
    if ($c.Power -eq 'Stopped') { Write-Host "  cluster $($c.Name) already stopped"; continue }
    if ($DryRun) { Write-Host "  [dry-run] stop cluster $($c.Name)" -ForegroundColor DarkGray; continue }
    Write-Host "  stopping cluster $($c.Name)..." -ForegroundColor Cyan
    az aks stop -g $ResourceGroup -n $c.Name -o none
    if ($LASTEXITCODE -ne 0) {
      Write-Host "    could not stop $($c.Name). Continuing; the firewall pause is independent." -ForegroundColor Yellow
    }
  }
}

foreach ($fw in $firewalls) {
  $id = $fw.id
  $current = Invoke-ArmGet -Id $id
  if ($null -eq $current) { throw "Could not read firewall '$($fw.name)' over ARM." }

  $ipConfigs = @(Get-Prop $current.properties 'ipConfigurations')
  $tags = Get-FirewallTagMap -Firewall $current

  if (-not $Resume) {
    # ------------------------------------------------------------------------------------------
    # Deallocate
    # ------------------------------------------------------------------------------------------
    if ($ipConfigs.Count -eq 0) {
      Write-Host "  firewall $($fw.name) is already deallocated, nothing to do." -ForegroundColor Yellow
      continue
    }

    $primary = $ipConfigs[0]
    $subnetId = Get-Prop (Get-Prop $primary.properties 'subnet') 'id'
    $pipId = Get-Prop (Get-Prop $primary.properties 'publicIPAddress') 'id'
    $privateIp = Get-Prop $primary.properties 'privateIPAddress'

    if (-not $subnetId -or -not $pipId) {
      throw "Firewall '$($fw.name)' has an IP configuration this script cannot reconstruct (no subnet or public IP). Deallocate it with Set-AzFirewall instead."
    }
    if ($ipConfigs.Count -gt 1) {
      Write-Host "  firewall $($fw.name) has $($ipConfigs.Count) IP configurations; only the primary is recorded for resume." -ForegroundColor Yellow
    }

    $tags[$tagSubnet] = $subnetId
    $tags[$tagPip] = $pipId
    $tags[$tagIpConfig] = [string](Get-Prop $primary 'name')
    $tags[$tagPrivateIp] = [string]$privateIp
    $tags[$tagPausedAt] = (Get-Date).ToUniversalTime().ToString('o')

    if ($DryRun) {
      Write-Host "  [dry-run] deallocate firewall $($fw.name) (private IP $privateIp)" -ForegroundColor DarkGray
      continue
    }

    Write-Host "  deallocating firewall $($fw.name) (was $privateIp)..." -ForegroundColor Cyan
    Invoke-ArmPut -Id $id -Body (ConvertTo-PutBody -Firewall $current -IpConfigurations @() -Tags $tags)
    Wait-Firewall -Id $id -Verb 'deallocate' -Minutes $TimeoutMinutes | Out-Null
  }
  else {
    # ------------------------------------------------------------------------------------------
    # Allocate
    # ------------------------------------------------------------------------------------------
    if ($ipConfigs.Count -gt 0) {
      Write-Host "  firewall $($fw.name) is already allocated, nothing to do." -ForegroundColor Yellow
      continue
    }
    if (-not $tags.ContainsKey($tagSubnet) -or -not $tags.ContainsKey($tagPip)) {
      throw "Firewall '$($fw.name)' is deallocated but has no '$tagSubnet'/'$tagPip' tags, so this script does not know what to reattach. Re-run scripts/deploy.ps1 for the architecture instead - it is idempotent and will allocate the firewall."
    }

    $oldIp = if ($tags.ContainsKey($tagPrivateIp)) { $tags[$tagPrivateIp] } else { '' }
    $ipConfigName = if ($tags.ContainsKey($tagIpConfig) -and $tags[$tagIpConfig]) { $tags[$tagIpConfig] } else { 'ipconfig' }

    if ($DryRun) {
      Write-Host "  [dry-run] allocate firewall $($fw.name) into $($tags[$tagSubnet])" -ForegroundColor DarkGray
      continue
    }

    $restored = @(
      [ordered]@{
        name       = $ipConfigName
        properties = [ordered]@{
          subnet          = @{ id = $tags[$tagSubnet] }
          publicIPAddress = @{ id = $tags[$tagPip] }
        }
      }
    )

    foreach ($n in @($tagSubnet, $tagPip, $tagIpConfig, $tagPrivateIp, $tagPausedAt)) { $tags.Remove($n) }

    Write-Host "  allocating firewall $($fw.name)... (this takes several minutes)" -ForegroundColor Cyan
    Invoke-ArmPut -Id $id -Body (ConvertTo-PutBody -Firewall $current -IpConfigurations $restored -Tags $tags)
    $after = Wait-Firewall -Id $id -Verb 'allocate' -Minutes $TimeoutMinutes

    $newIp = Get-Prop (@(Get-Prop $after.properties 'ipConfigurations')[0]).properties 'privateIPAddress'
    Write-Host "  firewall private IP: $newIp"

    # Azure does not promise the same private IP across a deallocate/allocate cycle, and a stale
    # 0.0.0.0/0 next hop black-holes the node subnet with no error anywhere.
    if ($oldIp -and $newIp -and $oldIp -ne $newIp) {
      Write-Host "  private IP moved $oldIp -> $newIp, reconciling route tables..." -ForegroundColor Yellow
      $tables = Invoke-AzJson @('network', 'route-table', 'list', '-g', $ResourceGroup)
      $fixed = 0
      foreach ($t in @($tables)) {
        foreach ($r in @(Get-Prop $t 'routes')) {
          if ((Get-Prop $r 'nextHopType') -eq 'VirtualAppliance' -and (Get-Prop $r 'nextHopIpAddress') -eq $oldIp) {
            az network route-table route update -g $ResourceGroup --route-table-name $t.name -n $r.name --next-hop-ip-address $newIp -o none
            if ($LASTEXITCODE -eq 0) { Write-Host "    $($t.name)/$($r.name) -> $newIp"; $fixed++ }
            else { Write-Host "    FAILED to update $($t.name)/$($r.name)" -ForegroundColor Red }
          }
        }
      }
      Write-Host "  updated $fixed route(s)."
    }
    elseif ($oldIp) {
      Write-Host '  private IP unchanged, route tables already correct.' -ForegroundColor Green
    }
  }
}

if ($Resume -and -not $FirewallOnly) {
  foreach ($c in $clusters) {
    if ($c.Power -eq 'Running') { Write-Host "  cluster $($c.Name) already running"; continue }
    if ($DryRun) { Write-Host "  [dry-run] start cluster $($c.Name)" -ForegroundColor DarkGray; continue }
    Write-Host "  starting cluster $($c.Name)..." -ForegroundColor Cyan
    az aks start -g $ResourceGroup -n $c.Name -o none
    if ($LASTEXITCODE -ne 0) { Write-Host "    could not start $($c.Name)." -ForegroundColor Yellow }
  }
}

Write-Host ''
if ($DryRun) {
  Write-Host 'Dry run only, nothing was changed.' -ForegroundColor DarkGray
}
elseif ($Resume) {
  Write-Host 'Resumed. Firewall billing has restarted.' -ForegroundColor Green
}
else {
  Write-Host 'Paused. Firewall compute is no longer billed; its public IP still is (a few dollars a month).' -ForegroundColor Green
  Write-Host "Resume with: ./scripts/pause.ps1 -ResourceGroup $ResourceGroup -Resume" -ForegroundColor Green
}
Write-Host ''
