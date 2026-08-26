metadata description = 'The one alert this reference environment exists to teach. A node that never finishes bootstrap does not appear as NotReady, because it never registers with the API server at all. It simply is not there, so the only signal is a Ready node count that stays below what the node pools asked for.'

param location string
param namePrefix string
param tags object

@description('Resource ID of the managed cluster to watch.')
param clusterId string

@description('How many nodes the deployment asked for across every pool. The alert fires when fewer than this number report Ready.')
@minValue(1)
param expectedReadyNodeCount int

@description('Email address to notify. Empty creates the action group with no receivers, which still records the alert in Azure Monitor and on the resource blade. Adding a receiver later does not require redeploying the rule.')
param notificationEmail string = ''

@description('Suppresses notifications without deleting the rule. Useful while a known-bad architecture is being demonstrated on purpose.')
param enabled bool = true

var actionGroupName = 'ag-${namePrefix}-aks'
var alertName = 'alert-${namePrefix}-node-bootstrap'

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: actionGroupName
  // Action groups are a global resource. The location must be the literal string below.
  location: 'global'
  tags: tags
  properties: {
    // The short name appears in the SMS and email subject and is capped at 12 characters.
    groupShortName: take(replace(namePrefix, '-', ''), 12)
    enabled: true
    emailReceivers: empty(notificationEmail)
      ? []
      : [
          {
            name: 'primary'
            emailAddress: notificationEmail
            useCommonAlertSchema: true
          }
        ]
  }
}

// ---------------------------------------------------------------------------------------------
// Node bootstrap failure.
//
// kube_node_status_condition splits on condition and status. Filtering to condition Ready and
// status true and summing gives the number of nodes that actually joined. A node whose custom
// script extension failed, which is the exit code 50 case in the primer, never reports at all,
// so this sum sits below the requested count and the rule fires.
//
// The window is fifteen minutes because a healthy node reaches Ready within roughly five, and a
// scale-up or an image upgrade can legitimately dip the count for a couple of minutes.
// ---------------------------------------------------------------------------------------------
resource nodeBootstrapFailure 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: alertName
  location: 'global'
  tags: tags
  properties: {
    description: 'Fewer nodes are reporting Ready than the deployment asked for. The usual cause is a node that never finished bootstrap: the scale set instance exists but the custom script extension could not reach an endpoint on the minimum outbound set. Run scripts/diagnose.sh against this cluster.'
    severity: 1
    enabled: enabled
    scopes: [
      clusterId
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    targetResourceType: 'Microsoft.ContainerService/managedClusters'
    targetResourceRegion: location
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'ReadyNodesBelowExpected'
          metricNamespace: 'Microsoft.ContainerService/managedClusters'
          metricName: 'kube_node_status_condition'
          dimensions: [
            {
              name: 'condition'
              operator: 'Include'
              values: [
                'Ready'
              ]
            }
            {
              name: 'status'
              operator: 'Include'
              values: [
                'true'
              ]
            }
          ]
          operator: 'LessThan'
          threshold: expectedReadyNodeCount
          timeAggregation: 'Total'
          // A cluster with no nodes at all reports no samples rather than zero. Treating missing
          // data as breaching is the difference between catching a total bootstrap failure and
          // staying silent through one.
          skipMetricValidation: false
        }
      ]
    }
    autoMitigate: true
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}

output actionGroupId string = actionGroup.id
output nodeBootstrapAlertId string = nodeBootstrapFailure.id
output alertName string = nodeBootstrapFailure.name
