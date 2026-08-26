metadata description = 'Architecture-driven AKS deployment. This file is the only place that reads architecture-matrix.json and turns an architecture into concrete Azure primitives. Every module below receives primitives, never an architecture name, so no module contains architecture switch logic.'

targetScope = 'resourceGroup'

import {
  architectureType
  networkProfileType
  egressType
  environmentType
  addressingType
  nodePoolType
  maintenanceType
  featuresType
  roleIdsType
  externalsType
} from './types.bicep'

import { abbreviations, geoCodes, hyphenated, compact, keyVaultName } from './modules/naming/naming.bicep'

// ---------------------------------------------------------------------------------------------
// Identity of the environment
// ---------------------------------------------------------------------------------------------

@minLength(2)
@maxLength(8)
@description('Short customer or business unit code, used in every resource name. Capped at eight because a storage account name is capped at 24 and the other five segments (st + prod + geo + instance + uniqueness suffix) already spend 16 of them.')
param customer string

param environment environmentType

@description('Azure region. For aks-arc-local this is the region the Arc projection lives in, not where the cluster runs.')
param location string = resourceGroup().location

@minLength(2)
@maxLength(3)
@description('Instance number, so a second environment can sit beside the first.')
param instance string = '01'

param tags object = {}

// ---------------------------------------------------------------------------------------------
// The three choices that define the cluster. All immutable after creation.
// ---------------------------------------------------------------------------------------------

param architecture architectureType

@description('Ignored by aks-arc-local and arc-attach-existing, which have no Azure-region network.')
param networkProfile networkProfileType = 'cni-overlay'

@description('Ignored by aks-arc-local and arc-attach-existing.')
param egress egressType = 'natgateway'

// ---------------------------------------------------------------------------------------------
// Addressing
// ---------------------------------------------------------------------------------------------

param addressing addressingType

// ---------------------------------------------------------------------------------------------
// Cluster shape
// ---------------------------------------------------------------------------------------------

param systemNodePool nodePoolType

param deployUserNodePool bool = true

param userNodePool nodePoolType = systemNodePool

param userNodePoolName string = 'user'

@description('Empty means AKS picks the current default, which is the safest choice for a first deployment.')
param kubernetesVersion string = ''

param autoUpgradeChannel 'rapid' | 'stable' | 'patch' | 'node-image' | 'none' = 'stable'

param nodeOsUpgradeChannel 'None' | 'Unmanaged' | 'NodeImage' | 'SecurityPatch' = 'NodeImage'

param maintenance maintenanceType = {
  utcOffset: '-05:00'
  dayOfWeek: 'Sunday'
  startTime: '02:00'
  durationHours: 4
}

@description('Leave unset to let the template pick: 110 when pods sit on a VNet subnet, 250 for overlay.')
@minValue(10)
@maxValue(250)
param maxPodsPerNode int?

@description('Encrypts the temp disk and OS disk cache on the node host. Requires the subscription feature EncryptionAtHost to be registered.')
param enableEncryptionAtHost bool = false

@description('Local SSH on nodes. Disabled is correct once Bastion or run-command is available.')
param nodeSshAccess 'LocalUser' | 'Disabled' = 'Disabled'

// ---------------------------------------------------------------------------------------------
// Access control
// ---------------------------------------------------------------------------------------------

@description('Entra group object IDs granted cluster-admin. Leave empty only if you intend to manage access entirely through separate role assignments.')
param adminGroupObjectIds string[] = []

@description('Required by aks-public-authorized-ip. The cluster egress IP is appended automatically when egress is natgateway or udr-firewall.')
param authorizedIpRanges string[] = []

@description('Object ID of the human or service principal running the deployment. Granted cluster admin and Grafana admin so the deployment is usable immediately.')
param deploymentPrincipalId string = ''

param deploymentPrincipalType 'User' | 'Group' | 'ServicePrincipal' = 'User'

@description('Role definition GUIDs resolved by display name in deploy.*, because this tenant does not use the well-known GUIDs for every built-in role.')
param roleIds roleIdsType

// ---------------------------------------------------------------------------------------------
// Platform features
// ---------------------------------------------------------------------------------------------

param features featuresType = {
  defenderForContainers: true
  containerInsights: true
  managedPrometheus: true
  managedGrafana: true
  diagnosticSettings: true
  azurePolicyAddon: true
  workloadIdentity: true
  keyVaultSecretsProvider: true
  imageCleaner: true
  containerRegistry: true
  keyVault: true
  storage: true
  privateDnsResolver: false
  policyAssignments: true
  bastion: false
  flux: false
}

@description('Premium adds IDPS and TLS inspection. Standard is enough for the AKS egress allowlist.')
param firewallSkuTier 'Standard' | 'Premium' = 'Standard'

@description('Free and Standard are the same cluster up to 1,000 nodes; Standard adds a financially backed 99.95% API server SLA and charges per cluster hour for it. Production runs Standard. The Automatic SKU forces Standard regardless of this value.')
param clusterSkuTier 'Free' | 'Standard' = 'Free'

@description('Basic is the evaluation tier: Entra-authenticated but on the public endpoint. Premium is required for the private endpoint and publicNetworkAccess=Disabled, and costs roughly ten times as much.')
param containerRegistrySku 'Basic' | 'Standard' | 'Premium' = 'Basic'

