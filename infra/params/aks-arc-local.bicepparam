// Architecture: aks-arc-local
// AKS on Azure Local, for a plant-floor or edge site that has to keep running when the WAN link
// does not. The cluster runs on customer hardware; Azure holds only the Arc projection.
//
// PREREQUISITES THIS TEMPLATE CANNOT CREATE, because they are physical-site constructs:
//   1. A registered Azure Local instance with an Arc Resource Bridge deployed.
//   2. A custom location projected from that bridge.        az customlocation list -o table
//   3. A logical network with a usable IP pool and gateway.  az stack-hci-vm network lnet list -o table
// Supply their resource IDs through AKS_CUSTOM_LOCATION_ID and AKS_LOGICAL_NETWORK_ID. The
// validation gate in main.bicep fails fast with the exact command to run if either is missing.
//
// networkProfile and egress are ignored: there is no Azure VNet, NAT Gateway or Azure Firewall in
// this path, so main.bicep forces both to "none" rather than pretending they apply.

using '../main.bicep'

var roleDefaults = loadJsonContent('role-ids.json')
var adminGroups = readEnvironmentVariable('AKS_ADMIN_GROUP_OBJECT_IDS', '')

// Cost tier. Almost nothing in a tier applies here because there is no Azure-region infrastructure
// in this path - the hardware is yours. The one thing the tier still controls is Defender for
// Containers, which bills per vCore against your on-premises nodes. docs/costs.md has the detail.
var tier = loadJsonContent('cost-tiers.json')[toLower(readEnvironmentVariable('AKS_COST_TIER', 'lean'))]

param customer = readEnvironmentVariable('AKS_CUSTOMER', 'contoso')
param environment = 'prod'
param location = readEnvironmentVariable('AKS_LOCATION', 'westus3')
param instance = '04'

param architecture = 'aks-arc-local'

param addressing = {
  vnetAddressSpace: ''
  nodeSubnetPrefix: ''
  systemNodeSubnetPrefix: ''
  podSubnetPrefix: ''
  apiServerSubnetPrefix: ''
  firewallSubnetPrefix: ''
  bastionSubnetPrefix: ''
  privateEndpointSubnetPrefix: ''
  dnsResolverInboundPrefix: ''
  dnsResolverOutboundPrefix: ''
  serviceCidr: ''
  dnsServiceIp: ''
  podCidr: '10.244.0.0/16'
  onPremisesCidrs: []
}

// Only count is read on this architecture; the VM size comes from arcLocalVmSize because Azure Local
// offers its own SKU list, not the Azure region list.
param systemNodePool = {
  vmSize: 'Standard_A4_v2'
  count: 3
  minCount: 3
  maxCount: 3
  zones: []
  osSku: 'AzureLinux'
  osDiskType: 'Managed'
  osDiskSizeGB: 128
  enableAutoScaling: false
}

param deployUserNodePool = false

param arcLocalVmSize = readEnvironmentVariable('AKS_ARC_VM_SIZE', 'Standard_A4_v2')
param arcLocalControlPlaneHostIp = readEnvironmentVariable('AKS_ARC_CONTROL_PLANE_IP', '')

param externals = {
  existingVnetId: ''
  existingNodeSubnetId: ''
  existingConnectedClusterId: ''
  customLocationId: readEnvironmentVariable('AKS_CUSTOM_LOCATION_ID', '')
  logicalNetworkId: readEnvironmentVariable('AKS_LOGICAL_NETWORK_ID', '')
  arcLocalSshPublicKey: readEnvironmentVariable('AKS_ARC_SSH_PUBLIC_KEY', '')
}

param adminGroupObjectIds = empty(adminGroups) ? [] : split(adminGroups, ',')
param deploymentPrincipalId = readEnvironmentVariable('AKS_DEPLOYMENT_PRINCIPAL_ID', '')
param deploymentPrincipalType = readEnvironmentVariable('AKS_DEPLOYMENT_PRINCIPAL_TYPE', 'User')

// Azure-region services are switched off: private endpoints, NAT Gateway and Azure Firewall have
// nothing to attach to on this architecture.
// Everything that needs an Azure-region VNet is forced off regardless of tier, because none of it
// exists on this path. Container Insights and the policy add-on stay on at every tier: they are the
// reason to attach an on-premises cluster to Azure in the first place, and both are Arc extensions
// rather than Azure resources. Defender follows the tier because it bills per vCore.
param features = union(tier.features, {
  containerInsights: true
  managedPrometheus: false
  managedGrafana: false
  diagnosticSettings: false
  azurePolicyAddon: true
  workloadIdentity: false
  keyVaultSecretsProvider: false
  imageCleaner: false
  containerRegistry: false
  keyVault: false
  storage: false
  privateDnsResolver: false
  policyAssignments: false
  bastion: false
  flux: false
})

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
