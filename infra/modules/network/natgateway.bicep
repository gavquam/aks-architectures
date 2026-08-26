metadata description = 'User-assigned NAT Gateway providing predictable SNAT for the node and pod subnets.'

param name string
param location string
param tags object

@description('Zone to pin the NAT Gateway to. A NAT Gateway is a zonal resource; leaving this empty makes it regional (non-zonal).')
param zone string = ''

@minValue(4)
@maxValue(120)
@description('SNAT port idle timeout in minutes.')
param idleTimeoutInMinutes int = 4

@description('Number of public IPs to attach. Each adds 64512 SNAT ports.')
@minValue(1)
@maxValue(16)
param publicIpCount int = 1

resource publicIps 'Microsoft.Network/publicIPAddresses@2024-05-01' = [
  for i in range(0, publicIpCount): {
    name: '${name}-pip-${padLeft(i + 1, 2, '0')}'
    location: location
    tags: tags
    sku: {
      name: 'Standard'
      tier: 'Regional'
    }
    zones: empty(zone) ? null : [zone]
    properties: {
      publicIPAllocationMethod: 'Static'
      publicIPAddressVersion: 'IPv4'
      idleTimeoutInMinutes: idleTimeoutInMinutes
    }
  }
]

resource natGateway 'Microsoft.Network/natGateways@2024-05-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  zones: empty(zone) ? null : [zone]
  properties: {
    idleTimeoutInMinutes: idleTimeoutInMinutes
    publicIpAddresses: [
      for i in range(0, publicIpCount): {
        id: publicIps[i].id
      }
    ]
  }
}

output id string = natGateway.id
output name string = natGateway.name

@description('Egress addresses. Fed into the API server authorized IP allowlist so nodes are never locked out of their own control plane.')
output egressIpAddresses string[] = [for i in range(0, publicIpCount): publicIps[i].properties.ipAddress]