@description('Managed Grafana tier. Essential is materially cheaper but carries no availability SLA and no per-user included quota.')
param grafanaSku 'Standard' | 'Essential' = 'Standard'

@description('Log Analytics interactive retention. 30 days is the free floor for most tables; longer costs per GB per month.')
@minValue(30)
@maxValue(730)
param logAnalyticsRetentionDays int = 30

@description('Hard ingestion cap in GB/day, the backstop against a runaway log bill. -1 removes the cap. Once the cap is hit telemetry is dropped silently until the next UTC day.')
param logAnalyticsDailyQuotaGb int = 1

@description('Purge protection blocks a hard delete of the Key Vault for the full retention period and CANNOT be turned off once enabled. Production wants it on. It is off by default here because the vault name is derived from the resource group ID, so leaving it on makes a torn-down environment impossible to redeploy under the same group name until retention expires.')
param keyVaultPurgeProtection bool = false

@description('Where the node bootstrap failure alert sends notifications. Empty still creates the rule and the action group, so the alert is visible in Azure Monitor; it just has nobody to email. A receiver can be added later without redeploying the rule.')
param alertNotificationEmail string = ''

@description('Source ranges permitted to reach management ports through the NSGs, for example the on-premises jumpbox range.')
param managementSourceRanges string[] = []

@description('Extra FQDNs the workload needs outbound, on top of the AKS required set. Only used when egress is udr-firewall.')
param additionalAllowedFqdns string[] = []

@description('Ranges routed to a virtual network gateway instead of the firewall. Only set these when this VNet actually holds an ExpressRoute or VPN gateway, otherwise the route is a black hole.')
param firewallBypassCidrs string[] = []

@description('Additional VNets to link to the private DNS zones, typically a hub or an on-premises-facing VNet.')
param additionalVnetIdsToLink string[] = []

@description('Conditional forwarders for the private DNS resolver, in the shape expected by modules/dns/private-resolver.bicep.')
param dnsForwardingRules array = []

@description('Resource ID of the custom deny-public-IP definition produced by infra/subscription-policy.bicep. Empty skips that assignment.')
param denyPublicIpPolicyDefinitionId string = ''

param policyEffect 'Audit' | 'Deny' | 'Disabled' = 'Deny'

// ---------------------------------------------------------------------------------------------
// GitOps
// ---------------------------------------------------------------------------------------------

param fluxGitRepositoryUrl string = ''
param fluxGitBranch string = 'main'
param fluxGitPath string = 'clusters/default'

// ---------------------------------------------------------------------------------------------
// Externally supplied resources
// ---------------------------------------------------------------------------------------------

param externals externalsType = {
  existingVnetId: ''
  existingNodeSubnetId: ''
  existingConnectedClusterId: ''
  customLocationId: ''
  logicalNetworkId: ''
  arcLocalSshPublicKey: ''
}

@description('Only used by aks-arc-local. Static API server address taken from the reserved range of the logical network.')
param arcLocalControlPlaneHostIp string = ''

@description('Only used by aks-arc-local. VM size offered by the Arc Resource Bridge.')
param arcLocalVmSize string = 'Standard_A4_v2'

// =============================================================================================
// Architecture resolution. Everything below this line is derived, never chosen.
// =============================================================================================

var matrix = loadJsonContent('architecture-matrix.json')
var architectureDef = matrix.architectures[architecture]

var isAzureRegion = bool(architectureDef.azureRegion)
var createsCluster = bool(architectureDef.createsCluster)

// Non-Azure-region architectures have no Azure network, so the caller's choice is discarded rather than
// silently half-applied.
var effectiveNetworkProfile = isAzureRegion ? networkProfile : 'none'
var effectiveEgress = isAzureRegion ? egress : 'none'

var np = matrix.networkProfiles[effectiveNetworkProfile]
var eg = matrix.egressModes[effectiveEgress]

var apiServerAccess = architectureDef.apiServerAccess
var isAutomatic = architectureDef.skuName == 'Automatic'
var isPrivateCluster = bool(architectureDef.privateCluster)

// ---------------------------------------------------------------------------------------------
// Validation gate.
//
// architecture-matrix.json contains exactly one key under validationGate: "ok". Indexing it with any
// other string is a hard template error, and ARM prints the key it could not find. That turns an
// invalid combination into a readable failure at template evaluation time, before a single
// resource is touched. scripts/preflight.* reads the same JSON and prints the same messages in a
// friendlier form first.
// ---------------------------------------------------------------------------------------------

