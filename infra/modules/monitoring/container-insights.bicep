metadata description = 'Data collection rule for Azure Monitor container insights. Created before the cluster; associated with it afterwards by cluster-attach.bicep.'

param name string
param location string
param tags object

@description('Log Analytics workspace the container telemetry lands in.')
param workspaceId string

@description('Collection interval. 1m is the Azure Monitor default; 5m materially reduces ingest cost on large clusters.')
param interval string = '1m'

@description('Off collects from every namespace. Exclude or Include applies namespaces to the filter below.')
param namespaceFilteringMode 'Off' | 'Include' | 'Exclude' = 'Exclude'

@description('Namespaces the filtering mode applies to. The kube-system and gatekeeper namespaces dominate log volume and rarely carry application signal.')
param namespaces string[] = ['kube-system', 'gatekeeper-system', 'azure-arc']

@description('ContainerLogV2 is the schema Azure Monitor invests in. The legacy ContainerLog table is not written when this is true.')
param enableContainerLogV2 bool = true

resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: name
  location: location
  tags: tags
  kind: 'Linux'
  properties: {
    dataSources: {
      extensions: [
        {
          name: 'ContainerInsightsExtension'
          streams: ['Microsoft-ContainerInsights-Group-Default']
          extensionName: 'ContainerInsights'
          extensionSettings: {
            dataCollectionSettings: {
              interval: interval
              namespaceFilteringMode: namespaceFilteringMode
              namespaces: namespaces
              enableContainerLogV2: enableContainerLogV2
            }
          }
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          name: 'ciworkspace'
          workspaceResourceId: workspaceId
        }
      ]
    }
    dataFlows: [
      {
        streams: ['Microsoft-ContainerInsights-Group-Default']
        destinations: ['ciworkspace']
      }
    ]
  }
}

output id string = dcr.id
output name string = dcr.name
