metadata description = 'Grants the Key Vault Secrets Store CSI driver identity read access to the vault. Split out from rbac/pre-cluster.bicep because the driver identity only exists once the cluster has been created.'

import { roleIdsType } from '../../types.bicep'

param roleIds roleIdsType

param keyVaultName string

@description('Object ID of the addon identity reported by the cluster once the Key Vault provider is enabled.')
param csiDriverPrincipalId string

resource vault 'Microsoft.KeyVault/vaults@2024-11-01' existing = {
  name: keyVaultName
}

resource secretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: vault
  name: guid(resourceGroup().id, keyVaultName, csiDriverPrincipalId, roleIds.keyVaultSecretsUser)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleIds.keyVaultSecretsUser)
    principalId: csiDriverPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output roleAssignmentId string = secretsUser.id