var validationFailures = filter(
  [
    contains(architectureDef.networkProfiles, effectiveNetworkProfile)
      ? ''
      : 'INVALID COMBINATION: architecture "${architecture}" does not support networkProfile "${networkProfile}". Supported: ${join(architectureDef.networkProfiles, ', ')}.'
    contains(architectureDef.egress, effectiveEgress)
      ? ''
      : 'INVALID COMBINATION: architecture "${architecture}" does not support egress "${egress}". Supported: ${join(architectureDef.egress, ', ')}.'
    (!contains(architectureDef.requiredParams, 'authorizedIpRanges') || !empty(authorizedIpRanges))
      ? ''
      : 'MISSING PARAMETER: architecture "${architecture}" requires authorizedIpRanges. Supply at least the CIDR your operators connect from.'
    (apiServerAccess != 'vnetIntegration' || !empty(addressing.apiServerSubnetPrefix))
      ? ''
      : 'MISSING PARAMETER: architecture "${architecture}" uses API Server VNet Integration, so addressing.apiServerSubnetPrefix is required. Minimum /28, and it must not be shared with nodes.'
    (!contains(architectureDef.requiredParams, 'customLocationId') || !empty(externals.customLocationId))
      ? ''
      : 'MISSING PARAMETER: architecture "${architecture}" requires externals.customLocationId. List them with: az customlocation list -o table'
    (!contains(architectureDef.requiredParams, 'logicalNetworkId') || !empty(externals.logicalNetworkId))
      ? ''
      : 'MISSING PARAMETER: architecture "${architecture}" requires externals.logicalNetworkId. List them with: az stack-hci-vm network lnet list -o table'
    (!contains(architectureDef.requiredParams, 'existingConnectedClusterId') || !empty(externals.existingConnectedClusterId))
      ? ''
      : 'MISSING PARAMETER: architecture "${architecture}" requires externals.existingConnectedClusterId. Run scripts/arc-onboard.ps1 first.'
    (!np.requiresPodSubnet || !empty(addressing.podSubnetPrefix))
      ? ''
      : 'MISSING PARAMETER: networkProfile "${networkProfile}" puts pods on a VNet subnet, so addressing.podSubnetPrefix is required.'
    (!np.requiresPodCidr || !empty(addressing.podCidr))
      ? ''
      : 'MISSING PARAMETER: networkProfile "${networkProfile}" uses an overlay, so addressing.podCidr is required.'
    (!bool(eg.requiresFirewall) || !empty(addressing.firewallSubnetPrefix))
      ? ''
      : 'MISSING PARAMETER: egress "${egress}" deploys Azure Firewall, so addressing.firewallSubnetPrefix is required and must be /26 or larger.'
    (!features.bastion || !empty(addressing.bastionSubnetPrefix))
      ? ''
      : 'MISSING PARAMETER: features.bastion is on, so addressing.bastionSubnetPrefix is required and must be /26 or larger.'
    (!features.privateDnsResolver || (!empty(addressing.dnsResolverInboundPrefix) && !empty(addressing.dnsResolverOutboundPrefix)))
      ? ''
      : 'MISSING PARAMETER: features.privateDnsResolver is on, so addressing.dnsResolverInboundPrefix and addressing.dnsResolverOutboundPrefix are required, each /28 or larger.'
    (!features.flux || !empty(fluxGitRepositoryUrl))
      ? ''
      : 'MISSING PARAMETER: features.flux is on, so fluxGitRepositoryUrl is required.'
    (architecture != 'aks-arc-local' || !empty(externals.arcLocalSshPublicKey))
      ? ''
      : 'MISSING PARAMETER: architecture "aks-arc-local" requires externals.arcLocalSshPublicKey. There is no Azure-side password reset for Azure Local nodes.'
  ],
  message => !empty(message)
)

var gateOk = matrix.validationGate[empty(validationFailures) ? 'ok' : validationFailures[0]]

// =============================================================================================
// Naming
// =============================================================================================

var geo = geoCodes[?location] ?? substring(location, 0, 3)
var uniqueSuffix = substring(uniqueString(resourceGroup().id), 0, 4)

var names = {
  vnet: hyphenated(abbreviations.virtualNetwork, customer, environment, geo, instance)
  nsgPrefix: hyphenated(abbreviations.networkSecurityGroup, customer, environment, geo, instance)
  routeTable: hyphenated(abbreviations.routeTable, customer, environment, geo, instance)
  natGateway: hyphenated(abbreviations.natGateway, customer, environment, geo, instance)
  firewall: hyphenated(abbreviations.firewall, customer, environment, geo, instance)
  firewallPolicy: hyphenated(abbreviations.firewallPolicy, customer, environment, geo, instance)
  bastion: hyphenated(abbreviations.bastion, customer, environment, geo, instance)
  dnsResolver: hyphenated(abbreviations.privateDnsResolver, customer, environment, geo, instance)
  cluster: hyphenated(abbreviations.managedCluster, customer, environment, geo, instance)
  connectedCluster: hyphenated(abbreviations.connectedCluster, customer, environment, geo, instance)
  clusterIdentity: '${hyphenated(abbreviations.userAssignedIdentity, customer, environment, geo, instance)}-aks'
  kubeletIdentity: '${hyphenated(abbreviations.userAssignedIdentity, customer, environment, geo, instance)}-kubelet'
  logAnalytics: hyphenated(abbreviations.logAnalytics, customer, environment, geo, instance)
  azureMonitorWorkspace: hyphenated(abbreviations.azureMonitorWorkspace, customer, environment, geo, instance)
  grafana: hyphenated(abbreviations.grafana, customer, environment, geo, instance)
  dataCollectionEndpoint: hyphenated(abbreviations.dataCollectionEndpoint, customer, environment, geo, instance)
  containerInsightsDcr: '${hyphenated(abbreviations.dataCollectionRule, customer, environment, geo, instance)}-ci'
  prometheusDcr: '${hyphenated(abbreviations.dataCollectionRule, customer, environment, geo, instance)}-prom'
  registry: compact(abbreviations.containerRegistry, customer, environment, geo, instance, uniqueSuffix)
  keyVault: keyVaultName(customer, environment, geo, instance, uniqueSuffix)
  storage: compact(abbreviations.storageAccount, customer, environment, geo, instance, uniqueSuffix)
  policyPrefix: '${customer}-${environment}-${geo}-${instance}'
}

