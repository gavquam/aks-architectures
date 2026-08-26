#Requires -Version 7.0
<#
.SYNOPSIS
  Collects evidence from an ALREADY-failed AKS deployment and turns it into an answer.

.DESCRIPTION
  A failed AKS provisioning attempt reports almost nothing useful at the ARM layer: the deployment
  says the agent pool failed, and that is it. The actual cause is in the custom script extension
  exit code on the node, and the reason for that exit code is in the effective route table, the
  effective NSG rules and the private DNS zone links. This script gathers all of it in one pass.

  Read-only. It creates nothing and deletes nothing.

.EXAMPLE
  ./diagnose.ps1 -ResourceGroup rg-aks-prod-wus3

.EXAMPLE
  ./diagnose.ps1 -ResourceGroup rg-aks-prod-wus3 -DeploymentName aks-architectures-aks-private-link-20260820
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$ResourceGroup,
  [string]$ClusterName = '',
  [string]$DeploymentName = '',
  [string]$SubscriptionId = '',
  [string]$JsonOutputPath = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/common.psm1') -Force

Assert-AzureCli
if ($SubscriptionId) { az account set --subscription $SubscriptionId -o none }

$cseCodes = (Get-Content (Join-Path $PSScriptRoot 'lib/cse-exit-codes.json') -Raw | ConvertFrom-Json).codes
$results = [System.Collections.Generic.List[object]]::new()
$evidence = [ordered]@{}

$acct = Invoke-AzJson @('account', 'show')
Write-Host ''
Write-Host 'AKS ARCHITECTURES - POST-FAILURE DIAGNOSTICS' -ForegroundColor Cyan
if ($acct) { Write-Host "Subscription: $($acct.name) $($acct.id)" }
Write-Host "Resource group: $ResourceGroup"
Write-Host ''

# ================================================================================================
# 1. Deployment operations
#
# The top-level deployment only says "a nested deployment failed", so the useful message is always
# one or more levels down. This walks the nested deployments to find the operations that actually
# carry a status message.
# ================================================================================================

if (-not $DeploymentName) {
  $deployments = Invoke-AzJson @('deployment', 'group', 'list', '-g', $ResourceGroup)
  if ($deployments) {
    $failed = @($deployments | Where-Object { $_.properties.provisioningState -eq 'Failed' } |
      Sort-Object { $_.properties.timestamp })
    if ($failed.Count -gt 0) { $DeploymentName = $failed[-1].name }
  }
}

function Get-StatusMessageText($statusMessage) {
  if ($null -eq $statusMessage) { return '' }
  if ($statusMessage.error -and $statusMessage.error.message) { return [string]$statusMessage.error.message }
  if ($statusMessage.Message) { return [string]$statusMessage.Message }
  return ($statusMessage | ConvertTo-Json -Depth 6 -Compress)
}

function Add-FailedOperation([string]$Deployment, [int]$Depth = 0) {
  if ($Depth -gt 4) { return }
  $ops = Invoke-AzJson @('deployment', 'operation', 'group', 'list', '-g', $ResourceGroup, '-n', $Deployment)
  if (-not $ops) { return }

  foreach ($op in @($ops | Where-Object { $_.properties.provisioningState -eq 'Failed' })) {
    $targetId = ''
    if ($op.properties.targetResource) { $targetId = [string]$op.properties.targetResource.id }
    $short = if ($targetId) { $targetId.Split('/')[-1] } else { '(deployment)' }
    $msg = (Get-StatusMessageText $op.properties.statusMessage) -replace '[\r\n\t]', ' '
    if ($msg.Length -gt 400) { $msg = $msg.Substring(0, 400) }
    $code = if ($op.properties.statusCode) { $op.properties.statusCode } else { 'Failed' }
    $results.Add((New-CheckResult -Id "deployment.$short" -Category 'deployment' -Status 'fail' -Message "${code}: $msg"))

    if ($targetId -match '/Microsoft\.Resources/deployments/') {
      Add-FailedOperation -Deployment $targetId.Split('/')[-1] -Depth ($Depth + 1)
    }
  }
}

