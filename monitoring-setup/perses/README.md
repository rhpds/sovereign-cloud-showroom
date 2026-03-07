# Sample Perses configuration

The provided [datasource](datasource.yaml) example targets Prometheus service, as installed with the [monitoring stack](../cluster-observability-operator) example.

Change `spec.config.plugin.spec.proxy.url` value according to your Prometheus installation.

The [dashboard](dashboard.yaml) references some predefined metrics, and some that need to be enabled at the RHACS side.

Available by default:

- `rox_central_cfg_total_policies`
- `rox_central_cert_exp_hours`

Need to be enabled via UI or API:

- `rox_central_image_vuln_deployment_severity`, with at least the following labels:
  - Cluster
  - Namespace
  - Deployment
  - IsPlatformWorkload
  - IsFixable
  - Severity
- `rox_central_node_vuln_node_severity`, with at least Cluster label.
- `rox_central_policy_violation_namespace_severity`, with at least Cluster and Namespace labels.

![Screenshot](screenshot.png "Screenshot")
