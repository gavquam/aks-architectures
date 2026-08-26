#Requires -Version 7.0
<#
.SYNOPSIS
  Interactive planner. Asks about ten questions, explains the trade-off behind each one, writes a
  parameter file you can keep, and then deploys it.

.DESCRIPTION
  The point of this script is not to save typing. It is to make the reasoning visible at the moment
  the decision is made, because the settings that matter most in AKS are the ones that cannot be
  changed afterwards, and they are usually chosen in the first ten minutes by someone who has not
  yet been told which ones those are.

  For every question you get three things: the minimum that works, what Microsoft recommends, and
  what this repository recommends for your situation - which is not always the same, and where they
  differ the reason is stated.

  The guidance text lives in infra/params/guidance.json, not in this script, so the bash and
  PowerShell wizards cannot drift apart and so the advice can be reviewed by someone who does not
  read shell.

  Nothing is deployed until the whole plan and its monthly cost have been shown and confirmed.

.EXAMPLE
  ./wizard.ps1

.EXAMPLE
  ./wizard.ps1 -ResourceGroup rg-aks-lab -PlanOnly
#>
[CmdletBinding()]
param(
  [Parameter(HelpMessage = 'Target resource group. Asked for if not supplied.')]
  [string] $ResourceGroup = '',

  [Parameter(HelpMessage = 'Write the plan and stop. Deploys nothing.')]
  [switch] $PlanOnly,

  [Parameter(HelpMessage = 'Where to write the generated parameter file.')]
  [string] $OutFile = ''
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'lib/common.psm1') -Force

$repoRoot = Get-RepoRoot
$guidance = Get-Content (Join-Path $repoRoot 'infra/params/guidance.json') -Raw | ConvertFrom-Json
$matrix = Get-ArchitectureMatrix

# ================================================================================================
# Presentation helpers
#
# Guidance is only useful if it is legible under pressure, so the three kinds of statement the
# wizard makes - what is required, what Microsoft says, what this repo says - are visually
# distinct rather than three more lines of grey text.
# ================================================================================================

function Write-Rule { Write-Host ('-' * 78) -ForegroundColor DarkGray }

function Write-Heading([string] $Text) {
  Write-Host ''
  Write-Rule
  Write-Host "  $Text" -ForegroundColor Cyan
  Write-Rule
}

function Write-Why($Lines) {
  foreach ($l in @($Lines)) { Write-Host "  $l" -ForegroundColor DarkGray }
}

function Write-Advice($Decision) {
  if ($Decision.minimum) { Write-Host "  Minimum:      $($Decision.minimum)" -ForegroundColor DarkYellow }
  if ($Decision.microsoftBestPractice) { Write-Host "  Microsoft:    $($Decision.microsoftBestPractice)" -ForegroundColor Yellow }
  if ($Decision.recommended -ne $null -and "$($Decision.recommended)" -ne '') {
    Write-Host "  Recommended:  $($Decision.recommended)" -ForegroundColor Green
  }
  if ($Decision.recommendedWhy) { Write-Host "                $($Decision.recommendedWhy)" -ForegroundColor DarkGreen }
  if ($Decision.immutable) {
    Write-Host '  IMMUTABLE:    changing this later means building a new cluster.' -ForegroundColor Magenta
  }
}

# Some decisions carry a reference table rather than a single recommendation. Zone support is the
# one that changes the answer most often, so it is shown rather than described.
function Write-Regions($Decision) {
  if (-not $Decision.regions) { return }
  Write-Host ''
  foreach ($r in $Decision.regions) {
    if ($r.zones -gt 0) {
      Write-Host ('    {0,-16} {1,-12} {2} zones' -f $r.name, $r.city, $r.zones) -ForegroundColor Green
    } else {
      Write-Host ('    {0,-16} {1,-12} no zones' -f $r.name, $r.city) -ForegroundColor DarkYellow
    }
  }
  if ($Decision.regionsNote) {
    Write-Host ''
    Write-Why $Decision.regionsNote
  }
}

# A free-text answer with a default. Enter takes the default, which is always the recommendation,
# so a user who wants to be led can hold Enter down and still get a defensible cluster.
function Read-Answer([string] $Prompt, [string] $Default, [scriptblock] $Validate = $null) {
  while ($true) {
    $shown = if ($Default) { " [$Default]" } else { '' }
    Write-Host ''
    Write-Host "  $Prompt$shown " -NoNewline -ForegroundColor White
    $raw = Read-Host
    $value = if ([string]::IsNullOrWhiteSpace($raw)) { $Default } else { $raw.Trim() }
    if ($Validate) {
      $problem = & $Validate $value
      if ($problem) { Write-Host "  $problem" -ForegroundColor Red; continue }
    }
    return $value
  }
}

