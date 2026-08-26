// Shared type and naming contract. Imported by main.bicep and the modules.

@export()
@description('Which cluster shape to build. Immutable after creation.')
type architectureType =
  | 'aks-public'
  | 'aks-public-authorized-ip'
  | 'aks-private-link'
  | 'aks-private-vnet-integration'
  | 'aks-automatic'
  | 'aks-arc-local'
  | 'arc-attach-existing'

@export()
@description('Pod IP model and dataplane. Immutable after creation.')
type networkProfileType = 'cni-overlay' | 'cni-podsubnet' | 'cni-overlay-cilium'

@export()
@description('Outbound path for node traffic. Only loadbalancer to natgateway/udr-firewall migrations are supported later.')
type egressType = 'loadbalancer' | 'natgateway' | 'udr-firewall'

@export()
type environmentType = 'dev' | 'test' | 'prod'

@export()
@description('Every address range the environment consumes. Overlaps here are the single most common cause of AKS provisioning failure, so preflight validates all of them.')
type addressingType = {
  @description('VNet address space in CIDR notation.')
  vnetAddressSpace: string

  @description('Node subnet. Size for max nodes plus surge; /22 gives 1019 usable addresses.')
  nodeSubnetPrefix: string

  @description('Subnet for the AKS Automatic managed system node pool. Only used when architecture is aks-automatic, where it is REQUIRED: the managed system pool lands in an AKS-managed VNet unless this subnet is supplied, and any egress mode other than a managed load balancer is then rejected. Minimum /26.')
  systemNodeSubnetPrefix: string

  @description('Pod subnet. Only used when networkProfile is cni-podsubnet.')
  podSubnetPrefix: string

  @description('API server subnet, delegated to Microsoft.ContainerService/managedClusters. Only used when architecture is aks-private-vnet-integration or aks-automatic. Minimum /28.')
  apiServerSubnetPrefix: string

  @description('AzureFirewallSubnet. Must be /26 or larger. Only used when egress is udr-firewall.')
  firewallSubnetPrefix: string

  @description('AzureBastionSubnet. Must be /26 or larger. Only used when deployBastion is true.')
  bastionSubnetPrefix: string

  @description('Subnet holding private endpoints for ACR, Key Vault and Storage.')
  privateEndpointSubnetPrefix: string

  @description('Azure DNS Private Resolver inbound endpoint subnet. Must be /28 or larger and delegated to Microsoft.Network/dnsResolvers.')
  dnsResolverInboundPrefix: string

  @description('Azure DNS Private Resolver outbound endpoint subnet. Must be /28 or larger and delegated to Microsoft.Network/dnsResolvers.')
  dnsResolverOutboundPrefix: string

  @description('Kubernetes service CIDR. Must not overlap the VNet, any peered VNet, or on-premises. Immutable.')
  serviceCidr: string

  @description('kube-dns service address. Must sit inside serviceCidr and must not be the network address. Immutable.')
  dnsServiceIp: string

  @description('Overlay pod CIDR. Used by cni-overlay and cni-overlay-cilium. Immutable.')
  podCidr: string

  @description('On-premises and peered ranges the cluster must reach. Preflight fails if serviceCidr or podCidr overlap any of them.')
  onPremisesCidrs: string[]
}

@export()
type nodePoolType = {
  @description('VM SKU. Avoid B-series; production wants 4 vCPU or more.')
  vmSize: string

  @description('Node count for the system pool, or initial count for a user pool.')
  count: int

  @minValue(1)
  minCount: int

  @maxValue(1000)
  maxCount: int

  @description('Empty array pins the pool to a single regional placement instead of spreading across zones.')
  zones: string[]

  osSku: 'AzureLinux' | 'Ubuntu'

  @description('Ephemeral requires a cache disk at least as large as the OS disk for the chosen VM SKU.')
  osDiskType: 'Ephemeral' | 'Managed'

  osDiskSizeGB: int

  enableAutoScaling: bool
}

@export()
type maintenanceType = {
  @description('Offset from UTC, for example -05:00.')
  utcOffset: string

  dayOfWeek: 'Sunday' | 'Monday' | 'Tuesday' | 'Wednesday' | 'Thursday' | 'Friday' | 'Saturday'

  @description('24-hour local start time, for example 02:00.')
  startTime: string

  @minValue(4)
  @maxValue(24)
  durationHours: int
}

@export()
@description('Every optional platform capability. All default to true except bastion and flux.')
type featuresType = {
  defenderForContainers: bool
  containerInsights: bool
  managedPrometheus: bool
  managedGrafana: bool
  diagnosticSettings: bool
  azurePolicyAddon: bool
  workloadIdentity: bool
  keyVaultSecretsProvider: bool
  imageCleaner: bool
  containerRegistry: bool
  keyVault: bool
  storage: bool
  privateDnsResolver: bool
  policyAssignments: bool
  bastion: bool
  flux: bool
}

@export()
@description('Role definition GUIDs resolved at deploy time by display name. This tenant does not use the well-known GUIDs for every built-in role, so they are never hardcoded in the templates.')
type roleIdsType = {
  acrPull: string
  networkContributor: string
  privateDnsZoneContributor: string
  monitoringMetricsPublisher: string
  aksRbacClusterAdmin: string
  keyVaultSecretsUser: string
  grafanaAdmin: string
  monitoringDataReader: string

  @description('Lets the cluster identity assign the kubelet identity to the node pools.')
  managedIdentityOperator: string
}

@export()
@description('Externally supplied resource IDs. Each is required only by the architectures that consume it.')
type externalsType = {
  @description('Bring your own VNet. Empty means this deployment creates the VNet.')
  existingVnetId: string

  @description('Bring your own node subnet. Empty means this deployment creates it.')
  existingNodeSubnetId: string

  @description('Required by arc-attach-existing. Resource ID of a Microsoft.Kubernetes/connectedClusters created by scripts/arc-onboard.*.')
  existingConnectedClusterId: string

  @description('Required by aks-arc-local. Resource ID of the custom location on the Azure Local instance.')
  customLocationId: string

  @description('Required by aks-arc-local. Resource ID of the Microsoft.AzureStackHCI/logicalNetworks the cluster attaches to.')
  logicalNetworkId: string

  @description('Required by aks-arc-local. SSH public key material authorized on the Azure Local control plane and worker nodes.')
  arcLocalSshPublicKey: string
}
