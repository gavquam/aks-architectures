metadata description = 'The managed cluster. Every architecture lands here; main.bicep resolves the architecture matrix into the primitives this module consumes so the switch logic lives in one place.'

import { nodePoolType } from '../../types.bicep'

param name string
param location string
param tags object

@description('DNS prefix for the API server FQDN. Immutable.')
param dnsPrefix string

@description('Empty takes the AKS default for the region, which is the safest choice for a first deployment.')
param kubernetesVersion string = ''

@description('Automatic hands node pools, scaling, upgrades and ingress to the platform. Migration between Base and Automatic is not supported in either direction.')
param skuName 'Base' | 'Automatic' = 'Base'

@description('Free has no uptime SLA and caps at 10 nodes. Standard is the floor for production.')
param skuTier 'Free' | 'Standard' | 'Premium' = 'Standard'

@description('Node resource group. Named explicitly so destroy.* can assert what it is about to remove.')
param nodeResourceGroupName string

@description('ReadOnly blocks writes to the node resource group. It also blocks VNet links on the AKS-managed private DNS zone, which is why a private cluster under lockdown must bring its own zone.')
param nodeResourceGroupRestriction 'Unrestricted' | 'ReadOnly' = 'Unrestricted'

// ---------------------------------------------------------------- identity

param clusterIdentityId string
param kubeletIdentityResourceId string
param kubeletIdentityClientId string
param kubeletIdentityObjectId string

// ---------------------------------------------------------------- access

param adminGroupObjectIds string[] = []

@description('Local Kubernetes accounts are certificate based and cannot be revoked centrally. Leaving this true is the whole point of the Entra integration.')
param disableLocalAccounts bool = true

param enablePrivateCluster bool = false

@description('Only meaningful on a private cluster. Suppresses the public API server FQDN so the name resolves only inside the network.')
param disablePublicFqdn bool = false

@description('system uses the AKS-managed zone, none disables private DNS entirely, or pass a private DNS zone resource ID to bring your own.')
param privateDnsZoneMode string = 'system'

@description('API Server VNet Integration. Projects the API server into a delegated subnet instead of reaching it over a tunnel.')
param enableVnetIntegration bool = false

@description('Delegated API server subnet. Required when enableVnetIntegration is true.')
param apiServerSubnetId string = ''

@description('Caller ranges permitted to reach a public API server. Empty means unrestricted.')
param authorizedIpRanges string[] = []

// ---------------------------------------------------------------- network

param networkPlugin string = 'azure'

@description('overlay for Azure CNI Overlay, empty for pods on a VNet subnet.')
param networkPluginMode string = 'overlay'

param networkDataplane string = 'azure'
param networkPolicy string = 'azure'

param serviceCidr string
param dnsServiceIp string

@description('Overlay pod range. Empty when pods live on a VNet subnet.')
param podCidr string = ''

param outboundType string = 'loadBalancer'

@description('Managed outbound IP count. Only used when outboundType is loadBalancer.')
@minValue(1)
@maxValue(100)
param managedOutboundIpCount int = 1

@description('Cilium eBPF observability and FQDN filtering. Only valid on the Cilium dataplane.')
param enableAdvancedNetworking bool = false

// ---------------------------------------------------------------- node pools

param systemNodePool nodePoolType
param nodeSubnetId string

@description('Empty unless pods live on a dedicated VNet subnet.')
param podSubnetId string = ''

@description('Reserves the system pool for control-plane add-ons. Only set when a user pool exists to take the workload.')
param taintSystemPool bool = true

@minValue(10)
@maxValue(250)
param maxPods int = 250

@description('SSH to nodes is the usual lateral-movement path on a flat OT network. Disabled means no sshd listener at all, not merely no key.')
param sshAccess 'LocalUser' | 'Disabled' = 'Disabled'

@description('Host-level encryption for OS and data disks. Requires the EncryptionAtHost feature to be registered on the subscription.')
param enableEncryptionAtHost bool = false

// ---------------------------------------------------------------- upgrades

param autoUpgradeChannel 'rapid' | 'stable' | 'patch' | 'node-image' | 'none' = 'stable'
param nodeOsUpgradeChannel 'None' | 'Unmanaged' | 'NodeImage' | 'SecurityPatch' = 'NodeImage'

// ---------------------------------------------------------------- features

@description('Empty disables container insights.')
param logAnalyticsWorkspaceId string = ''

