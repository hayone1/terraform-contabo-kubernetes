#!/usr/bin/env bash
# Starts a pod with Azure workload identity and exchanges the service account
# token of the pod at Entra ID. KUBECONFIG must point to the cluster.
#
#   token-exchange.sh <client id of the Entra ID application>
#
# The Entra ID application needs a federated credential for the service
# account wi-test/wi-test (or $TF_VAR_service_account_namespace and
# $TF_VAR_service_account_name).
set -euo pipefail
CLIENT_ID=${1:?usage: token-exchange.sh <client id>}
NS="${TF_VAR_service_account_namespace:-wi-test}"
SA="${TF_VAR_service_account_name:-wi-test}"
# "kubectl wait" fails at once while no node exists yet, so wait for the node first.
for _ in $(seq 1 60); do
  [ -n "$(kubectl get nodes -o name 2>/dev/null)" ] && break
  sleep 10
done
kubectl wait --for=condition=Ready node --all --timeout=600s
for _ in $(seq 1 60); do
  kubectl -n azure-workload-identity-system get deploy/azure-wi-webhook-controller-manager >/dev/null 2>&1 && break
  sleep 10
done
kubectl -n azure-workload-identity-system rollout status deploy/azure-wi-webhook-controller-manager --timeout=600s
# A pod from an earlier run must be gone before the new pod starts.
kubectl -n "$NS" delete pod token-exchange --ignore-not-found --wait=true >/dev/null 2>&1 || true
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $SA
  namespace: $NS
  annotations:
    azure.workload.identity/client-id: "$CLIENT_ID"
---
apiVersion: v1
kind: Pod
metadata:
  name: token-exchange
  namespace: $NS
  labels:
    azure.workload.identity/use: "true"
spec:
  serviceAccountName: $SA
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: exchange
      image: curlimages/curl:8.11.1
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: { drop: [ALL] }
      command:
        - sh
        - -c
        - |
          echo "AZURE_CLIENT_ID=\$AZURE_CLIENT_ID"
          echo "AZURE_TENANT_ID=\$AZURE_TENANT_ID"
          echo "AZURE_FEDERATED_TOKEN_FILE=\$AZURE_FEDERATED_TOKEN_FILE"
          curl -s -o /tmp/r -w "HTTP %{http_code}\n" -X POST "\${AZURE_AUTHORITY_HOST}\${AZURE_TENANT_ID}/oauth2/v2.0/token" \
            -d client_id="\$AZURE_CLIENT_ID" \
            -d grant_type=client_credentials \
            -d scope=https://graph.microsoft.com/.default \
            -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer \
            --data-urlencode client_assertion@"\$AZURE_FEDERATED_TOKEN_FILE"
          sed -E 's/"access_token":"[^"]+"/"access_token":"<redacted>"/' /tmp/r; echo
EOF
kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/token-exchange --timeout=300s || true
logs=$(kubectl -n "$NS" logs token-exchange)
echo "$logs"
kubectl -n "$NS" delete pod token-exchange --wait=false >/dev/null
if ! grep -q "^HTTP 200$" <<<"$logs"; then
  echo "FAIL: Entra ID did not accept the pod token." >&2
  exit 1
fi
echo "PASS: Entra ID accepted the pod token."
