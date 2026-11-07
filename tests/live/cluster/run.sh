#!/usr/bin/env bash
# Runs the live test of the root module. Run it in WSL or Linux.
#
#   ./run.sh apply [terraform arguments]   erase the instance and build the cluster (15 to 30 minutes)
#   ./run.sh plan      show the plan (exit code 2 means changes)
#   ./run.sh verify    check the cluster without changing it
#   ./run.sh test      start a pod and exchange its token at Entra ID
#   ./run.sh destroy   remove what the test created (the instance keeps running Talos)
#
# Settings come from ../.env (see ../.env.example). Never run this script
# with "bash -x": the .env file holds the Contabo credentials.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

if [ -f "$HERE/../.env" ]; then
  set -a
  # shellcheck disable=SC1091
  source "$HERE/../.env"
  set +a
fi
: "${TF_VAR_instance_id:?Set TF_VAR_instance_id in tests/live/.env}"
: "${TF_VAR_private_network_id:?Set TF_VAR_private_network_id in tests/live/.env}"
: "${TF_VAR_object_storage_id:?Set TF_VAR_object_storage_id in tests/live/.env}"

export TF_DATA_DIR="${TF_DATA_DIR:-$HOME/.cache/terraform-contabo-kubernetes/cluster-live}"
export TF_IN_AUTOMATION=1
WORK="$TF_DATA_DIR/work"
export TF_VAR_work_dir="$WORK"
STATE_FILE="$WORK/terraform.tfstate"
mkdir -p "$WORK/extra-patches"
export KUBECONFIG="$WORK/kubeconfig" TALOSCONFIG="$WORK/talosconfig"

# Extra control plane patches, for example from tests/live/examples/run.sh.
TF_VAR_extra_control_plane_patch_files=$(find "$WORK/extra-patches" -name "*.yaml" | sort | jq -R . | jq -sc .)
export TF_VAR_extra_control_plane_patch_files

init() { terraform init -input=false -upgrade -backend-config="path=$STATE_FILE" >/dev/null; }

failures=0
pass() { echo "PASS: $*"; }
fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}

