metadata description = 'User-assigned identities for the cluster control plane and for kubelet. User-assigned rather than system-assigned so ACR pull and network permissions can be granted before the cluster exists, which removes the first-revision chicken-and-egg failure.'

param clusterIdentityName string
param kubeletIdentityName string
param location string
param tags object

resource clusterIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: clusterIdentityName
  location: location
  tags: tags
}

resource kubeletIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: kubeletIdentityName
  location: location
  tags: tags
}

output clusterIdentityId string = clusterIdentity.id
output clusterIdentityPrincipalId string = clusterIdentity.properties.principalId
output clusterIdentityClientId string = clusterIdentity.properties.clientId

output kubeletIdentityId string = kubeletIdentity.id
output kubeletIdentityName string = kubeletIdentity.name
output kubeletIdentityPrincipalId string = kubeletIdentity.properties.principalId
output kubeletIdentityClientId string = kubeletIdentity.properties.clientId
output kubeletIdentityObjectId string = kubeletIdentity.properties.principalId
