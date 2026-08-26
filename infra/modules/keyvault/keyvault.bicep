metadata description = 'Key Vault with RBAC authorization, purge protection and private-only access. Consumed by the Secrets Store CSI driver through workload identity.'

param name string
param location string
param tags object

param privateEndpointSubnetId string
param privateDnsZoneId string
param privateEndpointName string

param logAnalyticsWorkspaceId string = ''

@description('Purge protection cannot be turned off once enabled, and it blocks a hard delete for the retention period. Required for production, occasionally inconvenient in dev.')
param enablePurgeProtection bool = true

@minValue(7)
@maxValue(90)
param softDeleteRetentionInDays int = 90

resource vault 'Microsoft.KeyVault/vaults@2024-11-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: tenant().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: softDeleteRetentionInDays
    enablePurgeProtection: enablePurgeProtection ? true : null
    enabledForDeployment: false
    enabledForDiskEncryption: false
    enabledForTemplateDeployment: false
    publicNetworkAccess: 'Disabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Deny'
      ipRules: []
      virtualNetworkRules: []
    }
  }
}

module privateEndpoint '../privateendpoint/private-endpoint.bicep' = {
  name: 'pe-${uniqueString(name)}'
  params: {
    name: privateEndpointName
    location: location
    tags: tags
    subnetId: privateEndpointSubnetId
    privateLinkServiceId: vault.id
    groupIds: ['vault']
    privateDnsZoneId: privateDnsZoneId
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = if (!empty(logAnalyticsWorkspaceId)) {
  scope: vault
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

output id string = vault.id
output name string = vault.name
output uri string = vault.properties.vaultUri