var baseTags = union(tags, {
  customer: customer
  environment: environment
  architecture: architecture
  networkProfile: effectiveNetworkProfile
  egress: effectiveEgress
  managedBy: 'aks-architectures'
})

// Public IPs created by the platform itself carry the exception tag so the deny-public-IP policy
// can be enforced on the same resource group without blocking redeployment.
var platformIpTags = union(baseTags, {
  publicIpException: 'platform-egress'
})

// =============================================================================================
// What gets deployed. Every flag folds in gateOk, so an invalid combination fails before any
// resource is evaluated rather than half way through.
// =============================================================================================

var buildAzureNetwork = gateOk && isAzureRegion
var buildAksCluster = gateOk && isAzureRegion && createsCluster
var buildArcLocal = gateOk && architecture == 'aks-arc-local'
var attachExistingArc = gateOk && architecture == 'arc-attach-existing'
var buildAnyArc = buildArcLocal || attachExistingArc

var deployPodSubnet = buildAzureNetwork && bool(np.requiresPodSubnet)
// The Automatic SKU always runs a managed system node pool. Giving it a subnet of our own is what
// keeps it inside the bring-your-own VNet; without it AKS rejects every egress mode except the
// managed load balancer.
var deploySystemNodeSubnet = buildAzureNetwork && isAutomatic && !empty(addressing.systemNodeSubnetPrefix)
var deployApiServerSubnet = buildAzureNetwork && apiServerAccess == 'vnetIntegration'
var deployFirewall = buildAzureNetwork && bool(eg.requiresFirewall)
var deployNatGateway = buildAzureNetwork && bool(eg.requiresNatGateway)
var deployRouteTable = buildAzureNetwork && bool(eg.requiresRouteTable)
var deployBastion = buildAzureNetwork && features.bastion
var deployDnsResolver = buildAzureNetwork && features.privateDnsResolver
var deployAksPrivateDnsZone = buildAzureNetwork && apiServerAccess == 'privateLink'

var deployRegistry = gateOk && features.containerRegistry && isAzureRegion
var deployKeyVault = gateOk && features.keyVault && isAzureRegion
var deployStorage = gateOk && features.storage && isAzureRegion

var deployWorkspace = gateOk && (features.containerInsights || features.diagnosticSettings || features.defenderForContainers)
var deployContainerInsights = gateOk && features.containerInsights && buildAksCluster
var deployPrometheus = gateOk && features.managedPrometheus && buildAksCluster
var deployFlux = gateOk && features.flux && (buildAksCluster || buildAnyArc)

var maxPods = maxPodsPerNode ?? (bool(np.requiresPodSubnet) ? 110 : 250)

// The floor the node bootstrap alert compares against. With the autoscaler on, a pool is only
// guaranteed to hold minCount, so using count would fire the alert every time the cluster scaled
// in. AKS Automatic sizes its own pools, so all that can be asserted there is that one node
// joined; below that the cluster is not running at all, which is exactly what we want to catch.
var systemPoolFloor = systemNodePool.enableAutoScaling ? systemNodePool.minCount : systemNodePool.count
var userPoolFloor = deployUserNodePool && !isAutomatic
  ? (userNodePool.enableAutoScaling ? userNodePool.minCount : userNodePool.count)
  : 0
var expectedReadyNodeCount = isAutomatic ? 1 : max(systemPoolFloor + userPoolFloor, 1)

// =============================================================================================
// Networking
// =============================================================================================

module nsgs 'modules/network/nsg.bicep' = if (buildAzureNetwork) {
  name: 'nsgs'
  params: {
    namePrefix: names.nsgPrefix
    location: location
    tags: baseTags
    deployPodNsg: deployPodSubnet
    deployApiServerNsg: deployApiServerSubnet
    deployBastionNsg: deployBastion
    managementSourceRanges: managementSourceRanges
  }
}

module routeTable 'modules/network/routetable.bicep' = if (deployRouteTable) {
  name: 'routetable'
  params: {
    name: names.routeTable
    location: location
    tags: baseTags
    firewallSubnetPrefix: addressing.firewallSubnetPrefix
    bypassCidrs: firewallBypassCidrs
  }
}

module natGateway 'modules/network/natgateway.bicep' = if (deployNatGateway) {
  name: 'natgateway'
  params: {
    name: names.natGateway
    location: location
    tags: platformIpTags
    publicIpCount: 1
  }
}

