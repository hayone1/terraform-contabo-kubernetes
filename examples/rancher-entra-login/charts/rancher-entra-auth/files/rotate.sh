#!/bin/sh
# Gives Rancher a valid, short-lived client secret for its Entra ID app, and
# keeps the Rancher Entra ID settings in the state that Terraform describes.
#
# The job logs in to Entra ID as the "rotator" app with the token file of its
# Kubernetes service account (workload identity). It never needs a stored
# secret of its own.
#
# Steps:
#   1. Wait until Rancher has created its "azuread" AuthConfig.
#   2. Get a Microsoft Graph token through workload identity.
#   3. Create a new client secret on the Rancher app when the current one is
#      missing, unknown or close to its end date.
#   4. Test the new secret, then store it in the Secret that Rancher reads.
#   5. Turn on the Entra ID login in Rancher with the settings from Terraform.
#   6. Remove older secrets that this job created. The newest older secret
#      stays until the next rotation, so a slow Rancher pod keeps working.
set -eu

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
fail() {
  log "ERROR: $*"
  exit 1
}

: "${AZURE_CLIENT_ID:?AZURE_CLIENT_ID is missing. Is the workload identity webhook running, and does the pod have the label azure.workload.identity/use=true?}"
: "${AZURE_TENANT_ID:?AZURE_TENANT_ID is missing.}"
: "${AZURE_FEDERATED_TOKEN_FILE:?AZURE_FEDERATED_TOKEN_FILE is missing.}"
: "${AZURE_AUTHORITY_HOST:?AZURE_AUTHORITY_HOST is missing.}"
: "${RANCHER_CLIENT_ID:?RANCHER_CLIENT_ID is missing.}"
: "${RANCHER_URL:?RANCHER_URL is missing.}"
: "${ALLOWED_PRINCIPALS:?ALLOWED_PRINCIPALS is missing.}"
: "${LIFETIME_DAYS:?LIFETIME_DAYS is missing.}"
: "${RENEW_BEFORE_DAYS:?RENEW_BEFORE_DAYS is missing.}"
: "${SECRET_DISPLAY_NAME:?SECRET_DISPLAY_NAME is missing.}"
FORCE_ROTATION="${FORCE_ROTATION:-false}"

SECRET_NAMESPACE=cattle-global-data
SECRET_NAME=azureadconfig-applicationsecret
KEY_ANNOTATION=entra-secret-rotator/key-id
END_ANNOTATION=entra-secret-rotator/end-date-time
PREVIOUS_ANNOTATION=entra-secret-rotator/previous-key-id
LOGIN_HOST="${AZURE_AUTHORITY_HOST%/}"
TOKEN_URL="$LOGIN_HOST/$AZURE_TENANT_ID/oauth2/v2.0/token"
GRAPH=https://graph.microsoft.com/v1.0
APP_URL="$GRAPH/applications(appId='$RANCHER_CLIENT_ID')"

