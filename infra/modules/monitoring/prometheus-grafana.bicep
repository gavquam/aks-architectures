metadata description = 'Azure Monitor workspace, its Prometheus data collection endpoint and rule, and Azure Managed Grafana wired to read from it. Created before the cluster; associated with it afterwards by cluster-attach.bicep.'

import { roleIdsType } from '../../types.bicep'

param azureMonitorWorkspaceName string
param dataCollectionEndpointName string
param dataCollectionRuleName string
param grafanaName string
param location string
param tags object

param roleIds roleIdsType

@description('Deploys Azure Managed Grafana. The Azure Monitor workspace and Prometheus scraping work without it; Grafana is only the visualisation layer.')
param deployGrafana bool = true

@description('Standard supports private endpoints, zone redundancy and more than one instance. Essential is cheaper but is not recommended for production.')
param grafanaSku 'Standard' | 'Essential' = 'Standard'

@description('Grafana is a management-plane UI reached from operator workstations, not from the cluster network, so it stays publicly reachable by default. Set false and add a private endpoint if operators reach it over the VNet.')
param grafanaPublicNetworkAccess bool = true

resource azureMonitorWorkspace 'Microsoft.Monitor/accounts@2023-04-03' = {
  name: azureMonitorWorkspaceName
  location: location
  tags: tags
  properties: {}
}

resource dataCollectionEndpoint 'Microsoft.Insights/dataCollectionEndpoints@2023-03-11' = {
  name: dataCollectionEndpointName
  location: location
  tags: tags
  kind: 'Linux'
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

resource dataCollectionRule 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dataCollectionRuleName
  location: location
  tags: tags
  kind: 'Linux'
  properties: {
    dataCollectionEndpointId: dataCollectionEndpoint.id
    dataSources: {
      prometheusForwarder: [
        {
          name: 'PrometheusDataSource'
          streams: ['Microsoft-PrometheusMetrics']
          labelIncludeFilter: {}
        }
      ]
    }
    destinations: {
      monitoringAccounts: [
        {
          name: 'MonitoringAccountDestination'
          accountResourceId: azureMonitorWorkspace.id
        }
      ]
    }
    dataFlows: [
      {
        streams: ['Microsoft-PrometheusMetrics']
        destinations: ['MonitoringAccountDestination']
      }
    ]
  }
}

resource grafana 'Microsoft.Dashboard/grafana@2023-09-01' = if (deployGrafana) {
  name: grafanaName
  location: location
  tags: tags
  sku: {
    name: grafanaSku
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    apiKey: 'Disabled'
    deterministicOutboundIP: 'Disabled'
    publicNetworkAccess: grafanaPublicNetworkAccess ? 'Enabled' : 'Disabled'
    zoneRedundancy: 'Disabled'
    grafanaIntegrations: {
      azureMonitorWorkspaceIntegrations: [
        {
          azureMonitorWorkspaceResourceId: azureMonitorWorkspace.id
        }
      ]
    }
  }
}

// Without this, the Grafana data source authenticates but every panel returns an authorisation error.
resource grafanaDataReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployGrafana) {
  scope: azureMonitorWorkspace
  name: guid(azureMonitorWorkspace.id, grafanaName, roleIds.monitoringDataReader)
  properties: {
    principalId: grafana!.identity!.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.monitoringDataReader)
  }
}

output azureMonitorWorkspaceId string = azureMonitorWorkspace.id
output azureMonitorWorkspaceName string = azureMonitorWorkspace.name
output dataCollectionRuleId string = dataCollectionRule.id
output dataCollectionEndpointId string = dataCollectionEndpoint.id
output grafanaName string = deployGrafana ? grafanaName : ''
output grafanaEndpoint string = deployGrafana ? grafana!.properties.endpoint : ''