module vnet 'modules/network/vnet.bicep' = if (buildAzureNetwork) {
  name: 'vnet'
  params: {
    name: names.vnet
    location: location
    tags: baseTags
    vnetAddressSpace: addressing.vnetAddressSpace
    nodeSubnetPrefix: addressing.nodeSubnetPrefix
    systemNodeSubnetPrefix: addressing.systemNodeSubnetPrefix
    podSubnetPrefix: addressing.podSubnetPrefix
    apiServerSubnetPrefix: addressing.apiServerSubnetPrefix
    firewallSubnetPrefix: addressing.firewallSubnetPrefix
    bastionSubnetPrefix: addressing.bastionSubnetPrefix
    privateEndpointSubnetPrefix: addressing.privateEndpointSubnetPrefix
    dnsResolverInboundPrefix: addressing.dnsResolverInboundPrefix
    dnsResolverOutboundPrefix: addressing.dnsResolverOutboundPrefix
    deployPodSubnet: deployPodSubnet
    deploySystemNodeSubnet: deploySystemNodeSubnet
    deployApiServerSubnet: deployApiServerSubnet
    deployFirewallSubnet: deployFirewall
    deployBastionSubnet: deployBastion
    deployDnsResolverSubnets: deployDnsResolver
    nodeNsgId: nsgs!.outputs.nodesId
    podNsgId: nsgs!.outputs.podsId
    apiServerNsgId: nsgs!.outputs.apiServerId
    privateEndpointNsgId: nsgs!.outputs.privateEndpointsId
    bastionNsgId: nsgs!.outputs.bastionId
    routeTableId: deployRouteTable ? routeTable!.outputs.id : ''
    natGatewayId: deployNatGateway ? natGateway!.outputs.id : ''
  }
}

module firewall 'modules/firewall/firewall.bicep' = if (deployFirewall) {
  name: 'firewall'
  params: {
    name: names.firewall
    policyName: names.firewallPolicy
    location: location
    tags: platformIpTags
    firewallSubnetId: vnet!.outputs.firewallSubnetId
    skuTier: firewallSkuTier
    clusterRegion: location
    sourceCidrs: union(
      union([addressing.nodeSubnetPrefix], deployPodSubnet ? [addressing.podSubnetPrefix] : []),
      deploySystemNodeSubnet ? [addressing.systemNodeSubnetPrefix] : []
    )
    nodeOsSku: systemNodePool.osSku
    allowFluxGitEndpoints: features.flux
    additionalAllowedFqdns: additionalAllowedFqdns
  }
}

module bastion 'modules/bastion/bastion.bicep' = if (deployBastion) {
  name: 'bastion'
  params: {
    name: names.bastion
    location: location
    tags: platformIpTags
    bastionSubnetId: vnet!.outputs.bastionSubnetId
  }
}

// =============================================================================================
// Private DNS
// =============================================================================================

module privateDnsZones 'modules/dns/private-zones.bicep' = if (buildAzureNetwork) {
  name: 'private-dns-zones'
  params: {
    location: 'global'
    tags: baseTags
    vnetId: vnet!.outputs.id
    deployAcrZone: deployRegistry
    deployKeyVaultZone: deployKeyVault
    deployStorageZone: deployStorage
    deployAksZone: deployAksPrivateDnsZone
    clusterRegion: location
    additionalVnetIds: additionalVnetIdsToLink
  }
}

module dnsResolver 'modules/dns/private-resolver.bicep' = if (deployDnsResolver) {
  name: 'dns-resolver'
  params: {
    name: names.dnsResolver
    location: location
    tags: baseTags
    vnetId: vnet!.outputs.id
    inboundSubnetId: vnet!.outputs.dnsResolverInboundSubnetId
    outboundSubnetId: vnet!.outputs.dnsResolverOutboundSubnetId
    forwardingRules: dnsForwardingRules
    rulesetVnetIds: additionalVnetIdsToLink
  }
}

// =============================================================================================
// Supporting data plane
// =============================================================================================

module workspace 'modules/monitoring/log-analytics.bicep' = if (deployWorkspace) {
  name: 'log-analytics'
  params: {
    name: names.logAnalytics
    location: location
    tags: baseTags
    retentionInDays: logAnalyticsRetentionDays
    dailyQuotaGb: logAnalyticsDailyQuotaGb
  }
}

var workspaceId = deployWorkspace ? workspace!.outputs.id : ''

module registry 'modules/acr/acr.bicep' = if (deployRegistry) {
  name: 'acr'
  params: {
    name: names.registry
    location: location
    tags: baseTags
    skuName: containerRegistrySku
    privateEndpointSubnetId: vnet!.outputs.privateEndpointSubnetId
    privateDnsZoneId: privateDnsZones!.outputs.acrZoneId
    privateEndpointName: '${abbreviations.privateEndpoint}-${names.registry}'
    logAnalyticsWorkspaceId: workspaceId
  }
}

module vault 'modules/keyvault/keyvault.bicep' = if (deployKeyVault) {
  name: 'keyvault'
  params: {
    name: names.keyVault
    location: location
    tags: baseTags
    privateEndpointSubnetId: vnet!.outputs.privateEndpointSubnetId
    privateDnsZoneId: privateDnsZones!.outputs.keyVaultZoneId
    privateEndpointName: '${abbreviations.privateEndpoint}-${names.keyVault}'
    logAnalyticsWorkspaceId: workspaceId
    enablePurgeProtection: keyVaultPurgeProtection
    // The vault name is derived from the resource group ID, so a redeploy into the same group
    // regenerates it. Without purge protection the destroy script can purge, and 7 days rather
    // than 90 bounds the damage if it cannot.
    softDeleteRetentionInDays: keyVaultPurgeProtection ? 90 : 7
  }
}