if (-not $DeploymentName) {
  $results.Add((New-CheckResult -Id 'deployment.failed' -Category 'deployment' -Status 'skip' `
        -Message 'No failed deployment found in this resource group. Diagnosing the live cluster state instead.'))
}
else {
  Write-Host "Reading deployment operations for '$DeploymentName'..."
  $evidence['deploymentName'] = $DeploymentName
  Add-FailedOperation -Deployment $DeploymentName
}

# ================================================================================================
# 2. Cluster state
# ================================================================================================

if (-not $ClusterName) {
  $clusters = Invoke-AzJson @('aks', 'list', '-g', $ResourceGroup)
  if ($clusters -and @($clusters).Count -gt 0) { $ClusterName = @($clusters)[0].name }
}

$nodeRg = ''; $nodeSubnetId = ''; $outboundType = ''; $privateFqdn = ''
if (-not $ClusterName) {
  $results.Add((New-CheckResult -Id 'cluster.exists' -Category 'cluster' -Status 'fail' `
        -Message "No AKS cluster exists in $ResourceGroup. The deployment failed before the cluster resource was created." `
        -Remediation 'Read the deployment findings above; the cause is upstream of the cluster.'))
}
else {
  Write-Host "Inspecting cluster '$ClusterName'..."
  $cluster = Invoke-AzJson @('aks', 'show', '-g', $ResourceGroup, '-n', $ClusterName)
  if (-not $cluster) {
    $results.Add((New-CheckResult -Id 'cluster.read' -Category 'cluster' -Status 'fail' `
          -Message "Could not read cluster $ClusterName."))
  }
  else {
    $nodeRg = [string]$cluster.nodeResourceGroup
    $outboundType = [string]$cluster.networkProfile.outboundType
    if ($cluster.PSObject.Properties['privateFqdn']) { $privateFqdn = [string]$cluster.privateFqdn }
    if (@($cluster.agentPoolProfiles).Count -gt 0) { $nodeSubnetId = [string]@($cluster.agentPoolProfiles)[0].vnetSubnetId }
    $evidence['clusterName'] = $ClusterName
    $evidence['nodeResourceGroup'] = $nodeRg
    $evidence['outboundType'] = $outboundType

    $power = if ($cluster.powerState) { $cluster.powerState.code } else { 'unknown' }
    if ($cluster.provisioningState -eq 'Succeeded') {
      $results.Add((New-CheckResult -Id 'cluster.provisioningState' -Category 'cluster' -Status 'pass' `
            -Message "Cluster provisioningState is Succeeded, powerState $power."))
    }
    else {
      $results.Add((New-CheckResult -Id 'cluster.provisioningState' -Category 'cluster' -Status 'fail' `
            -Message "Cluster provisioningState is $($cluster.provisioningState) (powerState $power)." `
            -Remediation 'A cluster stuck in Creating or Failed almost always means the node pool never registered. Check the CSE findings below.'))
    }

    foreach ($pool in @($cluster.agentPoolProfiles)) {
      if ($pool.provisioningState -eq 'Succeeded') {
        $results.Add((New-CheckResult -Id "cluster.pool.$($pool.name)" -Category 'cluster' -Status 'pass' `
              -Message "Node pool $($pool.name) ($($pool.mode), $($pool.count) nodes) is Succeeded."))
      }
      else {
        $results.Add((New-CheckResult -Id "cluster.pool.$($pool.name)" -Category 'cluster' -Status 'fail' `
              -Message "Node pool $($pool.name) ($($pool.mode)) is $($pool.provisioningState)." `
              -Remediation 'The node pool is where network failures surface. Continue to the CSE and route findings.'))
      }
    }

    $privateEnabled = if ($cluster.apiServerAccessProfile) { $cluster.apiServerAccessProfile.enablePrivateCluster } else { $false }
    $results.Add((New-CheckResult -Id 'cluster.networkConfig' -Category 'cluster' -Status 'pass' `
          -Message ("plugin={0} mode={1} dataplane={2} outboundType={3} privateCluster={4}" -f `
            $cluster.networkProfile.networkPlugin, $cluster.networkProfile.networkPluginMode,
          $cluster.networkProfile.networkDataplane, $outboundType, $privateEnabled)))
  }
}

