<#
.SYNOPSIS
  Pre-flight network validation for an AKS deployment. Fails fast, with a specific reason.

.DESCRIPTION
  Runs before (or independently of) the cluster deployment and answers one question: can this
  network path actually support an AKS cluster? It checks, in order:

    1.  The architecture / network profile / egress combination is one the matrix allows.
    2.  Every parameter the chosen architecture requires is present.
    3.  Service CIDR and Pod CIDR do not collide with the VNet, its subnets, any peered VNet, or a
        caller-supplied list of on-premises ranges.
    4.  Subnets are large enough for the requested node and pod counts.
    5.  Regional vCPU quota can absorb the node pools at their maximum size.
    6.  A throwaway Linux VM in the intended node subnet can resolve and reach every endpoint AKS
        node bootstrap depends on, including NTP on UDP 123.
    7.  Network Watcher effective routes on that VM's NIC, flagging an unintended 0.0.0.0/0 next hop.
    8.  Network Watcher IP flow verify outbound on 443, reporting the NSG rule responsible for a deny.
    9.  For aks-private-link, that the API server private DNS zone is linked to the network the
        operator will run kubectl from.

  Emits a human-readable table and a machine-readable JSON document, and exits non-zero if any check
  failed. The throwaway VM is always deleted, including on Ctrl-C.

.PARAMETER ParamFile
  A .bicepparam file from infra/params. Its values are compiled with the CURRENT environment, so run
  this in the same shell that will run the deployment.

.PARAMETER NodeSubnetId
  Resource ID of the subnet the nodes will live in. Supply this to validate a bring-your-own subnet
  BEFORE any deployment exists. If omitted, the subnet is discovered from the resource group using
  the repo's naming convention, which only works once the network has been deployed at least once.

.PARAMETER ApiServerFqdn
  FQDN of an existing API server to probe on TCP 443. Without it the API server check degrades to a
  DNS-only test, because *.hcp.<region>.azmk8s.io has no connectable wildcard host.

.PARAMETER SkipLiveProbe
  Runs only the checks that need no VM. Static analysis and quota still apply.

.EXAMPLE
  ./preflight.ps1 -ParamFile ../infra/params/aks-private-link.bicepparam -ResourceGroup rg-aks-prod

.EXAMPLE
  ./preflight.ps1 -Architecture aks-private-link -NetworkProfile cni-overlay -Egress udr-firewall `
                  -ResourceGroup rg-hub -NodeSubnetId /subscriptions/.../subnets/snet-nodes
#>
[CmdletBinding()]
param(
  [string]$ParamFile,
  [ValidateSet('aks-public', 'aks-public-authorized-ip', 'aks-private-link', 'aks-private-vnet-integration', 'aks-automatic', 'aks-arc-local', 'arc-attach-existing', '')]
  [string]$Architecture = '',
  [string]$NetworkProfile = '',
  [string]$Egress = '',
  [string]$ResourceGroup,
  [string]$Location = '',
  [string]$NodeSubnetId = '',
  [string]$ApiServerFqdn = '',
  [string[]]$AdditionalFqdns = @(),
  [string[]]$OnPremisesCidrs = @(),
  [string]$ProbeVmSize = 'Standard_D2ds_v5',
  [string]$ProbeVmImage = 'Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest',
  [string]$SubscriptionId = '',
  [string]$JsonOutputPath = '',
  [switch]$SkipLiveProbe,
  [switch]$KeepProbeVm
)

# StrictMode is deliberately NOT enabled: this script walks Azure CLI JSON whose shape varies by
# resource state, and a missing property must become a finding in the table, never a crash.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

Import-Module (Join-Path $PSScriptRoot 'lib' 'common.psm1') -Force

$repoRoot = Get-RepoRoot
$results = [System.Collections.Generic.List[object]]::new()
$evidence = [ordered]@{}
$probeVmName = ''
$probeVmCreated = $false

function Add-Result {
  param(
    [string]$Id, [string]$Category, [string]$Status, [string]$Message,
    [string]$Remediation = '', $Evidence = $null
  )
  $results.Add((New-CheckResult -Id $Id -Category $Category -Status $Status -Message $Message -Remediation $Remediation -Evidence $Evidence))
}

function Remove-ProbeVm {
  if (-not $script:probeVmCreated -or [string]::IsNullOrWhiteSpace($script:probeVmName)) { return }
  if ($KeepProbeVm) {
    Write-Host "Leaving probe VM '$($script:probeVmName)' in place because -KeepProbeVm was set. Delete it with: az vm delete -g $ResourceGroup -n $($script:probeVmName) --yes --force-deletion true" -ForegroundColor Yellow
    return
  }
  Write-Host "Deleting probe VM '$($script:probeVmName)'..." -ForegroundColor DarkGray
  az vm delete -g $ResourceGroup -n $script:probeVmName --yes --force-deletion true 2>$null | Out-Null
  # The NIC and OS disk carry delete options, but a failed create can leave one behind.
  az network nic delete -g $ResourceGroup -n "$($script:probeVmName)-nic" 2>$null | Out-Null
  $script:probeVmCreated = $false
}

# The probe calls below merge stderr into stdout with 2>&1 so a failure can be reported verbatim as
# evidence. az writes WARNING and deprecation notices to stderr, so the JSON payload is frequently
# preceded by warning text and ConvertFrom-Json chokes on the first character. Take everything from
# the first '{' or '[' instead of assuming the output begins with JSON.
function Get-JsonPayload {
  param([object[]]$Output)
  $text = (@($Output) | ForEach-Object { [string]$_ }) -join "`n"
  $i = $text.IndexOfAny([char[]]@('{', '['))
  if ($i -lt 0) { return $null }
  return $text.Substring($i)
}

# ================================================================================================
# 0. Environment
# ================================================================================================

$account = Assert-AzureCli
if ($SubscriptionId) {
  az account set --subscription $SubscriptionId | Out-Null
  $account = az account show -o json | ConvertFrom-Json
}
$evidence['subscriptionId'] = $account.id
$evidence['subscriptionName'] = $account.name
$evidence['signedInAs'] = $account.user.name

Write-Host ''
Write-Host 'AKS ARCHITECTURES - PRE-FLIGHT NETWORK VALIDATION' -ForegroundColor Cyan
Write-Host "Subscription: $($account.name) ($($account.id))" -ForegroundColor DarkGray
Write-Host ''

$matrix = Get-ArchitectureMatrix -RepoRoot $repoRoot

# ================================================================================================
# 1. Resolve the intended configuration
# ================================================================================================

$params = @{}
if ($ParamFile) {
  $resolvedParamFile = (Resolve-Path -LiteralPath $ParamFile).Path
  Write-Host "Compiling $([IO.Path]::GetFileName($resolvedParamFile))..." -ForegroundColor DarkGray
  $params = Resolve-BicepParamFile -Path $resolvedParamFile
  $evidence['paramFile'] = $resolvedParamFile
}

function Pick([string]$explicit, [string]$paramPath, [string]$fallback) {
  if (-not [string]::IsNullOrWhiteSpace($explicit)) { return $explicit }
  $v = Get-ParamValue -Params $params -Path $paramPath -Default ''
  if (-not [string]::IsNullOrWhiteSpace([string]$v)) { return [string]$v }
  return $fallback
}

$Architecture = Pick $Architecture 'architecture' ''
$NetworkProfile = Pick $NetworkProfile 'networkProfile' 'cni-overlay'
$Egress = Pick $Egress 'egress' 'natgateway'
$Location = Pick $Location 'location' ''

if ([string]::IsNullOrWhiteSpace($Architecture)) {
  throw 'No architecture specified. Pass -Architecture or -ParamFile.'
}
if (-not $matrix.architectures.PSObject.Properties[$Architecture]) {
  throw "Unknown architecture '$Architecture'. Valid values: $($matrix.architectures.PSObject.Properties.Name -join ', ')"
}
$architectureDef = $matrix.architectures.$Architecture

# An architecture that never touches an Azure VNet has no Azure network path to validate.
if (-not $architectureDef.azureRegion) {
  $NetworkProfile = 'none'
  $Egress = 'none'
}

