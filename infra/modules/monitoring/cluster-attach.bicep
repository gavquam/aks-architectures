metadata description = 'Everything that can only be wired once the cluster resource exists: the two data collection rule associations and the Prometheus recording rules.'

param clusterName string
param location string

@description('Container insights data collection rule. Empty skips the association.')
param containerInsightsDcrId string = ''

@description('Prometheus data collection rule. Empty skips the association and the recording rules.')
param prometheusDcrId string = ''

@description('Azure Monitor workspace the recording rules write into. Empty skips the recording rules.')
param azureMonitorWorkspaceId string = ''

resource cluster 'Microsoft.ContainerService/managedClusters@2026-05-01' existing = {
  name: clusterName
}

resource containerInsightsAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = if (!empty(containerInsightsDcrId)) {
  scope: cluster
  name: 'ContainerInsightsExtension'
  properties: {
    description: 'Container insights telemetry to Log Analytics.'
    dataCollectionRuleId: containerInsightsDcrId
  }
}

resource prometheusAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = if (!empty(prometheusDcrId)) {
  scope: cluster
  name: 'MSProm-${location}-${clusterName}'
  properties: {
    description: 'Managed Prometheus metrics to the Azure Monitor workspace.'
    dataCollectionRuleId: prometheusDcrId
  }
}

// These two groups back the Microsoft-published Grafana dashboards. Without them the dashboards render empty.
resource nodeRecordingRules 'Microsoft.AlertsManagement/prometheusRuleGroups@2023-03-01' = if (!empty(prometheusDcrId) && !empty(azureMonitorWorkspaceId)) {
  name: 'NodeRecordingRulesRuleGroup-${clusterName}'
  location: location
  properties: {
    enabled: true
    description: 'Node level recording rules for Managed Prometheus.'
    clusterName: clusterName
    scopes: [azureMonitorWorkspaceId, cluster.id]
    interval: 'PT1M'
    rules: [
      {
        record: 'instance:node_num_cpu:sum'
        expression: 'count without (cpu, mode) (  node_cpu_seconds_total{job="node",mode="idle"})'
      }
      {
        record: 'instance:node_cpu_utilisation:rate5m'
        expression: '1 - avg without (cpu) (  sum without (mode) (rate(node_cpu_seconds_total{job="node", mode=~"idle|iowait|steal"}[5m])))'
      }
      {
        record: 'instance:node_load1_per_cpu:ratio'
        expression: '(  node_load1{job="node"}/  instance:node_num_cpu:sum{job="node"})'
      }
      {
        record: 'instance:node_memory_utilisation:ratio'
        expression: '1 - (  (    node_memory_MemAvailable_bytes{job="node"}    or    (      node_memory_Buffers_bytes{job="node"}      +      node_memory_Cached_bytes{job="node"}      +      node_memory_MemFree_bytes{job="node"}      +      node_memory_Slab_bytes{job="node"}    )  )/  node_memory_MemTotal_bytes{job="node"})'
      }
      {
        record: 'instance:node_vmstat_pgmajfault:rate5m'
        expression: 'rate(node_vmstat_pgmajfault{job="node"}[5m])'
      }
      {
        record: 'instance_device:node_disk_io_time_seconds:rate5m'
        expression: 'rate(node_disk_io_time_seconds_total{job="node", device!=""}[5m])'
      }
      {
        record: 'instance_device:node_disk_io_time_weighted_seconds:rate5m'
        expression: 'rate(node_disk_io_time_weighted_seconds_total{job="node", device!=""}[5m])'
      }
      {
        record: 'instance:node_network_receive_bytes_excluding_lo:rate5m'
        expression: 'sum without (device) (  rate(node_network_receive_bytes_total{job="node", device!="lo"}[5m]))'
      }
      {
        record: 'instance:node_network_transmit_bytes_excluding_lo:rate5m'
        expression: 'sum without (device) (  rate(node_network_transmit_bytes_total{job="node", device!="lo"}[5m]))'
      }
    ]
  }
}

resource kubernetesRecordingRules 'Microsoft.AlertsManagement/prometheusRuleGroups@2023-03-01' = if (!empty(prometheusDcrId) && !empty(azureMonitorWorkspaceId)) {
  name: 'KubernetesRecordingRulesRuleGroup-${clusterName}'
  location: location
  properties: {
    enabled: true
    description: 'Kubernetes level recording rules for Managed Prometheus.'
    clusterName: clusterName
    scopes: [azureMonitorWorkspaceId, cluster.id]
    interval: 'PT1M'
    rules: [
      {
        record: 'node_namespace_pod_container:container_cpu_usage_seconds_total:sum_irate'
        expression: 'sum by (cluster, namespace, pod, container) (  irate(container_cpu_usage_seconds_total{job="cadvisor", image!=""}[5m])) * on (cluster, namespace, pod) group_left(node) topk by (cluster, namespace, pod) (  1, max by (cluster, namespace, pod, node) (kube_pod_info{node!=""}))'
      }
      {
        record: 'node_namespace_pod_container:container_memory_working_set_bytes'
        expression: 'container_memory_working_set_bytes{job="cadvisor", image!=""}* on (namespace, pod) group_left(node) topk by (namespace, pod) (1,  max by (namespace, pod, node) (kube_pod_info{node!=""}))'
      }
      {
        record: 'cluster:namespace:pod_cpu:active:kube_pod_container_resource_requests'
        expression: 'kube_pod_container_resource_requests{resource="cpu",job="kube-state-metrics"}  * on (namespace, pod, cluster)group_left() max by (namespace, pod, cluster) (  (kube_pod_status_phase{phase=~"Pending|Running"} == 1))'
      }
      {
        record: 'cluster:namespace:pod_memory:active:kube_pod_container_resource_requests'
        expression: 'kube_pod_container_resource_requests{resource="memory",job="kube-state-metrics"}  * on (namespace, pod, cluster)group_left() max by (namespace, pod, cluster) (  (kube_pod_status_phase{phase=~"Pending|Running"} == 1))'
      }
      {
        record: ':node_memory_MemAvailable_bytes:sum'
        expression: 'sum(  node_memory_MemAvailable_bytes{job="node"} or  (    node_memory_Buffers_bytes{job="node"} +    node_memory_Cached_bytes{job="node"} +    node_memory_MemFree_bytes{job="node"} +    node_memory_Slab_bytes{job="node"}  )) by (cluster)'
      }
    ]
  }
}