module storage 'modules/storage/storage.bicep' = if (deployStorage) {
  name: 'storage'
  params: {
    name: names.storage
    location: location
    tags: baseTags
    privateEndpointSubnetId: vnet!.outputs.privateEndpointSubnetId
    privateDnsZoneId: privateDnsZones!.outputs.storageZoneId
    privateEndpointName: '${abbreviations.privateEndpoint}-${names.storage}'
    logAnalyticsWorkspaceId: workspaceId
    containers: ['workload']
  }
}

// =============================================================================================
// Cluster identity and the role assignments that must exist before the cluster is created
// =============================================================================================

module identities 'modules/identity/identity.bicep' = if (buildAksCluster) {
  name: 'identities'
  params: {
    clusterIdentityName: names.clusterIdentity
    kubeletIdentityName: names.kubeletIdentity
    location: location
    tags: baseTags
  }
}

module preClusterRbac 'modules/rbac/pre-cluster.bicep' = if (buildAksCluster) {
  name: 'rbac-pre-cluster'
  params: {
    roleIds: roleIds
    clusterIdentityPrincipalId: identities!.outputs.clusterIdentityPrincipalId
    kubeletIdentityPrincipalId: identities!.outputs.kubeletIdentityPrincipalId
    kubeletIdentityName: identities!.outputs.kubeletIdentityName
    vnetName: vnet!.outputs.name
    acrName: deployRegistry ? registry!.outputs.name : ''
    privateDnsZoneName: deployAksPrivateDnsZone ? privateDnsZones!.outputs.aksZoneName : ''
    routeTableName: deployRouteTable ? routeTable!.outputs.name : ''
  }
}

// =============================================================================================
// Monitoring plumbing that has to exist before the cluster so the cluster can be attached to it
// =============================================================================================

module containerInsightsDcr 'modules/monitoring/container-insights.bicep' = if (deployContainerInsights) {
  name: 'container-insights-dcr'
  params: {
    name: names.containerInsightsDcr
    location: location
    tags: baseTags
    workspaceId: workspaceId
  }
}

module prometheus 'modules/monitoring/prometheus-grafana.bicep' = if (deployPrometheus) {
  name: 'prometheus-grafana'
  params: {
    azureMonitorWorkspaceName: names.azureMonitorWorkspace
    dataCollectionEndpointName: names.dataCollectionEndpoint
    dataCollectionRuleName: names.prometheusDcr
    grafanaName: names.grafana
    location: location
    tags: baseTags
    roleIds: roleIds
    deployGrafana: features.managedGrafana
    grafanaSku: grafanaSku
  }
}

// =============================================================================================
// The cluster
// =============================================================================================

// With a managed outbound load balancer AKS adds its own egress address to the allowlist. With a
// NAT Gateway or a firewall it does not, and the nodes lock themselves out of their own API server
// on the first kubelet reconnect. Appending it here is what stops that.
var egressPublicIp = deployNatGateway
  ? natGateway!.outputs.egressIpAddresses[0]
  : (deployFirewall ? firewall!.outputs.publicIpAddress : '')

var egressCidrs = empty(egressPublicIp) ? [] : ['${egressPublicIp}/32']

var effectiveAuthorizedIpRanges = apiServerAccess == 'authorizedIpRanges'
  ? union(authorizedIpRanges, egressCidrs)
  : []

module aks 'modules/aks/aks.bicep' = if (buildAksCluster) {
  name: 'aks'
  params: {
    name: names.cluster
    location: location
    tags: baseTags
    dnsPrefix: '${customer}-${environment}-${instance}'
    kubernetesVersion: kubernetesVersion
    skuName: isAutomatic ? 'Automatic' : 'Base'
    skuTier: clusterSkuTier
    nodeResourceGroupName: '${names.cluster}-nodes'
    nodeResourceGroupRestriction: isAutomatic ? 'ReadOnly' : 'Unrestricted'
    clusterIdentityId: identities!.outputs.clusterIdentityId
    kubeletIdentityResourceId: identities!.outputs.kubeletIdentityId
    kubeletIdentityClientId: identities!.outputs.kubeletIdentityClientId
    kubeletIdentityObjectId: identities!.outputs.kubeletIdentityObjectId
    adminGroupObjectIds: adminGroupObjectIds
    enablePrivateCluster: isPrivateCluster
    disablePublicFqdn: isPrivateCluster
    privateDnsZoneMode: deployAksPrivateDnsZone ? privateDnsZones!.outputs.aksZoneId : 'system'
    enableVnetIntegration: apiServerAccess == 'vnetIntegration'
    apiServerSubnetId: deployApiServerSubnet ? vnet!.outputs.apiServerSubnetId : ''
    authorizedIpRanges: effectiveAuthorizedIpRanges
    networkPlugin: np.networkPlugin
    networkPluginMode: np.networkPluginMode
    networkDataplane: np.networkDataplane
    networkPolicy: np.networkPolicy
    serviceCidr: addressing.serviceCidr
    dnsServiceIp: addressing.dnsServiceIp
    podCidr: bool(np.requiresPodCidr) ? addressing.podCidr : ''
    outboundType: eg.outboundType
    systemNodePool: systemNodePool
    nodeSubnetId: vnet!.outputs.nodeSubnetId
    systemNodeSubnetId: deploySystemNodeSubnet ? vnet!.outputs.systemNodeSubnetId : ''
    podSubnetId: deployPodSubnet ? vnet!.outputs.podSubnetId : ''
    maxPods: maxPods
    sshAccess: nodeSshAccess
    enableEncryptionAtHost: enableEncryptionAtHost
    autoUpgradeChannel: autoUpgradeChannel
    nodeOsUpgradeChannel: nodeOsUpgradeChannel
    logAnalyticsWorkspaceId: features.containerInsights ? workspaceId : ''
    enableAzurePolicy: features.azurePolicyAddon
    enableKeyVaultSecretsProvider: features.keyVaultSecretsProvider
    enableWorkloadIdentity: features.workloadIdentity
    enableImageCleaner: features.imageCleaner
    enableDefenderForContainers: features.defenderForContainers && deployWorkspace
    enableManagedPrometheus: features.managedPrometheus
  }
  dependsOn: [
    preClusterRbac
  ]
}

