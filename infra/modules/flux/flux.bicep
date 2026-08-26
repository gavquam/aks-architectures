metadata description = 'Flux v2 GitOps. The extension installs the controllers; the fluxConfiguration points them at a repository and a path.'

param clusterName string

@description('managedClusters for an AKS cluster, connectedClusters for an Arc-enabled one.')
param clusterKind 'managedClusters' | 'connectedClusters' = 'managedClusters'

param gitRepositoryUrl string

param gitBranch string = 'main'

@description('Path inside the repository this cluster reconciles, for example clusters/contoso-prod.')
param gitPath string

@description('Reconciliation interval in seconds.')
param intervalInSeconds int = 300

@description('Prune removes resources deleted from Git. Off means a deletion in Git leaves the object running on the cluster.')
param enablePrune bool = true

var isManaged = clusterKind == 'managedClusters'

var extensionProperties = {
  extensionType: 'microsoft.flux'
  autoUpgradeMinorVersion: true
  releaseTrain: 'Stable'
  scope: {
    cluster: {
      releaseNamespace: 'flux-system'
    }
  }
  configurationSettings: {
    'helm-controller.enabled': 'true'
    'source-controller.enabled': 'true'
    'kustomize-controller.enabled': 'true'
    'notification-controller.enabled': 'true'
    'image-automation-controller.enabled': 'false'
    'image-reflector-controller.enabled': 'false'
  }
}

var configurationProperties = {
  scope: 'cluster'
  namespace: 'flux-system'
  sourceKind: 'GitRepository'
  suspend: false
  gitRepository: {
    url: gitRepositoryUrl
    repositoryRef: {
      branch: gitBranch
    }
    syncIntervalInSeconds: intervalInSeconds
    timeoutInSeconds: 180
  }
  kustomizations: {
    infra: {
      path: '${gitPath}/infrastructure'
      dependsOn: []
      syncIntervalInSeconds: intervalInSeconds
      timeoutInSeconds: 300
      prune: enablePrune
    }
    apps: {
      path: '${gitPath}/apps'
      dependsOn: ['infra']
      syncIntervalInSeconds: intervalInSeconds
      timeoutInSeconds: 300
      prune: enablePrune
    }
  }
}

resource managedCluster 'Microsoft.ContainerService/managedClusters@2026-05-01' existing = {
  name: clusterName
}

resource connectedCluster 'Microsoft.Kubernetes/connectedClusters@2024-07-01-preview' existing = {
  name: clusterName
}

// Bicep requires an extension resource scope to resolve without knowing parameter values, so each
// cluster kind gets its own resource pair rather than one pair with a computed scope.
resource managedFluxExtension 'Microsoft.KubernetesConfiguration/extensions@2023-05-01' = if (isManaged) {
  scope: managedCluster
  name: 'flux'
  properties: extensionProperties
}

resource managedFluxConfiguration 'Microsoft.KubernetesConfiguration/fluxConfigurations@2023-05-01' = if (isManaged) {
  scope: managedCluster
  name: 'cluster-config'
  dependsOn: [managedFluxExtension]
  properties: configurationProperties
}

resource connectedFluxExtension 'Microsoft.KubernetesConfiguration/extensions@2023-05-01' = if (!isManaged) {
  scope: connectedCluster
  name: 'flux'
  properties: extensionProperties
}

resource connectedFluxConfiguration 'Microsoft.KubernetesConfiguration/fluxConfigurations@2023-05-01' = if (!isManaged) {
  scope: connectedCluster
  name: 'cluster-config'
  dependsOn: [connectedFluxExtension]
  properties: configurationProperties
}

output configurationId string = isManaged ? managedFluxConfiguration!.id : connectedFluxConfiguration!.id
