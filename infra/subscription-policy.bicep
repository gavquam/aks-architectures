targetScope = 'subscription'

metadata description = 'The custom policy definition denying public IP creation. Policy definitions cannot live at resource group scope, so this deploys separately from main.bicep. deploy.* runs it first and feeds the definition ID into the main deployment.'

@description('Prefix for the definition name, so two environments in one subscription do not collide.')
param namePrefix string

resource denyPublicIp 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: '${namePrefix}-deny-public-ip'
  properties: {
    policyType: 'Custom'
    mode: 'All'
    displayName: 'Deny public IP addresses outside an approved exception'
    description: 'Blocks creation of Microsoft.Network/publicIPAddresses unless the resource carries a non-empty publicIpException tag naming the approved change record. Platform egress addresses created by this repository (NAT Gateway, Azure Firewall, Bastion) are tagged automatically; everything else must go through the exception process documented in docs/governance.md.'
    metadata: {
      category: 'Network'
      version: '1.0.0'
    }
    parameters: {
      effect: {
        type: 'String'
        allowedValues: ['Audit', 'Deny', 'Disabled']
        defaultValue: 'Deny'
        metadata: {
          displayName: 'Effect'
          description: 'Audit records a violation, Deny blocks creation, Disabled turns the policy off.'
        }
      }
      exceptionTagName: {
        type: 'String'
        defaultValue: 'publicIpException'
        metadata: {
          displayName: 'Exception tag name'
          description: 'A public IP carrying this tag with a non-empty value is permitted.'
        }
      }
    }
    policyRule: {
      if: {
        allOf: [
          {
            field: 'type'
            equals: 'Microsoft.Network/publicIPAddresses'
          }
          {
            value: '[empty(coalesce(field(concat(\'tags[\', parameters(\'exceptionTagName\'), \']\')), \'\'))]'
            equals: true
          }
        ]
      }
      then: {
        effect: '[parameters(\'effect\')]'
      }
    }
  }
}

output definitionId string = denyPublicIp.id
output definitionName string = denyPublicIp.name