module userPool 'modules/aks/nodepool.bicep' = if (buildAksCluster && deployUserNodePool && !isAutomatic) {
  name: 'aks-user-pool'
  params: {
    clusterName: aks!.outputs.name
    poolName: userNodePoolName
    pool: userNodePool
    nodeSubnetId: vnet!.outputs.nodeSubnetId
    podSubnetId: deployPodSubnet ? vnet!.outputs.podSubnetId : ''
    maxPods: maxPods
    sshAccess: nodeSshAccess
    enableEncryptionAtHost: enableEncryptionAtHost
  }
}

// AKS Automatic manages its own upgrade cadence, so a maintenance window on it is rejected.
module maintenanceWindows 'modules/aks/maintenance.bicep' = if (buildAksCluster && !isAutomatic) {
  name: 'aks-maintenance'
  params: {
    clusterName: aks!.outputs.name
    maintenance: maintenance
  }
  dependsOn: [
    userPool
  ]
}

// A node that fails bootstrap never registers with the API server, so it does not show up as
// NotReady. It simply is not there. The only signal is a Ready count below what was asked for,
// which is what this rule watches. It is deployed on every tier because a metric alert rule
// costs cents per month and this is the failure the whole reference environment exists to teach.
module alerts 'modules/monitoring/alerts.bicep' = if (buildAksCluster) {
  name: 'alerts'
  params: {
    location: location
    namePrefix: names.policyPrefix
    tags: baseTags
    clusterId: aks!.outputs.id
    expectedReadyNodeCount: expectedReadyNodeCount
    notificationEmail: alertNotificationEmail
  }
  dependsOn: [
    userPool
  ]
}

// =============================================================================================
// Post-cluster wiring
// =============================================================================================

module clusterMonitoring 'modules/monitoring/cluster-attach.bicep' = if (buildAksCluster && (deployContainerInsights || deployPrometheus)) {
  name: 'cluster-monitoring-attach'
  params: {
    clusterName: aks!.outputs.name
    location: location
    containerInsightsDcrId: deployContainerInsights ? containerInsightsDcr!.outputs.id : ''
    prometheusDcrId: deployPrometheus ? prometheus!.outputs.dataCollectionRuleId : ''
    azureMonitorWorkspaceId: deployPrometheus ? prometheus!.outputs.azureMonitorWorkspaceId : ''
  }
}

module clusterDiagnostics 'modules/monitoring/diagnostics.bicep' = if (buildAksCluster && features.diagnosticSettings && deployWorkspace) {
  name: 'cluster-diagnostics'
  params: {
    clusterName: aks!.outputs.name
    workspaceId: workspaceId
  }
}

module postClusterRbac 'modules/rbac/post-cluster.bicep' = if (buildAksCluster) {
  name: 'rbac-post-cluster'
  params: {
    roleIds: roleIds
    clusterName: aks!.outputs.name
    adminGroupObjectIds: adminGroupObjectIds
    deploymentPrincipalId: deploymentPrincipalId
    deploymentPrincipalType: deploymentPrincipalType
    grafanaName: deployPrometheus && features.managedGrafana ? prometheus!.outputs.grafanaName : ''
  }
}

module csiKeyVaultRbac 'modules/rbac/csi-keyvault.bicep' = if (buildAksCluster && deployKeyVault && features.keyVaultSecretsProvider) {
  name: 'rbac-csi-keyvault'
  params: {
    roleIds: roleIds
    keyVaultName: vault!.outputs.name
    csiDriverPrincipalId: aks!.outputs.csiDriverPrincipalId
  }
}

// =============================================================================================
// Arc architectures
// =============================================================================================

module arcLocal 'modules/arc/provisioned-cluster.bicep' = if (buildArcLocal) {
  name: 'arc-local-cluster'
  params: {
    name: names.connectedCluster
    location: location
    tags: baseTags
    customLocationId: externals.customLocationId
    logicalNetworkId: externals.logicalNetworkId
    sshPublicKey: externals.arcLocalSshPublicKey
    kubernetesVersion: kubernetesVersion
    controlPlaneVmSize: arcLocalVmSize
    controlPlaneHostIp: arcLocalControlPlaneHostIp
    agentPoolCount: systemNodePool.count
    agentPoolVmSize: arcLocalVmSize
    podCidr: addressing.podCidr
    adminGroupObjectIds: adminGroupObjectIds
  }
}

var arcClusterName = buildArcLocal
  ? names.connectedCluster
  : (attachExistingArc ? last(split(externals.existingConnectedClusterId, '/')) : '')

