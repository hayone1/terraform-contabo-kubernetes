#!/usr/bin/env bash
# Runs the live tests of the examples on the cluster of the root module test.
# Run tests/live/cluster/run.sh apply first. Run this script in WSL
# or Linux.
#
#   ./run.sh platform apply|destroy   Traefik, cert-manager, DNS records, Entra ID group
#   ./run.sh headlamp apply|destroy   examples/headlamp-entra-login
#   ./run.sh rancher  apply|destroy   examples/rancher-entra-login
#   ./run.sh headlamp verify          checks without a browser
#   ./run.sh rancher  verify          checks without a browser
#
# Settings come from ../.env (see ../.env.example).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)

if [ -f "$HERE/../.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$HERE/../.env"
  set +a
fi
: "${EXAMPLES_DNS_ZONE:?Set EXAMPLES_DNS_ZONE in tests/live/.env}"

CACHE="$HOME/.cache/terraform-contabo-kubernetes"
CLUSTER_DATA_DIR="$CACHE/cluster-live"
WORK="$CLUSTER_DATA_DIR/work"
export KUBECONFIG="$WORK/kubeconfig"
export TF_IN_AUTOMATION=1

cluster_output() { TF_DATA_DIR="$CLUSTER_DATA_DIR" terraform -chdir="$REPO/tests/live/cluster" output -raw "$1"; }
platform_output() { TF_DATA_DIR="$CACHE/examples-platform" terraform -chdir="$HERE/platform" output -json "$1"; }
example_output() { TF_DATA_DIR="$CACHE/examples-$1" terraform -chdir="$2" output -raw "$3"; }

# init <name> <folder>
init() {
  local data_dir="$CACHE/examples-$1"
  # The state must not be $TF_DATA_DIR/terraform.tfstate, because Terraform
  # keeps its backend settings in that file.
  mkdir -p "$data_dir/state"
  # Examples have no backend block. A local state outside the repository
  # keeps secrets out of git.
  if [ ! -f "$2/backend_override.tf" ] && [ "$1" != platform ]; then
    printf 'terraform {\n  backend "local" {}\n}\n' >"$2/backend_override.tf"
  fi
  # Only the platform harness upgrades its providers. The examples keep the
  # versions of their committed lock files.
  local upgrade=()
  [ "$1" = platform ] && upgrade=(-upgrade)
  TF_DATA_DIR="$data_dir" terraform -chdir="$2" init -input=false "${upgrade[@]}" -reconfigure \
    -backend-config="path=$data_dir/state/terraform.tfstate" >/dev/null
}

# tf <name> <folder> <terraform arguments...>
tf() {
  local name=$1 dir=$2
  shift 2
  init "$name" "$dir"
  TF_DATA_DIR="$CACHE/examples-$name" terraform -chdir="$dir" "$@"
}

# Runs the cluster harness without the settings of this script.
cluster_apply() { env -u TF_DATA_DIR "$REPO/tests/live/cluster/run.sh" apply; }

example_vars() {
  export TF_VAR_kubeconfig_path="$KUBECONFIG"
  export TF_VAR_tenant_id TF_VAR_issuer_url TF_VAR_admin_group_object_ids TF_VAR_ingress TF_VAR_hostname
  init platform "$HERE/platform"
  TF_VAR_tenant_id=$(cluster_output tenant_id)
  TF_VAR_issuer_url=$(cluster_output issuer_url)
  TF_VAR_admin_group_object_ids="[$(platform_output admin_group_object_id)]"
  TF_VAR_ingress='{"class_name":"traefik","cluster_issuer":"letsencrypt-production"}'
  TF_VAR_hostname=$(platform_output hostnames | jq -r --arg l "$1-wi-live" '.[$l]')
}

case "${1:-} ${2:-}" in
  "platform apply" | "platform destroy")
    export TF_VAR_kubeconfig_path="$KUBECONFIG" TF_VAR_dns_zone="$EXAMPLES_DNS_ZONE"
    tf platform "$HERE/platform" "$2" -input=false -auto-approve
    ;;
  "headlamp apply")
    example_vars headlamp
    tf headlamp "$REPO/examples/headlamp-entra-login" apply -input=false -auto-approve
    # The API server must trust Entra ID. The cluster harness reads every
    # patch in $WORK/extra-patches.
    mkdir -p "$WORK/extra-patches"
    example_output headlamp "$REPO/examples/headlamp-entra-login" talos_config_patch >"$WORK/extra-patches/headlamp-authentication.yaml"
    cluster_apply
    ;;
  "headlamp destroy")
    example_vars headlamp
    rm -f "$WORK/extra-patches/headlamp-authentication.yaml"
    cluster_apply
    tf headlamp "$REPO/examples/headlamp-entra-login" destroy -input=false -auto-approve
    ;;
  "rancher apply" | "rancher destroy")
    example_vars rancher
    export TF_VAR_rancher='{"replicas":1}'
    tf rancher "$REPO/examples/rancher-entra-login" "$2" -input=false -auto-approve
    ;;
  "headlamp plan")
    example_vars headlamp
    tf headlamp "$REPO/examples/headlamp-entra-login" plan -input=false -detailed-exitcode
    ;;
  "rancher plan")
    example_vars rancher
    export TF_VAR_rancher='{"replicas":1}'
    tf rancher "$REPO/examples/rancher-entra-login" plan -input=false -detailed-exitcode
    ;;
  "headlamp verify")
    "$HERE/verify-headlamp.sh"
    ;;
  "rancher verify")
    "$HERE/verify-rancher.sh"
    ;;
  *)
    echo "usage: $0 platform|headlamp|rancher apply|destroy|verify" >&2
    exit 2
    ;;
esac
