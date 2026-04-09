#!/usr/bin/env bash
# Read-only: print OpenShift AI dashboard HTTPS hostname if found (stdout). Empty if unknown.
# Order: classic routes in redhat-ods-applications, then gateway/sharded routes in openshift-ingress
# (see: oc get route -n openshift-ingress — data-science-gateway, rhods-dashboard).

ai_resolve_dashboard_host() {
  local h

  h=$(oc get route rhods-dashboard -n redhat-ods-applications -o jsonpath='{.spec.host}' 2>/dev/null || true)
  if [ -n "$h" ]; then
    echo "$h"
    return 0
  fi

  h=$(oc get route -n redhat-ods-applications -l app=odh-dashboard -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)
  if [ -n "$h" ]; then
    echo "$h"
    return 0
  fi

  # Newer / sharded ingress: primary hostname is often on data-science-gateway in openshift-ingress
  h=$(oc get route data-science-gateway -n openshift-ingress -o jsonpath='{.spec.host}' 2>/dev/null || true)
  if [ -n "$h" ]; then
    echo "$h"
    return 0
  fi

  h=$(oc get route rhods-dashboard -n openshift-ingress -o jsonpath='{.spec.host}' 2>/dev/null || true)
  if [ -n "$h" ] && [ "$h" != "HostAlreadyClaimed" ] && [[ "$h" == *.* ]]; then
    echo "$h"
    return 0
  fi

  return 1
}
