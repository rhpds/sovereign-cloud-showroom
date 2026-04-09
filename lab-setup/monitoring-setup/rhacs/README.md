# RHACS Custom metrics

RHACS central API service (starting from version 4.9) exposes Prometheus metrics on `/metrics` path on port https (443).
The access is subject for authentication, authorization and scoped access control.

## Configuring role

[declarative-configuration-configmap.yaml](declarative-configuration-configmap.yaml): sample Permission Set and Role declarative configuration for Prometheus server access.

See details on using declarative configuration in [the product documentation](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.9/html/configuring/declarative-configuration-using).

## Configuring API access

- You can store a long-lived ROX API token in a secret.
- You can configure Prometheus to access RHACS API with a Kubernetes service account token in a few of ways:
  - OpenShift OAuth provider:
    - use the long-lived service account token as the client key.
  - Short-lived projected service account token:
    - can only be configured via additional scrape config file (not with ServiceMonitor, not with PodMonitor, neither with ScrapeConfig);
    - see the example in [prometheus-operator](../prometheus-operator).
  - Generated service account token secret:
    - you can create a secret of type `kubernetes.io/service-account-token`, and Kubernetes will add there a long-lived token, which can be used as the Bearer token for accessing RHACS API.
- You can configure Prometheus to access RHACS API using TLS certificate:
  - see examples in [cluster-observability-operator](../cluster-observability-operator).

## Configuring metrics via API

Some of the exposed metrics are fixed: they are always exposed with a fixed set of labels.
Other are customizable: they are enabled with a non-zero gathering period, have a custom name and a custom set of labels.

Fixed metrics, gathered once per hour:

- Cluster health: `rox_central_health_cluster_info`
- Total policy numbers: `rox_central_cfg_total_policies`
- Certificate expiry: `rox_central_cert_exp_hours`

Customizable:

- Image vulnerabilities: `rox_central_image_vuln_<name>`, configuration key: `imageVulnerabilities`
- Node vulnerabilities: `rox_central_node_vuln_<name>`, configuration key: `nodeVulnerabilities`
- Policy violations: `rox_central_policy_violation_<name>`, configuration key: `policyViolations`

Call `/v1/config` service to get or set the configuration, including the customizable metrics.

To get the current configuration:

```sh
curl "$ROX_API_ENDPOINT/v1/config" -H "Authorization: Bearer $ROX_API_TOKEN" | jq
```

To configure custom metrics, retrieve the current configuration, add or modify the `metrics` key under `privateConfig`, and send the complete configuration back. For example, to add `deployment_severity` and `namespace_severity` metrics under `imageVulnerabilities`:

```sh
curl "$ROX_API_ENDPOINT/v1/config" -H "Authorization: Bearer $ROX_API_TOKEN" | \
  jq '.privateConfig.metrics.imageVulnerabilities = {
        gatheringPeriodMinutes: 10,
        descriptors: {
          deployment_severity: {
            labels: ["Cluster", "Namespace", "Deployment", "IsPlatformWorkload", "IsFixable", "Severity"]
          },
          namespace_severity: {
            labels: ["Cluster", "Namespace", "Severity"]
          }
        }
      } |
      { config: . }' | \
  curl -X PUT "$ROX_API_ENDPOINT/v1/config" -H "Authorization: Bearer $ROX_API_TOKEN" --data-binary @-
```

> Note: all metrics under `imageVulnerabilities` are exposed with `rox_central_image_vuln_` prefix.
>
> Note: the new configuration has to be put back under `config` key, as: `{ "config": {...} }`.