param enableAzurePolicy bool = true
param enableKeyVaultSecretsProvider bool = true
param enableWorkloadIdentity bool = true
param enableImageCleaner bool = true
param enableDefenderForContainers bool = true
param enableManagedPrometheus bool = true
param enableCostAnalysis bool = true

@description('Managed NGINX ingress. The controller is published on an internal load balancer, which keeps it inside the policy baseline that forbids public workload IPs.')
param enableAppRouting bool = false

param enableKeda bool = false
param enableVerticalPodAutoscaler bool = false

@description('Node auto-provisioning. Forced on for the Automatic SKU.')
param enableNodeAutoProvisioning bool = false

@description('Subnet for the Automatic SKU managed system node pool. Required for the Automatic SKU: without it the managed pool ("hostedpool") is created in an AKS-managed VNet, and AKS then rejects any outbound type other than a managed load balancer.')
param systemNodeSubnetId string = ''

var isAutomatic = skuName == 'Automatic'

var systemPoolProfile = union(
  {
    name: 'system'
    mode: 'System'
    osType: 'Linux'
    osSKU: systemNodePool.osSku
    vmSize: systemNodePool.vmSize
    count: systemNodePool.count
    osDiskType: systemNodePool.osDiskType
    osDiskSizeGB: systemNodePool.osDiskSizeGB
    vnetSubnetID: nodeSubnetId
    maxPods: maxPods
    type: 'VirtualMachineScaleSets'
    enableNodePublicIP: false
    enableEncryptionAtHost: enableEncryptionAtHost
    availabilityZones: empty(systemNodePool.zones) ? null : systemNodePool.zones
    nodeTaints: taintSystemPool ? ['CriticalAddonsOnly=true:NoSchedule'] : []
    securityProfile: {
      sshAccess: sshAccess
    }
    upgradeSettings: {
      maxSurge: '33%'
      drainTimeoutInMinutes: 30
    }
  },
  empty(podSubnetId) ? {} : { podSubnetID: podSubnetId },
  // The Automatic SKU sizes and scales the system pool itself; supplying autoscaler bounds conflicts with it.
  isAutomatic
    ? {}
    : systemNodePool.enableAutoScaling
        ? {
            enableAutoScaling: true
            minCount: systemNodePool.minCount
            maxCount: systemNodePool.maxCount
          }
        : { enableAutoScaling: false }
)

var addonProfiles = union(
  {
    azurepolicy: {
      enabled: enableAzurePolicy
    }
    azureKeyvaultSecretsProvider: {
      enabled: enableKeyVaultSecretsProvider
      config: enableKeyVaultSecretsProvider
        ? {
            enableSecretRotation: 'true'
            rotationPollInterval: '2m'
          }
        : null
    }
  },
  empty(logAnalyticsWorkspaceId)
    ? {}
    : {
        omsagent: {
          enabled: true
          config: {
            logAnalyticsWorkspaceResourceID: logAnalyticsWorkspaceId
            useAADAuth: 'true'
          }
        }
      }
)

var apiServerAccessProfile = union(
  {
    disableRunCommand: false
    authorizedIPRanges: empty(authorizedIpRanges) ? null : authorizedIpRanges
  },
  enablePrivateCluster
    ? {
        enablePrivateCluster: true
        enablePrivateClusterPublicFQDN: !disablePublicFqdn
        privateDNSZone: privateDnsZoneMode
      }
    : {},
  enableVnetIntegration
    ? {
        enableVnetIntegration: true
        subnetId: apiServerSubnetId
      }
    : {}
)

var networkProfileValue = union(
  {
    networkPlugin: networkPlugin
    networkDataplane: networkDataplane
    networkPolicy: networkPolicy
    loadBalancerSku: 'standard'
    outboundType: outboundType
    serviceCidr: serviceCidr
    dnsServiceIP: dnsServiceIp
    ipFamilies: ['IPv4']
  },
  empty(networkPluginMode) ? {} : { networkPluginMode: networkPluginMode },
  empty(podCidr) ? {} : { podCidr: podCidr },
  outboundType == 'loadBalancer'
    ? {
        loadBalancerProfile: {
          managedOutboundIPs: {
            count: managedOutboundIpCount
          }
          backendPoolType: 'nodeIPConfiguration'
        }
      }
    : {},
  enableAdvancedNetworking
    ? {
        advancedNetworking: {
          enabled: true
          observability: {
            enabled: true
          }
        }
      }
    : {}
)

