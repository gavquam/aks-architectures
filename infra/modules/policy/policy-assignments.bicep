metadata description = 'The governance baseline. Assignments in Kubernetes mode are enforced in-cluster by the Azure Policy add-on; assignments in ARM mode are enforced by Resource Manager. Every definition ID below was resolved against the live built-in catalogue rather than copied from documentation.'

param location string
param namePrefix string

@description('Audit records violations without blocking. Deny blocks them. Start with Audit in a brownfield estate, move to Deny once the noise is understood. Individual assignments below override this where the definition publishes no Deny effect.')
param effect 'Audit' | 'Deny' | 'Disabled' = 'Deny'

@description('True when the architecture puts the API server on a private endpoint or a delegated subnet. Drives whether the private-cluster rule blocks or merely reports. A public architecture is left reporting rather than exempt, so the exposure appears on the compliance blade instead of disappearing.')
param apiServerIsPrivate bool = false

@description('True when the Azure Policy add-on is installed on the cluster. Nothing evaluates the in-cluster rules without it.')
param enableInClusterPolicies bool = true

@description('Resource ID of the Log Analytics workspace that control plane logs should land in. Empty skips the DeployIfNotExists assignment, which is the fallback when no workspace is deployed.')
param logAnalyticsWorkspaceId string = ''

@description('Regex of container image sources the cluster may pull from. Defaults to Microsoft Container Registry only. Pass the deployed registry login server so first-party images keep working.')
param allowedContainerImagesRegex string = '^mcr\\.microsoft\\.com/.+$'

@description('Deliberately separate from the main effect. Denying unapproved images breaks any tutorial that pulls from Docker Hub, so it reports by default. Move it to Deny once the image supply chain is settled.')
param allowedImagesEffect 'Audit' | 'Deny' | 'Disabled' = 'Audit'

@description('Resource ID of the custom deny-public-IP definition produced by subscription-policy.bicep. Empty skips that assignment, which is the fallback when the deployer has no subscription-level policy rights.')
param denyPublicIpPolicyDefinitionId string = ''

@description('Namespaces exempt from the in-cluster rules. The system namespaces are always excluded by the definitions themselves, but naming them keeps the intent visible.')
param excludedNamespaces string[] = [
  'kube-system'
  'gatekeeper-system'
  'azure-arc'
  'azure-extensions-usage-system'
  'app-routing-system'
]

// ---------------------------------------------------------------------------------------------
// Built-in definition IDs, resolved against `az policy definition list` rather than transcribed.
// ---------------------------------------------------------------------------------------------
var builtIn = {
  // Kubernetes mode. Needs the Azure Policy add-on to evaluate.
  internalLoadBalancer: '3fc4dc25-5baf-40d8-9b05-7fe74c1bc64e'
  noPrivilegedContainers: '95edb821-ddaf-4404-9732-666045e056b4'
  allowedImages: 'febd0533-8e55-448f-b837-bd0e06f16469'
  // ARM mode. Evaluated by Resource Manager against the cluster resource.
  privateClusters: '040732e8-d947-40b8-95d6-854c95024bf8'
  authorizedIpRanges: '0e246bcf-5f6f-4f87-bc6f-775d4712c7ea'
  kubernetesRbac: 'ac4a19c2-fa67-49b4-8ae5-0b2e78c49457'
  localAuthDisabled: '993c2fcd-2b29-49d2-9eb0-df2c3a730c32'
  defenderForContainers: '1c988dd6-ade4-430f-a608-2a3e5b0a6d38'
  diagnosticSettings: '6c66c325-74c8-42fd-a286-a74b0e2939d8'
}

// The resource-ID linter will not accept a helper function here, so tenantResourceId is spelled
// out at every assignment below.
var policyDefinitions = 'Microsoft.Authorization/policyDefinitions'

// Several definitions publish Audit and Disabled only, so asking for Deny fails validation.
var auditOnlyEffect = effect == 'Disabled' ? 'Disabled' : 'Audit'
var enforcement = effect == 'Disabled' ? 'DoNotEnforce' : 'Default'
var deployDiagnosticsPolicy = !empty(logAnalyticsWorkspaceId) && effect != 'Disabled'

// Roles the DeployIfNotExists remediation identity needs, taken from the definition's own
// roleDefinitionIds so the grant is exactly what the policy asks for and nothing more.
var monitoringContributorId = '749f88d5-cbae-40b8-bcfc-e573ddc772fa'
var logAnalyticsContributorId = '92aaf0da-9dab-42b6-94a3-d43ce8d16293'

