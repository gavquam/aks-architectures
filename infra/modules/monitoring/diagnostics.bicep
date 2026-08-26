metadata description = 'Diagnostic settings on the managed cluster control plane.'

param clusterName string
param workspaceId string

@description('kube-audit is excluded by default. It is the single largest log source AKS produces and kube-audit-admin carries the mutating subset that matters for investigations at a fraction of the volume.')
param includeFullKubeAudit bool = false

var baseCategories = [
  'kube-apiserver'
  'kube-audit-admin'
  'kube-controller-manager'
  'kube-scheduler'
  'cluster-autoscaler'
  'guard'
  'cloud-controller-manager'
  'csi-azuredisk-controller'
  'csi-azurefile-controller'
  'csi-snapshot-controller'
]

var categories = includeFullKubeAudit ? concat(baseCategories, ['kube-audit']) : baseCategories

resource cluster 'Microsoft.ContainerService/managedClusters@2026-05-01' existing = {
  name: clusterName
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  scope: cluster
  name: 'to-log-analytics'
  properties: {
    workspaceId: workspaceId
    logs: [
      for category in categories: {
        category: category
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