module arcExtensions 'modules/arc/connected-cluster-extensions.bicep' = if (buildAnyArc) {
  name: 'arc-extensions'
  params: {
    connectedClusterName: arcClusterName
    logAnalyticsWorkspaceId: workspaceId
    enableContainerInsights: features.containerInsights && deployWorkspace
    enableDefenderForContainers: features.defenderForContainers
    enableAzurePolicy: features.azurePolicyAddon
  }
  dependsOn: [
    arcLocal
  ]
}

// =============================================================================================
// Governance and GitOps
// =============================================================================================

module policies 'modules/policy/policy-assignments.bicep' = if (gateOk && features.policyAssignments) {
  name: 'policy-assignments'
  params: {
    location: location
    namePrefix: names.policyPrefix
    effect: policyEffect
    denyPublicIpPolicyDefinitionId: denyPublicIpPolicyDefinitionId
    // A public architecture still gets the private-cluster rule, in reporting mode. Skipping it would
    // hide the difference between the architectures on the compliance blade, which is the one place
    // someone comparing them is most likely to look.
    apiServerIsPrivate: isPrivateCluster
    // The in-cluster rules are inert without the add-on, so do not pretend to assign them.
    enableInClusterPolicies: features.azurePolicyAddon
    logAnalyticsWorkspaceId: workspaceId
    // Allow Microsoft Container Registry plus the registry this deployment created. Without the
    // second term the add-on would block the images the environment pushes for itself.
    allowedContainerImagesRegex: deployRegistry
      ? '^(mcr\\.microsoft\\.com|${replace(registry!.outputs.loginServer, '.', '\\.')})/.+$'
      : '^mcr\\.microsoft\\.com/.+$'
  }
}

module flux 'modules/flux/flux.bicep' = if (deployFlux) {
  name: 'flux'
  params: {
    clusterName: buildAksCluster ? names.cluster : arcClusterName
    clusterKind: buildAksCluster ? 'managedClusters' : 'connectedClusters'
    gitRepositoryUrl: fluxGitRepositoryUrl
    gitBranch: fluxGitBranch
    gitPath: fluxGitPath
  }
  dependsOn: [
    aks
    arcExtensions
  ]
}

// =============================================================================================
// Outputs. deploy.* and diagnose.* consume these, so the names are part of the contract.
// =============================================================================================

output architectureApplied string = architecture
output networkProfileApplied string = effectiveNetworkProfile
output egressApplied string = effectiveEgress
output outboundTypeApplied string = eg.outboundType

output resourceGroupName string = resourceGroup().name
output location string = location

output vnetId string = buildAzureNetwork ? vnet!.outputs.id : ''
output vnetName string = buildAzureNetwork ? vnet!.outputs.name : ''
output nodeSubnetId string = buildAzureNetwork ? vnet!.outputs.nodeSubnetId : ''

output clusterName string = buildAksCluster ? aks!.outputs.name : arcClusterName
output clusterId string = buildAksCluster ? aks!.outputs.id : (buildArcLocal ? arcLocal!.outputs.connectedClusterId : externals.existingConnectedClusterId)
output clusterFqdn string = buildAksCluster ? aks!.outputs.fqdn : ''
output nodeResourceGroup string = buildAksCluster ? aks!.outputs.nodeResourceGroup : ''
output oidcIssuerUrl string = buildAksCluster ? aks!.outputs.oidcIssuerUrl : ''

output apiServerAuthorizedIpRanges string[] = effectiveAuthorizedIpRanges

// deploy.* compares these two. Azure Firewall takes the fourth address of AzureFirewallSubnet, and
// the route table is built on that assumption. If Azure ever allocates differently the default
// route points into a black hole and every node bootstrap times out at 100% CPU with no error.
output expectedFirewallPrivateIp string = deployRouteTable ? routeTable!.outputs.expectedFirewallPrivateIp : ''
output actualFirewallPrivateIp string = deployFirewall ? firewall!.outputs.privateIpAddress : ''

output egressPublicIpAddress string = egressPublicIp
output dnsResolverInboundIp string = deployDnsResolver ? dnsResolver!.outputs.inboundIpAddress : ''

output containerRegistryLoginServer string = deployRegistry ? registry!.outputs.loginServer : ''
output keyVaultUri string = deployKeyVault ? vault!.outputs.uri : ''
output storageBlobEndpoint string = deployStorage ? storage!.outputs.blobEndpoint : ''
output logAnalyticsWorkspaceId string = workspaceId
output grafanaEndpoint string = deployPrometheus && features.managedGrafana ? prometheus!.outputs.grafanaEndpoint : ''

// Governance. deploy.* uses these to decide whether the in-cluster policy proof is worth running:
// a Deny rule that was never assigned, or was assigned without the add-on to enforce it, would
// otherwise look identical to one that simply has not synced yet.
output policyAssignedControlCount int = (gateOk && features.policyAssignments) ? policies!.outputs.assignedControlCount : 0
output policyInClusterEnforcement bool = (gateOk && features.policyAssignments) && features.azurePolicyAddon

output kubectlCredentialCommand string = buildAksCluster
  ? 'az aks get-credentials --resource-group ${resourceGroup().name} --name ${names.cluster} --overwrite-existing'
  : 'az connectedk8s proxy --resource-group ${resourceGroup().name} --name ${arcClusterName}'