resource cluster 'Microsoft.ContainerService/managedClusters@2026-05-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: skuName
    tier: isAutomatic ? 'Standard' : skuTier
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${clusterIdentityId}': {}
    }
  }
  properties: {
    dnsPrefix: dnsPrefix
    kubernetesVersion: empty(kubernetesVersion) ? null : kubernetesVersion
    nodeResourceGroup: nodeResourceGroupName
    nodeResourceGroupProfile: {
      restrictionLevel: isAutomatic ? 'ReadOnly' : nodeResourceGroupRestriction
    }
    enableRBAC: true
    disableLocalAccounts: disableLocalAccounts
    aadProfile: {
      managed: true
      enableAzureRBAC: true
      tenantID: tenant().tenantId
      adminGroupObjectIDs: adminGroupObjectIds
    }
    identityProfile: {
      kubeletidentity: {
        resourceId: kubeletIdentityResourceId
        clientId: kubeletIdentityClientId
        objectId: kubeletIdentityObjectId
      }
    }
    apiServerAccessProfile: apiServerAccessProfile
    networkProfile: networkProfileValue
    agentPoolProfiles: [systemPoolProfile]
    // AKS Automatic always runs a managed system node pool. Pinning it to our own subnet keeps the
    // whole cluster inside the bring-your-own VNet, which is what makes userAssignedNATGateway and
    // userDefinedRouting valid for this SKU.
    hostedSystemProfile: isAutomatic && !empty(systemNodeSubnetId)
      ? {
          enabled: true
          nodeSubnetID: nodeSubnetId
          systemNodeSubnetID: systemNodeSubnetId
        }
      : null
    nodeProvisioningProfile: {
      mode: isAutomatic || enableNodeAutoProvisioning ? 'Auto' : 'Manual'
    }
    autoUpgradeProfile: {
      upgradeChannel: autoUpgradeChannel
      nodeOSUpgradeChannel: nodeOsUpgradeChannel
    }
    oidcIssuerProfile: {
      enabled: enableWorkloadIdentity
    }
    securityProfile: {
      workloadIdentity: {
        enabled: enableWorkloadIdentity
      }
      imageCleaner: {
        enabled: enableImageCleaner
        // The Automatic SKU validates this against its own recommended value and rejects the
        // cluster with AKSAutomaticSKUFeatureValidationError if it differs. 168h is the AKS
        // default; 24h is a deliberate tightening that only the Base SKU accepts.
        intervalHours: isAutomatic ? 168 : 24
      }
      defender: enableDefenderForContainers && !empty(logAnalyticsWorkspaceId)
        ? {
            logAnalyticsWorkspaceResourceId: logAnalyticsWorkspaceId
            securityMonitoring: {
              enabled: true
            }
          }
        : null
    }
    azureMonitorProfile: {
      metrics: {
        enabled: enableManagedPrometheus
        kubeStateMetrics: {
          metricLabelsAllowlist: ''
          metricAnnotationsAllowList: ''
        }
      }
    }
    metricsProfile: {
      costAnalysis: {
        enabled: enableCostAnalysis && skuTier != 'Free'
      }
    }
    workloadAutoScalerProfile: {
      keda: {
        enabled: isAutomatic || enableKeda
      }
      verticalPodAutoscaler: {
        enabled: isAutomatic || enableVerticalPodAutoscaler
      }
    }
    ingressProfile: isAutomatic || enableAppRouting
      ? {
          webAppRouting: {
            enabled: true
            nginx: {
              defaultIngressControllerType: 'Internal'
            }
          }
        }
      : null
    storageProfile: {
      diskCSIDriver: {
        enabled: true
      }
      fileCSIDriver: {
        enabled: true
      }
      blobCSIDriver: {
        enabled: true
      }
      snapshotController: {
        enabled: true
      }
    }
    addonProfiles: addonProfiles
  }
}

output id string = cluster.id
output name string = cluster.name
output nodeResourceGroup string = cluster.properties.nodeResourceGroup
output fqdn string = enablePrivateCluster ? cluster.properties.privateFQDN : cluster.properties.fqdn
output oidcIssuerUrl string = enableWorkloadIdentity ? cluster.properties.oidcIssuerProfile.issuerURL : ''

@description('Principal ID of the Secrets Store CSI add-on identity. Empty when the add-on is off. Fed into the Key Vault Secrets User grant.')
output csiDriverPrincipalId string = enableKeyVaultSecretsProvider
  ? cluster.properties.addonProfiles.azureKeyvaultSecretsProvider.identity.objectId
  : ''
