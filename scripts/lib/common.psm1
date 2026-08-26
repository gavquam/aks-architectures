# Shared helpers for the aks-architectures scripts: architecture-matrix lookup, CIDR arithmetic, .bicepparam
# resolution, role-ID resolution and the pass/fail result model used by preflight and diagnose.
#
# Everything here is deliberately dependency-free (no Az PowerShell module) so the scripts run the
# same way on an engineer's laptop and on a GitHub Actions runner with only the Azure CLI installed.

Set-StrictMode -Version Latest

function Get-RepoRoot {
  [CmdletBinding()]
  param()
  # lib/ -> scripts/ -> repo root
  return (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
}

function Get-ArchitectureMatrix {
  [CmdletBinding()]
  param([string]$RepoRoot = (Get-RepoRoot))

  $path = Join-Path $RepoRoot 'infra' 'architecture-matrix.json'
  if (-not (Test-Path $path)) {
    throw "architecture-matrix.json not found at $path. Run the scripts from inside the aks-architectures repo."
  }
  return (Get-Content -Raw -LiteralPath $path | ConvertFrom-Json)
}

# ---------------------------------------------------------------------------------------------
# CIDR arithmetic
# ---------------------------------------------------------------------------------------------

function Get-CidrRange {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Cidr)

  $parts = $Cidr.Trim().Split('/')
  if ($parts.Count -ne 2) { throw "'$Cidr' is not a valid CIDR (expected a.b.c.d/nn)." }

  $addr = $null
  if (-not [System.Net.IPAddress]::TryParse($parts[0], [ref]$addr)) {
    throw "'$Cidr' does not contain a valid IPv4 address."
  }
  if ($addr.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
    throw "'$Cidr' is not IPv4. This repo validates IPv4 address plans only."
  }

  $prefix = 0
  if (-not [int]::TryParse($parts[1], [ref]$prefix) -or $prefix -lt 0 -or $prefix -gt 32) {
    throw "'$Cidr' has an invalid prefix length."
  }

  $bytes = $addr.GetAddressBytes()
  [Array]::Reverse($bytes)
  # [long] throughout: uint32 arithmetic in PowerShell silently promotes and wraps in confusing ways.
  $base = [long][System.BitConverter]::ToUInt32($bytes, 0)
  $size = [long][Math]::Pow(2, 32 - $prefix)
  $start = $base - ($base % $size)

  return [pscustomobject]@{
    Cidr      = $Cidr.Trim()
    Prefix    = $prefix
    Start     = $start
    End       = $start + $size - 1
    Size      = $size
    IsAligned = ($base -eq $start)
  }
}

function Convert-UInt32ToIp {
  [CmdletBinding()]
  param([Parameter(Mandatory)][long]$Value)

  $bytes = [System.BitConverter]::GetBytes([uint32]$Value)
  [Array]::Reverse($bytes)
  return ([System.Net.IPAddress]::new($bytes)).ToString()
}

function Test-CidrOverlap {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$A, [Parameter(Mandatory)][string]$B)

  $ra = Get-CidrRange $A
  $rb = Get-CidrRange $B
  return ($ra.Start -le $rb.End -and $rb.Start -le $ra.End)
}

function Test-CidrContains {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Outer, [Parameter(Mandatory)][string]$Inner)

  $ro = Get-CidrRange $Outer
  $ri = Get-CidrRange $Inner
  return ($ri.Start -ge $ro.Start -and $ri.End -le $ro.End)
}

function Test-IpInCidr {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Ip, [Parameter(Mandatory)][string]$Cidr)

  return (Test-CidrContains -Outer $Cidr -Inner "$Ip/32")
}

# ---------------------------------------------------------------------------------------------
# .bicepparam resolution
# ---------------------------------------------------------------------------------------------

function Resolve-BicepParamFile {
  <#
    .SYNOPSIS
      Compiles a .bicepparam file and returns a hashtable of parameter name -> value.
    .DESCRIPTION
      The parameter files call readEnvironmentVariable(), so this must run in the same process
      environment as the deployment for the two to agree.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) { throw "Parameter file not found: $Path" }

  $raw = az bicep build-params --file $Path --stdout 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "az bicep build-params failed for $Path`n$($raw -join "`n")"
  }

  $envelope = ($raw -join "`n") | ConvertFrom-Json
  $doc = $envelope.parametersJson | ConvertFrom-Json

  $result = @{}
  foreach ($p in $doc.parameters.PSObject.Properties) {
    $result[$p.Name] = $p.Value.value
  }
  return $result
}

