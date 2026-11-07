#!/usr/bin/env bash
# Checks examples/rancher-entra-login without a browser. Each check prints
# PASS or FAIL. The last step, a real login, needs a person (see README.md).
#
# ROTATE=1 ./verify-rancher.sh also forces a secret rotation and checks that
# Rancher keeps working with the new secret.
# result() reads $? of the check before it. Command substitutions in the
# message run after $? is read, so the warning SC2319 does not apply.
# shellcheck disable=SC2319
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
CACHE="$HOME/.cache/terraform-contabo-kubernetes"
export KUBECONFIG="$CACHE/cluster-live/work/kubeconfig"
EXAMPLE="$REPO/examples/rancher-entra-login"
out() { TF_DATA_DIR="$CACHE/examples-rancher" terraform -chdir="$EXAMPLE" output -raw "$1"; }

URL=$(out url)
APP=$(out rancher_client_id)
TENANT=$(TF_DATA_DIR="$CACHE/cluster-live" terraform -chdir="$REPO/tests/live/cluster" output -raw tenant_id)
GROUP=$(TF_DATA_DIR="$CACHE/examples-platform" terraform -chdir="$HERE/platform" output -raw admin_group_object_id)
NS=rancher-entra-auth
FAILED=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
result() {
  if [ "$1" = 0 ]; then echo "PASS: $2"; else
    echo "FAIL: $2"
    FAILED=1
  fi
}

current_key() {
  kubectl -n cattle-global-data get secret azureadconfig-applicationsecret \
    -o jsonpath='{.metadata.annotations.entra-secret-rotator/key-id}'
}

# A login with a fake code makes Rancher read its Entra ID settings and its
# client secret, and send the code to Entra ID. Entra ID answers AADSTS9002313
# (invalid code). The answer proves that Rancher reads the Secret and reaches
# Entra ID. Entra ID checks the code before the secret, so the answer does not
# prove that the secret is valid; secret_works checks that. A search from the
# local admin cannot reach Entra ID, because Rancher only searches with the
# provider of the caller's own login.
probe_login() {
  local since
  since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  curl -sS -o /dev/null -X POST "$URL/v3-public/azureADProviders/azuread?action=login" \
    -H 'Content-Type: application/json' -d '{"code": "fake-code", "responseType": "json"}'
  sleep 2
  kubectl -n cattle-system logs deploy/rancher --since-time="$since" | grep -q 'AADSTS9002313'
}

secret_works() {
  kubectl -n cattle-global-data get secret azureadconfig-applicationsecret -o jsonpath='{.data.applicationsecret}' |
    base64 -d >"$TMP/secret"
  code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "https://login.microsoftonline.com/$TENANT/oauth2/v2.0/token" \
    --data-urlencode "client_id=$APP" --data-urlencode grant_type=client_credentials \
    --data-urlencode scope=https://graph.microsoft.com/.default --data-urlencode "client_secret@$TMP/secret")
  rm -f "$TMP/secret"
  [ "$code" = 200 ]
}

# run_job <name> [FORCE_ROTATION value]
run_job() {
  kubectl -n "$NS" create job "$1" --from=cronjob/rancher-entra-auth-rotate --dry-run=client -o json |
    jq --arg f "${2:-false}" '.spec.template.spec.containers[0].env += [{name: "FORCE_ROTATION", value: $f}]' |
    kubectl create -f - >/dev/null
  kubectl -n "$NS" wait --for=condition=complete "job/$1" --timeout=900s >/dev/null
  status=$?
  kubectl -n "$NS" logs "job/$1" >"$TMP/$1.log"
  kubectl -n "$NS" delete job "$1" --wait=false >/dev/null
  return $status
}

echo "== Ingress and TLS"
for _ in $(seq 1 30); do
  kubectl -n cattle-system get certificate tls-rancher-ingress -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True && break
  sleep 10
done
curl -sS -o /dev/null "$URL/healthz"
result $? "TLS certificate of $URL is trusted"

echo "== Rancher settings"
kubectl get authconfig azuread -o json >"$TMP/authconfig.json"
jq -e '.enabled == true and .accessMode == "required"' "$TMP/authconfig.json" >/dev/null
result $? "the Entra ID login is on, and only allowed groups may log in"
jq -e --arg app "$APP" --arg url "$URL/verify-auth-azure" '.applicationId == $app and .rancherUrl == $url' "$TMP/authconfig.json" >/dev/null
result $? "the AuthConfig uses the app registration and the redirect address"
curl -sS "$URL/v3-public/authProviders" | jq -e --arg app "$APP" '[.data[] | select(.id == "azuread") | .redirectUrl | contains($app)] | any' >/dev/null
result $? "the Rancher login page offers Entra ID"
kubectl get globalrolebinding -o json | jq -e --arg g "azuread_group://$GROUP" '[.items[] | select(.groupPrincipalName == $g and .globalRoleName == "admin")] | length == 1' >/dev/null
result $? "the admin group has the Rancher admin role"

echo "== Client secret"
key=$(current_key)
[ -n "$key" ] && az ad app credential list --id "$APP" -o json | jq -e --arg k "$key" '[.[] | select(.keyId == $k)] | length == 1' >/dev/null
result $? "Rancher has the secret $key, and the secret exists on the app"
secret_works
result $? "the secret of Rancher works at Entra ID"
probe_login
result $? "Rancher reads its Entra ID settings and its secret, and reaches Entra ID"

echo "== Rotation job"
run_job verify-noop false
result $? "a scheduled run succeeds"
grep -q "still valid" "$TMP/verify-noop.log" && [ "$(current_key)" = "$key" ]
result $? "a scheduled run keeps a valid secret"

if [ "${ROTATE:-0}" = 1 ]; then
  run_job verify-rotate true
  result $? "a forced rotation succeeds"
  new=$(current_key)
  [ -n "$new" ] && [ "$new" != "$key" ]
  result $? "Rancher has a new secret ($key -> $new)"
  secret_works
  result $? "the new secret works at Entra ID"
  probe_login
  result $? "Rancher reads the new secret and reaches Entra ID"
  # A forced rotation is for a leak, so the old secret must be gone at once.
  az ad app credential list --id "$APP" -o json >"$TMP/credentials.json"
  jq -e --arg k "$key" '[.[] | select(.keyId == $k)] | length == 0' "$TMP/credentials.json" >/dev/null
  result $? "the forced rotation removed the old secret $key"
  count=$(jq '[.[] | select(.displayName | startswith("rancher-entra-auth"))] | length' "$TMP/credentials.json")
  [ "$count" = 1 ]
  result $? "exactly one secret of the job exists on the app ($count)"
fi

echo "== Least privilege of the job"
SA=system:serviceaccount:$NS:entra-secret-rotator
[ "$(kubectl auth can-i get secret/other -n cattle-global-data --as="$SA")" = no ]
result $? "the job cannot read other secrets in cattle-global-data"
[ "$(kubectl auth can-i get secrets -n cattle-system --as="$SA")" = no ]
result $? "the job cannot read secrets in other namespaces"
[ "$(kubectl auth can-i patch authconfig/github --as="$SA")" = no ]
result $? "the job cannot change other auth providers"

echo
echo "Manual check: open $URL in a browser, choose \"Log in with Microsoft Entra ID\", and log in as a member of the admin group."
exit $FAILED
