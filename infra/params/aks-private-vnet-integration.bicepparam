// Architecture: aks-private-vnet-integration
// Private cluster without a private endpoint or the konnectivity tunnel. The API server is
// projected into a delegated subnet in this VNet, so anything that can route to that subnet can
// reach it. Simpler DNS story than aks-private-link, and the standard enterprise choice where the
// hub already routes to the spoke.
//
// This example uses cni-podsubnet so pod IPs are VNet-routable and reachable from the OT network,
// which is what most plant-floor integrations need. That makes the pod subnet the binding
// constraint on cluster size: 110 pods per node against a /21 means roughly 18 nodes.

using '../main.bicep'

var roleDefaults = loadJsonContent('role-ids.json')
var adminGroups = readEnvironmentVariable('AKS_ADMIN_GROUP_OBJECT_IDS', '')
var extraVnets = readEnvironmentVariable('AKS_ADDITIONAL_VNET_IDS', '')
// Zones are subscription- and SKU-specific: a size that is generally available in a region can still
// be restricted in individual zones for your subscription (reasonCode NotAvailableForSubscription).
// Pre-flight reports this; override here rather than editing the node pool blocks. e.g. AKS_NODE_ZONES=2,3
var nodeZones = split(readEnvironmentVariable('AKS_NODE_ZONES', '1,2,3'), ',')

// Cost tier. lean (the default) deploys the architecture's network pattern and a working cluster and
// nothing that bills by the hour on top; standard adds Defender and full observability; full adds
// Managed Grafana, Bastion and the DNS Private Resolver. docs/costs.md prices every line.
var tier = loadJsonContent('cost-tiers.json')[toLower(readEnvironmentVariable('AKS_COST_TIER', 'lean'))]

// Node count, size, disk type and the optional user pool are the other things that move the bill.
// All of them are environment variables so making an architecture cheaper never means editing this file.
// Ephemeral OS disks are free but require a VM size with a local temp disk of at least
// osDiskSizeGB. If you pick a size without one, set AKS_OS_DISK_TYPE=Managed.
var nodeCount = int(readEnvironmentVariable('AKS_NODE_COUNT', '2'))
var nodeVmSize = readEnvironmentVariable('AKS_NODE_VM_SIZE', 'Standard_D4ds_v5')
var osDiskType = readEnvironmentVariable('AKS_OS_DISK_TYPE', 'Ephemeral')
var withUserPool = toLower(readEnvironmentVariable('AKS_DEPLOY_USER_POOL', 'false')) == 'true'

param customer = readEnvironmentVariable('AKS_CUSTOMER', 'contoso')
param environment = 'prod'
param location = readEnvironmentVariable('AKS_LOCATION', 'westus3')
param instance = '02'

param architecture = 'aks-private-vnet-integration'
param networkProfile = 'cni-podsubnet'
param egress = readEnvironmentVariable('AKS_EGRESS', 'natgateway')

param addressing = {
  vnetAddressSpace: '10.63.0.0/16'
  nodeSubnetPrefix: '10.63.0.0/22'
  systemNodeSubnetPrefix: ''
  podSubnetPrefix: '10.63.8.0/21'
  apiServerSubnetPrefix: '10.63.16.0/28'
  firewallSubnetPrefix: ''
  bastionSubnetPrefix: '10.63.17.64/26'
  privateEndpointSubnetPrefix: '10.63.18.0/24'
  dnsResolverInboundPrefix: '10.63.19.0/28'
  dnsResolverOutboundPrefix: '10.63.19.16/28'
  serviceCidr: '172.19.0.0/16'
  dnsServiceIp: '172.19.0.10'
  podCidr: ''
  onPremisesCidrs: ['10.10.0.0/16', '10.20.0.0/16']
}

param systemNodePool = {
  vmSize: nodeVmSize
  count: nodeCount
  minCount: nodeCount
  maxCount: nodeCount + 3
  zones: nodeZones
  osSku: 'AzureLinux'
  osDiskType: osDiskType
  osDiskSizeGB: 128
  enableAutoScaling: true
}

// Off by default: a second pool doubles the compute bill and nothing in this repository needs it.
// Set AKS_DEPLOY_USER_POOL=true when you want to see workload isolation from the system pool.
param deployUserNodePool = withUserPool