function Get-ParamValue {
  <#
    .SYNOPSIS
      Reads a (possibly nested) parameter value, returning $Default when absent or empty.
    .EXAMPLE
      Get-ParamValue $params 'addressing.serviceCidr' ''
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable]$Params,
    [Parameter(Mandatory)][string]$Path,
    $Default = ''
  )

  $segments = $Path.Split('.')
  if (-not $Params.ContainsKey($segments[0])) { return $Default }

  $current = $Params[$segments[0]]
  for ($i = 1; $i -lt $segments.Count; $i++) {
    if ($null -eq $current) { return $Default }
    $prop = $current.PSObject.Properties[$segments[$i]]
    if ($null -eq $prop) { return $Default }
    $current = $prop.Value
  }

  if ($null -eq $current) { return $Default }
  if ($current -is [string] -and [string]::IsNullOrWhiteSpace($current)) { return $Default }
  return $current
}

# ---------------------------------------------------------------------------------------------
# Result model
# ---------------------------------------------------------------------------------------------

# Status vocabulary, in severity order:
#   pass - the check ran and the condition holds.
#   warn - the check ran, the condition is questionable but not provably broken. Does not fail the run.
#   skip - the check could not run (missing prerequisite). Reason is always recorded. Does not fail.
#   fail - the check ran and the condition is broken. Fails the run.

function New-CheckResult {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Id,
    [Parameter(Mandatory)][string]$Category,
    [Parameter(Mandatory)][ValidateSet('pass', 'warn', 'skip', 'fail')][string]$Status,
    [Parameter(Mandatory)][string]$Message,
    [string]$Remediation = '',
    $Evidence = $null
  )

  return [pscustomobject]@{
    id          = $Id
    category    = $Category
    status      = $Status
    message     = $Message
    remediation = $Remediation
    evidence    = $Evidence
  }
}

function Write-CheckTable {
  [CmdletBinding()]
  param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Results, [string]$Title = 'PRE-FLIGHT RESULTS')

  $colors = @{ pass = 'Green'; warn = 'Yellow'; skip = 'DarkGray'; fail = 'Red' }
  $glyphs = @{ pass = 'PASS'; warn = 'WARN'; skip = 'SKIP'; fail = 'FAIL' }

  $width = 100
  Write-Host ''
  Write-Host ('=' * $width)
  Write-Host $Title
  Write-Host ('=' * $width)

  $lastCategory = ''
  foreach ($r in $Results) {
    if ($r.category -ne $lastCategory) {
      Write-Host ''
      Write-Host ("-- {0} " -f $r.category).PadRight($width, '-') -ForegroundColor Cyan
      $lastCategory = $r.category
    }
    Write-Host ('  [{0}] ' -f $glyphs[$r.status]) -ForegroundColor $colors[$r.status] -NoNewline
    Write-Host ('{0,-34} {1}' -f $r.id, $r.message)
    if ($r.remediation -and $r.status -in @('fail', 'warn')) {
      Write-Host ('         -> {0}' -f $r.remediation) -ForegroundColor DarkYellow
    }
  }

  $counts = @{}
  foreach ($s in @('pass', 'warn', 'skip', 'fail')) {
    $counts[$s] = @($Results | Where-Object { $_.status -eq $s }).Count
  }

  Write-Host ''
  Write-Host ('=' * $width)
  Write-Host ('  {0} passed   {1} warned   {2} skipped   {3} FAILED' -f $counts.pass, $counts.warn, $counts.skip, $counts.fail) -ForegroundColor $(if ($counts.fail -gt 0) { 'Red' } else { 'Green' })
  Write-Host ('=' * $width)
  Write-Host ''

  return $counts
}

# ---------------------------------------------------------------------------------------------
# Azure helpers
# ---------------------------------------------------------------------------------------------

function Resolve-AzRoleId {
  <#
    .SYNOPSIS
      Resolves a built-in role definition GUID by display name.
    .DESCRIPTION
      Managed and CSP tenants do NOT always use the published well-known GUIDs for built-in roles.
      Hardcoding them produces RoleDefinitionDoesNotExist at deploy time, so every role is resolved
      against the live subscription and only falls back to the documented GUID if lookup fails.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$DisplayName,
    [Parameter(Mandatory)][string]$Fallback
  )

  $id = az role definition list --name $DisplayName --query "[0].name" -o tsv 2>$null
  if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($id)) {
    return $id.Trim()
  }
  Write-Warning "Could not resolve role '$DisplayName' in this tenant; falling back to the well-known GUID $Fallback."
  return $Fallback
}

