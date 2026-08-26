metadata description = 'Azure Container Registry for the sample workload. Premium adds the private endpoint and public-access lockdown; Basic and Standard are the low-cost evaluation tiers and stay on the public endpoint with Entra authentication.'

param name string
param location string
param tags object

@description('Private endpoints, zone redundancy and publicNetworkAccess=Disabled are Premium-only. Basic and Standard still authenticate every pull with Entra, they simply cannot be network-restricted.')
param skuName 'Basic' | 'Standard' | 'Premium' = 'Premium'

param privateEndpointSubnetId string = ''
param privateDnsZoneId string = ''
param privateEndpointName string = ''

@description('Empty disables diagnostic settings.')
param logAnalyticsWorkspaceId string = ''

@description('Zone-redundant registry storage. Requires a region with three zones. Premium only.')
param zoneRedundant bool = true

@description('Trusted Microsoft services keep working through the firewall; everything else must come via the private endpoint.')
param bypassAzureServices bool = true

var isPremium = skuName == 'Premium'

resource registry 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: skuName
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    adminUserEnabled: false
    anonymousPullEnabled: false
    dataEndpointEnabled: false
    publicNetworkAccess: isPremium ? 'Disabled' : 'Enabled'
    networkRuleBypassOptions: bypassAzureServices ? 'AzureServices' : 'None'
    zoneRedundancy: (isPremium && zoneRedundant) ? 'Enabled' : 'Disabled'
    policies: {
      quarantinePolicy: {
        status: 'disabled'
      }
      trustPolicy: {
        type: 'Notary'
        status: 'disabled'
      }
      retentionPolicy: {
        days: 30
        status: isPremium ? 'enabled' : 'disabled'
      }
      exportPolicy: {
        status: 'disabled'
      }
    }
  }
}

module privateEndpoint '../privateendpoint/private-endpoint.bicep' = if (isPremium) {
  name: 'pe-${uniqueString(name)}'
  params: {
    name: privateEndpointName
    location: location
    tags: tags
    subnetId: privateEndpointSubnetId
    privateLinkServiceId: registry.id
    groupIds: ['registry']
    privateDnsZoneId: privateDnsZoneId
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceId)) {
  scope: registry
  name: 'to-log-analytics'
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output id string = registry.id
output name string = registry.name
output loginServer string = registry.properties.loginServer