# ================================================================================================
# 3. The custom script extension exit code
#
# This is the single most valuable number in an AKS provisioning failure and it is buried three
# levels inside the VMSS instance view.
# ================================================================================================

$nodeNicId = ''
if ($nodeRg) {
  Write-Host "Reading VMSS instance views in '$nodeRg'..."
  $scaleSets = @(Invoke-AzJson @('vmss', 'list', '-g', $nodeRg))

  if ($scaleSets.Count -eq 0) {
    $results.Add((New-CheckResult -Id 'cse.vmss' -Category 'cse' -Status 'fail' `
          -Message "No VMSS exists in the node resource group $nodeRg." `
          -Remediation 'The control plane never got as far as creating node infrastructure. This is a quota, policy or subnet permission failure, not an egress failure.'))
  }

  foreach ($vmss in $scaleSets) {
    $instances = @(Invoke-AzJson @('vmss', 'list-instances', '-g', $nodeRg, '-n', $vmss.name))
    if ($instances.Count -eq 0) {
      $results.Add((New-CheckResult -Id "cse.$($vmss.name).instances" -Category 'cse' -Status 'fail' `
            -Message "VMSS $($vmss.name) has no instances." `
            -Remediation 'Check regional vCPU quota and any Azure Policy denying VM creation in this subscription.'))
      continue
    }

    foreach ($inst in $instances) {
      $iid = [string]$inst.instanceId
      $iv = Invoke-AzJson @('vmss', 'get-instance-view', '-g', $nodeRg, '-n', $vmss.name, '--instance-id', $iid)
      if (-not $iv) { continue }

      $cseExt = @($iv.extensions | Where-Object { $_.name -match '(?i)CSE|CustomScript' })
      $cseMsg = (@($cseExt | ForEach-Object { @($_.substatuses) + @($_.statuses) } |
          Where-Object { $_ -and $_.message } | ForEach-Object { $_.message }) -join ' ') -replace '[\r\n\t]', ' '
      $cseStatus = (@($cseExt | ForEach-Object { @($_.statuses) } |
          Where-Object { $_ -and $_.displayStatus } | ForEach-Object { $_.displayStatus }) -join ', ')

      if (-not $cseMsg -and -not $cseStatus) {
        $results.Add((New-CheckResult -Id "cse.$($vmss.name).$iid" -Category 'cse' -Status 'skip' `
              -Message "Instance $iid has no custom script extension status yet. The node is still early in provisioning."))
        continue
      }

      # "command terminated with exit status=50" is the canonical form; older agents emit
      # "Enable failed: ... exit status 50" without the '='.
      $exitCode = $null
      $m = [regex]::Matches($cseMsg, 'exit status[ =]+(\d+)')
      if ($m.Count -gt 0) { $exitCode = $m[$m.Count - 1].Groups[1].Value }

      if (-not $exitCode) {
        if ($cseStatus -match '(?i)succe') {
          $results.Add((New-CheckResult -Id "cse.$($vmss.name).$iid" -Category 'cse' -Status 'pass' `
                -Message "Instance $iid custom script extension succeeded."))
        }
        else {
          $trimmed = if ($cseMsg.Length -gt 300) { $cseMsg.Substring(0, 300) } else { $cseMsg }
          $results.Add((New-CheckResult -Id "cse.$($vmss.name).$iid" -Category 'cse' -Status 'warn' `
                -Message "Instance $iid extension status '$cseStatus' with no parseable exit code: $trimmed"))
        }
        continue
      }

      $evidence["cseExitCode.$($vmss.name).$iid"] = $exitCode
      $known = $cseCodes.PSObject.Properties[$exitCode]
      $codeName = if ($known) { $known.Value.name } else { 'UNKNOWN' }
      $meaning = if ($known) { $known.Value.meaning } else { 'Exit code not present in the known table. Read the full extension message.' }
      $isNetwork = if ($known) { [bool]$known.Value.network } else { $false }

      if ($exitCode -eq '0') {
        $results.Add((New-CheckResult -Id "cse.$($vmss.name).$iid" -Category 'cse' -Status 'pass' `
              -Message "Instance $iid custom script extension exit code 0."))
      }
      elseif ($isNetwork) {
        $results.Add((New-CheckResult -Id "cse.$($vmss.name).$iid" -Category 'cse' -Status 'fail' `
              -Message "Instance $iid exit $exitCode ${codeName}: $meaning" `
              -Remediation 'This is a network-path failure. The route, NSG and DNS findings below tell you which hop is at fault.'))
      }
      else {
        $results.Add((New-CheckResult -Id "cse.$($vmss.name).$iid" -Category 'cse' -Status 'fail' `
              -Message "Instance $iid exit $exitCode ${codeName}: $meaning" `
              -Remediation 'Not primarily a network failure. Collect /var/log/azure/cluster-provision.log from the node.'))
      }

      if (-not $nodeNicId) {
        $nics = Invoke-AzJson @('vmss', 'nic', 'list-vm-nics', '-g', $nodeRg, '--vmss-name', $vmss.name, '--instance-id', $iid)
        if ($nics -and @($nics).Count -gt 0) { $nodeNicId = [string]@($nics)[0].id }
      }
    }
  }
}