// ---------------------------------------------------------------------------------------------
// 1. Surface 2, workload load balancers. No Service may allocate a public frontend.
// ---------------------------------------------------------------------------------------------
resource internalLoadBalancers 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: '${namePrefix}-internal-lb'
  location: location
  identity: {
    type: 'None'
  }
  properties: {
    displayName: 'Kubernetes clusters should use internal load balancers'
    description: 'Blocks Service objects of type LoadBalancer that would provision a public frontend.'
    policyDefinitionId: tenantResourceId(policyDefinitions, builtIn.internalLoadBalancer)
    enforcementMode: enforcement
    parameters: {
      effect: {
        value: effect == 'Disabled' ? 'Disabled' : effect
      }
      excludedNamespaces: {
        value: excludedNamespaces
      }
      warn: {
        value: true
      }
    }
  }
}

// ---------------------------------------------------------------------------------------------
// 2. Defence in depth behind the rule above. Catches a public IP created by any other route.
// ---------------------------------------------------------------------------------------------
resource denyPublicIp 'Microsoft.Authorization/policyAssignments@2024-04-01' = if (!empty(denyPublicIpPolicyDefinitionId)) {
  name: '${namePrefix}-deny-public-ip'
  location: location
  identity: {
    type: 'None'
  }
  properties: {
    displayName: 'Deny public IP addresses outside an approved exception'
    description: 'Defence in depth behind the internal load balancer rule. See docs/governance.md for the exception path.'
    policyDefinitionId: denyPublicIpPolicyDefinitionId
    enforcementMode: enforcement
    parameters: {
      effect: {
        value: effect
      }
    }
  }
}

// ---------------------------------------------------------------------------------------------
// 3. Surface 1, the API server endpoint.
//
// On a private architecture this blocks a later edit that would put the API server back on the
// internet. On a public architecture it is left reporting rather than skipped, because a sandbox
// showing as non-compliant is the honest result and it is the quickest way to see the
// difference between the architectures on the compliance blade.
// ---------------------------------------------------------------------------------------------
resource privateClusters 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: '${namePrefix}-private-cluster'
  location: location
  identity: {
    type: 'None'
  }
  properties: {
    displayName: 'Azure Kubernetes Service private clusters should be enabled'
    description: apiServerIsPrivate
      ? 'Enforced. This architecture keeps the API server off the internet and this rule stops that being undone.'
      : 'Reporting only. This architecture puts the API server on the internet, so the finding is expected and is left visible on purpose.'
    policyDefinitionId: tenantResourceId(policyDefinitions, builtIn.privateClusters)
    enforcementMode: enforcement
    parameters: {
      effect: {
        value: effect == 'Disabled' ? 'Disabled' : (apiServerIsPrivate ? effect : 'Audit')
      }
    }
  }
}

// ---------------------------------------------------------------------------------------------
// 4. If the API server is going to be public, the allowlist is the only thing bounding it.
//    The definition publishes Audit and Disabled only, so this reports and cannot block.
// ---------------------------------------------------------------------------------------------
resource authorizedIpRanges 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: '${namePrefix}-authorized-ip'
  location: location
  identity: {
    type: 'None'
  }
  properties: {
    displayName: 'Authorized IP ranges should be defined on Kubernetes Services'
    description: 'Reports any cluster with a public API server and no CIDR allowlist. The definition offers no Deny effect, so this cannot block on its own.'
    policyDefinitionId: tenantResourceId(policyDefinitions, builtIn.authorizedIpRanges)
    enforcementMode: enforcement
    parameters: {
      effect: {
        value: auditOnlyEffect
      }
    }
  }
}

// ---------------------------------------------------------------------------------------------
// 5. Authorisation. Kubernetes RBAC without Entra means group membership is not the control.
// ---------------------------------------------------------------------------------------------
resource kubernetesRbac 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: '${namePrefix}-k8s-rbac'
  location: location
  identity: {
    type: 'None'
  }
  properties: {
    displayName: 'Role-based access control should be used on Kubernetes Services'
    description: 'Reports clusters not using Azure RBAC for Kubernetes authorization. Audit only; the definition offers no Deny effect.'
    policyDefinitionId: tenantResourceId(policyDefinitions, builtIn.kubernetesRbac)
    enforcementMode: enforcement
    parameters: {
      effect: {
        value: auditOnlyEffect
      }
    }
  }
}

// ---------------------------------------------------------------------------------------------
// 6. Authentication. A live local admin kubeconfig routes around Entra, conditional access
//    and PIM entirely, which is the whole identity story for an OT platform.
// ---------------------------------------------------------------------------------------------
resource localAuthDisabled 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: '${namePrefix}-no-local-auth'
  location: location
  identity: {
    type: 'None'
  }
  properties: {
    displayName: 'Kubernetes clusters should have local authentication methods disabled'
    description: 'Blocks a cluster keeping its local admin kubeconfig, which would bypass Entra ID, conditional access and PIM.'
    policyDefinitionId: tenantResourceId(policyDefinitions, builtIn.localAuthDisabled)
    enforcementMode: enforcement
    parameters: {
      effect: {
        value: effect
      }
    }
  }
}

