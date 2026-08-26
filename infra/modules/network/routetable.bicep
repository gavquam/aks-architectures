metadata description = 'Route table forcing node egress through Azure Firewall. Only deployed when egress is udr-firewall.'

param name string
param location string
param tags object

@description('AzureFirewallSubnet prefix. The firewall private IP is the fourth address of this range, which is how the default route is resolved without creating a dependency cycle between the VNet, the firewall and this route table.')
param firewallSubnetPrefix string

@description('Extra ranges that must bypass the firewall, for example an ExpressRoute-reachable on-premises range that already has a specific route.')
param bypassCidrs string[] = []

var firewallPrivateIp = cidrHost(firewallSubnetPrefix, 3)

resource routeTable 'Microsoft.Network/routeTables@2024-05-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    disableBgpRoutePropagation: false
    routes: concat(
      [
        {
          name: 'default-to-firewall'
          properties: {
            addressPrefix: '0.0.0.0/0'
            nextHopType: 'VirtualAppliance'
            nextHopIpAddress: firewallPrivateIp
          }
        }
      ],
      map(range(0, length(bypassCidrs)), i => {
        name: 'bypass-${i}'
        properties: {
          addressPrefix: bypassCidrs[i]
          nextHopType: 'VirtualNetworkGateway'
        }
      })
    )
  }
}

output id string = routeTable.id
output name string = routeTable.name

@description('The firewall private IP this route table assumes. deploy.* compares it against the address the firewall actually received and aborts on a mismatch.')
output expectedFirewallPrivateIp string = firewallPrivateIp