# ================================================================================================
# 4. Effective routes on a real node NIC
#
# The route table attached to the subnet is not what the node uses; the effective table is the merge
# of system routes, the attached UDR and any BGP routes learned over a gateway. Reading the
# effective table is the only way to see what the node will actually do with a packet.
# ================================================================================================

if (-not $nodeNicId) {
  $results.Add((New-CheckResult -Id 'routes.effective' -Category 'routes' -Status 'skip' `
        -Message 'No node NIC exists yet, so Network Watcher cannot report effective routes. Run scripts/preflight.ps1 against the intended subnet instead - it deploys a probe VM to answer the same question.'))
}
else {
  Write-Host 'Querying effective routes...'
  $routes = Invoke-AzJson @('network', 'nic', 'show-effective-route-table', '--ids', $nodeNicId)
  if (-not $routes) {
    $results.Add((New-CheckResult -Id 'routes.effective' -Category 'routes' -Status 'warn' `
          -Message 'Network Watcher did not return an effective route table. The NIC may be detached or the VM deallocated.'))
  }
  else {
    $defaultRoute = @($routes.value | Where-Object { $_.addressPrefix -contains '0.0.0.0/0' })[0]
    $hopIp = if ($defaultRoute -and @($defaultRoute.nextHopIpAddress).Count -gt 0) { @($defaultRoute.nextHopIpAddress)[0] } else { '' }
    $defaultHop = if ($defaultRoute) { "$($defaultRoute.nextHopType) $hopIp".Trim() } else { 'none' }
    $defaultSrc = if ($defaultRoute -and $defaultRoute.source) { $defaultRoute.source } else { 'unknown' }
    $evidence['defaultRouteNextHop'] = $defaultHop

    if ($outboundType -eq 'userDefinedRouting') {
      if ($defaultHop -like 'VirtualAppliance*') {
        $results.Add((New-CheckResult -Id 'routes.defaultRoute' -Category 'routes' -Status 'pass' `
              -Message "outboundType is userDefinedRouting and 0.0.0.0/0 points at $defaultHop (source $defaultSrc)."))
      }
      else {
        $results.Add((New-CheckResult -Id 'routes.defaultRoute' -Category 'routes' -Status 'fail' `
              -Message "outboundType is userDefinedRouting but the effective 0.0.0.0/0 next hop is '$defaultHop' (source $defaultSrc)." `
              -Remediation 'The route table is missing, not associated with the node subnet, or its next hop is wrong. With userDefinedRouting there is no AKS-managed outbound path to fall back on, so the node has no egress at all.'))
      }
    }
    elseif ($defaultHop -like 'VirtualAppliance*') {
      $results.Add((New-CheckResult -Id 'routes.defaultRoute' -Category 'routes' -Status 'warn' `
            -Message "outboundType is $outboundType but 0.0.0.0/0 is forced to $defaultHop (source $defaultSrc)." `
            -Remediation 'A UDR is overriding the managed outbound path. Return traffic to the load balancer will be asymmetric and dropped unless the appliance SNATs. This is the most common cause of a cluster that provisions and then goes unreachable.'))
    }
    else {
      $results.Add((New-CheckResult -Id 'routes.defaultRoute' -Category 'routes' -Status 'pass' `
            -Message "0.0.0.0/0 next hop is $defaultHop (source $defaultSrc), consistent with outboundType $outboundType."))
    }

    $invalid = @($routes.value | Where-Object { $_.state -ne 'Active' }).Count
    if ($invalid -gt 0) {
      $results.Add((New-CheckResult -Id 'routes.invalid' -Category 'routes' -Status 'warn' `
            -Message "$invalid effective route(s) are not in the Active state." `
            -Remediation 'An Invalid route usually points at a virtual appliance IP that no longer exists.'))
    }
    else {
      $results.Add((New-CheckResult -Id 'routes.invalid' -Category 'routes' -Status 'pass' -Message 'All effective routes are Active.'))
    }
  }
}

