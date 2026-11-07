#!/usr/bin/env bash
# Edge-case checks for the workload identity live test. Run after "./run.sh apply".
# Each case prints PASS or FAIL. The script repairs what it breaks.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE" || exit 1
# shellcheck source-path=SCRIPTDIR source=env.sh
source "$HERE/env.sh"
export TF_CLI_ARGS="-no-color"
# env.sh checks that .env sets TF_VAR_object_storage_id.
# shellcheck disable=SC2154
STORAGE="$TF_VAR_object_storage_id"
BUCKET=wi-live-oidc
ISSUER=$(terraform output -raw issuer_url)
LOG=$(mktemp)

result() { if [ "$1" = 0 ]; then echo "PASS: $2"; else echo "FAIL: $2"; tail -30 "$LOG"; fi; }

# S3 access for breaking things on purpose, with the keys of the API user.
CREDS=$(cntb get user-credentials --userId "$(cntb get users -o json | jq -r '.[] | select(.owner==true) | .userId')" --storageId "$STORAGE" -o json)
MC_CONFIG_DIR=$(mktemp -d)
export MC_CONFIG_DIR
# The S3 endpoint is the part of the issuer before the tenant and the bucket.
S3_URL=$(sed -E 's#^(https://[^/]+)/.*#\1#' <<<"$ISSUER")
mc alias set t "$S3_URL" "$(jq -r '.[0].accessKey' <<<"$CREDS")" "$(jq -r '.[0].secretKey' <<<"$CREDS")" --api S3v4 --path on >/dev/null

echo "== 1. Issuer guard: a different bucket name must stop the plan"
TF_VAR_oidc_bucket_name=wi-live-oidc-other terraform plan -input=false >"$LOG" 2>&1
grep -q "The service account issuer would change" "$LOG"
result $? "issuer change is rejected"

echo "== 2. Location guard: a new generation alone must not delete the old documents"
TF_VAR_oidc_bucket_name=wi-live-oidc-other TF_VAR_issuer_generation=2 terraform plan -input=false >"$LOG" 2>&1
grep -q "The issuer documents would move" "$LOG" && ! grep -q "issuer would change" "$LOG" &&
  ! grep -q "will be destroyed" "$LOG"
result $? "the move is stopped until the old documents leave the state"

echo "== 3. Drift: someone overwrites the key set"
echo '{"keys":[]}' > /tmp/bad.json
# Without POISON_CACHE=1 the bad copy carries a short Cache-Control header, so
# the cache drops it within a minute. With POISON_CACHE=1 the bad copy has no
# header, and the Contabo cache keeps it for about 30 minutes. Entra ID logins
# then fail with AADSTS7000272 until the cache expires. Use that only on purpose.
if [ "${POISON_CACHE:-0}" = 1 ]; then
  mc cp -q --attr "Content-Type=application/json" /tmp/bad.json "t/$BUCKET/openid/v1/jwks" >/dev/null
else
  mc cp -q --attr "Content-Type=application/json;Cache-Control=public, max-age=10" /tmp/bad.json "t/$BUCKET/openid/v1/jwks" >/dev/null
fi
terraform plan -input=false >"$LOG" 2>&1
grep -q 'contabo_object_storage_object.documents\["jwks"\] will be updated in-place' "$LOG"
result $? "changed key set is detected"
terraform apply -input=false -auto-approve >"$LOG" 2>&1
result $? "changed key set is repaired"
# Wait until the public copy is the repaired key set again. With POISON_CACHE=1
# the bad copy has no Cache-Control header and can stay in the cache longer.
for i in $(seq 1 30); do
  body=$(curl -s "$ISSUER/openid/v1/jwks")
  [ "$(jq '.keys | length' <<<"$body" 2>/dev/null)" = 1 ] && break
  sleep 10
done
# Known problem: the copy that was uploaded without Cache-Control can stay in
# the Contabo cache for a long time. See the module README, "Known problems".
echo "   INFO: public key set after repair: $(jq -c '[.keys[].kid]' <<<"$body" 2>/dev/null) (waited $((i * 10)) s)"

echo "== 4. Drift: someone deletes the discovery document"
mc rm -q "t/$BUCKET/.well-known/openid-configuration" >/dev/null
terraform plan -input=false >"$LOG" 2>&1
grep -q 'contabo_object_storage_object.documents\["openid_configuration"\] will be created' "$LOG"
result $? "deleted document is detected"
terraform apply -input=false -auto-approve >"$LOG" 2>&1
result $? "deleted document is restored"

echo "== 5. Import of an object"
# The backup goes to the work folder, not into the repository.
terraform state rm -backup="$WORK/state-rm.backup" 'module.workload_identity.contabo_object_storage_object.documents["jwks"]' >/dev/null
terraform import -input=false 'module.workload_identity.contabo_object_storage_object.documents["jwks"]' "$STORAGE/$BUCKET/openid/v1/jwks" >"$LOG" 2>&1
result $? "object import"
terraform plan -input=false >"$LOG" 2>&1
grep -q "0 to add, 0 to change, 0 to destroy\|No changes" "$LOG"
result $? "no changes after import"

rm -rf "$MC_CONFIG_DIR" "$LOG"
