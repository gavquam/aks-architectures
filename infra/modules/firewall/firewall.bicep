metadata description = 'Azure Firewall plus the policy that lets an AKS cluster actually finish provisioning behind userDefinedRouting.'

param name string
param policyName string
param location string
param tags object

@description('AzureFirewallSubnet resource ID.')
param firewallSubnetId string

@description('Availability zones for the firewall and its public IP. Empty deploys a non-zonal firewall.')
param zones string[] = ['1', '2', '3']

@description('Standard covers FQDN tags and application rules. Premium adds TLS inspection and IDPS and costs materially more.')
param skuTier 'Standard' | 'Premium' = 'Standard'

@description('Serving DNS from the firewall is what makes FQDN filtering work in network rules and gives a single egress audit point.')
param enableDnsProxy bool = true

@description('Region the cluster is built in. Used to scope the AzureCloud service tag so node traffic is not opened to every Azure region.')
param clusterRegion string

@description('Node and pod ranges permitted to egress.')
param sourceCidrs string[]

@description('Node OS. Determines which distribution update endpoints are opened.')
param nodeOsSku 'AzureLinux' | 'Ubuntu' = 'AzureLinux'

@description('Opens the endpoints Flux needs to reconcile from a public Git remote. Leave false when GitOps is sourced from a private remote reachable over the VNet.')
param allowFluxGitEndpoints bool = false

@description('Extra FQDNs to permit on 443, for workload dependencies the baseline does not cover.')
param additionalAllowedFqdns string[] = []

var azureCloudRegionTag = 'AzureCloud.${clusterRegion}'

var ubuntuUpdateFqdns = [
  'security.ubuntu.com'
  'azure.archive.ubuntu.com'
  'changelogs.ubuntu.com'
  'motd.ubuntu.com'
]

var azureLinuxUpdateFqdns = [
  'packages.microsoft.com'
  'azurelinuxsupport.azureedge.net'
]

var distroUpdateFqdns = nodeOsSku == 'Ubuntu' ? ubuntuUpdateFqdns : azureLinuxUpdateFqdns

// Resolved from the cloud environment so the same template is correct in sovereign clouds.
var loginHost = replace(replace(environment().authentication.loginEndpoint, 'https://', ''), '/', '')

var monitoringFqdns = [
  '*.ods.opinsights.azure.com'
  '*.oms.opinsights.azure.com'
  '*.monitoring.azure.com'
  '*.handler.control.monitor.azure.com'
  'dc.services.visualstudio.com'
  loginHost
]

var defenderFqdns = [
  '*.ods.opinsights.azure.com'
  '*.oms.opinsights.azure.com'
  loginHost
]

var fluxFqdns = [
  'github.com'
  'api.github.com'
  'codeload.github.com'
  'objects.githubusercontent.com'
  'ghcr.io'
  '*.pkg.github.com'
  // The rest of this list is what the sample GitOps tree under clusters/ actually pulls. Without
  // them Flux reconciles the manifests but every pod sits in ImagePullBackOff, which looks like a
  // workload bug and is really a firewall rule. Mirror these into ACR for a production OT estate
  // and drop them from the allowlist.
  'kubernetes.github.io'
  'registry.k8s.io'
  '*.pkg.dev'
]

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${name}-pip'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  zones: empty(zones) ? null : zones
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource policy 'Microsoft.Network/firewallPolicies@2024-05-01' = {
  name: policyName
  location: location
  tags: tags
  properties: {
    sku: {
      tier: skuTier
    }
    threatIntelMode: 'Alert'
    dnsSettings: enableDnsProxy
      ? {
          enableProxy: true
        }
      : null
  }
}

