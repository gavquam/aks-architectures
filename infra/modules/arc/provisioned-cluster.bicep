metadata description = 'AKS on Azure Local. This creates the Arc connected cluster shell and the provisioned cluster instance that Azure Local materialises into real VMs. It does NOT create the Azure Local instance, the Arc Resource Bridge or the custom location - those are physical-site prerequisites and must already exist. See docs/architectures.md.'

param name string
param location string
param tags object

@description('Resource ID of the custom location projected by the Arc Resource Bridge on the Azure Local instance. Obtain with: az customlocation list -o table')
param customLocationId string

@description('Resource ID of a Microsoft.AzureStackHCI/logicalNetworks on the Azure Local instance. This is the layer 2 network the nodes attach to, and it is the single most common cause of failed AKS Arc provisioning when its IP pool is exhausted or its gateway is wrong.')
param logicalNetworkId string

@description('SSH public key installed on every node for break-glass access. There is no Azure-side password reset for these nodes.')
param sshPublicKey string

@description('Kubernetes version offered by the Arc Resource Bridge. List with: az aksarc get-versions --custom-location <id>')
param kubernetesVersion string = ''

@allowed([1, 3, 5])
@description('One control plane node is a lab. Three is the minimum that survives a node failure at a site.')
param controlPlaneCount int = 3

param controlPlaneVmSize string = 'Standard_A4_v2'

@description('Static IP for the API server, taken from the reserved range of the logical network. Leave empty only when the logical network uses DHCP.')
param controlPlaneHostIp string = ''

param agentPoolName string = 'nodepool1'
param agentPoolCount int = 3
param agentPoolVmSize string = 'Standard_A4_v2'

@description('CIDR for pods inside the cluster. Must not overlap anything routable at the site.')
param podCidr string = '10.244.0.0/16'

@description('Number of load balancer replicas fronting services of type LoadBalancer. Zero means the site provides its own load balancing.')
param loadBalancerCount int = 1

@description('CIDRs permitted to reach the node VMs directly. Empty means no restriction beyond the site network.')
param authorizedIpRanges string = ''

@description('Applies existing Windows Server Datacenter licences to the control plane nodes.')
param azureHybridBenefit 'True' | 'False' | 'NotApplicable' = 'NotApplicable'

param adminGroupObjectIds string[] = []

resource connectedCluster 'Microsoft.Kubernetes/connectedClusters@2024-01-01' = {
  name: name
  location: location
  tags: tags
  kind: 'ProvisionedCluster'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    // Empty is correct for a provisioned cluster: the Arc Resource Bridge supplies the agent
    // certificate during provisioning rather than the caller supplying it up front.
    agentPublicKeyCertificate: ''
    aadProfile: {
      enableAzureRBAC: !empty(adminGroupObjectIds)
      adminGroupObjectIDs: adminGroupObjectIds
      tenantID: subscription().tenantId
    }
    arcAgentProfile: {
      agentAutoUpgrade: 'Enabled'
    }
  }
}

resource provisionedCluster 'Microsoft.HybridContainerService/provisionedClusterInstances@2024-01-01' = {
  scope: connectedCluster
  name: 'default'
  extendedLocation: {
    type: 'CustomLocation'
    name: customLocationId
  }
  properties: {
    kubernetesVersion: empty(kubernetesVersion) ? null : kubernetesVersion
    controlPlane: {
      count: controlPlaneCount
      vmSize: controlPlaneVmSize
      controlPlaneEndpoint: empty(controlPlaneHostIp)
        ? null
        : {
            hostIP: controlPlaneHostIp
          }
    }
    agentPoolProfiles: [
      {
        name: agentPoolName
        count: agentPoolCount
        vmSize: agentPoolVmSize
        osType: 'Linux'
        osSKU: 'CBLMariner'
        enableAutoScaling: false
      }
    ]
    cloudProviderProfile: {
      infraNetworkProfile: {
        vnetSubnetIds: [logicalNetworkId]
      }
    }
    networkProfile: {
      networkPolicy: 'calico'
      podCidr: podCidr
      loadBalancerProfile: {
        count: loadBalancerCount
      }
    }
    linuxProfile: {
      ssh: {
        publicKeys: [
          {
            keyData: sshPublicKey
          }
        ]
      }
    }
    clusterVMAccessProfile: empty(authorizedIpRanges)
      ? null
      : {
          authorizedIPRanges: authorizedIpRanges
        }
    licenseProfile: {
      azureHybridBenefit: azureHybridBenefit
    }
    storageProfile: {
      nfsCsiDriver: {
        enabled: false
      }
      smbCsiDriver: {
        enabled: false
      }
    }
  }
}

output connectedClusterId string = connectedCluster.id
output connectedClusterName string = connectedCluster.name
output provisionedClusterInstanceId string = provisionedCluster.id