verify() {
  local ip node
  ip=$(terraform output -json nodes | jq -r 'to_entries[0].value.public_ipv4')
  node=$(terraform output -json nodes | jq -r 'keys[0]')

  if [ "$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ]; then
    pass "the node $node is ready"
  else
    fail "the node $node is not ready"
  fi

  local external
  external=$(kubectl get node "$node" -o jsonpath='{.status.addresses[?(@.type=="ExternalIP")].address}')
  if [ "$external" = "$ip" ]; then
    pass "the Talos CCM set the public address $ip as ExternalIP"
  else
    fail "the ExternalIP of the node is \"$external\", not $ip"
  fi

  if [ -n "$(kubectl get node "$node" -o jsonpath='{.spec.providerID}')" ]; then
    pass "the node has a provider id"
  else
    fail "the node has no provider id"
  fi

  if kubectl get node "$node" -o jsonpath='{.spec.taints}' | grep -q uninitialized; then
    fail "the node still has the uninitialized taint"
  else
    pass "the node has no uninitialized taint"
  fi

  if kubectl -n kube-system rollout status ds/cilium --timeout=300s >/dev/null 2>&1; then
    pass "Cilium runs"
  else
    fail "Cilium does not run"
  fi

  local encryption
  encryption=$(kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg encrypt status 2>/dev/null | sed -n 's/^Encryption:[[:space:]]*//p')
  if [ "${encryption%% *}" = Wireguard ]; then
    pass "Cilium encrypts with WireGuard"
  else
    fail "Cilium encryption is \"$encryption\""
  fi

  if kubectl -n kube-system get ds kube-proxy >/dev/null 2>&1; then
    fail "kube-proxy runs, but Cilium should replace it"
  else
    pass "kube-proxy is not installed"
  fi

  local pending
  pending=$(kubectl get csr -o jsonpath='{range .items[?(@.spec.signerName=="kubernetes.io/kubelet-serving")]}{.metadata.name}={.status.conditions[0].type}{"\n"}{end}' | grep -v '=Approved$' | grep -c . || true)
  if [ "$pending" = 0 ]; then
    pass "every kubelet serving certificate request is approved"
  else
    fail "$pending kubelet serving certificate requests are not approved"
  fi

  if kubectl -n kube-system logs deploy/talos-cloud-controller-manager --tail=1 >/dev/null 2>&1; then
    pass "kubectl logs works (kubelet serving certificate)"
  else
    fail "kubectl logs does not work"
  fi

  local top=""
  for _ in $(seq 1 30); do
    top=$(kubectl top node "$node" --no-headers 2>/dev/null || true)
    [ -n "$top" ] && break
    sleep 10
  done
  if [ -n "$top" ]; then
    pass "metrics-server reports node metrics"
  else
    fail "kubectl top node returns nothing"
  fi

  if kubectl -n kube-system rollout status deploy/coredns --timeout=300s >/dev/null 2>&1; then
    pass "CoreDNS runs"
  else
    fail "CoreDNS does not run"
  fi

  # A pod must resolve names inside and outside the cluster and reach the
  # internet.
  kubectl delete pod net-check -n default --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kubectl run net-check -n default --image=curlimages/curl:8.11.1 --restart=Never --command -- sh -c \
    'nslookup kubernetes.default.svc.cluster.local >/dev/null && curl -sS -o /dev/null -w "%{http_code}" https://factory.talos.dev/' >/dev/null
  kubectl -n default wait --for=jsonpath='{.status.phase}'=Succeeded pod/net-check --timeout=180s >/dev/null 2>&1 || true
  local net
  net=$(kubectl -n default logs net-check 2>/dev/null || true)
  kubectl delete pod net-check -n default --wait=false >/dev/null 2>&1 || true
  if [ "$net" = 200 ]; then
    pass "a pod resolves cluster names and reaches the internet"
  else
    fail "the network check of a pod returned \"$net\""
  fi

  # The Talos host firewall is an nftables chain "ingress" that drops what
  # no rule accepts.
  local policy
  policy=$(talosctl -n "$ip" -e "$ip" get nftableschains ingress -o jsonpath='{.spec.policy}' 2>/dev/null || true)
  if [ "$policy" = drop ]; then
    pass "the Talos host firewall drops everything that no rule accepts"
  else
    fail "the policy of the Talos host firewall is \"$policy\""
  fi

  # From the computer that runs the test: Talos and Kubernetes answer,
  # kubelet does not.
  if timeout 5 bash -c "</dev/tcp/$ip/10250" 2>/dev/null; then
    fail "kubelet (10250) answers on the public address"
  else
    pass "kubelet (10250) does not answer on the public address"
  fi
  if talosctl -n "$ip" -e "$ip" get disks --insecure >/dev/null 2>&1; then
    fail "the node still accepts insecure (maintenance mode) connections"
  else
    pass "the node refuses insecure connections"
  fi

  local hostname
  hostname=$(talosctl -n "$ip" -e "$ip" get hostname -o jsonpath='{.spec.hostname}' 2>/dev/null || true)
  if [ "$hostname" = "$node" ]; then
    pass "the Talos hostname is $node"
  else
    fail "the Talos hostname is \"$hostname\""
  fi

  local private
  private=$(terraform output -json nodes | jq -r 'to_entries[0].value.private_ipv4')
  if [ "$(kubectl get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')" = "$private" ]; then
    pass "the InternalIP is the private address $private"
  else
    fail "the InternalIP is not the private address $private"
  fi

  if [ "$(curl -s -o /dev/null -w '%{http_code}' "$(terraform output -raw issuer_url)/.well-known/openid-configuration")" = 200 ]; then
    pass "the issuer documents are public"
  else
    fail "the issuer documents are not public"
  fi

  echo "$failures failures"
  [ "$failures" = 0 ]
}

case "${1:-}" in
  apply)
    init
    # Extra arguments go to terraform, for example
    # -replace=module.cluster.talos_machine_bootstrap.this
    terraform apply -input=false -auto-approve "${@:2}"
    chmod 600 "$KUBECONFIG" "$TALOSCONFIG"
    echo "kubeconfig: $KUBECONFIG"
    ;;
  plan)
    init
    terraform plan -input=false -detailed-exitcode
    ;;
  verify)
    verify
    ;;
  test)
    "$HERE/../workload-identity/token-exchange.sh" "$(terraform output -raw client_id)"
    ;;
  destroy)
    init
    terraform destroy -input=false -auto-approve
    ;;
  *)
    echo "usage: $0 apply|plan|verify|test|destroy" >&2
    exit 2
    ;;
esac
