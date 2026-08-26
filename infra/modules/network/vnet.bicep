metadata description = 'The virtual network and every subnet the environment can use. Subnets are declared inline so a redeploy cannot orphan them.'

import { subnetNames } from '../naming/naming.bicep'

param name string
param location string
param tags object

param vnetAddressSpace string
param nodeSubnetPrefix string
param systemNodeSubnetPrefix string = ''
param podSubnetPrefix string
param apiServerSubnetPrefix string
param firewallSubnetPrefix string
param bastionSubnetPrefix string
param privateEndpointSubnetPrefix string
param dnsResolverInboundPrefix string
param dnsResolverOutboundPrefix string

param deployPodSubnet bool
param deploySystemNodeSubnet bool = false
param deployApiServerSubnet bool
param deployFirewallSubnet bool
param deployBastionSubnet bool
param deployDnsResolverSubnets bool

param nodeNsgId string
param podNsgId string
param apiServerNsgId string
param privateEndpointNsgId string
param bastionNsgId string

@description('Empty unless egress is udr-firewall.')
param routeTableId string = ''

@description('Empty unless egress is natgateway.')
param natGatewayId string = ''

@description('Custom DNS servers for the VNet. Empty uses Azure-provided DNS. Point this at the DNS Private Resolver inbound endpoint for hub-and-spoke resolution.')
param dnsServers string[] = []

var routeTable = empty(routeTableId) ? null : { id: routeTableId }
var natGateway = empty(natGatewayId) ? null : { id: natGatewayId }

var nodeSubnet = [
  {
    name: subnetNames.nodes
    properties: {
      addressPrefix: nodeSubnetPrefix
      networkSecurityGroup: { id: nodeNsgId }
      routeTable: routeTable
      natGateway: natGateway
      privateEndpointNetworkPolicies: 'Disabled'
    }
  }
]

// The AKS Automatic managed system node pool ('hostedpool'). It carries real nodes, so it needs the
// same NSG, route table and NAT gateway as the user node subnet - otherwise cluster egress for the
// system pool does not follow the architecture's egress mode. No delegation: AKS injects into it directly.
var systemNodeSubnet = deploySystemNodeSubnet
  ? [
      {
        name: subnetNames.systemNodes
        properties: {
          addressPrefix: systemNodeSubnetPrefix
          networkSecurityGroup: { id: nodeNsgId }
          routeTable: routeTable
          natGateway: natGateway
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  : []

var podSubnet = deployPodSubnet
  ? [
      {
        name: subnetNames.pods
        properties: {
          addressPrefix: podSubnetPrefix
          networkSecurityGroup: { id: podNsgId }
          routeTable: routeTable
          natGateway: natGateway
          privateEndpointNetworkPolicies: 'Disabled'
          // AKS adds this delegation itself when it attaches to the pod subnet, together with a
          // serviceAssociationLink. Declaring it here is what makes the template idempotent: a
          // redeploy that omits it tries to strip a delegation the link still depends on, and the
          // VNet update fails with SubnetMissingRequiredDelegation. The name matches what AKS uses.
          delegations: [
            {
              name: 'aks-delegation'
              properties: {
                serviceName: 'Microsoft.ContainerService/managedClusters'
              }
            }
          ]
        }
      }
    ]
  : []

var apiServerSubnet = deployApiServerSubnet
  ? [
      {
        name: subnetNames.apiServer
        properties: {
          addressPrefix: apiServerSubnetPrefix
          networkSecurityGroup: { id: apiServerNsgId }
          delegations: [
            {
              name: 'aks-apiserver-delegation'
              properties: {
                serviceName: 'Microsoft.ContainerService/managedClusters'
              }
            }
          ]
        }
      }
    ]
  : []

var privateEndpointSubnet = [
  {
    name: subnetNames.privateEndpoints
    properties: {
      addressPrefix: privateEndpointSubnetPrefix
      networkSecurityGroup: { id: privateEndpointNsgId }
      routeTable: routeTable
      privateEndpointNetworkPolicies: 'Disabled'
    }
  }
]

// AzureFirewallSubnet must carry no NSG and no route table, otherwise the firewall fails to deploy.
var firewallSubnet = deployFirewallSubnet
  ? [
      {
        name: subnetNames.firewall
        properties: {
          addressPrefix: firewallSubnetPrefix
        }
      }
    ]
  : []

var bastionSubnet = deployBastionSubnet
  ? [
      {
        name: subnetNames.bastion
        properties: {
          addressPrefix: bastionSubnetPrefix
          networkSecurityGroup: { id: bastionNsgId }
        }
      }
    ]
  : []

var dnsResolverSubnets = deployDnsResolverSubnets
  ? [
      {
        name: subnetNames.dnsResolverInbound
        properties: {
          addressPrefix: dnsResolverInboundPrefix
          delegations: [
            {
              name: 'dnsresolver-inbound-delegation'
              properties: {
                serviceName: 'Microsoft.Network/dnsResolvers'
              }
            }
          ]
        }
      }
      {
        name: subnetNames.dnsResolverOutbound
        properties: {
          addressPrefix: dnsResolverOutboundPrefix
          delegations: [
            {
              name: 'dnsresolver-outbound-delegation'
              properties: {
                serviceName: 'Microsoft.Network/dnsResolvers'
              }
            }
          ]
        }
      }
    ]
  : []

resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [vnetAddressSpace]
    }
    dhcpOptions: empty(dnsServers) ? null : { dnsServers: dnsServers }
    subnets: concat(
      nodeSubnet,
      systemNodeSubnet,
      podSubnet,
      apiServerSubnet,
      privateEndpointSubnet,
      firewallSubnet,
      bastionSubnet,
      dnsResolverSubnets
    )
  }
}

output id string = vnet.id
output name string = vnet.name
output addressSpace string = vnetAddressSpace

output nodeSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', name, subnetNames.nodes)
output systemNodeSubnetId string = deploySystemNodeSubnet
  ? resourceId('Microsoft.Network/virtualNetworks/subnets', name, subnetNames.systemNodes)
  : ''
output podSubnetId string = deployPodSubnet
  ? resourceId('Microsoft.Network/virtualNetworks/subnets', name, subnetNames.pods)
  : ''
output apiServerSubnetId string = deployApiServerSubnet
  ? resourceId('Microsoft.Network/virtualNetworks/subnets', name, subnetNames.apiServer)
  : ''
output privateEndpointSubnetId string = resourceId(
  'Microsoft.Network/virtualNetworks/subnets',
  name,
  subnetNames.privateEndpoints
)
output firewallSubnetId string = deployFirewallSubnet
  ? resourceId('Microsoft.Network/virtualNetworks/subnets', name, subnetNames.firewall)
  : ''
output bastionSubnetId string = deployBastionSubnet
  ? resourceId('Microsoft.Network/virtualNetworks/subnets', name, subnetNames.bastion)
  : ''
output dnsResolverInboundSubnetId string = deployDnsResolverSubnets
  ? resourceId('Microsoft.Network/virtualNetworks/subnets', name, subnetNames.dnsResolverInbound)
  : ''
output dnsResolverOutboundSubnetId string = deployDnsResolverSubnets
  ? resourceId('Microsoft.Network/virtualNetworks/subnets', name, subnetNames.dnsResolverOutbound)
  : ''