# A numbered choice. The recommended option is marked so the default is never a mystery.
function Read-Choice($Decision, [array] $Options, [string] $RecommendedValue) {
  $recIndex = 1
  for ($i = 0; $i -lt $Options.Count; $i++) {
    $o = $Options[$i]
    $isRec = ($o.value -eq $RecommendedValue)
    if ($isRec) { $recIndex = $i + 1 }
    $marker = if ($isRec) { '*' } else { ' ' }
    $colour = if ($isRec) { 'Green' } else { 'White' }
    Write-Host ''
    Write-Host ("  {0}{1}) {2}" -f $marker, ($i + 1), $o.label) -ForegroundColor $colour
    if ($o.detail) { Write-Host "       $($o.detail)" -ForegroundColor DarkGray }
    if ($o.warning) { Write-Host "       $($o.warning)" -ForegroundColor DarkYellow }
  }
  Write-Host ''
  Write-Host '  * = recommended' -ForegroundColor DarkGray

  while ($true) {
    Write-Host ''
    Write-Host "  Choose 1-$($Options.Count) [$recIndex] " -NoNewline -ForegroundColor White
    $raw = Read-Host
    if ([string]::IsNullOrWhiteSpace($raw)) { return $Options[$recIndex - 1] }
    $n = 0
    if ([int]::TryParse($raw.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $Options.Count) {
      return $Options[$n - 1]
    }
    Write-Host "  Enter a number between 1 and $($Options.Count)." -ForegroundColor Red
  }
}

function Test-Cidr([string] $Value, [int] $MaxPrefix, [int] $MinPrefix) {
  try { $r = Get-CidrRange $Value } catch { return $_.Exception.Message }
  if (-not $r.IsAligned) {
    $aligned = Convert-UInt32ToIp $r.Start
    return "$Value is not aligned to its own prefix. Did you mean $aligned/$($r.Prefix)?"
  }
  if ($r.Prefix -gt $MaxPrefix) { return "$Value is too small. Use /$MaxPrefix or larger." }
  if ($r.Prefix -lt $MinPrefix) { return "$Value is larger than /$MinPrefix, which is more address space than any cluster needs." }
  return $null
}

# ================================================================================================
# Intro
# ================================================================================================

# Starting from a clean screen makes the guidance readable, but the console handle does not exist
# when the wizard is driven from a pipe or a CI log, and failing to clear a screen is never a
# reason to refuse to run.
try { Clear-Host } catch { }
Write-Host ''
Write-Host "  $($guidance.intro.title)" -ForegroundColor Cyan
Write-Rule
foreach ($l in $guidance.intro.body) { Write-Host "  $l" -ForegroundColor Gray }
Write-Rule

Assert-AzureCli
$account = Invoke-AzJson @('account', 'show')
Write-Host ''
Write-Host "  Subscription: $($account.name)" -ForegroundColor DarkGray
Write-Host "  Signed in as: $($account.user.name)" -ForegroundColor DarkGray

# ================================================================================================
# 1. Purpose. This sets the cost tier, and it is where the wizard is most explicit about what a
#    cheaper answer actually costs you, because that is the trade people make without noticing.
# ================================================================================================

$d = $guidance.decisions.purpose
Write-Heading $d.question
Write-Why $d.whyItMatters
$purpose = Read-Choice $d $d.options $d.recommended
$costTier = $purpose.costTier

if ($purpose.disables.Count -gt 0) {
  Write-Host ''
  Write-Host '  This choice switches OFF the following. They are named rather than merely omitted,' -ForegroundColor Yellow
  Write-Host '  because a cost tier that silently drops security controls is how a demo becomes a' -ForegroundColor Yellow
  Write-Host '  production template:' -ForegroundColor Yellow
  foreach ($x in $purpose.disables) { Write-Host "    - $x" -ForegroundColor Yellow }
}
Write-Host ''
Write-Host "  $($purpose.disablesNote)" -ForegroundColor DarkGray
Write-Host "  Cost tier: $costTier" -ForegroundColor Green

# ================================================================================================
# 2. Architecture. Asked as a situation rather than a product name, because people know their situation
#    and do not yet know which API server access model it implies.
# ================================================================================================

$d = $guidance.decisions.architecture
Write-Heading $d.question
Write-Why $d.whyItMatters
$architectureChoice = Read-Choice $d $d.options $d.recommended

# The OT entry is the same architecture reached by a different route. Keeping it as its own line means
# someone with an OT problem recognises themselves in the list instead of having to translate.
$isOt = $architectureChoice.value.EndsWith(':ot')
$architecture = $architectureChoice.value -replace ':ot$', ''
$architectureDef = $matrix.architectures.$architecture

Write-Host ''
Write-Host "  Architecture: $architecture" -ForegroundColor Green
Write-Host "  $($architectureDef.summary)" -ForegroundColor DarkGray

if (-not $architectureDef.azureRegion) {
  Write-Host ''
  Write-Host '  This architecture does not build anything in an Azure region, so there is no address plan,' -ForegroundColor Yellow
  Write-Host '  no node sizing and no egress model for this wizard to ask about.' -ForegroundColor Yellow
  Write-Host ''
  Write-Host "  Required prerequisites this wizard cannot create: $($architectureDef.requiredParams -join ', ')" -ForegroundColor Yellow
  Write-Host ''
  Write-Host '  Next step:' -ForegroundColor Cyan
  if ($architecture -eq 'arc-attach-existing') {
    Write-Host '    ./scripts/arc-onboard.ps1 -ResourceGroup <rg> -ClusterName <name>'
    Write-Host '    then ./scripts/deploy.ps1 -Architecture arc-attach-existing -ResourceGroup <rg>'
  }
  else {
    Write-Host '    Register the Azure Local instance, its Arc Resource Bridge, a custom location and a'
    Write-Host '    logical network first. Then edit infra/params/aks-arc-local.bicepparam and run:'
    Write-Host '    ./scripts/deploy.ps1 -Architecture aks-arc-local -ResourceGroup <rg>'
  }
  Write-Host ''
  Write-Host '  See docs/architectures.md for the full prerequisite list.' -ForegroundColor DarkGray
  Write-Host ''
  exit 0
}

if ($isOt) {
  Write-Host ''
  Write-Host '  Because this is an OT platform, two further things are worth doing and neither is' -ForegroundColor Yellow
  Write-Host '  handled by the address plan:' -ForegroundColor Yellow
  Write-Host '    - place administrative access on a jump host at Purdue Level 3.5 rather than' -ForegroundColor Yellow
  Write-Host '      giving plant engineers direct routes to the API server subnet, and' -ForegroundColor Yellow
  Write-Host '    - disable local Kubernetes accounts entirely, so the shared credential does not' -ForegroundColor Yellow
  Write-Host '      exist to be found later.' -ForegroundColor Yellow
  Write-Host '  Choosing an Entra admin group below is what makes the second one possible.' -ForegroundColor DarkGray
}

# ================================================================================================
# 3. Region
# ================================================================================================

$d = $guidance.decisions.location
Write-Heading $d.question
Write-Why $d.whyItMatters
Write-Advice $d
Write-Regions $d
$location = Read-Answer 'Region' $d.recommended {
  param($v)
  if ($v -notmatch '^[a-z0-9]+$') { return "'$v' does not look like a region short name, e.g. westus3 or northeurope." }
  return $null
}

# ================================================================================================
# 4. Egress. Asked before addressing because udr-firewall needs a firewall subnet, and asked early
#    because it is immutable in the direction people care about.
# ================================================================================================

$d = $guidance.decisions.egress
Write-Heading $d.question
Write-Why $d.whyItMatters
Write-Advice $d
$allowedEgress = @($architectureDef.egress)
$egressOptions = @($d.options | Where-Object { $allowedEgress -contains $_.value })
$egress = (Read-Choice $d $egressOptions $d.recommended).value
Write-Host ''
Write-Host "  Egress: $egress  (outboundType = $($matrix.egressModes.$egress.outboundType))" -ForegroundColor Green

# ================================================================================================
# 5. Network profile. Constrained by the architecture - Automatic accepts exactly one - so where there is
#    no choice the wizard says so rather than presenting a menu of one.
# ================================================================================================

$d = $guidance.decisions.networkProfile
$allowedProfiles = @($architectureDef.networkProfiles)
if ($allowedProfiles.Count -eq 1) {
  $networkProfile = $allowedProfiles[0]
  Write-Heading $d.question
  Write-Host "  The $architecture architecture hard-wires this to $networkProfile, so there is nothing to choose." -ForegroundColor DarkGray
  Write-Host "  $($matrix.networkProfiles.$networkProfile.summary)" -ForegroundColor DarkGray
}
else {
  Write-Heading $d.question
  Write-Why $d.whyItMatters
  Write-Advice $d
  $profileOptions = @($d.options | Where-Object { $allowedProfiles -contains $_.value })
  $networkProfile = (Read-Choice $d $profileOptions $d.recommended).value
}
$profileDef = $matrix.networkProfiles.$networkProfile
Write-Host ''
Write-Host "  Network profile: $networkProfile" -ForegroundColor Green

# ================================================================================================
# 6. Addressing
#
# The wizard asks for one number - the VNet range - and derives every subnet from it, then shows
# the derived plan. Asking for nine subnets one at a time would be honest but nobody would finish;
# showing the derivation afterwards keeps it inspectable, which is the part that matters.
# ================================================================================================

$d = $guidance.decisions.vnetAddressSpace
Write-Heading $d.question
Write-Why $d.whyItMatters
Write-Advice $d
Write-Host ''
Write-Host '  The wizard derives the node, pod, API server, firewall, Bastion, private endpoint and' -ForegroundColor DarkGray
Write-Host '  DNS resolver subnets from this one range, and shows you the result before deploying.' -ForegroundColor DarkGray
Write-Host '  It needs at least a /19 of room to lay them all out.' -ForegroundColor DarkGray

$vnet = Read-Answer 'VNet address space' $d.recommended {
  param($v) Test-Cidr $v 19 8
}

$base = (Get-CidrRange $vnet).Start
function Sub([int] $Offset256, [int] $Extra, [int] $Prefix) {
  return ('{0}/{1}' -f (Convert-UInt32ToIp ($base + ($Offset256 * 256) + $Extra)), $Prefix)
}

$nodeSubnet = Sub 0 0 22
$podSubnet = if ($profileDef.requiresPodSubnet) { Sub 8 0 21 } else { '' }
$apiSubnet = if ($architectureDef.apiServerAccess -eq 'vnetIntegration') { Sub 16 0 28 } else { '' }
$fwSubnet = if ($matrix.egressModes.$egress.requiresFirewall) { Sub 17 0 26 } else { '' }
$bastionSubnet = Sub 17 64 26
$peSubnet = Sub 18 0 24
$dnsIn = Sub 19 0 28
$dnsOut = Sub 19 16 28

# Overlay pod addresses never appear in the VNet, so this range only has to avoid colliding with
# something the pods will genuinely need to reach.
$podCidr = if ($profileDef.requiresPodCidr) { '192.168.0.0/16' } else { '' }

$d = $guidance.decisions.serviceCidr
Write-Heading $d.question
Write-Why $d.whyItMatters
Write-Advice $d
$serviceCidr = Read-Answer 'Service CIDR' $d.recommended {
  param($v)
  $problem = Test-Cidr $v 24 8
  if ($problem) { return $problem }
  if (Test-CidrOverlap $v $vnet) { return "$v overlaps the VNet range $vnet. The Service CIDR must not overlap anything routable." }
  if ($podCidr -and (Test-CidrOverlap $v $podCidr)) { return "$v overlaps the overlay pod range $podCidr." }
  return $null
}
# .10 in the Service CIDR is the convention CoreDNS is configured against everywhere.
$dnsServiceIp = Convert-UInt32ToIp ((Get-CidrRange $serviceCidr).Start + 10)

Write-Host ''
Write-Host '  On-premises or plant ranges this cluster must not collide with.' -ForegroundColor White
Write-Host '  Pre-flight checks the whole plan against these. Comma separated, or Enter to skip.' -ForegroundColor DarkGray
$onPremRaw = Read-Answer 'On-premises CIDRs' '' {
  param($v)
  if (-not $v) { return $null }
  foreach ($c in ($v -split ',')) {
    $problem = Test-Cidr $c.Trim() 32 8
    if ($problem) { return $problem }
    if (Test-CidrOverlap $c.Trim() $vnet) { return "$($c.Trim()) overlaps the VNet range $vnet. This is the overlap that is most expensive to discover later - pick a different VNet range." }
  }
  return $null
}
$onPrem = @()
if ($onPremRaw) { $onPrem = @($onPremRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

# ================================================================================================
# 7. Sizing
# ================================================================================================

$d = $guidance.decisions.nodeCount
Write-Heading $d.question
Write-Why $d.whyItMatters
Write-Advice $d
$nodeCount = Read-Answer 'System node count' $d.recommended {
  param($v)
  $n = 0
  if (-not [int]::TryParse($v, [ref]$n) -or $n -lt 1 -or $n -gt 50) { return 'Enter a whole number between 1 and 50.' }
  return $null
}

$d = $guidance.decisions.nodeVmSize
Write-Heading $d.question
Write-Why $d.whyItMatters
Write-Advice $d
$nodeVmSize = Read-Answer 'Node VM size' $d.recommended {
  param($v)
  if ($v -notmatch '^Standard_') { return "'$v' does not look like an Azure VM size, e.g. Standard_D4ds_v5." }
  return $null
}

if ($profileDef.requiresPodSubnet) {
  # This is the constraint that surprises people, so it is computed rather than described.
  $podRange = Get-CidrRange $podSubnet
  $maxNodes = [Math]::Floor(($podRange.Size - 5) / 110)
  Write-Host ''
  Write-Host "  Pod subnet $podSubnet gives $($podRange.Size) addresses. At 110 pods per node that is" -ForegroundColor DarkYellow
  Write-Host "  a hard ceiling of about $maxNodes nodes, and it cannot be raised after creation." -ForegroundColor DarkYellow
}

# ================================================================================================
# 8. Access and identity
# ================================================================================================

$authorizedIps = @()
if ($architectureDef.apiServerAccess -eq 'authorizedIpRanges') {
  Write-Heading 'Which addresses may reach the API server?'
  Write-Why @(
    'This list is the entire control. Everything not on it is refused, including you.',
    'It also fails quietly when it drifts: an address changes and someone is locked out with',
    'no error that points at this list. Keep it in source control next to the cluster.'
  )
  $myIp = ''
  try { $myIp = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 5).Trim() } catch { $myIp = '' }
  if ($myIp) {
    Write-Host ''
    Write-Host "  Your current public address appears to be $myIp." -ForegroundColor DarkGray
    Write-Host '  Behind corporate NAT this rotates across a pool, so a single /32 will lock you out' -ForegroundColor DarkYellow
    Write-Host '  within hours. Ask your network team for the egress range rather than trusting this.' -ForegroundColor DarkYellow
  }
  $default = if ($myIp) { "$myIp/32" } else { '' }
  $ipRaw = Read-Answer 'Authorized CIDRs (comma separated)' $default {
    param($v)
    if (-not $v) { return 'At least one range is required for this architecture, or the cluster is unreachable.' }
    foreach ($c in ($v -split ',')) {
      $problem = Test-Cidr $c.Trim() 32 0
      if ($problem) { return $problem }
    }
    return $null
  }
  $authorizedIps = @($ipRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

$d = $guidance.decisions.adminGroup
Write-Heading $d.question
Write-Why $d.whyItMatters
Write-Advice $d

$groupHint = ''
# Groups the signed-in user belongs to are far more likely to be the right answer than groups they
# happen to own, and this is the difference between a useful suggestion and a confusing one.
$memberOf = Invoke-AzJson @('rest', '--method', 'get', '--url', 'https://graph.microsoft.com/v1.0/me/memberOf')
$myGroups = @()
if ($memberOf -and $memberOf.value) {
  $myGroups = @($memberOf.value | Where-Object { $_.'@odata.type' -eq '#microsoft.graph.group' })
}
if ($myGroups.Count -gt 0) {
  Write-Host ''
  Write-Host '  Groups you belong to:' -ForegroundColor DarkGray
  foreach ($g in ($myGroups | Select-Object -First 8)) {
    Write-Host "    $($g.id)  $($g.displayName)" -ForegroundColor DarkGray
  }
}
$adminRaw = Read-Answer 'Entra group object IDs (comma separated, Enter to skip)' $groupHint {
  param($v)
  if (-not $v) { return $null }
  foreach ($g in ($v -split ',')) {
    if ($g.Trim() -notmatch '^[0-9a-fA-F-]{36}$') { return "'$($g.Trim())' is not an object ID (a GUID). Find one with: az ad group show -g <name> --query id -o tsv" }
  }
  return $null
}
$adminGroups = @()
if ($adminRaw) { $adminGroups = @($adminRaw -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
if ($adminGroups.Count -eq 0) {
  Write-Host ''
  Write-Host '  No group supplied, so cluster access will use local Kubernetes accounts. That is a' -ForegroundColor Yellow
  Write-Host '  shared credential which nobody rotates and which survives someone leaving. Acceptable' -ForegroundColor Yellow
  Write-Host '  for a sandbox you will delete; not acceptable for anything that outlives this week.' -ForegroundColor Yellow
}

$d = $guidance.decisions.alertEmail
Write-Heading $d.question
Write-Why $d.whyItMatters
Write-Advice $d
$alertEmail = Read-Answer 'Alert email (Enter to skip)' '' {
  param($v)
  if ($v -and $v -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { return "'$v' is not an email address." }
  return $null
}

# ================================================================================================
# 9. Naming and target
# ================================================================================================

Write-Heading 'Naming'
Write-Why @(
  'Every resource name is derived from these four values, so they are what you will see in the',
  'portal, in the bill and in every alert. The customer code is capped at eight characters because',
  'a storage account name is capped at 24 and the other five segments already spend 16 of them.'
)
$customer = Read-Answer 'Customer or project code (2-8 chars)' 'contoso' {
  param($v)
  if ($v -notmatch '^[a-z0-9]{2,8}$') { return 'Use 2 to 8 lowercase letters or digits.' }
  return $null
}
$environment = Read-Answer 'Environment (dev, test, prod)' $(if ($purpose.value -eq 'learning') { 'dev' } else { 'prod' }) {
  param($v)
  if ($v -notin @('dev', 'test', 'prod')) { return 'Must be dev, test or prod.' }
  return $null
}
$instance = Read-Answer 'Instance number' '01' {
  param($v)
  if ($v -notmatch '^\d{2}$') { return 'Two digits, e.g. 01.' }
  return $null
}

if (-not $ResourceGroup) {
  # Soft-deleted, purge-protected Key Vaults hold their names for 90 days, so a repeated resource
  # group name is a common way to make a second deployment fail for a reason nobody enjoys finding.
  $ResourceGroup = Read-Answer 'Resource group' "rg-aks-$customer-$environment-$instance" {
    param($v)
    if ($v -notmatch '^[A-Za-z0-9._\-()]{1,90}$') { return 'Not a valid resource group name.' }
    return $null
  }
}

# ================================================================================================
# 10. Write the plan
# ================================================================================================

$paramsDir = Join-Path $repoRoot 'infra/params'
if (-not $OutFile) {
  $OutFile = Join-Path $paramsDir "$architecture.local.bicepparam"
}
elseif (-not (Split-Path $OutFile -Parent)) {
  $OutFile = Join-Path $paramsDir $OutFile
}

# A .bicepparam resolves 'using ../main.bicep' and loadJsonContent('cost-tiers.json') relative to
# its own location, so a plan written anywhere else produces a wall of BCP091 file-not-found errors
# that say nothing about the real cause. Refuse early and say what the real cause is.
$outDir = (Resolve-Path (Split-Path $OutFile -Parent) -ErrorAction SilentlyContinue).Path
if ($outDir -ne (Resolve-Path $paramsDir).Path) {
  throw "The plan must be written into infra/params/, because a .bicepparam resolves its 'using' target and its loadJsonContent() paths relative to its own directory. Requested: $OutFile"
}

$template = Get-Content (Join-Path $PSScriptRoot 'lib/wizard-template.bicepparam.tmpl') -Raw

function Format-BicepArray([array] $Items) {
  if (-not $Items -or $Items.Count -eq 0) { return '[]' }
  return '[' + (($Items | ForEach-Object { "'$_'" }) -join ', ') + ']'
}

$replacements = @{
  '__GENERATED_ON__'   = (Get-Date -Format 'yyyy-MM-dd HH:mm')
  '__PURPOSE_LABEL__'  = $purpose.label
  '__COST_TIER__'      = $costTier
  '__ARCHITECTURE__'         = $architecture
  '__NETWORK_PROFILE__' = $networkProfile
  '__EGRESS__'         = $egress
  '__CUSTOMER__'       = $customer
  '__ENVIRONMENT__'    = $environment
  '__LOCATION__'       = $location
  '__INSTANCE__'       = $instance
  '__NODE_ZONES__'     = '1,2,3'
  '__NODE_COUNT__'     = $nodeCount
  '__NODE_VM_SIZE__'   = $nodeVmSize
  '__VNET__'           = $vnet
  '__NODE_SUBNET__'    = $nodeSubnet
  '__POD_SUBNET__'     = $podSubnet
  '__API_SUBNET__'     = $apiSubnet
  '__FIREWALL_SUBNET__' = $fwSubnet
  '__BASTION_SUBNET__' = $bastionSubnet
  '__PE_SUBNET__'      = $peSubnet
  '__DNS_IN_SUBNET__'  = $dnsIn
  '__DNS_OUT_SUBNET__' = $dnsOut
  '__SERVICE_CIDR__'   = $serviceCidr
  '__DNS_SERVICE_IP__' = $dnsServiceIp
  '__POD_CIDR__'       = $podCidr
  '__ON_PREM_CIDRS__'  = (Format-BicepArray $onPrem)
  '__ADMIN_GROUPS__'   = (Format-BicepArray $adminGroups)
  '__AUTHORIZED_IPS__' = (Format-BicepArray $authorizedIps)
  '__MANAGEMENT_RANGES__' = (Format-BicepArray $onPrem)
  '__ALERT_EMAIL__'    = $alertEmail
}
foreach ($k in $replacements.Keys) { $template = $template.Replace($k, [string]$replacements[$k]) }

# A leftover placeholder means the template and this script have drifted. Failing here is far
# better than writing a file that compiles into something nobody intended.
if ($template -match '__[A-Z0-9_]+__') {
  throw "Template placeholder $($Matches[0]) was not substituted. scripts/lib/wizard-template.bicepparam.tmpl and wizard.ps1 have drifted."
}

# TrimEnd, because Set-Content appends its own trailing newline and the template already ends with
# one. Without this the two wizards produce files that differ by a blank line, which is exactly the
# kind of harmless-looking drift that makes a real diff impossible to trust later.
Set-Content -Path $OutFile -Value $template.TrimEnd() -Encoding utf8
$env:AKS_COST_TIER = $costTier

# ================================================================================================
# 11. Show the plan, then confirm
# ================================================================================================

Write-Heading 'Your plan'
$rows = [ordered]@{
  'Purpose'          = "$($purpose.label)  (cost tier $costTier)"
  'Architecture'           = $architecture
  'API server'       = $architectureDef.apiServerAccess
  'Region'           = $location
  'Egress'           = "$egress  ->  outboundType $($matrix.egressModes.$egress.outboundType)"
  'Network profile'  = $networkProfile
  'VNet'             = $vnet
  'Node subnet'      = $nodeSubnet
  'Pod addressing'   = $(if ($podSubnet) { "pod subnet $podSubnet (VNet-routable)" } else { "overlay $podCidr (not VNet-routable)" })
  'API subnet'       = $(if ($apiSubnet) { $apiSubnet } else { 'n/a' })
  'Firewall subnet'  = $(if ($fwSubnet) { $fwSubnet } else { 'n/a' })
  'Service CIDR'     = "$serviceCidr  (DNS $dnsServiceIp)"
  'On-premises'      = $(if ($onPrem.Count) { $onPrem -join ', ' } else { 'none declared' })
  'System pool'      = "$nodeCount x $nodeVmSize across zones 1,2,3"
  'Entra admins'     = $(if ($adminGroups.Count) { $adminGroups -join ', ' } else { 'NONE - local accounts only' })
  'Authorized IPs'   = $(if ($authorizedIps.Count) { $authorizedIps -join ', ' } else { 'n/a' })
  'Alert email'      = $(if ($alertEmail) { $alertEmail } else { 'none' })
  'Resource group'   = $ResourceGroup
}
foreach ($k in $rows.Keys) { Write-Host ("  {0,-17} {1}" -f $k, $rows[$k]) }

Write-Host ''
foreach ($l in $guidance.closing.immutableWarning) { Write-Host "  $l" -ForegroundColor Magenta }

Write-Host ''
Write-Host "  Plan written to: $OutFile" -ForegroundColor Green
Write-Host '  That file is the whole plan. Keep it, review it, or re-run this wizard to replace it.' -ForegroundColor DarkGray

# The plan is compiled before anyone is asked to approve it, so a malformed answer surfaces here
# rather than sixty seconds into an ARM deployment.
Write-Host ''
Write-Host '  Compiling the plan...' -ForegroundColor DarkGray
$null = az bicep build-params --file $OutFile --stdout 2>&1
if ($LASTEXITCODE -ne 0) {
  Write-Host '  The generated plan does not compile. This is a bug in the wizard, not in your answers.' -ForegroundColor Red
  az bicep build-params --file $OutFile --stdout
  exit 1
}
Write-Host '  Compiles cleanly.' -ForegroundColor Green

$resolved = Resolve-BicepParamFile -Path $OutFile
$estimate = Get-CostEstimate -Params $resolved -Architecture $architectureDef
Write-CostEstimate -Estimate $estimate -Tier $costTier

Write-Host ''
foreach ($l in $guidance.closing.nextSteps) { Write-Host "  $l" -ForegroundColor DarkGray }

if ($PlanOnly) {
  Write-Host ''
  Write-Host '  Plan only, nothing deployed. When you are ready:' -ForegroundColor Cyan
  Write-Host "    `$env:AKS_COST_TIER = '$costTier'"
  Write-Host "    ./scripts/deploy.ps1 -Architecture $architecture -ResourceGroup $ResourceGroup -Location $location -ParamFile '$OutFile'"
  Write-Host ''
  exit 0
}

Write-Host ''
Write-Host '  Type deploy to build this, or anything else to stop.' -ForegroundColor White
Write-Host '  Nothing has been created yet.' -ForegroundColor DarkGray
Write-Host ''
Write-Host '  > ' -NoNewline -ForegroundColor White
if ((Read-Host).Trim().ToLower() -ne 'deploy') {
  Write-Host ''
  Write-Host '  Stopped. The plan is still on disk, so you can deploy it later with:' -ForegroundColor Yellow
  Write-Host "    ./scripts/deploy.ps1 -Architecture $architecture -ResourceGroup $ResourceGroup -Location $location -ParamFile '$OutFile'"
  Write-Host ''
  exit 0
}

# ================================================================================================
# 12. Deploy, through the ordinary path
#
# The wizard deliberately does not deploy anything itself. It hands the plan to the same script a
# pipeline would use, so the pre-flight gate, the cost gate, the firewall next-hop assertion and
# the governance proof all apply exactly as they would otherwise.
# ================================================================================================

$deployArgs = @{
  Architecture        = $architecture
  ResourceGroup = $ResourceGroup
  Location      = $location
  ParamFile     = $OutFile
  Yes           = $true
}
if ($onPrem.Count) { $deployArgs['OnPremisesCidrs'] = $onPrem }

& (Join-Path $PSScriptRoot 'deploy.ps1') @deployArgs
$deployRc = $LASTEXITCODE

if ($deployRc -ne 0) {
  Write-Host ''
  Write-Host '  The deployment did not complete. Nothing about your plan is lost - it is still at' -ForegroundColor Yellow
  Write-Host "  $OutFile and can be corrected and re-run." -ForegroundColor Yellow
  Write-Host ''
  Write-Host '  For a readable post-mortem of what failed and why:' -ForegroundColor Cyan
  Write-Host "    ./scripts/diagnose.ps1 -ResourceGroup $ResourceGroup"
  Write-Host ''
  exit $deployRc
}

Write-Heading 'What to try next'
Write-Host '  The cluster exists. These are worth doing in order, because each one proves something' -ForegroundColor DarkGray
Write-Host '  different about the shape you just built:' -ForegroundColor DarkGray
Write-Host ''
Write-Host '   1. Get credentials and list nodes. On a private architecture this is the moment you find out' -ForegroundColor White
Write-Host '      whether you actually have a network path - which is the point of the architecture.' -ForegroundColor DarkGray
Write-Host '   2. Prove the governance is real, not just assigned:' -ForegroundColor White
Write-Host "      ./scripts/verify-policy.ps1 -ResourceGroup $ResourceGroup -ClusterName <cluster> -WaitMinutes 20" -ForegroundColor DarkGray
Write-Host '   3. Stop paying for it without destroying it:' -ForegroundColor White
Write-Host "      ./scripts/pause.ps1 -ResourceGroup $ResourceGroup" -ForegroundColor DarkGray
Write-Host '   4. Remove it completely, including role assignments and policy definitions:' -ForegroundColor White
Write-Host "      ./scripts/destroy.ps1 -Architecture $architecture -ResourceGroup $ResourceGroup" -ForegroundColor DarkGray
Write-Host ''
