metadata description = 'Log Analytics workspace. Every diagnostic setting, Container Insights and Defender for Containers land here.'

param name string
param location string
param tags object

@minValue(30)
@maxValue(730)
@description('Interactive retention. Beyond this, data ages into the cheaper archive tier if configured.')
param retentionInDays int = 30

@description('Ingestion cap in GB per day. -1 disables the cap. A cap protects the bill but silently drops telemetry once hit, so it is off by default.')
param dailyQuotaGb int = -1

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }
    workspaceCapping: {
      dailyQuotaGb: dailyQuotaGb
    }
  }
}

output id string = workspace.id
output name string = workspace.name
output customerId string = workspace.properties.customerId