if ($ResourceGroup) {
  $rg = Invoke-AzJson @('group', 'show', '-n', $ResourceGroup)
  if ($rg -and [string]::IsNullOrWhiteSpace($Location)) { $Location = $rg.location }
}
if ([string]::IsNullOrWhiteSpace($Location)) { $Location = 'westus3' }

$evidence['architecture'] = $Architecture
$evidence['networkProfile'] = $NetworkProfile
$evidence['egress'] = $Egress
$evidence['location'] = $Location
$evidence['resourceGroup'] = $ResourceGroup

Write-Host "Architecture: $Architecture   Network: $NetworkProfile   Egress: $Egress   Region: $Location" -ForegroundColor DarkGray

# ================================================================================================
# 2. Static: matrix combination and required parameters
# ================================================================================================

$cat = 'configuration'

if ($architectureDef.networkProfiles -contains $NetworkProfile) {
  Add-Result -Id 'architecture.networkProfile' -Category $cat -Status 'pass' -Message "'$NetworkProfile' is supported by architecture '$Architecture'."
}
else {
  Add-Result -Id 'architecture.networkProfile' -Category $cat -Status 'fail' `
    -Message "Architecture '$Architecture' does not support network profile '$NetworkProfile'." `
    -Remediation "Choose one of: $($architectureDef.networkProfiles -join ', ')"
}

if ($architectureDef.egress -contains $Egress) {
  Add-Result -Id 'architecture.egress' -Category $cat -Status 'pass' -Message "Egress mode '$Egress' is supported by architecture '$Architecture'."
}
else {
  Add-Result -Id 'architecture.egress' -Category $cat -Status 'fail' `
    -Message "Architecture '$Architecture' does not support egress mode '$Egress'." `
    -Remediation "Choose one of: $($architectureDef.egress -join ', ')"
}

# Required parameters declared by the matrix, checked against the compiled parameter file.
$requiredParamPaths = @{
  authorizedIpRanges         = 'authorizedIpRanges'
  apiServerSubnetPrefix      = 'addressing.apiServerSubnetPrefix'
  podSubnetPrefix            = 'addressing.podSubnetPrefix'
  podCidr                    = 'addressing.podCidr'
  firewallSubnetPrefix       = 'addressing.firewallSubnetPrefix'
  customLocationId           = 'externals.customLocationId'
  logicalNetworkId           = 'externals.logicalNetworkId'
  existingConnectedClusterId = 'externals.existingConnectedClusterId'
  arcLocalSshPublicKey       = 'externals.arcLocalSshPublicKey'
}
$requiredHints = @{
  customLocationId           = 'az customlocation list -o table   then set AKS_CUSTOM_LOCATION_ID'
  logicalNetworkId           = 'az stack-hci-vm network lnet list -o table   then set AKS_LOGICAL_NETWORK_ID'
  existingConnectedClusterId = 'Run scripts/arc-onboard.ps1 first, then set AKS_EXISTING_CONNECTED_CLUSTER_ID'
  arcLocalSshPublicKey       = 'ssh-keygen -t rsa -b 4096   then set AKS_ARC_SSH_PUBLIC_KEY to the contents of the .pub file'
  authorizedIpRanges         = 'Set AKS_AUTHORIZED_IP_RANGES to a comma-separated list of CIDRs, e.g. 203.0.113.0/24'
}

foreach ($req in @($architectureDef.requiredParams)) {
  if (-not $ParamFile) {
    Add-Result -Id "required.$req" -Category $cat -Status 'skip' -Message "Cannot verify required parameter '$req' without -ParamFile."
    continue
  }
  $path = if ($requiredParamPaths.ContainsKey($req)) { $requiredParamPaths[$req] } else { $req }
  $val = Get-ParamValue -Params $params -Path $path -Default ''
  $isEmpty = ($null -eq $val) -or ($val -is [string] -and [string]::IsNullOrWhiteSpace($val)) -or ($val -is [array] -and $val.Count -eq 0)
  if ($isEmpty) {
    Add-Result -Id "required.$req" -Category $cat -Status 'fail' `
      -Message "Architecture '$Architecture' requires '$req' but it is empty." `
      -Remediation $(if ($requiredHints.ContainsKey($req)) { $requiredHints[$req] } else { "Set '$path' in $([IO.Path]::GetFileName($ParamFile))." })
  }
  else {
    Add-Result -Id "required.$req" -Category $cat -Status 'pass' -Message "Required parameter '$req' is present."
  }
}

# The API server subnet is a consequence of the architecture, not a free choice: vnetIntegration cannot
# delegate a subnet that was never sized.
if ($architectureDef.apiServerAccess -eq 'vnetIntegration' -and $ParamFile) {
  $apiPrefix = [string](Get-ParamValue -Params $params -Path 'addressing.apiServerSubnetPrefix' -Default '')
  if ([string]::IsNullOrWhiteSpace($apiPrefix)) {
    Add-Result -Id 'required.apiServerSubnetPrefix' -Category $cat -Status 'fail' `
      -Message 'API Server VNet Integration needs a dedicated, delegated API server subnet.' `
      -Remediation 'Set addressing.apiServerSubnetPrefix to a /28 or larger that is inside the VNet address space.'
  }
}

# The Automatic SKU validates the system pool against its own recommended values and rejects the
# cluster with a single opaque AKSAutomaticSKUFeatureValidationError listing everything at once,
# 10+ minutes in. These are cheap to check up front.
if ($architectureDef.skuName -eq 'Automatic' -and $ParamFile) {
  $autoZones = @(Get-ParamValue -Params $params -Path 'systemNodePool.zones' -Default @() | ForEach-Object { [string]$_ })
  $missingZones = @('1', '2', '3') | Where-Object { $autoZones -notcontains $_ }
  if ($missingZones.Count -gt 0) {
    Add-Result -Id 'automatic.zones' -Category $cat -Status 'fail' `
      -Message "The Automatic SKU requires availability zones 1, 2 and 3 on the system pool; this pool requests $(if ($autoZones.Count) { $autoZones -join ', ' } else { 'none' })." `
      -Remediation 'Set systemNodePool.zones to [1, 2, 3]. Automatic is only supported in regions offering three zones, so this is not a free choice.'
  }
  else {
    Add-Result -Id 'automatic.zones' -Category $cat -Status 'pass' -Message 'System pool requests all three availability zones, as the Automatic SKU requires.'
  }

  $autoDisk = [string](Get-ParamValue -Params $params -Path 'systemNodePool.osDiskType' -Default '')
  if ($autoDisk -ne 'Ephemeral') {
    Add-Result -Id 'automatic.ephemeralOsDisk' -Category $cat -Status 'fail' `
      -Message "The Automatic SKU requires ephemeral OS disks on the system pool; osDiskType is '$autoDisk'." `
      -Remediation 'Set systemNodePool.osDiskType to Ephemeral, and make sure the VM size has a cache or NVMe disk at least as large as osDiskSizeGB.'
  }
  else {
    Add-Result -Id 'automatic.ephemeralOsDisk' -Category $cat -Status 'pass' -Message 'System pool uses ephemeral OS disks, as the Automatic SKU requires.'
  }

  if ([string]::IsNullOrWhiteSpace([string](Get-ParamValue -Params $params -Path 'addressing.systemNodeSubnetPrefix' -Default ''))) {
    Add-Result -Id 'automatic.systemNodeSubnet' -Category $cat -Status 'fail' `
      -Message 'The Automatic SKU always runs a managed system node pool, and without a subnet of its own it is created in an AKS-managed VNet.' `
      -Remediation 'Set addressing.systemNodeSubnetPrefix to a /26 or larger inside the VNet. Otherwise AKS rejects every egress mode except the managed load balancer.'
  }
  else {
    Add-Result -Id 'automatic.systemNodeSubnet' -Category $cat -Status 'pass' -Message 'A subnet is reserved for the Automatic managed system node pool.'
  }
}

# Immutability reminder. Not a failure - a deliberate, loud notice, because these cannot be changed
# after creation without rebuilding the cluster.
$immutableSummary = ($matrix.immutable.PSObject.Properties | ForEach-Object { $_.Name }) -join ', '
Add-Result -Id 'config.immutable' -Category $cat -Status 'warn' `
  -Message "Immutable after creation: $immutableSummary." `
  -Remediation 'Confirm these are correct now. Changing any of them later requires a new cluster.'