# ================================================================================================
# 5. NSG evaluation on the real node NIC
# ================================================================================================

if (-not $nodeNicId) {
  $results.Add((New-CheckResult -Id 'nsg.flowVerify' -Category 'nsg' -Status 'skip' `
        -Message 'No node NIC to evaluate. Use scripts/preflight.ps1 against the intended subnet.'))
}
else {
  Write-Host 'Running IP flow verify...'
  $nic = Invoke-AzJson @('network', 'nic', 'show', '--ids', $nodeNicId)
  $nodeIp = if ($nic) { [string]@($nic.ipConfigurations)[0].privateIPAddress } else { '' }
  $vmId = if ($nic -and $nic.virtualMachine) { [string]$nic.virtualMachine.id } else { '' }
  $nicLocation = if ($nic) { [string]$nic.location } else { '' }

  if (-not $nodeIp -or -not $vmId) {
    $results.Add((New-CheckResult -Id 'nsg.flowVerify' -Category 'nsg' -Status 'skip' `
          -Message 'Could not resolve the node private IP or VM ID for IP flow verify.'))
  }
  else {
    $targets = @(
      @{ Dst = '20.10.0.10'; Port = '443'; Proto = 'TCP'; Label = 'api-server-range' },
      @{ Dst = '13.107.42.14'; Port = '443'; Proto = 'TCP'; Label = 'mcr-range' },
      @{ Dst = '168.63.129.16'; Port = '53'; Proto = 'UDP'; Label = 'azure-dns' }
    )
    foreach ($t in $targets) {
      $flow = Invoke-AzJson @('network', 'watcher', 'test-ip-flow', '--direction', 'Outbound', '--protocol', $t.Proto,
        '--local', "$($nodeIp):10000", '--remote', "$($t.Dst):$($t.Port)", '--vm', $vmId, '--nic', $nodeNicId, '-l', $nicLocation)
      if (-not $flow) {
        $results.Add((New-CheckResult -Id "nsg.flow.$($t.Label)" -Category 'nsg' -Status 'skip' `
              -Message "Network Watcher could not evaluate the flow to $($t.Dst):$($t.Port)."))
      }
      elseif ($flow.access -eq 'Allow') {
        $results.Add((New-CheckResult -Id "nsg.flow.$($t.Label)" -Category 'nsg' -Status 'pass' `
              -Message "Outbound $($t.Proto) to $($t.Dst):$($t.Port) is allowed by rule $($flow.ruleName)."))
      }
      else {
        $results.Add((New-CheckResult -Id "nsg.flow.$($t.Label)" -Category 'nsg' -Status 'fail' `
              -Message "Outbound $($t.Proto) to $($t.Dst):$($t.Port) is DENIED by rule $($flow.ruleName)." `
              -Remediation 'Remove or reorder that NSG rule. Nodes cannot provision without outbound 443 and DNS.'))
      }
    }
  }
}