function Invoke-AzJson {
  <#
    .SYNOPSIS
      Runs an Azure CLI command and returns parsed JSON, or $null when the command fails.
    .DESCRIPTION
      Preflight must never crash on a missing resource - a missing resource is a finding, not an
      exception - so CLI failures are converted into $null and surfaced through the result table.

      Arguments are passed as a single array rather than as remaining arguments, because PowerShell
      tries to bind any token starting with '-' as a parameter name before it reaches the splat.
    .EXAMPLE
      Invoke-AzJson @('network', 'vnet', 'list', '-g', $rg)
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory, Position = 0)][string[]]$Arguments)

  $out = az @Arguments -o json 2>$null
  if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace(($out -join ''))) { return $null }
  try { return ($out -join "`n") | ConvertFrom-Json } catch { return $null }
}

function Get-GeoCode {
  <#
    .SYNOPSIS
      Mirrors the geoCodes map in infra/modules/naming/naming.bicep so scripts can predict names.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Location)

  $codes = @{
    eastus = 'eus'; eastus2 = 'eus2'; centralus = 'cus'; northcentralus = 'ncus'
    southcentralus = 'scus'; westcentralus = 'wcus'; westus = 'wus'; westus2 = 'wus2'
    westus3 = 'wus3'; canadacentral = 'cac'; canadaeast = 'cae'; brazilsouth = 'brs'
    northeurope = 'neu'; westeurope = 'weu'; uksouth = 'uks'; ukwest = 'ukw'
    francecentral = 'frc'; germanywestcentral = 'gwc'; switzerlandnorth = 'chn'
    norwayeast = 'nwe'; swedencentral = 'sdc'; polandcentral = 'plc'; italynorth = 'itn'
    spaincentral = 'spc'; uaenorth = 'uan'; southafricanorth = 'san'; australiaeast = 'aue'
    australiasoutheast = 'ause'; southeastasia = 'sea'; eastasia = 'ea'; japaneast = 'jpe'
    japanwest = 'jpw'; koreacentral = 'krc'; centralindia = 'inc'; southindia = 'ins'
    israelcentral = 'ilc'; mexicocentral = 'mxc'; newzealandnorth = 'nzn'
  }
  $key = $Location.ToLower()
  if ($codes.ContainsKey($key)) { return $codes[$key] }
  return $key.Substring(0, [Math]::Min(3, $key.Length))
}

function Assert-AzureCli {
  [CmdletBinding()]
  param()

  $ver = az version -o json 2>$null
  if ($LASTEXITCODE -ne 0) {
    throw 'Azure CLI not found on PATH. Install it from https://aka.ms/azcli and run: az login'
  }
  $account = az account show -o json 2>$null
  if ($LASTEXITCODE -ne 0) {
    throw 'Not signed in. Run: az login   (then: az account set --subscription <id>)'
  }
  return ($account | ConvertFrom-Json)
}

# ---------------------------------------------------------------------------------------------
# Cost estimate
#
# The point of this is not accounting accuracy, it is that nobody should discover an Azure Firewall
# on their invoice. It itemises only the things that bill continuously once created; per-request and
# per-GB charges are named but not totalled, because guessing someone's traffic would be dishonest.
# ---------------------------------------------------------------------------------------------

