metadata description = 'Azure Bastion. The supported way to reach a node or a jumpbox on a private cluster without exposing SSH or RDP to the internet.'

param name string
param location string
param tags object

param bastionSubnetId string

@description('Basic has no native client, no IP-based connection and no tunnelling. Standard is what an operator actually needs for kubectl port-forward style work.')
param skuName 'Basic' | 'Standard' | 'Premium' = 'Standard'

@minValue(2)
@maxValue(50)
@description('Only applies to Standard and above. Each unit supports roughly 20 concurrent sessions.')
param scaleUnits int = 2

@description('Required for the az network bastion tunnel command that operators use to reach a private API server or a node.')
param enableTunneling bool = true

@description('Lets an operator connect to a private IP directly rather than selecting an Azure VM resource.')
param enableIpConnect bool = true

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: '${name}-pip'
  location: location
  tags: union(tags, {
    publicIpException: 'platform-bastion'
  })
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource bastion 'Microsoft.Network/bastionHosts@2024-05-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: skuName
  }
  properties: {
    scaleUnits: skuName == 'Basic' ? null : scaleUnits
    enableTunneling: skuName == 'Basic' ? null : enableTunneling
    enableIpConnect: skuName == 'Basic' ? null : enableIpConnect
    disableCopyPaste: false
    ipConfigurations: [
      {
        name: 'ipconfig'
        properties: {
          subnet: {
            id: bastionSubnetId
          }
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
  }
}

output id string = bastion.id
output name string = bastion.name
