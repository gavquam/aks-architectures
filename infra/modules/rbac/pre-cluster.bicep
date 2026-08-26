metadata description = 'Role assignments that must exist BEFORE the cluster is created. Azure Kubernetes Service validates these during provisioning; granting them afterwards produces a cluster that provisions and then cannot pull images or manage its own subnet.'

import { roleIdsType } from '../../types.bicep'

param roleIds roleIdsType

@description('Principal ID of the user-assigned control plane identity.')
param clusterIdentityPrincipalId string

@description('Principal ID of the user-assigned kubelet identity.')
param kubeletIdentityPrincipalId string

@description('Name of the kubelet identity. The control plane identity needs Managed Identity Operator on it to attach it to node pools.')
param kubeletIdentityName string

@description('VNet the nodes live in. The control plane identity needs Network Contributor here for load balancers, route tables and NAT Gateway association.')
param vnetName string

@description('Empty skips the AcrPull grant.')
param acrName string = ''

@description('Empty skips the Key Vault Secrets User grant for the Secrets Store CSI driver.')
param keyVaultName string = ''

@description('Principal ID the Secrets Store CSI add-on runs as. Empty skips the Key Vault grant.')
param csiDriverPrincipalId string = ''

@description('Bring-your-own private DNS zone for a private cluster. Empty skips the Private DNS Zone Contributor grant.')
param privateDnsZoneName string = ''

@description('Route table backing userDefinedRouting. Empty skips the grant. AKS needs Network Contributor here to attach the table to new node pool subnets.')
param routeTableName string = ''

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: vnetName
}

resource kubeletIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: kubeletIdentityName
}

resource acr 'Microsoft.ContainerRegistry/registries@2023-11-01-preview' existing = if (!empty(acrName)) {
  name: acrName
}

resource keyVault 'Microsoft.KeyVault/vaults@2024-11-01' existing = if (!empty(keyVaultName)) {
  name: keyVaultName
}

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' existing = if (!empty(privateDnsZoneName)) {
  name: privateDnsZoneName
}

resource routeTable 'Microsoft.Network/routeTables@2024-05-01' existing = if (!empty(routeTableName)) {
  name: routeTableName
}

resource vnetNetworkContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: vnet
  name: guid(resourceGroup().id, vnetName, clusterIdentityPrincipalId, roleIds.networkContributor)
  properties: {
    principalId: clusterIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.networkContributor)
  }
}

resource routeTableNetworkContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(routeTableName)) {
  scope: routeTable
  name: guid(resourceGroup().id, routeTableName, clusterIdentityPrincipalId, roleIds.networkContributor)
  properties: {
    principalId: clusterIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.networkContributor)
  }
}

resource kubeletManagedIdentityOperator 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: kubeletIdentity
  name: guid(resourceGroup().id, kubeletIdentityName, clusterIdentityPrincipalId, roleIds.managedIdentityOperator)
  properties: {
    principalId: clusterIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.managedIdentityOperator)
  }
}

resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(acrName)) {
  scope: acr
  name: guid(resourceGroup().id, acrName, kubeletIdentityPrincipalId, roleIds.acrPull)
  properties: {
    principalId: kubeletIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.acrPull)
  }
}

resource privateDnsZoneContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(privateDnsZoneName)) {
  scope: privateDnsZone
  name: guid(resourceGroup().id, privateDnsZoneName, clusterIdentityPrincipalId, roleIds.privateDnsZoneContributor)
  properties: {
    principalId: clusterIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      roleIds.privateDnsZoneContributor
    )
  }
}

resource keyVaultSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(keyVaultName) && !empty(csiDriverPrincipalId)) {
  scope: keyVault
  name: guid(resourceGroup().id, keyVaultName, csiDriverPrincipalId, roleIds.keyVaultSecretsUser)
  properties: {
    principalId: csiDriverPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.keyVaultSecretsUser)
  }
}
