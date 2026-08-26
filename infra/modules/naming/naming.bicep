// Compile-time naming convention. Imported, never deployed, so it costs no deployment time.
//
// Hyphenated:  <abbrev>-<customer>-<env>-<geo>-<instance>        aks-contoso-prod-cus-01
// Compact:     <abbrev><customer><env><geo><instance><suffix>    crcontosoprodcus01k3x9
//
// The compact form is for resource types that disallow hyphens and demand a globally unique name
// (ACR, Storage). Those take a deterministic suffix derived from the resource group ID.

@export()
@description('Short codes for Azure regions. Unmapped regions fall back to the first three characters of the region name.')
var geoCodes = {
  eastus: 'eus'
  eastus2: 'eus2'
  centralus: 'cus'
  northcentralus: 'ncus'
  southcentralus: 'scus'
  westcentralus: 'wcus'
  westus: 'wus'
  westus2: 'wus2'
  westus3: 'wus3'
  canadacentral: 'cac'
  canadaeast: 'cae'
  brazilsouth: 'brs'
  northeurope: 'neu'
  westeurope: 'weu'
  uksouth: 'uks'
  ukwest: 'ukw'
  francecentral: 'frc'
  germanywestcentral: 'gwc'
  switzerlandnorth: 'chn'
  norwayeast: 'nwe'
  swedencentral: 'sdc'
  polandcentral: 'plc'
  italynorth: 'itn'
  spaincentral: 'spc'
  uaenorth: 'uan'
  southafricanorth: 'san'
  australiaeast: 'aue'
  australiasoutheast: 'ause'
  southeastasia: 'sea'
  eastasia: 'ea'
  japaneast: 'jpe'
  japanwest: 'jpw'
  koreacentral: 'krc'
  centralindia: 'inc'
  southindia: 'ins'
  israelcentral: 'ilc'
  mexicocentral: 'mxc'
  newzealandnorth: 'nzn'
}

@export()
@description('Resource type abbreviations, following the Cloud Adoption Framework recommendations.')
var abbreviations = {
  resourceGroup: 'rg'
  virtualNetwork: 'vnet'
  networkSecurityGroup: 'nsg'
  routeTable: 'rt'
  natGateway: 'ng'
  publicIp: 'pip'
  firewall: 'afw'
  firewallPolicy: 'afwp'
  bastion: 'bas'
  privateEndpoint: 'pep'
  privateDnsResolver: 'dnspr'
  managedCluster: 'aks'
  containerRegistry: 'cr'
  keyVault: 'kv'
  storageAccount: 'st'
  logAnalytics: 'log'
  azureMonitorWorkspace: 'amw'
  grafana: 'graf'
  dataCollectionEndpoint: 'dce'
  dataCollectionRule: 'dcr'
  userAssignedIdentity: 'id'
  connectedCluster: 'arck'
  virtualMachine: 'vm'
  networkInterface: 'nic'
  deployment: 'deploy'
}

@export()
@description('Subnet names. Two of these are fixed by Azure and cannot be renamed.')
var subnetNames = {
  nodes: 'snet-nodes'
  systemNodes: 'snet-system-nodes'
  pods: 'snet-pods'
  apiServer: 'snet-apiserver'
  privateEndpoints: 'snet-privateendpoints'
  dnsResolverInbound: 'snet-dnsresolver-in'
  dnsResolverOutbound: 'snet-dnsresolver-out'
  firewall: 'AzureFirewallSubnet'
  bastion: 'AzureBastionSubnet'
}

@export()
@description('Builds a hyphenated resource name: <abbrev>-<customer>-<env>-<geo>-<instance>.')
func hyphenated(abbrev string, customer string, environment string, geo string, instance string) string =>
  toLower('${abbrev}-${customer}-${environment}-${geo}-${instance}')

@export()
@description('Builds a compact, globally unique resource name for types that reject hyphens.')
func compact(abbrev string, customer string, environment string, geo string, instance string, suffix string) string =>
  toLower('${abbrev}${customer}${environment}${geo}${instance}${suffix}')

@export()
@description('Key Vault names cap at 24 characters and must be globally unique, so the suffix is appended but the whole name is then truncated.')
func keyVaultName(customer string, environment string, geo string, instance string, suffix string) string =>
  toLower(substring('kv-${customer}-${environment}-${geo}-${instance}${suffix}', 0, min(length('kv-${customer}-${environment}-${geo}-${instance}${suffix}'), 24)))