function Get-CostEstimate {
  <#
    .SYNOPSIS
      Itemises the continuously billed components a set of resolved parameters will create.
    .OUTPUTS
      A hashtable with Lines (label, monthly, expensive), Total and HasExpensive.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][hashtable]$Params,
    [Parameter(Mandatory)]$Architecture
  )

  $priceFile = Join-Path $PSScriptRoot 'cost-estimates.json'
  $prices = (Get-Content -LiteralPath $priceFile -Raw | ConvertFrom-Json)
  $hours = $prices.hoursPerMonth
  $item = { param($key) $prices.items.$key }

  # Monthly cost of one unit of an item, whatever unit it is quoted in.
  $monthly = {
    param($key, [double]$multiplier = 1)
    $i = & $item $key
    $per = switch ($i.unit) {
      'hour' { $i.unitPrice * $hours }
      'day' { $i.unitPrice * ($hours / 24) }
      'month' { $i.unitPrice }
      default { 0 }
    }
    if ($i.PSObject.Properties['count']) { $per = $per * $i.count }
    # AwayFromZero, not the .NET default of ToEven, so these match jq's round() in common.sh.
    return [math]::Round($per * $multiplier, 0, [MidpointRounding]::AwayFromZero)
  }

  # A List, not an array: the closures below append to it, and += inside a script block would
  # silently write to a copy in the child scope.
  $lines = [System.Collections.Generic.List[object]]::new()
  $add = {
    param($label, [double]$amount, [bool]$expensive = $false, [string]$note = '')
    $lines.Add([pscustomobject]@{ Label = $label; Monthly = $amount; Expensive = $expensive; Note = $note })
  }

  $egress = Get-ParamValue $Params 'egress' 'none'
  $features = $Params['features']
  $hasFeature = { param($name) [bool]($features -and $features.PSObject.Properties[$name] -and $features.$name) }

  if ($Architecture.azureRegion -and $Architecture.createsCluster) {
    # Only the sizes this repo actually defaults to carry a price. Anything else is reported
    # honestly as unpriced rather than guessed at. Standard_D4ds_v5 -> nodeD4dsV5.
    $nodeKey = {
      param($size)
      $k = 'node' + ((($size -replace '^Standard_', '') -replace '_v(\d+)$', 'V$1'))
      if ($prices.items.PSObject.Properties[$k]) { $k } else { $null }
    }
    $pool = $Params['systemNodePool']
    $count = if ($pool) { [int]$pool.count } else { 0 }
    $size = if ($pool) { [string]$pool.vmSize } else { '' }
    $key = & $nodeKey $size
    if ($key) {
      & $add "System node pool, $count x $size" (& $monthly $key $count) $false ''
    }
    else {
      & $add "System node pool, $count x $size" 0 $false 'size not priced here, see docs/costs.md'
    }
    if (Get-ParamValue $Params 'deployUserNodePool' $false) {
      $upool = $Params['userNodePool']
      $ucount = if ($upool) { [int]$upool.count } else { 0 }
      $usize = if ($upool) { [string]$upool.vmSize } else { '' }
      $ukey = & $nodeKey $usize
      $uamount = if ($ukey) { & $monthly $ukey $ucount } else { 0 }
      & $add "User node pool, $ucount x $usize" $uamount $true 'AKS_DEPLOY_USER_POOL=false removes it'
    }

    # Automatic pins the cluster to Standard regardless of clusterSkuTier, so the SLA is billed
    # there whatever the cost tier says.
    $isAutomatic = $Architecture.skuName -eq 'Automatic'
    if ($isAutomatic -or (Get-ParamValue $Params 'clusterSkuTier' 'Free') -eq 'Standard') {
      $slaNote = if ($isAutomatic) { 'not optional on this architecture' } else { 'Free tier is the same cluster without the SLA' }
      & $add 'AKS Standard tier (uptime SLA)' (& $monthly 'aksUptimeSla') $false $slaNote
    }
    if ($isAutomatic) {
      & $add 'AKS Automatic hosted control plane' (& $monthly 'aksAutomaticControlPlane') $false 'not optional on this architecture'
    }

    switch ($egress) {
      'natgateway' { & $add 'NAT Gateway + 1 public IP' ((& $monthly 'natGateway') + (& $monthly 'publicIp')) $false '' }
      'udr-firewall' {
        $sku = Get-ParamValue $Params 'firewallSkuTier' 'Standard'
        $key = if ($sku -eq 'Premium') { 'azureFirewallPremium' } else { 'azureFirewallStandard' }
        & $add "Azure Firewall ($sku) + 1 public IP" ((& $monthly $key) + (& $monthly 'publicIp')) $true 'AKS_EGRESS=natgateway removes it'
      }
      default { }
    }

    if (& $hasFeature 'bastion') { & $add 'Azure Bastion (Basic)' (& $monthly 'bastionBasic') $true 'AKS_COST_TIER=lean removes it' }
    if (& $hasFeature 'privateDnsResolver') { & $add 'DNS Private Resolver (2 endpoints)' (& $monthly 'dnsResolverEndpoint') $true 'AKS_COST_TIER=lean removes it' }
    if (& $hasFeature 'managedGrafana') {
      $gsku = Get-ParamValue $Params 'grafanaSku' 'Essential'
      $gkey = if ($gsku -eq 'Standard') { 'grafanaStandard' } else { 'grafanaEssential' }
      & $add "Managed Grafana ($gsku)" (& $monthly $gkey) ($gsku -eq 'Standard') 'AKS_GRAFANA_SKU=Essential is cheaper'
    }
    if (& $hasFeature 'containerRegistry') {
      $asku = Get-ParamValue $Params 'containerRegistrySku' 'Basic'
      & $add "Container registry ($asku)" (& $monthly "acr$asku") ($asku -eq 'Premium') 'Premium buys the private endpoint'
    }
    if (& $hasFeature 'diagnosticSettings') {
      $cap = [int](Get-ParamValue $Params 'logAnalyticsDailyQuotaGb' -1)
      if ($cap -gt 0) {
        & $add "Log Analytics ceiling, $cap GB/day cap" ([math]::Round((& $item 'logAnalyticsPerGb').unitPrice * $cap * 30, 0, [MidpointRounding]::AwayFromZero)) $false 'a ceiling, not a run rate'
      }
      else {
        & $add 'Log Analytics ingestion' 0 $true 'UNCAPPED - set logAnalyticsDailyQuotaGb'
      }
    }
    if (& $hasFeature 'defenderForContainers') {
      $vcores = $count * 4
      & $add "Defender for Containers, about $vcores vCores" ([math]::Round((& $item 'defenderPerVcoreHour').unitPrice * $hours * $vcores, 0, [MidpointRounding]::AwayFromZero)) $false 'scales with every node you add'
    }
  }
  elseif (& $hasFeature 'defenderForContainers') {
    & $add 'Defender for Containers on the Arc cluster' 0 $false 'about $7 per vCore per month'
  }

  $total = if ($lines.Count -gt 0) { ($lines | Measure-Object -Property Monthly -Sum).Sum } else { 0 }
  return @{
    Lines        = @($lines)
    Total        = [int]$total
    HasExpensive = [bool]($lines | Where-Object { $_.Expensive })
    Prices       = $prices
  }
}

