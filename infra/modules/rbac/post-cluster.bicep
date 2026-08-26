metadata description = 'Role assignments that can only be made after the cluster exists. With Azure RBAC for Kubernetes authorization and local accounts disabled, these grants are the only way anyone reaches the cluster.'

import { roleIdsType } from '../../types.bicep'

param roleIds roleIdsType

param clusterName string

@description('Entra group object IDs receiving Azure Kubernetes Service RBAC Cluster Admin.')
param adminGroupObjectIds string[] = []

@description('Object ID of the operator or pipeline identity running the deployment. Empty skips the grant, which leaves only the admin groups with access.')
param deploymentPrincipalId string = ''

param deploymentPrincipalType 'User' | 'Group' | 'ServicePrincipal' = 'User'

@description('Azure Managed Grafana instance. Empty skips the Grafana Admin grant.')
param grafanaName string = ''

resource cluster 'Microsoft.ContainerService/managedClusters@2026-05-01' existing = {
  name: clusterName
}

resource grafana 'Microsoft.Dashboard/grafana@2023-09-01' existing = if (!empty(grafanaName)) {
  name: grafanaName
}

resource adminGroupClusterAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for objectId in adminGroupObjectIds: {
    scope: cluster
    name: guid(resourceGroup().id, clusterName, objectId, roleIds.aksRbacClusterAdmin)
    properties: {
      principalId: objectId
      principalType: 'Group'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.aksRbacClusterAdmin)
    }
  }
]

resource deployerClusterAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deploymentPrincipalId)) {
  scope: cluster
  name: guid(resourceGroup().id, clusterName, deploymentPrincipalId, roleIds.aksRbacClusterAdmin)
  properties: {
    principalId: deploymentPrincipalId
    principalType: deploymentPrincipalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.aksRbacClusterAdmin)
  }
}

resource deployerGrafanaAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(grafanaName) && !empty(deploymentPrincipalId)) {
  scope: grafana
  name: guid(resourceGroup().id, grafanaName, deploymentPrincipalId, roleIds.grafanaAdmin)
  properties: {
    principalId: deploymentPrincipalId
    principalType: deploymentPrincipalType
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.grafanaAdmin)
  }
}

resource adminGroupGrafanaAdmin 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for objectId in adminGroupObjectIds: if (!empty(grafanaName)) {
    scope: grafana
    name: guid(resourceGroup().id, grafanaName, objectId, roleIds.grafanaAdmin)
    properties: {
      principalId: objectId
      principalType: 'Group'
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.grafanaAdmin)
    }
  }
]