# ================================================================================================
# 6. Private DNS for a private cluster
# ================================================================================================

if (-not $privateFqdn) {
  $results.Add((New-CheckResult -Id 'dns.privateZone' -Category 'dns' -Status 'skip' `
        -Message 'Not a private cluster, or the cluster was never created; no private DNS zone to validate.'))
}
else {
  $zone = $privateFqdn.Substring($privateFqdn.IndexOf('.') + 1)
  Write-Host "Checking private DNS zone '$zone'..."
  $allZones = Invoke-AzJson @('network', 'private-dns', 'zone', 'list')
  $zoneObj = @($allZones | Where-Object { $_.name -eq $zone })[0]
  if (-not $zoneObj) {
    $results.Add((New-CheckResult -Id 'dns.privateZone' -Category 'dns' -Status 'fail' `
          -Message "No private DNS zone named $zone is visible in this subscription." `
          -Remediation 'A private cluster whose zone was deleted or lives in another subscription cannot be resolved by its own nodes.'))
  }
  else {
    $zoneRg = $zoneObj.id.Split('/')[4]
    $links = @(Invoke-AzJson @('network', 'private-dns', 'link', 'vnet', 'list', '-g', $zoneRg, '-z', $zone))
    if ($links.Count -eq 0) {
      $results.Add((New-CheckResult -Id 'dns.zoneLinks' -Category 'dns' -Status 'fail' `
            -Message "Private DNS zone $zone has no virtual network links." `
            -Remediation 'Nodes cannot resolve the API server. This produces CSE exit 52. Link the node VNet to the zone.'))
    }
    else {
      $nodeVnetId = if ($nodeSubnetId) { $nodeSubnetId -replace '/subnets/.*$', '' } else { '' }
      $linked = $nodeVnetId -and @($links | Where-Object { $_.virtualNetwork.id -eq $nodeVnetId }).Count -gt 0
      if ($linked) {
        $results.Add((New-CheckResult -Id 'dns.zoneLinks' -Category 'dns' -Status 'pass' `
              -Message "Private DNS zone $zone is linked to the node VNet ($($links.Count) link(s) total)."))
      }
      else {
        $results.Add((New-CheckResult -Id 'dns.zoneLinks' -Category 'dns' -Status 'fail' `
              -Message "Private DNS zone $zone has $($links.Count) link(s) but none of them is the node VNet." `
              -Remediation 'Nodes cannot resolve the API server. This produces CSE exit 52.'))
      }
    }
  }
}

# ================================================================================================
# 7. Report
# ================================================================================================

$title = "DIAGNOSTIC RESULTS - $ResourceGroup"
if ($ClusterName) { $title += " / $ClusterName" }
$counts = Write-CheckTable -Results $results.ToArray() -Title $title

if (-not $JsonOutputPath) { $JsonOutputPath = "./diagnose-$ResourceGroup.json" }
[pscustomobject]@{
  resourceGroup = $ResourceGroup
  cluster       = $ClusterName
  deployment    = $DeploymentName
  summary       = $counts
  results       = $results.ToArray()
  evidence      = $evidence
} | ConvertTo-Json -Depth 8 | Set-Content -Path $JsonOutputPath -Encoding utf8
Write-Host "Machine-readable result: $JsonOutputPath"

if ($counts.fail -gt 0) {
  Write-Host 'Findings above are ordered from the deployment inwards. The first FAIL in the cse, routes or dns'
  Write-Host 'categories is the one to fix; the rest are usually consequences of it.'
  exit 1
}
Write-Host 'No failures detected. If the cluster is still unhealthy the cause is above the network layer.' -ForegroundColor Green
exit 0