function Write-CostEstimate {
  <#
    .SYNOPSIS
      Prints the estimate produced by Get-CostEstimate.
  #>
  [CmdletBinding()]
  param([Parameter(Mandatory)][hashtable]$Estimate, [string]$Tier = 'lean')

  $p = $Estimate.Prices
  Write-Host ''
  Write-Host "COST ESTIMATE  (cost tier: $Tier)" -ForegroundColor Cyan
  Write-Host "$($p.currency) list prices for $($p.referenceRegion), captured $($p.capturedOn). An estimate, not a quote."
  Write-Host ('-' * 78)
  if ($Estimate.Lines.Count -eq 0) {
    Write-Host '   Nothing in this architecture bills by the hour. Attaching a cluster to Arc is free;'
    Write-Host '   only the Arc features you enable on top of it are chargeable.'
    Write-Host ''
    return
  }
  foreach ($line in $Estimate.Lines) {
    $amount = if ($line.Monthly -gt 0) { '${0}' -f $line.Monthly } else { 'usage' }
    $marker = if ($line.Expensive) { '!!' } else { '  ' }
    $colour = if ($line.Expensive) { 'Yellow' } else { 'Gray' }
    Write-Host ('{0} {1,-42} {2,10} /mo  {3}' -f $marker, $line.Label, $amount, $line.Note) -ForegroundColor $colour
  }
  Write-Host ('-' * 78)
  Write-Host ('   {0,-42} {1,10} /mo' -f 'Estimated standing cost', ('${0}' -f $Estimate.Total))
  Write-Host '   Log ingestion is counted at its daily cap, so this is an upper bound.'
  Write-Host '   Excludes data processed, egress bandwidth, storage and per-request charges.'
  if ($Estimate.HasExpensive) {
    Write-Host ''
    Write-Host '   Lines marked !! are the ones worth a second look. docs/costs.md explains each.' -ForegroundColor Yellow
  }
  Write-Host ''
}

Export-ModuleMember -Function @(
  'Get-RepoRoot'
  'Get-ArchitectureMatrix'
  'Get-CidrRange'
  'Convert-UInt32ToIp'
  'Test-CidrOverlap'
  'Test-CidrContains'
  'Test-IpInCidr'
  'Resolve-BicepParamFile'
  'Get-ParamValue'
  'New-CheckResult'
  'Write-CheckTable'
  'Resolve-AzRoleId'
  'Invoke-AzJson'
  'Get-GeoCode'
  'Assert-AzureCli'
  'Get-CostEstimate'
  'Write-CostEstimate'
)