param userNodePool = {
  vmSize: nodeVmSize
  count: nodeCount
  minCount: nodeCount
  maxCount: nodeCount + 10
  zones: nodeZones
  osSku: 'AzureLinux'
  osDiskType: osDiskType
  osDiskSizeGB: 128
  enableAutoScaling: true
}

param adminGroupObjectIds = empty(adminGroups) ? [] : split(adminGroups, ',')
param deploymentPrincipalId = readEnvironmentVariable('AKS_DEPLOYMENT_PRINCIPAL_ID', '')
param deploymentPrincipalType = readEnvironmentVariable('AKS_DEPLOYMENT_PRINCIPAL_TYPE', 'User')

param additionalVnetIdsToLink = empty(extraVnets) ? [] : split(extraVnets, ',')

param managementSourceRanges = ['10.10.0.0/16']

// This architecture takes the tier as-is. At lean you still get the private API server projected into the
// delegated subnet and VNet-routable pod IPs - the whole point of the architecture - without Bastion or
// the DNS Private Resolver, which are conveniences for reaching it and bill per hour.
param features = tier.features

// The tier also picks the SKUs and caps that carry a fixed monthly charge. ACR and Grafana have an
// environment override so you can move one line without moving the whole tier; retention and the
// ingestion cap live in cost-tiers.json because they should be consistent across every architecture.
param clusterSkuTier = tier.clusterSkuTier
param containerRegistrySku = readEnvironmentVariable('AKS_ACR_SKU', tier.containerRegistrySku)
param grafanaSku = readEnvironmentVariable('AKS_GRAFANA_SKU', tier.grafanaSku)
param logAnalyticsRetentionDays = tier.logAnalyticsRetentionDays
// Set to -1 in cost-tiers.json to remove the cap. Leaving it on means a misbehaving workload cannot
// run up a four-figure ingestion bill overnight; the trade is that telemetry is dropped once hit.
param logAnalyticsDailyQuotaGb = tier.logAnalyticsDailyQuotaGb
param keyVaultPurgeProtection = toLower(readEnvironmentVariable('AKS_KEYVAULT_PURGE_PROTECTION', 'false')) == 'true'

// Where the node bootstrap failure alert notifies. Empty still creates the rule; it just has
// nobody to email, and the alert remains visible in Azure Monitor.
param alertNotificationEmail = readEnvironmentVariable('AKS_ALERT_EMAIL', '')

param denyPublicIpPolicyDefinitionId = readEnvironmentVariable('AKS_DENY_PUBLIC_IP_POLICY_ID', '')

param roleIds = {
  acrPull: readEnvironmentVariable('AKS_ROLE_ACR_PULL', roleDefaults.acrPull)
  networkContributor: readEnvironmentVariable('AKS_ROLE_NETWORK_CONTRIBUTOR', roleDefaults.networkContributor)
  privateDnsZoneContributor: readEnvironmentVariable(
    'AKS_ROLE_PRIVATE_DNS_ZONE_CONTRIBUTOR',
    roleDefaults.privateDnsZoneContributor
  )
  monitoringMetricsPublisher: readEnvironmentVariable(
    'AKS_ROLE_MONITORING_METRICS_PUBLISHER',
    roleDefaults.monitoringMetricsPublisher
  )
  aksRbacClusterAdmin: readEnvironmentVariable('AKS_ROLE_RBAC_CLUSTER_ADMIN', roleDefaults.aksRbacClusterAdmin)
  keyVaultSecretsUser: readEnvironmentVariable('AKS_ROLE_KEY_VAULT_SECRETS_USER', roleDefaults.keyVaultSecretsUser)
  grafanaAdmin: readEnvironmentVariable('AKS_ROLE_GRAFANA_ADMIN', roleDefaults.grafanaAdmin)
  monitoringDataReader: readEnvironmentVariable('AKS_ROLE_MONITORING_DATA_READER', roleDefaults.monitoringDataReader)
  managedIdentityOperator: readEnvironmentVariable(
    'AKS_ROLE_MANAGED_IDENTITY_OPERATOR',
    roleDefaults.managedIdentityOperator
  )
}
