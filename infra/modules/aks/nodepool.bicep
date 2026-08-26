metadata description = 'User node pool. Kept out of the cluster resource so pool changes do not force a diff on the cluster itself.'

import { nodePoolType } from '../../types.bicep'

param clusterName string
param poolName string
param pool nodePoolType

param nodeSubnetId string

@description('Empty unless pods live on a dedicated VNet subnet.')
param podSubnetId string = ''

@minValue(10)
@maxValue(250)
param maxPods int = 250

param sshAccess 'LocalUser' | 'Disabled' = 'Disabled'
param enableEncryptionAtHost bool = false

@description('Labels applied to every node in the pool, for workload scheduling.')
param nodeLabels object = {}

@description('Taints applied to every node in the pool, in the form key=value:Effect.')
param nodeTaints string[] = []

@description('Spot nodes are evicted with 30 seconds notice. Never use them for stateful or safety-relevant OT workloads.')
param useSpot bool = false

resource cluster 'Microsoft.ContainerService/managedClusters@2026-05-01' existing = {
  name: clusterName
}

var scaleSettings = pool.enableAutoScaling
  ? {
      enableAutoScaling: true
      minCount: pool.minCount
      maxCount: pool.maxCount
    }
  : {
      enableAutoScaling: false
    }

var spotSettings = useSpot
  ? {
      scaleSetPriority: 'Spot'
      scaleSetEvictionPolicy: 'Delete'
      spotMaxPrice: json('-1')
    }
  : {}

resource agentPool 'Microsoft.ContainerService/managedClusters/agentPools@2026-05-01' = {
  parent: cluster
  name: poolName
  properties: union(
    {
      mode: 'User'
      osType: 'Linux'
      osSKU: pool.osSku
      vmSize: pool.vmSize
      count: pool.count
      osDiskType: pool.osDiskType
      osDiskSizeGB: pool.osDiskSizeGB
      vnetSubnetID: nodeSubnetId
      maxPods: maxPods
      type: 'VirtualMachineScaleSets'
      enableNodePublicIP: false
      enableEncryptionAtHost: enableEncryptionAtHost
      availabilityZones: empty(pool.zones) ? null : pool.zones
      nodeLabels: nodeLabels
      nodeTaints: nodeTaints
      securityProfile: {
        sshAccess: sshAccess
      }
      upgradeSettings: {
        maxSurge: '33%'
        drainTimeoutInMinutes: 30
      }
    },
    empty(podSubnetId) ? {} : { podSubnetID: podSubnetId },
    scaleSettings,
    spotSettings
  )
}

output id string = agentPool.id
output name string = agentPool.name
