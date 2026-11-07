#!/usr/bin/env bash
# Checks examples/headlamp-entra-login without a browser. Each check prints
# PASS or FAIL. The last step, a real login, needs a person (see README.md).
# result() reads $? of the check before it. Command substitutions in the
# message run after $? is read, so the warning SC2319 does not apply.
# shellcheck disable=SC2319
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
CACHE="$HOME/.cache/terraform-contabo-kubernetes"
export KUBECONFIG="$CACHE/cluster-live/work/kubeconfig"
EXAMPLE="$REPO/examples/headlamp-entra-login"
out() { TF_DATA_DIR="$CACHE/examples-headlamp" terraform -chdir="$EXAMPLE" output -raw "$1"; }

URL=$(out url)
HOST=${URL#https://}
CLIENT_ID=$(out client_id)
NS=headlamp
TENANT=$(TF_DATA_DIR="$CACHE/cluster-live" terraform -chdir="$REPO/tests/live/cluster" output -raw tenant_id | tr "[:upper:]" "[:lower:]")
FAILED=0
result() {
  if [ "$1" = 0 ]; then echo "PASS: $2"; else
    echo "FAIL: $2"
    FAILED=1
  fi
}

echo "== Ingress and TLS"
for _ in $(seq 1 30); do
  kubectl -n "$NS" get certificate headlamp-tls -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True && break
  sleep 10
done
kubectl -n "$NS" get certificate headlamp-tls -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' | grep -q True
result $? "cert-manager issued the certificate"

location=$(curl -sS -o /dev/null -w '%{redirect_url}' "$URL/")
result $? "TLS certificate of $HOST is trusted"
echo "$location" | grep -q "^https://login.microsoftonline.com/$TENANT/oauth2/v2.0/authorize?"
result $? "an anonymous visit goes straight to the Entra ID login"
echo "$location" | grep -q "client_id=$CLIENT_ID" && echo "$location" | grep -q "code_challenge_method=S256"
result $? "the login uses the app registration and PKCE"
echo "$location" | grep -q "redirect_uri=https%3A%2F%2F$HOST%2Foauth2%2Fcallback"
result $? "the redirect address is the registered callback"

echo "== Spoofed identity headers"
code=$(curl -sS -o /dev/null -w '%{http_code}' -H "X-Forwarded-User: admin" -H "X-Forwarded-Id-Token: x" "$URL/api/v1/namespaces")
[ "$code" = 302 ] || [ "$code" = 401 ] || [ "$code" = 403 ]
result $? "a request with forged identity headers but without a session goes to the login (HTTP $code)"

echo "== Workload identity of oauth2-proxy"
pod=$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=oauth2-proxy -o name | head -1)
kubectl -n "$NS" get "$pod" -o jsonpath='{.spec.containers[0].env[*].name}' | grep -q AZURE_FEDERATED_TOKEN_FILE
result $? "the webhook gave oauth2-proxy the Entra ID token file"
kubectl -n "$NS" get secret oauth2-proxy -o json | jq -e '.data | has("client-secret") | not' >/dev/null
result $? "oauth2-proxy has no client secret"

# The same federated credential that oauth2-proxy uses to redeem the login
# code. A token request for Microsoft Graph proves that Entra ID accepts it.
kubectl -n "$NS" delete pod wi-check --ignore-not-found --wait=true >/dev/null
kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: wi-check
  labels:
    azure.workload.identity/use: "true"
spec:
  serviceAccountName: oauth2-proxy
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: check
      image: curlimages/curl:8.11.1
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: { drop: [ALL] }
      command:
        - sh
        - -c
        - |
          curl -s -o /tmp/r -w "%{http_code}" -X POST "\${AZURE_AUTHORITY_HOST}\${AZURE_TENANT_ID}/oauth2/v2.0/token" \
            -d client_id="\$AZURE_CLIENT_ID" -d grant_type=client_credentials \
            -d scope=https://graph.microsoft.com/.default \
            -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer \
            --data-urlencode client_assertion@"\$AZURE_FEDERATED_TOKEN_FILE"
          echo
          # A token for the app itself must be refused: only people log in.
          curl -s -o /tmp/s -w "%{http_code}" -X POST "\${AZURE_AUTHORITY_HOST}\${AZURE_TENANT_ID}/oauth2/v2.0/token" \
            -d client_id="\$AZURE_CLIENT_ID" -d grant_type=client_credentials \
            -d scope="\$AZURE_CLIENT_ID/.default" \
            -d client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer \
            --data-urlencode client_assertion@"\$AZURE_FEDERATED_TOKEN_FILE"
          echo
          sed -n 's/.*"error_codes":\[\([0-9]*\).*/\1/p' /tmp/s
