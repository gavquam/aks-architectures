metadata description = 'Private DNS zones and VNet links for the private endpoints this environment creates, plus the AKS private cluster zone.'

param location string = 'global'
param tags object

@description('VNet to link every zone to. This is the network the nodes live in.')
param vnetId string

param deployAcrZone bool
param deployKeyVaultZone bool
param deployStorageZone bool

@description('Creates privatelink.<region>.azmk8s.io. Required by aks-private-link when the cluster brings its own zone rather than using the AKS-managed one.')
param deployAksZone bool

@description('Region the AKS private cluster is built in. Only used when deployAksZone is true.')
param clusterRegion string = ''

@description('Additional VNet resource IDs to link, for example a hub or a jumpbox network the operator runs kubectl from.')
param additionalVnetIds string[] = []

var acrZoneName = 'privatelink${environment().suffixes.acrLoginServer}'
var keyVaultZoneName = 'privatelink${replace(environment().suffixes.keyvaultDns, '.vault.', '.vaultcore.')}'
var storageBlobZoneName = 'privatelink.blob.${environment().suffixes.storage}'
var aksZoneName = 'privatelink.${clusterRegion}.azmk8s.io'

// union, not concat: link names are derived from the VNet ID, so if a caller also lists the cluster
// VNet in additionalVnetIds, concat would emit duplicate resource names and ARM rejects the entire
// template with InvalidTemplate before any resource is created.
var linkTargets = union([vnetId], additionalVnetIds)

resource acrZone 'Microsoft.Network/privateDnsZones@2024-06-01' = if (deployAcrZone) {
  name: acrZoneName
  location: location
  tags: tags
}

resource keyVaultZone 'Microsoft.Network/privateDnsZones@2024-06-01' = if (deployKeyVaultZone) {
  name: keyVaultZoneName
  location: location
  tags: tags
}

resource storageZone 'Microsoft.Network/privateDnsZones@2024-06-01' = if (deployStorageZone) {
  name: storageBlobZoneName
  location: location
  tags: tags
}

resource aksZone 'Microsoft.Network/privateDnsZones@2024-06-01' = if (deployAksZone) {
  name: aksZoneName
  location: location
  tags: tags
}

resource acrLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for (target, i) in linkTargets: if (deployAcrZone) {
    parent: acrZone
    name: 'link-${uniqueString(target)}'
    location: location
    tags: tags
    properties: {
      registrationEnabled: false
      #disable-next-line use-resource-id-functions // target is sourced from resource ID parameters
      virtualNetwork: { id: target }
    }
  }
]

resource keyVaultLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for (target, i) in linkTargets: if (deployKeyVaultZone) {
    parent: keyVaultZone
    name: 'link-${uniqueString(target)}'
    location: location
    tags: tags
    properties: {
      registrationEnabled: false
      #disable-next-line use-resource-id-functions // target is sourced from resource ID parameters
      virtualNetwork: { id: target }
    }
  }
]

resource storageLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for (target, i) in linkTargets: if (deployStorageZone) {
    parent: storageZone
    name: 'link-${uniqueString(target)}'
    location: location
    tags: tags
    properties: {
      registrationEnabled: false
      #disable-next-line use-resource-id-functions // target is sourced from resource ID parameters
      virtualNetwork: { id: target }
    }
  }
]

// Preflight check 7 verifies these links exist. Without one, kubectl resolves the API server to nothing.
resource aksLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for (target, i) in linkTargets: if (deployAksZone) {
    parent: aksZone
    name: 'link-${uniqueString(target)}'
    location: location
    tags: tags
    properties: {
      registrationEnabled: false
      #disable-next-line use-resource-id-functions // target is sourced from resource ID parameters
      virtualNetwork: { id: target }
    }
  }
]

output acrZoneId string = deployAcrZone ? acrZone.id : ''
output acrZoneName string = acrZoneName
output keyVaultZoneId string = deployKeyVaultZone ? keyVaultZone.id : ''
output keyVaultZoneName string = keyVaultZoneName
output storageZoneId string = deployStorageZone ? storageZone.id : ''
output storageZoneName string = storageBlobZoneName
output aksZoneId string = deployAksZone ? aksZone.id : ''
output aksZoneName string = deployAksZone ? aksZoneName : ''
