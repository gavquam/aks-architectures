# Environment template for the aks-architectures "drive it directly" path.
# Dot-source this in every shell that runs deploy/preflight/destroy:
#   . ./demo-env.ps1
#
# You do not need this file if you use the wizard (make wizard) — it collects the same values,
# explains each one, and writes them into a parameter file you keep.
#
# deploy.* sets AKS_ROLE_* and AKS_DENY_PUBLIC_IP_POLICY_ID itself.

$env:AKS_CUSTOMER = 'contoso'          # 2-8 lowercase chars; appears in every resource name
$env:AKS_LOCATION = 'westus3'

# A VM size that is generally available in a region can still be restricted in individual zones for
# your subscription (reasonCode NotAvailableForSubscription). Pre-flight reports it; confirm with
#   az vm list-skus --location $env:AKS_LOCATION --size Standard_D4ds_v5 --all -o json
# and narrow the list rather than editing the parameter files.
$env:AKS_NODE_ZONES = '1,2,3'

# Grants the interactive operator Azure RBAC cluster-admin so kubectl works immediately.
$env:AKS_DEPLOYMENT_PRINCIPAL_ID = (az ad signed-in-user show --query id -o tsv)
$env:AKS_DEPLOYMENT_PRINCIPAL_TYPE = 'User'

# Consumed only by aks-public-authorized-ip. Corporate NAT rotates egress addresses, so this is
# resolved at load time rather than pinned; if kubectl starts timing out, re-run this file.
$env:AKS_AUTHORIZED_IP_RANGES = "$((Invoke-RestMethod 'https://api.ipify.org').Trim())/32"

# Preferred for anything beyond a sandbox: grant cluster access to an Entra group, not a person.
$env:AKS_ADMIN_GROUP_OBJECT_IDS = ''

Write-Host "aks-architectures env loaded: customer=$($env:AKS_CUSTOMER) location=$($env:AKS_LOCATION) zones=$($env:AKS_NODE_ZONES)"