EOF
kubectl -n "$NS" wait --for=jsonpath='{.status.phase}'=Succeeded pod/wi-check --timeout=180s >/dev/null ||
  kubectl -n "$NS" get events --field-selector involvedObject.name=wi-check | tail -5
logs=$(kubectl -n "$NS" logs wi-check)
kubectl -n "$NS" delete pod wi-check --wait=false >/dev/null
[ "$(sed -n 1p <<<"$logs")" = 200 ]
result $? "Entra ID accepts the federated credential of oauth2-proxy (HTTP $(sed -n 1p <<<"$logs"))"
[ "$(sed -n 2p <<<"$logs")" = 400 ]
result $? "Entra ID refuses an app-only token for the app (HTTP $(sed -n 2p <<<"$logs"), error $(sed -n 3p <<<"$logs"))"

echo "== API server trusts Entra ID"
kubectl get --raw /readyz >/dev/null
result $? "the API server accepts the authentication configuration and is ready"
metrics=$(kubectl get --raw /metrics)
grep -q '^apiserver_authentication_config_controller_last_config_info' <<<"$metrics"
result $? "the API server loaded the structured authentication configuration"
# A token with the right issuer and audience but a fake signature. The Entra ID
# authenticator handles the token, and must refuse the signature.
b64url() { base64 -w0 | tr '+/' '-_' | tr -d '='; }
header=$(printf '{"alg":"RS256","kid":"fake","typ":"JWT"}' | b64url)
payload=$(jq -cn --arg iss "https://login.microsoftonline.com/$TENANT/v2.0" --arg aud "$CLIENT_ID" --arg tid "$TENANT" \
  '{iss: $iss, aud: $aud, tid: $tid, oid: "00000000-0000-0000-0000-000000000001", exp: (now + 600 | floor), iat: (now | floor)}' | b64url)
code=$(curl -sk -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $header.$payload.ZmFrZQ" "$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')/api")
[ "$code" = 401 ]
result $? "the API server refuses an Entra ID token with a forged signature (HTTP $code)"
# Talos always loads an authentication configuration, so the metric above
# exists even without the Entra ID authenticator. The latency metric of the
# authenticator only exists when the authenticator for this issuer handled
# the forged token.
issuer_hash="sha256:$(printf '%s' "https://login.microsoftonline.com/$TENANT/v2.0" | sha256sum | cut -d' ' -f1)"
metrics=$(kubectl get --raw /metrics)
grep -q "^apiserver_authentication_jwt_authenticator_latency_seconds_count{.*jwt_issuer_hash=\"$issuer_hash\"" <<<"$metrics"
result $? "the Entra ID authenticator of the API server handled the token"
grep -q "^apiserver_authentication_jwt_authenticator_jwks_fetch_last_timestamp_seconds{.*jwt_issuer_hash=\"$issuer_hash\".*result=\"success\"" <<<"$metrics"
result $? "the API server fetched the key set of Entra ID"

echo "== RBAC"
kubectl get clusterrolebinding -o json | jq -e '[.items[] | select(.metadata.name | startswith("entra-cluster-admin-"))] | length > 0' >/dev/null
result $? "the admin group is bound to cluster-admin"
# "kubectl auth can-i" exits with 1 when the answer is no, so compare the text.
[ "$(kubectl auth can-i list pods --as=system:serviceaccount:"$NS":headlamp -A)" = no ]
result $? "the Headlamp service account has no permissions of its own"

echo
echo "Manual check: open $URL in a browser, and log in as a member of the admin group."
exit $FAILED