# ================================================================================================
# 3. Static: address plan
# ================================================================================================

$cat = 'addressing'
$addressing = if ($ParamFile) { Get-ParamValue -Params $params -Path 'addressing' -Default $null } else { $null }

function Get-Addr([string]$name) {
  if ($null -eq $addressing) { return '' }
  $p = $addressing.PSObject.Properties[$name]
  if ($null -eq $p -or $null -eq $p.Value) { return '' }
  return [string]$p.Value
}

if ($architectureDef.azureRegion -and $null -ne $addressing) {
  $vnetSpace = Get-Addr 'vnetAddressSpace'
  $serviceCidr = Get-Addr 'serviceCidr'
  $podCidr = Get-Addr 'podCidr'
  $dnsServiceIp = Get-Addr 'dnsServiceIp'

  $subnetPrefixes = [ordered]@{}
  foreach ($n in @('nodeSubnetPrefix', 'systemNodeSubnetPrefix', 'podSubnetPrefix', 'apiServerSubnetPrefix', 'firewallSubnetPrefix', 'bastionSubnetPrefix', 'privateEndpointSubnetPrefix', 'dnsResolverInboundPrefix', 'dnsResolverOutboundPrefix')) {
    $v = Get-Addr $n
    if ($v) { $subnetPrefixes[$n] = $v }
  }

  # 3a. Every declared CIDR must parse.
  $allCidrs = @{ vnetAddressSpace = $vnetSpace; serviceCidr = $serviceCidr; podCidr = $podCidr }
  foreach ($k in $subnetPrefixes.Keys) { $allCidrs[$k] = $subnetPrefixes[$k] }
  $malformed = @()
  foreach ($kv in $allCidrs.GetEnumerator()) {
    if (-not $kv.Value) { continue }
    try { Get-CidrRange $kv.Value | Out-Null } catch { $malformed += "$($kv.Key)='$($kv.Value)' ($($_.Exception.Message))" }
  }
  if ($malformed.Count -gt 0) {
    Add-Result -Id 'cidr.parse' -Category $cat -Status 'fail' -Message "Malformed CIDR values: $($malformed -join '; ')" -Remediation 'Use a.b.c.d/nn IPv4 notation.'
  }
  else {
    Add-Result -Id 'cidr.parse' -Category $cat -Status 'pass' -Message 'All declared address ranges parse as valid IPv4 CIDRs.'

    # 3b. Subnets must sit inside the VNet and must not overlap each other.
    $outside = @()
    foreach ($kv in $subnetPrefixes.GetEnumerator()) {
      if (-not (Test-CidrContains -Outer $vnetSpace -Inner $kv.Value)) { $outside += "$($kv.Key)=$($kv.Value)" }
    }
    if ($outside.Count -gt 0) {
      Add-Result -Id 'cidr.subnetsInVnet' -Category $cat -Status 'fail' `
        -Message "Subnets fall outside the VNet address space ${vnetSpace}: $($outside -join ', ')" `
        -Remediation 'Re-plan the subnets so each is a strict subset of vnetAddressSpace, or widen the VNet.'
    }
    else {
      Add-Result -Id 'cidr.subnetsInVnet' -Category $cat -Status 'pass' -Message "All $($subnetPrefixes.Count) subnets are inside $vnetSpace."
    }

    $names = @($subnetPrefixes.Keys)
    $collisions = @()
    for ($i = 0; $i -lt $names.Count; $i++) {
      for ($j = $i + 1; $j -lt $names.Count; $j++) {
        if (Test-CidrOverlap $subnetPrefixes[$names[$i]] $subnetPrefixes[$names[$j]]) {
          $collisions += "$($names[$i]) ($($subnetPrefixes[$names[$i]])) <-> $($names[$j]) ($($subnetPrefixes[$names[$j]]))"
        }
      }
    }
    if ($collisions.Count -gt 0) {
      Add-Result -Id 'cidr.subnetOverlap' -Category $cat -Status 'fail' -Message "Subnets overlap each other: $($collisions -join '; ')" -Remediation 'Give every subnet a disjoint range.'
    }
    else {
      Add-Result -Id 'cidr.subnetOverlap' -Category $cat -Status 'pass' -Message 'No subnet-to-subnet overlaps.'
    }

    # 3c. Service CIDR is routed inside the cluster only. Overlapping the VNet, a peer, or an
    #     on-premises range silently black-holes traffic to whichever side loses the route.
    $conflictSources = [ordered]@{ "VNet address space" = @($vnetSpace) }

    $onPrem = @()
    if ($OnPremisesCidrs.Count -gt 0) { $onPrem = $OnPremisesCidrs }
    elseif ($null -ne $addressing -and $addressing.PSObject.Properties['onPremisesCidrs']) { $onPrem = @($addressing.onPremisesCidrs) }
    if ($onPrem.Count -gt 0) { $conflictSources['on-premises ranges'] = $onPrem }

    # Peered VNets are discovered live: an address plan that looks fine on paper routinely collides
    # with a hub that someone else owns.
    $peerRanges = @()
    if ($ResourceGroup) {
      $vnets = Invoke-AzJson @('network', 'vnet', 'list', '-g', $ResourceGroup)
      if ($vnets) {
        foreach ($v in @($vnets)) {
          $peerings = Invoke-AzJson @('network', 'vnet', 'peering', 'list', '-g', $ResourceGroup, '--vnet-name', $v.name)
          if ($peerings) {
            foreach ($p in @($peerings)) {
              if ($p.PSObject.Properties['remoteAddressSpace'] -and $p.remoteAddressSpace -and $p.remoteAddressSpace.addressPrefixes) {
                $peerRanges += @($p.remoteAddressSpace.addressPrefixes)
              }
            }
          }
        }
      }
    }
    if ($peerRanges.Count -gt 0) {
      $conflictSources['peered VNet ranges'] = ($peerRanges | Select-Object -Unique)
      $evidence['peeredRanges'] = $conflictSources['peered VNet ranges']
    }

    foreach ($clusterCidrName in @('serviceCidr', 'podCidr')) {
      $value = if ($clusterCidrName -eq 'serviceCidr') { $serviceCidr } else { $podCidr }
      if (-not $value) { continue }
      $hits = @()
      foreach ($src in $conflictSources.GetEnumerator()) {
        foreach ($range in $src.Value) {
          if (-not $range) { continue }
          if (Test-CidrOverlap $value $range) { $hits += "$range ($($src.Key))" }
        }
      }
      if ($hits.Count -gt 0) {
        Add-Result -Id "cidr.$clusterCidrName" -Category $cat -Status 'fail' `
          -Message "$clusterCidrName $value overlaps: $($hits -join ', ')" `
          -Remediation "Move $clusterCidrName to a range used nowhere else in the routed estate. serviceCidr is immutable after cluster creation." `
          -Evidence $hits
      }
      else {
        Add-Result -Id "cidr.$clusterCidrName" -Category $cat -Status 'pass' -Message "$clusterCidrName $value does not overlap the VNet, its peers, or on-premises ranges."
      }
    }

    if ($serviceCidr -and $podCidr -and (Test-CidrOverlap $serviceCidr $podCidr)) {
      Add-Result -Id 'cidr.serviceVsPod' -Category $cat -Status 'fail' -Message "serviceCidr $serviceCidr overlaps podCidr $podCidr." -Remediation 'These are two independent routing domains inside the cluster and must be disjoint.'
    }

    # 3d. dnsServiceIp must sit inside the service CIDR and must not be the network address.
    if ($serviceCidr -and $dnsServiceIp) {
      $svc = Get-CidrRange $serviceCidr
      if (-not (Test-IpInCidr -Ip $dnsServiceIp -Cidr $serviceCidr)) {
        Add-Result -Id 'cidr.dnsServiceIp' -Category $cat -Status 'fail' -Message "dnsServiceIp $dnsServiceIp is not inside serviceCidr $serviceCidr." -Remediation "Use an address within $serviceCidr, conventionally the tenth, e.g. $(Convert-UInt32ToIp ($svc.Start + 10))."
      }
      elseif ((Get-CidrRange "$dnsServiceIp/32").Start -eq $svc.Start) {
        Add-Result -Id 'cidr.dnsServiceIp' -Category $cat -Status 'fail' -Message "dnsServiceIp $dnsServiceIp is the network address of $serviceCidr." -Remediation "Use $(Convert-UInt32ToIp ($svc.Start + 10)) instead."
      }
      else {
        Add-Result -Id 'cidr.dnsServiceIp' -Category $cat -Status 'pass' -Message "dnsServiceIp $dnsServiceIp is a valid address inside $serviceCidr."
      }
    }

    # 3e. Fixed minimum sizes Azure enforces on named subnets.
    $minima = @{ firewallSubnetPrefix = 26; bastionSubnetPrefix = 26; systemNodeSubnetPrefix = 26; apiServerSubnetPrefix = 28; dnsResolverInboundPrefix = 28; dnsResolverOutboundPrefix = 28 }
    $tooSmall = @()
    foreach ($kv in $minima.GetEnumerator()) {
      if (-not $subnetPrefixes.Contains($kv.Key)) { continue }
      $p = (Get-CidrRange $subnetPrefixes[$kv.Key]).Prefix
      if ($p -gt $kv.Value) { $tooSmall += "$($kv.Key)=$($subnetPrefixes[$kv.Key]) needs at least a /$($kv.Value)" }
    }
    if ($tooSmall.Count -gt 0) {
      Add-Result -Id 'cidr.minimumSizes' -Category $cat -Status 'fail' -Message ($tooSmall -join '; ') -Remediation 'Azure rejects these subnets outright at create time; widen them now.'
    }
    else {
      Add-Result -Id 'cidr.minimumSizes' -Category $cat -Status 'pass' -Message 'AzureFirewallSubnet, AzureBastionSubnet, API server and DNS resolver subnets all meet their minimum sizes.'
    }

    # 3f. Capacity: nodes, and - on a pod subnet - pods.
    $sysMax = [int](Get-ParamValue -Params $params -Path 'systemNodePool.maxCount' -Default 3)
    $usrMax = 0
    if ([bool](Get-ParamValue -Params $params -Path 'deployUserNodePool' -Default $false)) {
      $usrMax = [int](Get-ParamValue -Params $params -Path 'userNodePool.maxCount' -Default 3)
    }
    $totalMaxNodes = $sysMax + $usrMax
    $maxPods = [int](Get-ParamValue -Params $params -Path 'maxPodsPerNode' -Default $(if ($NetworkProfile -eq 'cni-podsubnet') { 110 } else { 250 }))

    if ($subnetPrefixes.Contains('nodeSubnetPrefix')) {
      $nodeUsable = (Get-CidrRange $subnetPrefixes['nodeSubnetPrefix']).Size - 5   # Azure reserves 5 per subnet
      # Upgrades surge by 33%, and a node subnet that cannot absorb the surge blocks every upgrade.
      $needed = [math]::Ceiling($totalMaxNodes * 1.34) + 1
      if ($nodeUsable -lt $needed) {
        Add-Result -Id 'capacity.nodeSubnet' -Category $cat -Status 'fail' `
          -Message "Node subnet $($subnetPrefixes['nodeSubnetPrefix']) has $nodeUsable usable IPs but needs about $needed for $totalMaxNodes nodes plus 33% upgrade surge." `
          -Remediation 'Widen nodeSubnetPrefix. Subnet size is immutable once resources are attached.'
      }
      else {
        Add-Result -Id 'capacity.nodeSubnet' -Category $cat -Status 'pass' -Message "Node subnet has $nodeUsable usable IPs for a maximum of $totalMaxNodes nodes plus upgrade surge."
      }
    }

    if ($NetworkProfile -eq 'cni-podsubnet' -and $subnetPrefixes.Contains('podSubnetPrefix')) {
      $podUsable = (Get-CidrRange $subnetPrefixes['podSubnetPrefix']).Size - 5
      $podNeeded = $totalMaxNodes * $maxPods
      if ($podUsable -lt $podNeeded) {
        Add-Result -Id 'capacity.podSubnet' -Category $cat -Status 'fail' `
          -Message "Pod subnet $($subnetPrefixes['podSubnetPrefix']) has $podUsable usable IPs but $totalMaxNodes nodes x $maxPods pods needs $podNeeded." `
          -Remediation 'Widen podSubnetPrefix, lower maxPodsPerNode, or switch networkProfile to cni-overlay which does not consume VNet addresses for pods.'
      }
      else {
        Add-Result -Id 'capacity.podSubnet' -Category $cat -Status 'pass' -Message "Pod subnet has $podUsable usable IPs for $podNeeded pod addresses."
      }
    }
    elseif ($NetworkProfile -like 'cni-overlay*') {
      $overlayUsable = if ($podCidr) { (Get-CidrRange $podCidr).Size } else { 0 }
      $overlayNeeded = $totalMaxNodes * $maxPods
      if ($podCidr -and $overlayUsable -lt $overlayNeeded) {
        Add-Result -Id 'capacity.podCidr' -Category $cat -Status 'fail' -Message "podCidr $podCidr holds $overlayUsable addresses but $totalMaxNodes nodes x $maxPods pods needs $overlayNeeded." -Remediation 'Widen podCidr. It is overlay space and does not consume VNet addresses, so /16 is a safe default.'
      }
      elseif ($podCidr) {
        Add-Result -Id 'capacity.podCidr' -Category $cat -Status 'pass' -Message "Overlay podCidr $podCidr holds $overlayUsable addresses for $overlayNeeded pods."
      }
    }
  }
}
else {
  # Two different reasons land here and they are not interchangeable. Saying "no VNet" when the
  # real reason is "you did not tell me the address plan" reads as reassurance when it is a gap.
  if (-not $architectureDef.azureRegion) {
    Add-Result -Id 'cidr.parse' -Category $cat -Status 'skip' -Message "Architecture '$Architecture' does not create an Azure VNet, so there is no Azure address plan to validate."
  }
  else {
    Add-Result -Id 'cidr.parse' -Category $cat -Status 'skip' `
      -Message 'No -ParamFile was supplied, so the address plan was never read and NOTHING about it was validated.' `
      -Remediation "Re-run with -ParamFile infra/params/$Architecture.bicepparam to check CIDR parsing, overlap, subnet sizing and Service CIDR conflicts."
  }
}

# ================================================================================================
# 4. Quota
# ================================================================================================

$cat = 'quota'

# Provider registration is a property of the subscription, not of the parameter file, so it is
# checked whenever a cluster is in scope. It used to sit inside the vCPU branch below, which meant
# an architecture that does not deploy into an Azure region never checked it at all.
if ($architectureDef.createsCluster) {
  $prov = Invoke-AzJson @('provider', 'show', '-n', 'Microsoft.ContainerService')
  if ($prov -and $prov.registrationState -eq 'Registered') {
    Add-Result -Id 'quota.provider' -Category $cat -Status 'pass' -Message 'Microsoft.ContainerService is registered on this subscription.'
  }
  else {
    Add-Result -Id 'quota.provider' -Category $cat -Status 'fail' -Message 'Microsoft.ContainerService is not registered.' -Remediation 'az provider register -n Microsoft.ContainerService --wait'
  }
}

if ($architectureDef.createsCluster -and $architectureDef.azureRegion) {
  $skus = @()
  if ($ParamFile) {
    $skus += [string](Get-ParamValue -Params $params -Path 'systemNodePool.vmSize' -Default '')
    if ([bool](Get-ParamValue -Params $params -Path 'deployUserNodePool' -Default $false)) {
      $skus += [string](Get-ParamValue -Params $params -Path 'userNodePool.vmSize' -Default '')
    }
  }
  $skus = @($skus | Where-Object { $_ -and $_ -ne 'n/a' } | Select-Object -Unique)

  if ($skus.Count -eq 0) {
    Add-Result -Id 'quota.vcpu' -Category $cat -Status 'skip' -Message 'No node SKU available to check (supply -ParamFile).'
  }
  else {
    $usage = Invoke-AzJson @('vm', 'list-usage', '-l', $Location)
    if (-not $usage) {
      Add-Result -Id 'quota.vcpu' -Category $cat -Status 'warn' -Message "Could not read vCPU usage in $Location." -Remediation "az vm list-usage -l $Location -o table"
    }
    else {
      foreach ($sku in $skus) {
        # The Resource SKUs API is not self-consistent: the same query omits the restrictions array
        # on a minority of calls, so a single call makes the zone-availability verdict flap between
        # warn and silent. --all plus a union over up to three samples makes it stable, and a
        # preflight that sometimes stays quiet about a real capacity constraint is worse than no
        # preflight at all.
        $match = $null
        $restrictions = @()
        foreach ($attempt in 1..3) {
          $skuInfo = Invoke-AzJson @('vm', 'list-skus', '-l', $Location, '--size', $sku, '--resource-type', 'virtualMachines', '--all')
          if (-not $skuInfo) { continue }
          $hit = @($skuInfo | Where-Object { $_.name -eq $sku }) | Select-Object -First 1
          if (-not $hit) { continue }
          $match = $hit
          if ($hit.PSObject.Properties['restrictions'] -and $null -ne $hit.restrictions) {
            foreach ($r in @($hit.restrictions)) {
              $key = '{0}|{1}|{2}' -f $r.type, $r.reasonCode, (@($r.restrictionInfo.zones) -join ',')
              if (-not ($restrictions | Where-Object { $_.Key -eq $key })) {
                $restrictions += [pscustomobject]@{ Key = $key; Value = $r }
              }
            }
          }
          if ($restrictions.Count -gt 0) { break }
        }
        if (-not $match) {
          Add-Result -Id "quota.sku.$sku" -Category $cat -Status 'fail' -Message "VM size $sku is not offered in $Location." -Remediation "az vm list-skus -l $Location --resource-type virtualMachines --all -o table" 
          continue
        }

        # Restrictions come in two architectures that demand different responses: a Location restriction
        # means the SKU is unusable here at all, a Zone restriction only rules out some zones - and
        # that only matters if the node pool actually asks for those zones.
        $requestedZones = @()
        if ($ParamFile) { $requestedZones = @(Get-ParamValue -Params $params -Path 'systemNodePool.zones' -Default @()) }

        foreach ($entry in $restrictions) {
          $r = $entry.Value
          $reason = if ($r.PSObject.Properties['reasonCode']) { $r.reasonCode } else { 'Restricted' }
          $rType = if ($r.PSObject.Properties['type']) { $r.type } else { 'Location' }
          $rZones = @()
          if ($r.PSObject.Properties['restrictionInfo'] -and $r.restrictionInfo -and $r.restrictionInfo.PSObject.Properties['zones']) {
            $rZones = @($r.restrictionInfo.zones)
          }

          if ($rType -eq 'Zone' -and $rZones.Count -gt 0) {
            $blocked = @($requestedZones | Where-Object { $rZones -contains [string]$_ })
            if ($blocked.Count -gt 0 -and $blocked.Count -ge $requestedZones.Count) {
              Add-Result -Id "quota.restriction.$sku" -Category $cat -Status 'fail' `
                -Message "$sku is unavailable ($reason) in every zone the node pool requests ($($requestedZones -join ', ')) in $Location." `
                -Remediation "Pick another SKU, another region, or set zones to one of the available zones. az vm list-skus -l $Location --size $sku --all --query '[0].restrictions'"
            }
            elseif ($blocked.Count -gt 0) {
              Add-Result -Id "quota.restriction.$sku" -Category $cat -Status 'warn' `
                -Message "$sku is unavailable ($reason) in zone(s) $($blocked -join ', ') of $Location; the remaining requested zones are usable." `
                -Remediation 'Zone-imbalanced node pools scale unevenly. Consider dropping the restricted zone from the node pool definition.'
            }
            else {
              Add-Result -Id "quota.restriction.$sku" -Category $cat -Status 'pass' -Message "$sku has a zone restriction in $Location ($($rZones -join ', ')) but the node pool does not request those zones."
            }
          }
          else {
            Add-Result -Id "quota.restriction.$sku" -Category $cat -Status 'fail' `
              -Message "$sku is not available to this subscription in ${Location}: $reason." `
              -Remediation "Choose another SKU or region, or raise a support request to lift the restriction. az vm list-skus -l $Location --resource-type virtualMachines -o table"
          }
        }

        $vcpuCap = @($match.capabilities | Where-Object { $_.name -eq 'vCPUs' }) | Select-Object -First 1
        $vcpuPerNode = if ($vcpuCap) { [int]$vcpuCap.value } else { 0 }

        $nodes = 0
        if ($ParamFile) {
          if ([string](Get-ParamValue -Params $params -Path 'systemNodePool.vmSize' -Default '') -eq $sku) { $nodes += [int](Get-ParamValue -Params $params -Path 'systemNodePool.maxCount' -Default 3) }
          if ([bool](Get-ParamValue -Params $params -Path 'deployUserNodePool' -Default $false) -and [string](Get-ParamValue -Params $params -Path 'userNodePool.vmSize' -Default '') -eq $sku) {
            $nodes += [int](Get-ParamValue -Params $params -Path 'userNodePool.maxCount' -Default 3)
          }
        }
        $required = $vcpuPerNode * $nodes
        $requiredWithSurge = [math]::Ceiling($required * 1.34)

        $famUsage = @($usage | Where-Object { $_.name.value -eq $match.family }) | Select-Object -First 1
        $totalUsage = @($usage | Where-Object { $_.name.value -eq 'cores' }) | Select-Object -First 1

        foreach ($u in @(@{ n = "family $($match.family)"; u = $famUsage }, @{ n = 'regional total cores'; u = $totalUsage })) {
          if (-not $u.u) { continue }
          $headroom = [int]$u.u.limit - [int]$u.u.currentValue
          $id = "quota.$(($u.n -replace '[^a-zA-Z0-9]','_'))"
          if ($headroom -lt $required) {
            Add-Result -Id $id -Category $cat -Status 'fail' `
              -Message "$($u.n): only $headroom vCPUs available, but $sku x $nodes nodes needs $required." `
              -Remediation "Lower maxCount, choose a smaller SKU, or request an increase. Portal: Subscription > Usage + quotas > $($u.n)."
          }
          elseif ($headroom -lt $requiredWithSurge) {
            # A cluster that fits at rest but not during a 33% surge cannot be upgraded, and node
            # image upgrades are automatic. This is a real operational trap, not a nicety.
            Add-Result -Id $id -Category $cat -Status 'warn' `
              -Message "$($u.n): $headroom vCPUs available. The cluster fits at $required vCPUs but a 33% upgrade surge needs $requiredWithSurge, so upgrades will stall at maximum scale." `
              -Remediation "Raise the quota to at least $requiredWithSurge vCPUs, or lower maxCount."
          }
          else {
            Add-Result -Id $id -Category $cat -Status 'pass' -Message "$($u.n): $headroom vCPUs available, $required required ($requiredWithSurge including upgrade surge)."
          }
        }
      }
    }
  }

}
else {
  Add-Result -Id 'quota.vcpu' -Category $cat -Status 'skip' -Message "Architecture '$Architecture' does not create Azure compute."
}

# ================================================================================================
# 5-8. Live path validation from inside the node subnet
# ================================================================================================

$cat = 'network-path'
$liveSubnetId = $NodeSubnetId

if ($architectureDef.azureRegion -and -not $SkipLiveProbe -and [string]::IsNullOrWhiteSpace($liveSubnetId) -and $ResourceGroup -and $ParamFile) {
  # Discover the node subnet from a previous deployment using the repo's naming convention.
  $geo = Get-GeoCode -Location $Location
  $vnetName = ('vnet-{0}-{1}-{2}-{3}' -f (Get-ParamValue -Params $params -Path 'customer' -Default 'contoso'), (Get-ParamValue -Params $params -Path 'environment' -Default 'dev'), $geo, (Get-ParamValue -Params $params -Path 'instance' -Default '01')).ToLower()
  $subnet = Invoke-AzJson @('network', 'vnet', 'subnet', 'show', '-g', $ResourceGroup, '--vnet-name', $vnetName, '-n', 'snet-nodes')
  if ($subnet) {
    $liveSubnetId = $subnet.id
    Write-Host "Discovered node subnet from a previous deployment: $vnetName/snet-nodes" -ForegroundColor DarkGray
  }
}

if (-not $architectureDef.azureRegion) {
  Add-Result -Id 'path.probe' -Category $cat -Status 'skip' -Message "Architecture '$Architecture' has no Azure node subnet. Validate the site network with scripts/arc-onboard.ps1 -WhatIf and the Arc connectivity docs."
}
elseif ($SkipLiveProbe) {
  Add-Result -Id 'path.probe' -Category $cat -Status 'skip' -Message '-SkipLiveProbe was set; no VM was deployed and the real network path was NOT tested.'
}
elseif (-not $ResourceGroup) {
  Add-Result -Id 'path.probe' -Category $cat -Status 'skip' -Message 'No -ResourceGroup supplied, so no probe VM could be created.'
}
elseif ([string]::IsNullOrWhiteSpace($liveSubnetId)) {
  Add-Result -Id 'path.probe' -Category $cat -Status 'skip' `
    -Message 'The node subnet does not exist yet, so the live network path could not be tested.' `
    -Remediation 'For a bring-your-own network, pass -NodeSubnetId <subnet resource id>. For a greenfield build, re-run preflight after the first deployment to validate the path that was created.'
}
else {
  try {
    $probeVmName = "vm-preflight-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
    $evidence['probeVmName'] = $probeVmName
    $evidence['probeSubnetId'] = $liveSubnetId

    Write-Host "Creating probe VM $probeVmName in the node subnet (this takes about a minute)..." -ForegroundColor DarkGray
    # '--public-ip-address ""' is how the CLI is told to create no public IP. On Windows the `az`
    # entry point is a .cmd shim and cmd.exe strips a genuinely empty argument, so az sees the flag
    # with no value and fails with "expected one argument". Passing the two literal quote characters
    # survives the shim and arrives as an empty string. On other platforms there is no shim, so the
    # literal quotes would be taken as a resource NAME - send a real empty string there.
    $emptyArg = if ($env:OS -eq 'Windows_NT') { '""' } else { '' }
    $createOut = az vm create -g $ResourceGroup -n $probeVmName `
      --image $ProbeVmImage --size $ProbeVmSize --subnet $liveSubnetId `
      --public-ip-address $emptyArg --nsg $emptyArg --admin-username azureuser --generate-ssh-keys `
      --os-disk-delete-option Delete --nic-delete-option Delete `
      --tags purpose=aks-preflight managedBy=aks-architectures `
      -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
      throw "az vm create failed. This is itself a finding - the subnet may be full, policy-blocked or delegated.`n$($createOut -join "`n")"
    }
    $probeVmCreated = $true
    $vm = Get-JsonPayload $createOut | ConvertFrom-Json
    $privateIp = $vm.privateIpAddress

    # ---- 5/6. Endpoint reachability from inside the subnet -------------------------------------
    $probeBody = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'lib' 'probe.sh')
    $extra = ($AdditionalFqdns -join ',')
    $header = "#!/usr/bin/env bash`nset -- '$Location' '$ApiServerFqdn' '$extra'`n"
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "aks-preflight-$([Guid]::NewGuid().ToString('N')).sh"
    # Azure run-command requires LF endings; CRLF produces "\r: command not found" on every line.
    [IO.File]::WriteAllText($tmp, ($header + $probeBody).Replace("`r`n", "`n"))

    Write-Host 'Running endpoint probes from inside the subnet...' -ForegroundColor DarkGray
    $runOut = az vm run-command invoke -g $ResourceGroup -n $probeVmName --command-id RunShellScript --scripts "@$tmp" -o json 2>&1
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue

    $lines = @()
    if ($LASTEXITCODE -ne 0) {
      Add-Result -Id 'path.runCommand' -Category $cat -Status 'fail' `
        -Message 'Could not run commands on the probe VM. The guest agent could not reach Azure.' `
        -Remediation 'Check that the NSG allows outbound to 168.63.129.16 and that no UDR overrides 168.63.129.16/32.' `
        -Evidence ($runOut -join "`n")
    }
    else {
      $message = ((Get-JsonPayload $runOut | ConvertFrom-Json).value | Select-Object -First 1).message
      $evidence['probeRawOutput'] = $message
      $lines = $message -split "`n"

      $probeLines = @($lines | Where-Object { $_ -match '^PREFLIGHT\|' })
      foreach ($line in $probeLines) {
        $f = $line.Trim() -split '\|', 4
        $remediation = switch ($f[1]) {
          'ntp' { 'Allow UDP 123 outbound, or configure the nodes against an internal NTP server. Clock skew breaks TLS and AAD token validation on every node.' }
          'wireserver' { 'Allow outbound to 168.63.129.16 and ensure no UDR sends 168.63.129.16/32 to a firewall.' }
          'imds' { 'Allow outbound to 169.254.169.254. Kubelet and workload identity both depend on IMDS.' }
          default {
            if ($Egress -eq 'udr-firewall') { 'Add the FQDN to the Azure Firewall application rule collection, or use the AzureKubernetesService FQDN tag which covers the AKS-required set.' }
            else { 'Check the subnet NSG outbound rules and any UDR forcing 0.0.0.0/0 to an appliance.' }
          }
        }
        Add-Result -Id "path.$($f[1])" -Category $cat -Status $f[2] -Message $f[3] -Remediation $(if ($f[2] -in @('fail', 'warn')) { $remediation } else { '' })
      }
      if ($probeLines.Count -eq 0) {
        Add-Result -Id 'path.probeOutput' -Category $cat -Status 'fail' -Message 'The probe script produced no results.' -Evidence $message
      }

      foreach ($line in @($lines | Where-Object { $_ -match '^CONTEXT\|' })) {
        $f = $line.Trim() -split '\|', 3
        $evidence["probe_$($f[1])"] = $f[2]
      }

      # The observed egress IP is what authorized-IP-range rules have to contain. People almost
      # always guess it wrong when a NAT Gateway or Firewall is in the path.
      if ($evidence.Contains('probe_observed_egress_ip') -and $evidence['probe_observed_egress_ip'] -match '^\d+\.\d+\.\d+\.\d+$') {
        $observed = $evidence['probe_observed_egress_ip']
        if ($architectureDef.apiServerAccess -eq 'authorizedIpRanges') {
          $declared = @()
          if ($ParamFile) { $declared = @(Get-ParamValue -Params $params -Path 'authorizedIpRanges' -Default @()) }
          $covered = $false
          foreach ($r in $declared) { if ($r -and (Test-IpInCidr -Ip $observed -Cidr $r)) { $covered = $true } }
          if ($covered) {
            Add-Result -Id 'path.egressIpCovered' -Category $cat -Status 'pass' -Message "Observed egress IP $observed is covered by the declared authorized IP ranges."
          }
          else {
            Add-Result -Id 'path.egressIpCovered' -Category $cat -Status 'warn' `
              -Message "Nodes egress as $observed, which is not in the declared authorized IP ranges ($($declared -join ', '))." `
              -Remediation "main.bicep appends the NAT Gateway or Firewall public IP automatically, so this is usually fine. If you manage the list by hand, add $observed/32."
          }
        }
        else {
          Add-Result -Id 'path.egressIp' -Category $cat -Status 'pass' -Message "Nodes egress from this subnet as $observed."
        }
      }
    }

    # ---- 3. Effective routes -------------------------------------------------------------------
    $nicName = "$probeVmName-nic"
    Write-Host 'Reading Network Watcher effective routes...' -ForegroundColor DarkGray
    $routes = Invoke-AzJson @('network', 'nic', 'show-effective-route-table', '-g', $ResourceGroup, '-n', $nicName)
    if (-not $routes -or -not $routes.value) {
      Add-Result -Id 'path.effectiveRoutes' -Category $cat -Status 'warn' -Message 'Effective route table could not be read.' -Remediation "az network nic show-effective-route-table -g $ResourceGroup -n $nicName -o table"
    }
    else {
      $active = @($routes.value | Where-Object { $_.state -eq 'Active' })
      $evidence['effectiveRoutes'] = $active | ForEach-Object { [ordered]@{ source = $_.source; prefix = ($_.addressPrefix -join ','); nextHopType = $_.nextHopType; nextHopIp = ($_.nextHopIpAddress -join ',') } }

      $default = @($active | Where-Object { $_.addressPrefix -contains '0.0.0.0/0' }) | Select-Object -First 1
      if (-not $default) {
        Add-Result -Id 'path.defaultRoute' -Category $cat -Status 'fail' -Message 'No active 0.0.0.0/0 route on the node NIC.' -Remediation 'Nodes cannot reach the internet or a firewall. Restore the default route.'
      }
      else {
        $hop = $default.nextHopType
        $hopIp = ($default.nextHopIpAddress -join ',')
        $expected = switch ($Egress) {
          'udr-firewall' { 'VirtualAppliance' }
          'natgateway' { 'Internet' }
          'loadbalancer' { 'Internet' }
          default { $hop }
        }
        if ($hop -eq $expected) {
          Add-Result -Id 'path.defaultRoute' -Category $cat -Status 'pass' -Message "0.0.0.0/0 next hop is $hop$(if ($hopIp) { " ($hopIp)" }), which matches egress mode '$Egress'."
        }
        else {
          Add-Result -Id 'path.defaultRoute' -Category $cat -Status 'fail' `
            -Message "0.0.0.0/0 next hop is $hop$(if ($hopIp) { " ($hopIp)" }) but egress mode '$Egress' expects $expected." `
            -Remediation $(if ($Egress -eq 'udr-firewall') { 'The route table is not associated with the node subnet, or its next hop IP does not match the firewall private IP. Compare the expectedFirewallPrivateIp and actualFirewallPrivateIp deployment outputs.' } else { "Remove the user-defined route sending 0.0.0.0/0 to $hop, or switch egress to udr-firewall." })
        }

        # A UDR pointing at a firewall that does not exist yet is the classic silent failure: the
        # deployment validates, the nodes never register, and the error surfaces 40 minutes later.
        if ($hop -eq 'VirtualAppliance' -and $hopIp) {
          $probeIpReachable = (@($lines | Where-Object { $_ -match '^PREFLIGHT\|(arm|mcr)\|pass' }).Count -gt 0)
          if (-not $probeIpReachable) {
            Add-Result -Id 'path.applianceReachable' -Category $cat -Status 'fail' `
              -Message "All traffic is forced to the virtual appliance at $hopIp, and endpoint probes through it failed." `
              -Remediation "Confirm an appliance is actually listening on $hopIp and that its rules allow the AKS-required FQDNs. Azure Firewall: add the AzureKubernetesService FQDN tag."
          }
        }
      }

      $hijacked = @($active | Where-Object { $_.nextHopType -eq 'None' -and $_.addressPrefix -notcontains '0.0.0.0/0' })
      if ($hijacked.Count -gt 0) {
        Add-Result -Id 'path.blackholeRoutes' -Category $cat -Status 'warn' `
          -Message "$($hijacked.Count) route(s) have next hop 'None' and will black-hole traffic: $((($hijacked | ForEach-Object { $_.addressPrefix -join ',' }) | Select-Object -First 5) -join '; ')" `
          -Remediation 'Confirm each of these is intentional. A None next hop silently drops packets with no ICMP response.'
      }
    }

    # ---- 4. IP flow verify ---------------------------------------------------------------------
    Write-Host 'Running Network Watcher IP flow verify...' -ForegroundColor DarkGray
    az network watcher configure -l $Location --enabled true 2>$null | Out-Null

    $flowTargets = [ordered]@{}
    if ($evidence.Contains('probeRawOutput')) {
      foreach ($id in @('arm', 'mcr', 'aad')) {
        $m = [regex]::Match($evidence['probeRawOutput'], "PREFLIGHT\|$id\|\w+\|.*?(?:via|resolved to) (\d+\.\d+\.\d+\.\d+)")
        if ($m.Success) { $flowTargets[$id] = $m.Groups[1].Value }
      }
    }
    if ($flowTargets.Count -eq 0) { $flowTargets['generic-internet'] = '1.1.1.1' }

    foreach ($t in $flowTargets.GetEnumerator()) {
      $flow = Invoke-AzJson @('network', 'watcher', 'test-ip-flow', '--vm', $probeVmName, '-g', $ResourceGroup, '--nic', $nicName,
        '--direction', 'Outbound', '--protocol', 'TCP', '--local', "${privateIp}:33000", '--remote', "$($t.Value):443")
      if (-not $flow) {
        Add-Result -Id "path.ipFlow.$($t.Key)" -Category $cat -Status 'warn' -Message "IP flow verify to $($t.Value):443 could not be evaluated." -Remediation 'Network Watcher may be disabled in this region, or the caller lacks Network Contributor.'
      }
      elseif ($flow.access -eq 'Allow') {
        Add-Result -Id "path.ipFlow.$($t.Key)" -Category $cat -Status 'pass' -Message "Outbound TCP 443 to $($t.Value) is allowed by NSG rule '$($flow.ruleName)'."
      }
      else {
        Add-Result -Id "path.ipFlow.$($t.Key)" -Category $cat -Status 'fail' `
          -Message "Outbound TCP 443 to $($t.Value) is DENIED by NSG rule '$($flow.ruleName)'." `
          -Remediation "Amend or remove NSG rule '$($flow.ruleName)'. AKS nodes require outbound 443 to the Azure control plane, MCR and AAD."
      }
    }
  }
  catch {
    Add-Result -Id 'path.probe' -Category $cat -Status 'fail' -Message $_.Exception.Message -Remediation 'Resolve the error above and re-run. Nothing was left behind.'
  }
  finally {
    Remove-ProbeVm
  }
}

# ================================================================================================
# 9. Private DNS reachability for aks-private-link
# ================================================================================================

$cat = 'private-dns'
if ($Architecture -eq 'aks-private-link') {
  $zoneName = "privatelink.$Location.azmk8s.io"
  $zones = Invoke-AzJson @('network', 'private-dns', 'zone', 'list')
  $zone = if ($zones) { @($zones | Where-Object { $_.name -like "*.$Location.azmk8s.io" }) | Select-Object -First 1 } else { $null }

  if (-not $zone) {
    Add-Result -Id 'dns.zoneExists' -Category $cat -Status 'skip' `
      -Message "No $zoneName private DNS zone found yet." `
      -Remediation 'AKS creates it in the node resource group on first deployment. Re-run preflight afterwards to confirm the operator network can resolve it.'
  }
  else {
    Add-Result -Id 'dns.zoneExists' -Category $cat -Status 'pass' -Message "Found private DNS zone $($zone.name)."
    $zoneRg = ($zone.id -split '/')[4]
    $links = Invoke-AzJson @('network', 'private-dns', 'link', 'vnet', 'list', '-g', $zoneRg, '-z', $zone.name)
    $linkedVnets = if ($links) { @($links | ForEach-Object { $_.virtualNetwork.id }) } else { @() }
    $evidence['privateDnsZoneLinks'] = $linkedVnets

    if ($linkedVnets.Count -eq 0) {
      Add-Result -Id 'dns.zoneLinked' -Category $cat -Status 'fail' `
        -Message "Private DNS zone $($zone.name) has no virtual network links." `
        -Remediation "kubectl will fail to resolve the API server. Link the operator's VNet: az network private-dns link vnet create -g $zoneRg -z $($zone.name) -n operator-link -v <vnetId> -e false"
    }
    else {
      Add-Result -Id 'dns.zoneLinked' -Category $cat -Status 'pass' -Message "Private DNS zone is linked to $($linkedVnets.Count) VNet(s)."

      # Resolution only works from a VNet that is linked, or from a network that forwards to a
      # resolver inbound endpoint in a linked VNet. Report which, so the operator knows where
      # kubectl will actually work from.
      $resolvers = Invoke-AzJson @('dns-resolver', 'list')
      if ($resolvers -and @($resolvers).Count -gt 0) {
        $inbound = @()
        foreach ($r in @($resolvers)) {
          $rrg = ($r.id -split '/')[4]
          $eps = Invoke-AzJson @('dns-resolver', 'inbound-endpoint', 'list', '--resolver-name', $r.name, '-g', $rrg)
          if ($eps) { foreach ($e in @($eps)) { $inbound += @($e.ipConfigurations | ForEach-Object { $_.privateIpAddress }) } }
        }
        if ($inbound.Count -gt 0) {
          Add-Result -Id 'dns.resolverInbound' -Category $cat -Status 'pass' `
            -Message "DNS Private Resolver inbound endpoint(s) at $($inbound -join ', ') can serve on-premises conditional forwarders." `
            -Evidence $inbound
        }
      }
      else {
        Add-Result -Id 'dns.resolverInbound' -Category $cat -Status 'warn' `
          -Message 'No DNS Private Resolver found. Operators outside a linked VNet will not resolve the API server.' `
          -Remediation 'Set features.privateDnsResolver to true and point the on-premises conditional forwarder for the azmk8s.io zone at the inbound endpoint IP.'
      }
    }
  }
}
else {
  Add-Result -Id 'dns.zoneExists' -Category $cat -Status 'skip' -Message "Private DNS zone validation applies to the aks-private-link architecture only."
}

# ================================================================================================
# 10. Identity: can this caller create the role assignments the deployment depends on
#
# AKS validates the control plane identity's rights on the VNet, the route table and the registry
# WHILE it provisions. Granting them afterwards produces a cluster that came up and then cannot
# attach a load balancer or pull an image. The deployment therefore creates those assignments
# itself, which means the person running it needs Microsoft.Authorization/roleAssignments/write.
# Contributor does not include it. This is the most common way a deployment gets three quarters
# of the way through and then fails on something that looks unrelated.
# ================================================================================================

# An Azure action pattern grants a target action when it matches allowing for wildcards, which can
# appear anywhere in the pattern rather than only at the end.
function Test-ActionGranted([string]$Pattern, [string]$Action) {
  $regex = '^' + ([regex]::Escape($Pattern) -replace '\\\*', '.*') + '$'
  return [regex]::IsMatch($Action, $regex, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

$cat = 'identity'
if (-not $architectureDef.azureRegion) {
  Add-Result -Id 'identity.roleAssignmentWrite' -Category $cat -Status 'skip' `
    -Message "Architecture '$Architecture' creates no Azure resources that need role assignments."
}
else {
  # Scope the question as narrowly as the deployment will actually run. Permissions inherit
  # downward, so asking at the resource group is the honest test when we know the group.
  if ($ResourceGroup) {
    $permScope = "/subscriptions/$($account.id)/resourceGroups/$ResourceGroup"
    $permLabel = "resource group '$ResourceGroup'"
  }
  else {
    $permScope = "/subscriptions/$($account.id)"
    $permLabel = "subscription '$($account.name)'"
  }

  # This endpoint returns the effective permissions of the CALLER at the scope, already collapsed
  # across every assignment they hold. It is the only way to answer the question without being
  # able to read role assignments, which is itself a privilege the caller may not have.
  $permUrl = "https://management.azure.com$permScope/providers/Microsoft.Authorization/permissions?api-version=2022-04-01"
  $permResponse = Invoke-AzJson @('rest', '--method', 'get', '--url', $permUrl)
  $permissions = @($permResponse.value)

  if ($permissions.Count -eq 0) {
    Add-Result -Id 'identity.roleAssignmentWrite' -Category $cat -Status 'warn' `
      -Message "Effective permissions at $permLabel could not be read, so role assignment rights are unverified." `
      -Remediation 'Deployment will still be attempted. If it fails with AuthorizationFailed on Microsoft.Authorization/roleAssignments/write, ask for User Access Administrator or RBAC Administrator on the resource group.'
  }
  else {
    # An action grants the target only if some assignment matches it AND that same assignment does
    # not claw it back through a notAction. The wildcard can appear anywhere, not just at the end:
    # Contributor holds actions ["*"] but notActions ["Microsoft.Authorization/*/Write"], which is
    # exactly the case a naive prefix match gets wrong and reports as a pass.
    $target = 'Microsoft.Authorization/roleAssignments/write'

    $canAssign = $false
    foreach ($p in $permissions) {
      $allowed = @($p.actions) | Where-Object { $_ -and (Test-ActionGranted $_ $target) }
      if (-not $allowed) { continue }
      $denied = @($p.notActions) | Where-Object { $_ -and (Test-ActionGranted $_ $target) }
      if (-not $denied) { $canAssign = $true; break }
    }

    if ($canAssign) {
      Add-Result -Id 'identity.roleAssignmentWrite' -Category $cat -Status 'pass' `
        -Message "Caller can create role assignments at $permLabel."
    }
    else {
      Add-Result -Id 'identity.roleAssignmentWrite' -Category $cat -Status 'fail' `
        -Message "Caller cannot create role assignments at $permLabel (Microsoft.Authorization/roleAssignments/write is not granted)." `
        -Remediation "Contributor is not enough - it holds actions [*] but explicitly excludes Microsoft.Authorization/*/Write. Ask for Owner, User Access Administrator, or Role Based Access Control Administrator on that scope: az role assignment create --assignee <you> --role 'Role Based Access Control Administrator' --scope $permScope"
    }
  }

  # Spell out what the deployment is about to grant. A reviewer who can see the list can approve
  # it; one who cannot is approving a black box.
  $grants = [Collections.Generic.List[string]]::new()
  $grants.Add('Network Contributor on the VNet')
  $grants.Add('Managed Identity Operator on the kubelet identity')
  if ($Egress -eq 'udr-firewall') { $grants.Add('Network Contributor on the route table (required for userDefinedRouting)') }
  if ($architectureDef.apiServerAccess -eq 'privateLink') { $grants.Add('Private DNS Zone Contributor on the API server zone') }
  $grants.Add('AcrPull on the registry')
  $grants.Add('Key Vault Secrets User for the CSI driver')
  Add-Result -Id 'identity.grantsPlanned' -Category $cat -Status 'pass' `
    -Message "The deployment will create these role assignments: $($grants -join '; ')." `
    -Remediation 'Each one is scoped to a single resource, never to the subscription. Review infra/modules/rbac/pre-cluster.bicep.'
}

# ================================================================================================
# Report
# ================================================================================================

$counts = Write-CheckTable -Results $results.ToArray() -Title "PRE-FLIGHT RESULTS - $Architecture / $NetworkProfile / $Egress"

# 2.0.0 renamed the 'flavor' key to 'architecture'. A reader written against 1.x sees null, not an error.
$document = [ordered]@{
  schemaVersion  = '2.0.0'
  tool           = 'aks-architectures/preflight'
  timestampUtc   = (Get-Date).ToUniversalTime().ToString('o')
  architecture         = $Architecture
  networkProfile = $NetworkProfile
  egress         = $Egress
  location       = $Location
  resourceGroup  = $ResourceGroup
  outcome        = $(if ($counts.fail -gt 0) { 'fail' } else { 'pass' })
  summary        = $counts
  results        = $results.ToArray()
  evidence       = $evidence
}

if ([string]::IsNullOrWhiteSpace($JsonOutputPath)) {
  $JsonOutputPath = Join-Path (Get-Location) "preflight-$Architecture.json"
}
$document | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $JsonOutputPath -Encoding utf8
Write-Host "Machine-readable result: $JsonOutputPath" -ForegroundColor DarkGray

if ($counts.fail -gt 0) {
  Write-Host 'PRE-FLIGHT FAILED. Fix the items above before deploying.' -ForegroundColor Red
  exit 1
}

if ($counts.skip -gt 0) {
  Write-Host "PRE-FLIGHT PASSED, with $($counts.skip) check(s) skipped. Read the SKIP lines - a skipped network-path check means the real path was never tested." -ForegroundColor Yellow
}
else {
  Write-Host 'PRE-FLIGHT PASSED.' -ForegroundColor Green
}
exit 0