// ---------------------------------------------------------------------------------------------
// 7. Defender for Containers. The definition is AuditIfNotExists, so it reports rather than
//    remediates. The template turns the plan on directly from the standard cost tier upward.
// ---------------------------------------------------------------------------------------------
resource defenderForContainers 'Microsoft.Authorization/policyAssignments@2024-04-01' = {
  name: '${namePrefix}-defender-containers'
  location: location
  identity: {
    type: 'None'
  }
  properties: {
    displayName: 'Microsoft Defender for Containers should be enabled'
    description: 'Reports when the Defender for Containers plan is off on the subscription. Expected to be non-compliant on the lean cost tier, which leaves the plan off.'
    policyDefinitionId: tenantResourceId(policyDefinitions, builtIn.defenderForContainers)
    enforcementMode: enforcement
    parameters: {
      effect: {
        value: effect == 'Disabled' ? 'Disabled' : 'AuditIfNotExists'
      }
    }
  }
}

// ---------------------------------------------------------------------------------------------
// 8. Control plane logs. The template already wires diagnostic settings on the resources it
//    creates; this catches a cluster added to the group by any other route.
// ---------------------------------------------------------------------------------------------
resource diagnosticSettings 'Microsoft.Authorization/policyAssignments@2024-04-01' = if (deployDiagnosticsPolicy) {
  name: '${namePrefix}-aks-diagnostics'
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    displayName: 'Deploy diagnostic settings for Kubernetes Services to Log Analytics'
    description: 'Remediates any cluster in this group missing control plane logging, including kube-audit-admin.'
    policyDefinitionId: tenantResourceId(policyDefinitions, builtIn.diagnosticSettings)
    enforcementMode: 'Default'
    parameters: {
      logAnalytics: {
        value: logAnalyticsWorkspaceId
      }
    }
  }
}

// The remediation identity can only deploy the diagnostic setting if it holds the roles the
// definition names. Both are scoped to this resource group, not the subscription.
resource monitoringContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployDiagnosticsPolicy) {
  name: guid(resourceGroup().id, '${namePrefix}-aks-diagnostics', monitoringContributorId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', monitoringContributorId)
    principalId: diagnosticSettings!.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource logAnalyticsContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployDiagnosticsPolicy) {
  name: guid(resourceGroup().id, '${namePrefix}-aks-diagnostics', logAnalyticsContributorId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', logAnalyticsContributorId)
    principalId: diagnosticSettings!.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------------------------
// 9 and 10. Workload baseline, enforced in-cluster by the add-on.
// ---------------------------------------------------------------------------------------------
resource noPrivilegedContainers 'Microsoft.Authorization/policyAssignments@2024-04-01' = if (enableInClusterPolicies) {
  name: '${namePrefix}-no-privileged'
  location: location
  identity: {
    type: 'None'
  }
  properties: {
    displayName: 'Kubernetes cluster should not allow privileged containers'
    description: 'A privileged container can reach the node it runs on. Blocking it is the single highest-value workload rule.'
    policyDefinitionId: tenantResourceId(policyDefinitions, builtIn.noPrivilegedContainers)
    enforcementMode: enforcement
    parameters: {
      effect: {
        value: effect == 'Disabled' ? 'Disabled' : effect
      }
      excludedNamespaces: {
        value: excludedNamespaces
      }
      warn: {
        value: true
      }
    }
  }
}

resource allowedImages 'Microsoft.Authorization/policyAssignments@2024-04-01' = if (enableInClusterPolicies) {
  name: '${namePrefix}-allowed-images'
  location: location
  identity: {
    type: 'None'
  }
  properties: {
    displayName: 'Kubernetes cluster containers should only use allowed images'
    description: 'Constrains pulls to approved registries. Reports rather than blocks by default; see docs/governance.md before moving it to Deny.'
    policyDefinitionId: tenantResourceId(policyDefinitions, builtIn.allowedImages)
    enforcementMode: effect == 'Disabled' || allowedImagesEffect == 'Disabled' ? 'DoNotEnforce' : 'Default'
    parameters: {
      allowedContainerImagesRegex: {
        value: allowedContainerImagesRegex
      }
      effect: {
        value: effect == 'Disabled' ? 'Disabled' : allowedImagesEffect
      }
      excludedNamespaces: {
        value: excludedNamespaces
      }
      warn: {
        value: true
      }
    }
  }
}

output internalLoadBalancerAssignmentId string = internalLoadBalancers.id
output denyPublicIpAssignmentId string = empty(denyPublicIpPolicyDefinitionId) ? '' : denyPublicIp!.id

@description('How many of the ten baseline controls this deployment actually assigned. Surfaced by the deploy scripts so a skipped control is visible rather than silent.')
output assignedControlCount int = 6 + (empty(denyPublicIpPolicyDefinitionId) ? 0 : 1) + (deployDiagnosticsPolicy ? 1 : 0) + (enableInClusterPolicies ? 2 : 0)

