metadata description = 'Azure DNS Private Resolver. The supported way to resolve Azure private zones from on-premises and to forward internal zones outbound, instead of hand-maintained conditional forwarders on a pair of DNS VMs.'

param name string
param location string
param tags object

param vnetId string
param inboundSubnetId string
param outboundSubnetId string

@description('Forwarding rules applied to queries leaving the VNet. Each entry is { name, domainName (trailing dot required), targetDnsServers: [{ ipAddress, port }] }.')
param forwardingRules array = []

@description('Additional VNets whose queries should be resolved by this ruleset, typically spokes in a hub-and-spoke topology.')
param rulesetVnetIds string[] = []

resource resolver 'Microsoft.Network/dnsResolvers@2022-07-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    virtualNetwork: {
      id: vnetId
    }
  }
}

resource inbound 'Microsoft.Network/dnsResolvers/inboundEndpoints@2022-07-01' = {
  parent: resolver
  name: 'inbound'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        privateIpAllocationMethod: 'Dynamic'
        subnet: {
          id: inboundSubnetId
        }
      }
    ]
  }
}

resource outbound 'Microsoft.Network/dnsResolvers/outboundEndpoints@2022-07-01' = {
  parent: resolver
  name: 'outbound'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: outboundSubnetId
    }
  }
}

resource ruleset 'Microsoft.Network/dnsForwardingRulesets@2022-07-01' = {
  name: '${name}-ruleset'
  location: location
  tags: tags
  properties: {
    dnsResolverOutboundEndpoints: [
      {
        id: outbound.id
      }
    ]
  }
}

resource rules 'Microsoft.Network/dnsForwardingRulesets/forwardingRules@2022-07-01' = [
  for rule in forwardingRules: {
    parent: ruleset
    name: rule.name
    properties: {
      domainName: rule.domainName
      forwardingRuleState: 'Enabled'
      targetDnsServers: rule.targetDnsServers
    }
  }
]

resource rulesetLinks 'Microsoft.Network/dnsForwardingRulesets/virtualNetworkLinks@2022-07-01' = [
  // union, not concat: the link name is derived from the VNet ID, so a caller that also passes the
  // cluster VNet in rulesetVnetIds would otherwise emit two resources with the same name and ARM
  // rejects the whole template with InvalidTemplate before anything deploys.
  for (target, i) in union([vnetId], rulesetVnetIds): {
    parent: ruleset
    name: 'link-${uniqueString(target)}'
    properties: {
      virtualNetwork: {
        #disable-next-line use-resource-id-functions // target is sourced from resource ID parameters
        id: target
      }
    }
  }
]

output id string = resolver.id
output rulesetId string = ruleset.id

@description('Point on-premises conditional forwarders, or the VNet custom DNS setting, at this address.')
output inboundIpAddress string = inbound.properties.ipConfigurations[0].privateIpAddress