// Network rules are evaluated before application rules, so they carry the lowest priority number.
resource networkRules 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2024-05-01' = {
  parent: policy
  name: 'aks-network-rules'
  properties: {
    priority: 200
    ruleCollections: [
      {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: 'aks-required-network'
        priority: 200
        action: {
          type: 'Allow'
        }
        rules: [
          {
            ruleType: 'NetworkRule'
            name: 'allow-ntp'
            ipProtocols: ['UDP']
            sourceAddresses: sourceCidrs
            destinationAddresses: ['*']
            destinationPorts: ['123']
          }
          {
            ruleType: 'NetworkRule'
            name: 'allow-azurecloud-region-https'
            ipProtocols: ['TCP']
            sourceAddresses: sourceCidrs
            destinationAddresses: [azureCloudRegionTag]
            destinationPorts: ['443']
          }
          {
            ruleType: 'NetworkRule'
            name: 'allow-tunnel-front'
            ipProtocols: ['TCP']
            sourceAddresses: sourceCidrs
            destinationAddresses: [azureCloudRegionTag]
            destinationPorts: ['9000']
          }
          {
            ruleType: 'NetworkRule'
            name: 'allow-dns'
            ipProtocols: ['TCP', 'UDP']
            sourceAddresses: sourceCidrs
            destinationAddresses: ['*']
            destinationPorts: ['53']
          }
        ]
      }
    ]
  }
}

resource applicationRules 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2024-05-01' = {
  parent: policy
  name: 'aks-application-rules'
  dependsOn: [networkRules]
  properties: {
    priority: 300
    ruleCollections: concat(
      [
        {
          ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
          name: 'aks-fqdn-tag'
          priority: 300
          action: {
            type: 'Allow'
          }
          rules: [
            {
              ruleType: 'ApplicationRule'
              name: 'allow-aks-service'
              sourceAddresses: sourceCidrs
              fqdnTags: ['AzureKubernetesService']
              protocols: [
                { protocolType: 'Http', port: 80 }
                { protocolType: 'Https', port: 443 }
              ]
            }
          ]
        }
        {
          ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
          name: 'aks-platform-fqdns'
          priority: 310
          action: {
            type: 'Allow'
          }
          rules: concat(
            [
              {
                ruleType: 'ApplicationRule'
                name: 'allow-distro-updates'
                sourceAddresses: sourceCidrs
                targetFqdns: distroUpdateFqdns
                protocols: [
                  { protocolType: 'Http', port: 80 }
                  { protocolType: 'Https', port: 443 }
                ]
              }
              {
                ruleType: 'ApplicationRule'
                name: 'allow-monitoring'
                sourceAddresses: sourceCidrs
                targetFqdns: union(monitoringFqdns, defenderFqdns)
                protocols: [
                  { protocolType: 'Https', port: 443 }
                ]
              }
            ],
            empty(additionalAllowedFqdns)
              ? []
              : [
                  {
                    ruleType: 'ApplicationRule'
                    name: 'allow-additional'
                    sourceAddresses: sourceCidrs
                    targetFqdns: additionalAllowedFqdns
                    protocols: [
                      { protocolType: 'Https', port: 443 }
                    ]
                  }
                ]
          )
        }
      ],
      allowFluxGitEndpoints
        ? [
            {
              ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
              name: 'flux-git-endpoints'
              priority: 320
              action: {
                type: 'Allow'
              }
              rules: [
                {
                  ruleType: 'ApplicationRule'
                  name: 'allow-flux-git'
                  sourceAddresses: sourceCidrs
                  targetFqdns: fluxFqdns
                  protocols: [
                    { protocolType: 'Https', port: 443 }
                  ]
                }
              ]
            }
          ]
        : []
    )
  }
}

resource firewall 'Microsoft.Network/azureFirewalls@2024-05-01' = {
  name: name
  location: location
  tags: tags
  zones: empty(zones) ? null : zones
  dependsOn: [applicationRules]
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: skuTier
    }
    firewallPolicy: {
      id: policy.id
    }
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          subnet: {
            id: firewallSubnetId
          }
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
  }
}

output id string = firewall.id
output name string = firewall.name
output policyId string = policy.id

@description('Compared against the address the route table assumed. A mismatch means the default route points at nothing and every node will fail to bootstrap.')
output privateIpAddress string = firewall.properties.ipConfigurations[0].properties.privateIPAddress

@description('Egress address seen by the API server. Appended to the authorized IP allowlist when the architecture restricts API server access.')
output publicIpAddress string = publicIp.properties.ipAddress