# Secrets only ever live in files in this memory-backed folder, never in
# command arguments.
umask 077
WORK=$(mktemp -d "${WORK_DIR:-/work}/rotate.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
# A forced rotation fills this list. The job removes these keys at the end,
# whatever their age.
: >"$WORK/revoke.txt"

# retry <attempts> <seconds between attempts> <command...>
retry() {
  attempts=$1
  pause=$2
  shift 2
  n=1
  until "$@"; do
    if [ "$n" -ge "$attempts" ]; then
      return 1
    fi
    n=$((n + 1))
    sleep "$pause"
  done
}

# Exchanges the service account token for a Microsoft Graph token.
graph_login() {
  if ! curl -sS --fail-with-body -o "$WORK/token.json" -X POST "$TOKEN_URL" \
    --data-urlencode "client_id=$AZURE_CLIENT_ID" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "scope=https://graph.microsoft.com/.default" \
    --data-urlencode "client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer" \
    --data-urlencode "client_assertion@$AZURE_FEDERATED_TOKEN_FILE"; then
    log "The token exchange failed: $(jq -r '.error_description // .' "$WORK/token.json" 2>/dev/null | head -c 400)"
    return 1
  fi
  printf 'Authorization: Bearer %s\n' "$(jq -r .access_token "$WORK/token.json")" >"$WORK/graph-header"
  rm -f "$WORK/token.json"
}

# graph <method> <url> <output file> [<request body file>]
graph() {
  if [ -n "${4:-}" ]; then
    set -- "$1" "$2" "$3" --data-binary "@$4"
  else
    set -- "$1" "$2" "$3"
  fi
  method=$1
  url=$2
  out=$3
  shift 3
  if ! curl -sS --fail-with-body -o "$out" -X "$method" -H "@$WORK/graph-header" \
    -H "Content-Type: application/json" "$@" "$url"; then
    log "Microsoft Graph $method $url failed: $(jq -r '.error.message // .' "$out" 2>/dev/null | head -c 400)"
    return 1
  fi
}

# Removes one client secret from the Rancher app.
remove_secret() {
  jq -n --arg key "$1" '{keyId: $key}' >"$WORK/remove.json"
  if graph POST "$APP_URL/removePassword" "$WORK/out.json" "$WORK/remove.json"; then
    log "Removed the secret $1."
  else
    return 1
  fi
}

# Tests a client secret of the Rancher app with a real token request.
secret_works() {
  curl -sS --fail-with-body -o "$WORK/test.json" -X POST "$TOKEN_URL" \
    --data-urlencode "client_id=$RANCHER_CLIENT_ID" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "scope=https://graph.microsoft.com/.default" \
    --data-urlencode "client_secret@$1" >/dev/null 2>&1
  status=$?
  rm -f "$WORK/test.json"
  return $status
}

log "Waiting for the Rancher AuthConfig azuread."
retry 90 10 kubectl get authconfig azuread -o name >/dev/null 2>&1 ||
  fail "Rancher did not create the AuthConfig azuread within 15 minutes. Is Rancher running?"

log "Logging in to Microsoft Graph as $AZURE_CLIENT_ID with workload identity."
# A new federated credential or a new permission can take a few minutes to
# reach every Entra ID server.
retry 30 10 graph_login || fail "The workload identity login failed. Check the federated credential of the rotator app."

retry 30 10 graph GET "$APP_URL?\$select=id,passwordCredentials" "$WORK/app.json" ||
  fail "Cannot read the Rancher app. The rotator must own the app and have the Graph permission Application.ReadWrite.OwnedBy with admin consent."

now=$(date -u +%s)
kubectl -n "$SECRET_NAMESPACE" get secret "$SECRET_NAME" -o json >"$WORK/current.json" ||
  fail "Cannot read $SECRET_NAMESPACE/$SECRET_NAME. The chart creates this Secret; is the chart installed?"
current_key=$(jq -r --arg a "$KEY_ANNOTATION" '.metadata.annotations[$a] // ""' "$WORK/current.json")
previous_key=$(jq -r --arg a "$PREVIOUS_ANNOTATION" '.metadata.annotations[$a] // ""' "$WORK/current.json")
rm -f "$WORK/current.json"

# The end date as seconds, or 0 when the key is not on the app.
current_end=0
if [ -n "$current_key" ]; then
  current_end=$(jq -r --arg k "$current_key" '
    [.passwordCredentials[] | select(.keyId == $k) | .endDateTime | sub("\\.[0-9]+"; "") | fromdateiso8601] | first // 0
  ' "$WORK/app.json")
fi
renew_at=$((current_end - RENEW_BEFORE_DAYS * 86400))

if [ "$FORCE_ROTATION" = "true" ]; then
  reason="FORCE_ROTATION is true"
elif [ -z "$current_key" ]; then
  reason="Rancher has no secret from this job yet"
elif [ "$current_end" -eq 0 ]; then
  reason="the current secret $current_key no longer exists on the app"
elif [ "$now" -ge "$renew_at" ]; then
  reason="the current secret $current_key ends in less than $RENEW_BEFORE_DAYS days"
else
  reason=""
fi

if [ -n "$reason" ]; then
  log "Creating a new client secret, because $reason."
  end_date=$(jq -rn --argjson days "$LIFETIME_DAYS" 'now + $days * 86400 | floor | strftime("%Y-%m-%dT%H:%M:%SZ")')
  jq -n --arg name "$SECRET_DISPLAY_NAME" --arg end "$end_date" \
    '{passwordCredential: {displayName: $name, endDateTime: $end}}' >"$WORK/add.json"
  graph POST "$APP_URL/addPassword" "$WORK/new.json" "$WORK/add.json" || fail "Cannot create a client secret."
  new_key=$(jq -r .keyId "$WORK/new.json")
  jq -j .secretText "$WORK/new.json" >"$WORK/secret-text"
  rm -f "$WORK/new.json"

  log "Testing the new secret $new_key. A new secret can take a few minutes to work."
  if ! retry 36 10 secret_works "$WORK/secret-text"; then
    remove_secret "$new_key" || log "WARNING: Cannot remove the failed secret $new_key. The next run removes it."
    fail "The new secret $new_key did not work within 6 minutes. Rancher keeps the old secret."
  fi

  # A forced rotation is for a leaked secret, so the old secret goes away at
  # once. A normal rotation keeps the old secret until the next rotation.
  if [ "$FORCE_ROTATION" = "true" ]; then
    # Every secret of this job that Rancher had may have leaked: the current
    # secret, the previous secret, and every older secret. $WORK/app.json was
    # read before addPassword. A secret of that list that is younger than ten
    # minutes and is neither current nor previous belongs to another run that
    # is still testing it. Rancher never had that secret, so it stays.
    jq -r --arg name "$SECRET_DISPLAY_NAME" --arg current "$current_key" --arg previous "$previous_key" '
      .passwordCredentials[]
      | select(.displayName | startswith($name))
      | select(.keyId == $current or .keyId == $previous or
          (((.startDateTime // "1970-01-01T00:00:00Z") | sub("\\.[0-9]+"; "") | fromdateiso8601) < (now - 600)))
      | .keyId
    ' "$WORK/app.json" >"$WORK/revoke.txt"
    previous_key=""
  else
    previous_key=$current_key
  fi

  jq -n --rawfile secret "$WORK/secret-text" --arg ns "$SECRET_NAMESPACE" --arg name "$SECRET_NAME" \
    --arg ka "$KEY_ANNOTATION" --arg key "$new_key" --arg ea "$END_ANNOTATION" --arg end "$end_date" \
    --arg pa "$PREVIOUS_ANNOTATION" --arg previous "$previous_key" '{
      apiVersion: "v1",
      kind: "Secret",
      type: "Opaque",
      metadata: {name: $name, namespace: $ns, annotations: {($ka): $key, ($ea): $end, ($pa): $previous}},
      data: {applicationsecret: ($secret | @base64)}
    }' >"$WORK/secret.json"
  rm -f "$WORK/secret-text"
  # Server-side apply keeps no copy of the secret in an annotation. The chart
  # creates the empty Secret, so the job only needs the right to patch it.
  if ! kubectl apply --server-side --force-conflicts --field-manager=entra-secret-rotator -f "$WORK/secret.json" >/dev/null; then
    rm -f "$WORK/secret.json"
    remove_secret "$new_key" || log "WARNING: Cannot remove the unused secret $new_key. The next run removes it."
    fail "Cannot store the new secret in $SECRET_NAMESPACE/$SECRET_NAME. Rancher keeps the old secret."
  fi
  rm -f "$WORK/secret.json"
  current_key=$new_key
  log "Rancher now uses the secret $new_key, which ends on $end_date."

  # After a forced rotation, the leaked secrets go away before anything else
  # can fail. Rancher reads the Secret on every request, so Rancher already
  # uses the new secret. A failure here stops the job, because a leaked secret
  # would stay valid.
  if [ -s "$WORK/revoke.txt" ]; then
    graph GET "$APP_URL?\$select=id,passwordCredentials" "$WORK/app.json" || fail "Cannot read the Rancher app again."
    while read -r key; do
      if [ -z "$key" ] || [ "$key" = "$current_key" ]; then continue; fi
      jq -e --arg k "$key" 'any(.passwordCredentials[]; .keyId == $k)' "$WORK/app.json" >/dev/null || continue
      remove_secret "$key" || fail "Cannot remove the old secret $key after a forced rotation. Remove the secret in Entra ID by hand."
    done <"$WORK/revoke.txt"
  fi
else
  log "The current secret $current_key is still valid. No new secret is needed."
fi

log "Applying the Entra ID settings to the Rancher AuthConfig azuread."
jq -n \
  --arg tenant "$AZURE_TENANT_ID" \
  --arg app "$RANCHER_CLIENT_ID" \
  --arg url "${RANCHER_URL%/}" \
  --arg login "$LOGIN_HOST" \
  --arg ref "$SECRET_NAMESPACE:$SECRET_NAME" \
  --argjson principals "$ALLOWED_PRINCIPALS" '{
    # "user-locked" stops Rancher from deleting the Secret, the global role
    # bindings and the Entra ID users when somebody turns the login off in the
    # user interface. The next run of the job turns the login on again.
    metadata: {annotations: {
      "auth.cattle.io/azuread-endpoint-migrated": "true",
      "management.cattle.io/auth-provider-cleanup": "user-locked"
    }},
    enabled: true,
    # Only the allowed principals may log in. "restricted" would also admit
    # every member of a cluster or a project.
    accessMode: "required",
    allowedPrincipalIds: $principals,
    tenantId: $tenant,
    applicationId: $app,
    applicationSecret: $ref,
    endpoint: ($login + "/"),
    graphEndpoint: "https://graph.microsoft.com",
    tokenEndpoint: ($login + "/" + $tenant + "/oauth2/v2.0/token"),
    authEndpoint: ($login + "/" + $tenant + "/oauth2/v2.0/authorize"),
    deviceAuthEndpoint: ($login + "/" + $tenant + "/oauth2/v2.0/devicecode"),
    rancherUrl: ($url + "/verify-auth-azure")
  }' >"$WORK/authconfig.json"
kubectl patch authconfig azuread --type=merge --patch-file="$WORK/authconfig.json" >/dev/null ||
  fail "Cannot update the Rancher AuthConfig azuread."

# Remove every secret of this job except the current secret and the previous
# secret. The key IDs come from the annotations of the Secret, so a secret
# that a failed run left behind is removed too. Secrets with another display
# name, for example secrets that a person created, stay.
#
# Another run of the job can run at the same time, for example the install
# job and a scheduled run. Read the Secret and the app again, and keep every
# secret that is less than one hour old, so that this run never removes a
# secret that another run has just stored.
kubectl -n "$SECRET_NAMESPACE" get secret "$SECRET_NAME" -o json >"$WORK/current.json" ||
  fail "Cannot read $SECRET_NAMESPACE/$SECRET_NAME again."
current_key=$(jq -r --arg a "$KEY_ANNOTATION" '.metadata.annotations[$a] // ""' "$WORK/current.json")
previous_key=$(jq -r --arg a "$PREVIOUS_ANNOTATION" '.metadata.annotations[$a] // ""' "$WORK/current.json")
rm -f "$WORK/current.json"
graph GET "$APP_URL?\$select=id,passwordCredentials" "$WORK/app.json" || fail "Cannot read the Rancher app again."

# The display name is a prefix, so secrets from older versions of the
# example, which added the host name to the display name, are found too.
jq -r --arg name "$SECRET_DISPLAY_NAME" --arg current "$current_key" --arg previous "$previous_key" '
  .passwordCredentials[]
  | select((.displayName | startswith($name)) and .keyId != $current and .keyId != $previous)
  | select(((.startDateTime // "1970-01-01T00:00:00Z") | sub("\\.[0-9]+"; "") | fromdateiso8601) < (now - 3600))
  | .keyId
' "$WORK/app.json" >"$WORK/remove.txt"

while read -r key; do
  [ -n "$key" ] || continue
  remove_secret "$key" || log "WARNING: Cannot remove the old secret $key. The next run tries again."
done <"$WORK/remove.txt"

# Another run can store its secret after this run. Check at the end that the
# secret that Rancher uses now still exists on the app.
graph GET "$APP_URL?\$select=id,passwordCredentials" "$WORK/app.json" || fail "Cannot read the Rancher app at the end."
current_key=$(kubectl -n "$SECRET_NAMESPACE" get secret "$SECRET_NAME" -o json |
  jq -r --arg a "$KEY_ANNOTATION" '.metadata.annotations[$a] // ""')
jq -e --arg k "$current_key" 'any(.passwordCredentials[]; .keyId == $k)' "$WORK/app.json" >/dev/null ||
  fail "Rancher uses the secret $current_key, which does not exist on the app. Run the job again with FORCE_ROTATION=true."

log "Done."
