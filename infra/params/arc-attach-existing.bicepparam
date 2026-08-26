// Architecture: arc-attach-existing
// Creates no cluster. Takes a Kubernetes cluster that already exists anywhere - another cloud, a
// bare-metal distribution on the plant floor, a lab - and layers Azure management on top of it.
//
// Onboarding itself is a client-side operation: az connectedk8s connect installs Helm charts into
// the target cluster using your kubeconfig, which Resource Manager has no way to do. Run
// scripts/arc-onboard.ps1 (or .sh) first, then set AKS_EXISTING_CONNECTED_CLUSTER_ID to the
// resource ID it prints and deploy this file. The validation gate says exactly that if you forget.

using '../main.bicep'

var roleDefaults = loadJsonContent('role-ids.json')
var adminGroups = readEnvironmentVariable('AKS_ADMIN_GROUP_OBJECT_IDS', '')

// Cost tier. Almost nothing in a tier applies here because this architecture creates no infrastructure at
// all - it attaches governance to a cluster you already run. The one thing the tier still controls
// is Defender for Containers, which bills per vCore against that cluster. docs/costs.md has detail.
var tier = loadJsonContent('cost-tiers.json')[toLower(readEnvironmentVariable('AKS_COST_TIER', 'lean'))]

param customer = readEnvironmentVariable('AKS_CUSTOMER', 'contoso')
param environment = 'test'
param location = readEnvironmentVariable('AKS_LOCATION', 'westus3')
param instance = '05'

param architecture = 'arc-attach-existing'

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
  podCidr: ''
  onPremisesCidrs: []
}

// Unused on this architecture. The cluster already exists and its node shape is not Azure's business.
param systemNodePool = {
  vmSize: 'n/a'
  count: 1
  minCount: 1
  maxCount: 1
  zones: []
  osSku: 'AzureLinux'
  osDiskType: 'Managed'
  osDiskSizeGB: 128
  enableAutoScaling: false
}

param deployUserNodePool = false

param externals = {
  existingVnetId: ''
  existingNodeSubnetId: ''
  existingConnectedClusterId: readEnvironmentVariable('AKS_EXISTING_CONNECTED_CLUSTER_ID', '')
  customLocationId: ''
  logicalNetworkId: ''
  arcLocalSshPublicKey: ''
}

param adminGroupObjectIds = empty(adminGroups) ? [] : split(adminGroups, ',')
param deploymentPrincipalId = readEnvironmentVariable('AKS_DEPLOYMENT_PRINCIPAL_ID', '')
param deploymentPrincipalType = readEnvironmentVariable('AKS_DEPLOYMENT_PRINCIPAL_TYPE', 'User')

// Flux is on here because GitOps is usually the whole point of attaching an existing cluster:
// it is the one management surface that works identically no matter where the cluster runs.
// Everything that needs an Azure-region VNet is forced off regardless of tier: this architecture creates
// no infrastructure. Container Insights, the policy add-on and Flux stay on at every tier - they
// are the governance this architecture exists to deliver, and all three are Arc extensions rather than
// Azure resources. Defender follows the tier because it bills per vCore.
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
  flux: true
})

param fluxGitRepositoryUrl = readEnvironmentVariable(
  'AKS_FLUX_GIT_URL',
  'https://github.com/Azure/gitops-flux2-kustomize-helm-mt'
)
param fluxGitBranch = readEnvironmentVariable('AKS_FLUX_GIT_BRANCH', 'main')
param fluxGitPath = readEnvironmentVariable('AKS_FLUX_GIT_PATH', 'clusters/contoso-prod')

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
