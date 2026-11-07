#!/usr/bin/env bash
# Runs the workload identity live test. Run it in WSL or Linux.
#
#   ./run.sh apply     build the cluster, publish the documents, create the Entra ID app
#   ./run.sh test      start a pod and exchange its token at Entra ID
#   ./run.sh plan      show the plan
#   ./run.sh destroy   remove what the test created (the instance itself stays)
#
# Settings come from ../.env (see ../.env.example).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

# shellcheck source-path=SCRIPTDIR source=env.sh
source "$HERE/env.sh"

tf() { terraform "$@"; }

case "${1:-}" in
  apply)
    tf init -input=false -upgrade -backend-config="path=$STATE_FILE" >/dev/null
    tf apply -input=false -auto-approve
    tf output -raw kubeconfig > "$WORK/kubeconfig"
    tf output -raw talosconfig > "$WORK/talosconfig"
    chmod 600 "$WORK/kubeconfig" "$WORK/talosconfig"
    echo "kubeconfig: $WORK/kubeconfig"
    ;;
  plan)
    tf init -input=false -backend-config="path=$STATE_FILE" >/dev/null
    tf plan -input=false
    ;;
  test)
    export KUBECONFIG="$WORK/kubeconfig"
    "$HERE/token-exchange.sh" "$(tf output -raw client_id)"
    ;;
  destroy)
    tf init -input=false -backend-config="path=$STATE_FILE" >/dev/null
    tf destroy -input=false -auto-approve
    ;;
  *)
    echo "usage: $0 apply|plan|test|destroy" >&2
    exit 2
    ;;
esac
