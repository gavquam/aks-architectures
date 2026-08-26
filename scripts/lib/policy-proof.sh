#!/usr/bin/env bash
# Runs INSIDE the cluster, uploaded by `az aks command invoke --file`. Never run this locally.
#
# It answers one question the deployment cannot answer from the outside: is the Deny actually being
# enforced by the admission controller, or does the compliance blade merely say it was assigned?
# Those are different things, and only the second one is usually checked.
#
# The test is deliberately the exact thing the control exists to stop: create a Service of type
# LoadBalancer with no internal annotation. On a governed cluster Gatekeeper must refuse it. If it
# is accepted, the control is not in force, whatever the portal says.
#
# Output is a set of KEY=VALUE lines on stdout so the caller can parse it without guessing.

NS='aksarchitectures-policy-proof'
SVC='aksarchitectures-lb-proof'

# ---------------------------------------------------------------------------------------------
# 1. Is the constraint even present yet?
#
# The Azure Policy add-on polls for assignments roughly every fifteen minutes, so immediately
# after a deployment the constraint template usually does not exist. That is a PENDING result,
# not a failure, and conflating the two would teach exactly the wrong lesson.
# ---------------------------------------------------------------------------------------------
TEMPLATES="$(kubectl get constrainttemplates -o name 2>/dev/null)"
if [ -z "$TEMPLATES" ]; then
  echo 'GATEKEEPER=absent'
  echo 'CONSTRAINT=absent'
  echo 'RESULT=pending'
  echo 'DETAIL=No Gatekeeper constraint templates exist on this cluster yet.'
  exit 0
fi
echo 'GATEKEEPER=present'

LB_TEMPLATE="$(echo "$TEMPLATES" | grep -i 'loadbalancer' | head -1)"
if [ -z "$LB_TEMPLATE" ]; then
  echo 'CONSTRAINT=absent'
  echo 'RESULT=pending'
  echo "DETAIL=Gatekeeper is running but the internal-load-balancer constraint template has not synced yet. Templates present: $(echo "$TEMPLATES" | tr '\n' ' ')"
  exit 0
fi
echo "CONSTRAINT=${LB_TEMPLATE}"

# ---------------------------------------------------------------------------------------------
# 2. Attempt the thing that must be refused.
#
# `kubectl create service loadbalancer` produces an un-annotated public LoadBalancer in one
# command, so there is no manifest to upload and nothing to get wrong in quoting. If the cluster
# accepts it, a public IP allocation is requested, which is why the namespace is torn down
# unconditionally below.
# ---------------------------------------------------------------------------------------------
kubectl create namespace "$NS" >/dev/null 2>&1

ATTEMPT="$(kubectl -n "$NS" create service loadbalancer "$SVC" --tcp=80:80 2>&1)"
ATTEMPT_RC=$?

# Tear down first, report second. An interrupted run must not leave a public IP behind.
kubectl delete namespace "$NS" --wait=false >/dev/null 2>&1

if [ "$ATTEMPT_RC" -ne 0 ]; then
  if echo "$ATTEMPT" | grep -qi 'gatekeeper\|denied the request\|admission webhook'; then
    echo 'RESULT=enforced'
    echo "DETAIL=$(echo "$ATTEMPT" | tr '\n' ' ')"
  else
    # Refused, but not by the policy. Reporting this as a pass would be a lie.
    echo 'RESULT=inconclusive'
    echo "DETAIL=The Service was rejected, but not by an admission webhook: $(echo "$ATTEMPT" | tr '\n' ' ')"
  fi
else
  echo 'RESULT=notenforced'
  echo 'DETAIL=A Service of type LoadBalancer with no internal annotation was ACCEPTED. The Deny is assigned but is not being enforced by the admission controller.'
fi
