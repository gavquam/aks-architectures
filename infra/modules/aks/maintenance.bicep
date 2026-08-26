metadata description = 'Planned maintenance windows. Set explicitly so cluster and node image upgrades land inside a change window rather than whenever AKS decides.'

import { maintenanceType } from '../../types.bicep'

param clusterName string
param maintenance maintenanceType

@description('Node OS patching runs more often than cluster upgrades. Weekly on the same day keeps both inside one change window.')
param nodeOsIntervalWeeks int = 1

resource cluster 'Microsoft.ContainerService/managedClusters@2026-05-01' existing = {
  name: clusterName
}

resource autoUpgradeSchedule 'Microsoft.ContainerService/managedClusters/maintenanceConfigurations@2026-05-01' = {
  parent: cluster
  name: 'aksManagedAutoUpgradeSchedule'
  properties: {
    maintenanceWindow: {
      schedule: {
        weekly: {
          intervalWeeks: 1
          dayOfWeek: maintenance.dayOfWeek
        }
      }
      durationHours: maintenance.durationHours
      utcOffset: maintenance.utcOffset
      startTime: maintenance.startTime
      notAllowedDates: []
    }
  }
}

resource nodeOsUpgradeSchedule 'Microsoft.ContainerService/managedClusters/maintenanceConfigurations@2026-05-01' = {
  parent: cluster
  name: 'aksManagedNodeOSUpgradeSchedule'
  properties: {
    maintenanceWindow: {
      schedule: {
        weekly: {
          intervalWeeks: nodeOsIntervalWeeks
          dayOfWeek: maintenance.dayOfWeek
        }
      }
      durationHours: maintenance.durationHours
      utcOffset: maintenance.utcOffset
      startTime: maintenance.startTime
      notAllowedDates: []
    }
  }
}
