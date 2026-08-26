metadata description = 'Governance and observability extensions layered onto an existing Arc-enabled Kubernetes cluster. The cluster itself is onboarded client side by scripts/arc-onboard.* because az connectedk8s connect needs kubeconfig access to the target cluster, which Resource Manager does not have.'

@description('Name of an existing Microsoft.Kubernetes/connectedClusters resource in this resource group.')
param connectedClusterName string

param logAnalyticsWorkspaceId string = ''

param enableContainerInsights bool = true
param enableDefenderForContainers bool = true
param enableAzurePolicy bool = true

@description('Namespaces the Azure Policy add-on ignores. Cluster operators frequently need to add their own platform namespaces here.')
param policyExcludedNamespaces string[] = [
  'kube-system'
  'gatekeeper-system'
  'azure-arc'
]

resource connectedCluster 'Microsoft.Kubernetes/connectedClusters@2024-01-01' existing = {
  name: connectedClusterName
}

resource containerInsights 'Microsoft.KubernetesConfiguration/extensions@2023-05-01' = if (enableContainerInsights && !empty(logAnalyticsWorkspaceId)) {
  scope: connectedCluster
  name: 'azuremonitor-containers'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    extensionType: 'microsoft.azuremonitor.containers'
    autoUpgradeMinorVersion: true
    releaseTrain: 'Stable'
    configurationSettings: {
      logAnalyticsWorkspaceResourceID: logAnalyticsWorkspaceId
      // Managed identity authentication. The alternative writes the workspace key into a Kubernetes
      // secret, which is exactly the sort of long-lived credential an OT estate should not carry.
      'amalogs.useAADAuth': 'true'
    }
  }
}

resource defender 'Microsoft.KubernetesConfiguration/extensions@2023-05-01' = if (enableDefenderForContainers) {
  scope: connectedCluster
  name: 'microsoft-defender'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    extensionType: 'microsoft.azuredefender.kubernetes'
    autoUpgradeMinorVersion: true
    releaseTrain: 'Stable'
    configurationSettings: empty(logAnalyticsWorkspaceId)
      ? {}
      : {
          logAnalyticsWorkspaceResourceID: logAnalyticsWorkspaceId
        }
  }
}

resource azurePolicy 'Microsoft.KubernetesConfiguration/extensions@2023-05-01' = if (enableAzurePolicy) {
  scope: connectedCluster
  name: 'azurepolicy'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    extensionType: 'microsoft.policyinsights'
    autoUpgradeMinorVersion: true
    releaseTrain: 'Stable'
    configurationSettings: {
      'azurepolicy.excludedNamespaces': join(policyExcludedNamespaces, ',')
    }
  }
}

output connectedClusterId string = connectedCluster.id
