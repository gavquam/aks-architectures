// Architecture: aks-automatic
// For teams with limited Kubernetes expertise. The platform owns node pools, scaling, upgrades,
// ingress and deployment safeguards. Automatic hard-wires Azure CNI Overlay powered by Cilium and
// API Server VNet Integration, so networkProfile cannot be anything else and an API server subnet
// is always required.
//
// The node resource group is locked to ReadOnly. Anything you would normally do by editing
// resources in that group has to be done through the cluster API instead.

using '../main.bicep'

var roleDefaults = loadJsonContent('role-ids.json')
var adminGroups = readEnvironmentVariable('AKS_ADMIN_GROUP_OBJECT_IDS', '')

// Cost tier. lean (the default) deploys the architecture's network pattern and a working cluster and
// nothing that bills by the hour on top; standard adds Defender and full observability; full adds
// Managed Grafana. docs/costs.md prices every line. Note that the Automatic SKU also carries the
// Standard tier's per-cluster uptime SLA charge, which is not optional on this architecture.
var tier = loadJsonContent('cost-tiers.json')[toLower(readEnvironmentVariable('AKS_COST_TIER', 'lean'))]

param customer = readEnvironmentVariable('AKS_CUSTOMER', 'contoso')
param environment = 'dev'
param location = readEnvironmentVariable('AKS_LOCATION', 'westus3')
param instance = '03'

param architecture = 'aks-automatic'
param networkProfile = 'cni-overlay-cilium'
param egress = readEnvironmentVariable('AKS_EGRESS', 'natgateway')

param addressing = {
  vnetAddressSpace: '10.64.0.0/16'
  nodeSubnetPrefix: '10.64.0.0/22'
  // Required by the Automatic SKU's managed system node pool. Minimum /26.
  systemNodeSubnetPrefix: '10.64.16.64/26'
  podSubnetPrefix: ''
  apiServerSubnetPrefix: '10.64.16.0/28'
  firewallSubnetPrefix: ''
  bastionSubnetPrefix: '10.64.17.64/26'
  privateEndpointSubnetPrefix: '10.64.18.0/24'
  dnsResolverInboundPrefix: '10.64.19.0/28'
  dnsResolverOutboundPrefix: '10.64.19.16/28'
  serviceCidr: '172.20.0.0/16'
  dnsServiceIp: '172.20.0.10'
  podCidr: '192.168.0.0/16'
  onPremisesCidrs: []
}

// Automatic sizes and scales the pool itself. These values seed the initial system pool only;
// autoscaler bounds are deliberately not sent to the API, because they conflict with the SKU.
//
// The Automatic SKU validates the system pool against its own recommended values and fails with
// AKSAutomaticSKUFeatureValidationError otherwise. Three things are NOT free choices here:
//   1. zones must be all three - Automatic requires a region and SKU with 1, 2 and 3, so this is
//      deliberately NOT wired to AKS_NODE_ZONES.
//   2. osDiskType must be Ephemeral.
//   3. vmSize must therefore be a size offered in ALL THREE zones for YOUR subscription. The v5
//      D-series is zone-restricted in some subscription/region combinations, so this uses v6.
//      Verify with: az vm list-skus -l <region> --size <size> --all
param systemNodePool = {
  vmSize: 'Standard_D4ds_v6'
  count: 3
  minCount: 3
  maxCount: 5
  zones: ['1', '2', '3']
  osSku: 'AzureLinux'
  osDiskType: 'Ephemeral'
  osDiskSizeGB: 128
  enableAutoScaling: false
}

// Node auto-provisioning creates user capacity on demand, so a statically declared user pool would
// fight it. main.bicep skips the user pool module on this SKU regardless of this value.
param deployUserNodePool = false

param adminGroupObjectIds = empty(adminGroups) ? [] : split(adminGroups, ',')
param deploymentPrincipalId = readEnvironmentVariable('AKS_DEPLOYMENT_PRINCIPAL_ID', '')
param deploymentPrincipalType = readEnvironmentVariable('AKS_DEPLOYMENT_PRINCIPAL_TYPE', 'User')

// Automatic runs its own private cluster, its own ingress and its own DNS, so Bastion and the DNS
// Private Resolver would bill per hour for nothing. Everything else follows the tier. The node
// pool above is deliberately not wired to AKS_NODE_COUNT or AKS_NODE_VM_SIZE - the SKU validates
// those values itself and rejects anything outside its recommended set.
param features = union(tier.features, {
  storage: false
  privateDnsResolver: false
  bastion: false
})

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
