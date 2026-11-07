#!/usr/bin/env bash
# Runs the live test of a cluster with several nodes. Run it in WSL or Linux.
#
#   ./run.sh apply [terraform arguments]   order the instances and build the cluster
#   ./run.sh plan [terraform arguments]    show the plan (exit code 2 means changes)
#   ./run.sh verify                        check the cluster without changing it
#   ./run.sh ingress                       check the Gateway, certificates and DNS (HA_INGRESS=1)
#   ./run.sh tailscale                     check the access through the tailnet (HA_TAILSCALE=1 or HA_HEADSCALE=1)
#   ./run.sh headscale-init                wait for the Headscale server and create its API key (HA_HEADSCALE_SERVER=1)
#   ./run.sh longhorn-v2                   check the V2 Data Engine of Longhorn (HA_LONGHORN_V2=1)
#   ./run.sh backups                       run a backup of etcd and of a Longhorn volume (HA_BACKUPS=1)
#   ./run.sh destroy                       cancel the instances and remove the private network
#   ./run.sh tf <terraform arguments>      run another terraform command, for example "state list"
#
# Settings come from ../.env (see ../.env.example). Never run this script
# with "bash -x": the .env file holds the Contabo credentials.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

for env_file in "$HERE/../.env" "$HERE/../../../.env"; do
  if [ -f "$env_file" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
  fi
done

# HA_INGRESS=1 turns on the Gateway, cert-manager and external-dns with the
# domain ha-live.<EXAMPLES_DNS_ZONE>. The DNS webhooks use the Contabo
# credentials of the test. Keep HA_INGRESS=1 for every later run.
if [ -n "${HA_INGRESS:-}" ]; then
  : "${EXAMPLES_DNS_ZONE:?Set EXAMPLES_DNS_ZONE in tests/live/.env}"
  export TF_VAR_ingress_domain="ha-live.$EXAMPLES_DNS_ZONE"
  export TF_VAR_acme_email="hostmaster@$EXAMPLES_DNS_ZONE"
  TF_VAR_dns_credentials=$(jq -n \
    --arg client_id "$CNTB_OAUTH2_CLIENT_ID" --arg client_secret "$CNTB_OAUTH2_CLIENT_SECRET" \
    --arg api_user "$CNTB_OAUTH2_USER" --arg api_password "$CNTB_OAUTH2_PASS" \
    '{client_id: $client_id, client_secret: $client_secret, api_user: $api_user, api_password: $api_password}')
  export TF_VAR_dns_credentials
fi

# HA_TAILSCALE=1 turns on the Tailscale node agent and the operator. The
# Tailscale provider uses the API access token TAILSCALE_ACCESS_TOKEN.
# HA_ADMIN_MODE=tailscale closes the public Kubernetes API. The provider
# refuses empty credentials even without Tailscale resources, so a run without
# HA_TAILSCALE gets a placeholder.
export TAILSCALE_API_KEY="${TAILSCALE_ACCESS_TOKEN:-unused}"
if [ -n "${HA_TAILSCALE:-}" ]; then
  : "${TAILSCALE_ACCESS_TOKEN:?Set TAILSCALE_ACCESS_TOKEN in tests/live/.env}"
  : "${TAILSCALE_TAILNET_DOMAIN:?Set TAILSCALE_TAILNET_DOMAIN in tests/live/.env}"
  export TAILSCALE_API_KEY="$TAILSCALE_ACCESS_TOKEN"
  export TF_VAR_tailscale=true TF_VAR_tailnet_domain="$TAILSCALE_TAILNET_DOMAIN"
  export TF_VAR_admin_mode="${HA_ADMIN_MODE:-public}"
fi
[ -z "${HA_TAILSCALE_WORKERS:-}" ] || export TF_VAR_tailscale_workers=true

# HA_LONGHORN_V2=1 turns on the V2 Data Engine of Longhorn. Only reinstalled
# workers get the raw partition of v2.
[ -z "${HA_LONGHORN_V2:-}" ] || export TF_VAR_longhorn_v2=true
[ -z "${HA_LONGHORN_V2_INTERRUPT:-}" ] || export TF_VAR_longhorn_v2_interrupt=true

export TF_DATA_DIR="${TF_DATA_DIR:-$HOME/.cache/terraform-contabo-kubernetes/ha-live}"
export TF_IN_AUTOMATION=1
WORK="$TF_DATA_DIR/work"
export TF_VAR_work_dir="$WORK"
STATE_FILE="$WORK/terraform.tfstate"
mkdir -p "$WORK"
export KUBECONFIG="$WORK/kubeconfig" TALOSCONFIG="$WORK/talosconfig"

# HA_BACKUPS=1 backs up etcd and Longhorn into a new bucket of the object
# storage TF_VAR_object_storage_id. The age key stays in the work folder.
if [ -n "${HA_BACKUPS:-}" ]; then
  : "${TF_VAR_object_storage_id:?Set TF_VAR_object_storage_id in tests/live/.env}"
  if [ ! -s "$WORK/age-key.txt" ]; then
    age-keygen -o "$WORK/age-key.txt" 2>/dev/null
    chmod 600 "$WORK/age-key.txt"
  fi
  export TF_VAR_backup_object_storage_id="$TF_VAR_object_storage_id"
  TF_VAR_backup_age_public_key=$(age-keygen -y "$WORK/age-key.txt")
  export TF_VAR_backup_age_public_key
fi

# HA_HEADSCALE_SERVER=1 runs a Headscale server in the cluster at
# headscale.<ingress domain>:8443 (needs HA_INGRESS=1). HA_HEADSCALE=1 also
# moves the node agents from the Tailscale service to that server; run
# "./run.sh headscale-init" between both steps. The Headscale provider uses
# the API key in the work folder whenever the key exists, so that a later
# run (also destroy) can delete the Headscale resources. Like the Tailscale
# provider, it gets placeholders without a key.
export HEADSCALE_ENDPOINT=https://headscale.invalid HEADSCALE_API_KEY=unused
if [ -n "${HA_HEADSCALE_SERVER:-}${HA_HEADSCALE:-}" ]; then
  : "${TF_VAR_ingress_domain:?Headscale needs HA_INGRESS=1}"
  export TF_VAR_headscale_server=true
fi
if [ -s "$WORK/headscale-api-key" ] && [ -n "${TF_VAR_ingress_domain:-}" ]; then
  HEADSCALE_API_KEY=$(cat "$WORK/headscale-api-key")
  export HEADSCALE_API_KEY HEADSCALE_ENDPOINT="https://headscale.$TF_VAR_ingress_domain:8443"
fi
if [ -n "${HA_HEADSCALE:-}" ]; then
  if [ -n "${HA_TAILSCALE:-}" ]; then
    echo "Set HA_HEADSCALE=1 or HA_TAILSCALE=1, not both." >&2
    exit 2
  fi
  [ -s "$WORK/headscale-api-key" ] || {
    echo "Run ./run.sh headscale-init with HA_HEADSCALE_SERVER=1 first." >&2
    exit 2
  }
  export TF_VAR_headscale=true
  export TF_VAR_admin_mode="${HA_ADMIN_MODE:-public}"
fi

# The computer that runs the test joins the tailnet with its own tailscaled in
# userspace mode, so the test needs no root rights. Programs reach the tailnet
# through the HTTP proxy of tailscaled.
# With Headscale, the runner uses a second tailscaled with its own state.
# Only one of them may hold the proxy port.
TS_HOME="$HOME/.local/state/ha-live-tailscale" TS_OTHER="$HOME/.local/state/ha-live-headscale"
RUNNER_KEY="$WORK/tailscale-runner-key" RUNNER_LOGIN=(--advertise-tags=tag:k8s-admin)
if [ -n "${HA_HEADSCALE:-}" ]; then
  TS_HOME="$HOME/.local/state/ha-live-headscale" TS_OTHER="$HOME/.local/state/ha-live-tailscale"
  RUNNER_KEY="$WORK/headscale-runner-key" RUNNER_LOGIN=(--login-server="$HEADSCALE_ENDPOINT")
fi
runner_tailnet() {
  [ -n "${HA_TAILSCALE:-}${HA_HEADSCALE:-}" ] && [ -s "$RUNNER_KEY" ] || return 0
  local sock="$TS_HOME/tailscaled.sock"
  mkdir -p "$TS_HOME"
  pkill -f "tailscaled .*--socket=$TS_OTHER/tailscaled.sock" 2>/dev/null && sleep 2
  if ! tailscale --socket="$sock" status >/dev/null 2>&1; then
    if ! pgrep -f "tailscaled .*--socket=$sock" >/dev/null; then
      nohup tailscaled --tun=userspace-networking --socket="$sock" --statedir="$TS_HOME/state" \
        --outbound-http-proxy-listen=localhost:1055 >"$TS_HOME/tailscaled.log" 2>&1 &
      sleep 5
    fi
    tailscale --socket="$sock" up --auth-key="file:$RUNNER_KEY" "${RUNNER_LOGIN[@]}" \
      --hostname=ha-live-runner --accept-dns=false >/dev/null
  fi
  # Only tailnet names (*.ts.net and the Headscale domain *.hs.internal) go
  # through the proxy. Public addresses and the usual internet domains go
  # direct.
  export HTTPS_PROXY=http://localhost:1055 HTTP_PROXY=http://localhost:1055
  export NO_PROXY=localhost,127.0.0.1,0.0.0.0/0,::/0,.com,.io,.dev,.org,.sh
}
ts() { tailscale --socket="$TS_HOME/tailscaled.sock" "$@"; }

init() { terraform init -input=false -upgrade -backend-config="path=$STATE_FILE" >/dev/null; }

failures=0
pass() { echo "PASS: $*"; }
fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}

node_checks() {
  local name=$1 ip=$2 private=$3 role=$4 pool=$5
  if [ "$(kubectl get node "$name" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ]; then
    pass "$name is ready"
  else
    fail "$name is not ready"
  fi
  if [ "$(kubectl get node "$name" -o jsonpath='{.status.addresses[?(@.type=="ExternalIP")].address}')" = "$ip" ] &&
    [ "$(kubectl get node "$name" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')" = "$private" ]; then
    pass "$name has ExternalIP $ip and InternalIP $private"
  else
    fail "$name has wrong addresses"
  fi
  if [ "$(kubectl get node "$name" -o jsonpath='{.metadata.labels.nodepool}')" = "$pool" ]; then
    pass "$name has the nodepool label $pool"
  else
    fail "$name has no nodepool label"
  fi
  if [ "$role" = worker ]; then
    if [ "$(kubectl get node "$name" -o jsonpath='{.metadata.labels.example\.com/tier}')" = general ] &&
      kubectl get node "$name" -o jsonpath='{.spec.taints}' | grep -q 'example.com/dedicated'; then
      pass "$name has the label and the taint of its pool"
    else
      fail "$name lacks the label or the taint of its pool"
    fi
  fi
  if [ "$(talosctl -n "$ip" -e "$ip" get nftableschains ingress -o jsonpath='{.spec.policy}' 2>/dev/null || true)" = drop ]; then
    pass "the Talos host firewall of $name drops by default"
  else
    fail "the Talos host firewall of $name does not drop by default"
  fi
  if timeout 5 bash -c "</dev/tcp/$ip/10250" 2>/dev/null; then
    fail "kubelet of $name answers on the public address"
  else
    pass "kubelet of $name does not answer on the public address"
  fi
  if talosctl -n "$ip" -e "$ip" get disks --insecure >/dev/null 2>&1; then
    fail "$name accepts insecure (maintenance mode) connections"
  else
    pass "$name refuses insecure connections"
  fi
}

LONGHORN_TEST=$(
  cat <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: lh-test
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: lh-test
spec:
  # No toleration: the pod must land on a Longhorn node.
  restartPolicy: Never
  containers:
    - name: test
      image: busybox:1.37
      command: ["sh", "-c", "echo longhorn > /data/test && sync && cat /data/test"]
      volumeMounts: [{ name: data, mountPath: /data }]
  volumes:
    - name: data
      persistentVolumeClaim: { claimName: lh-test }
YAML
)

verify() {
  local nodes count name
  nodes=$(terraform output -json nodes)
  count=$(jq 'length' <<<"$nodes")

  for name in $(jq -r 'keys[]' <<<"$nodes"); do
    node_checks "$name" \
      "$(jq -r --arg n "$name" '.[$n].public_ipv4' <<<"$nodes")" \
      "$(jq -r --arg n "$name" '.[$n].private_ipv4' <<<"$nodes")" \
      "$(jq -r --arg n "$name" '.[$n].role' <<<"$nodes")" \
      "$(jq -r --arg n "$name" '.[$n].pool' <<<"$nodes")"
  done

  local first_ip cp_count members cp_private w_private
  first_ip=$(jq -r '[.[] | select(.role == "controlplane")][0].public_ipv4' <<<"$nodes")
  cp_count=$(jq '[.[] | select(.role == "controlplane")] | length' <<<"$nodes")
  members=$(talosctl -n "$first_ip" -e "$first_ip" etcd members 2>/dev/null | tail -n +2 | grep -c . || true)
  if [ "$members" = "$cp_count" ]; then
    pass "etcd has $members members"
  else
    fail "etcd has $members members, expected $cp_count"
  fi

  cp_private=$(jq -r '[.[] | select(.role == "controlplane") | .private_ipv4] | join(",")' <<<"$nodes")
  w_private=$(jq -r '[.[] | select(.role == "worker") | .private_ipv4] | join(",")' <<<"$nodes")
  local health_args=(--control-plane-nodes "$cp_private" --wait-timeout 5m)
  [ -n "$w_private" ] && health_args+=(--worker-nodes "$w_private")
  if talosctl -n "$first_ip" -e "$first_ip" health "${health_args[@]}" >/dev/null 2>&1; then
    pass "talosctl health passes"
  else
    fail "talosctl health fails"
  fi

  if kubectl -n kube-system rollout status ds/cilium --timeout=300s >/dev/null 2>&1; then
    pass "Cilium runs on every node"
  else
    fail "Cilium does not run on every node"
  fi
  local peers
  peers=$(kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg encrypt status 2>/dev/null | sed -n 's/.*Number of peers:[[:space:]]*//p' | head -n 1)
  if [ "${peers:-0}" = "$((count - 1))" ]; then
    pass "WireGuard has $peers peers"
  else
    fail "WireGuard has \"$peers\" peers, expected $((count - 1))"
  fi

  local pending
  pending=$(kubectl get csr -o jsonpath='{range .items[?(@.spec.signerName=="kubernetes.io/kubelet-serving")]}{.metadata.name}={.status.conditions[0].type}{"\n"}{end}' | grep -v '=Approved$' | grep -c . || true)
  if [ "$pending" = 0 ]; then
    pass "every kubelet serving certificate request is approved"
  else
    fail "$pending kubelet serving certificate requests are not approved"
  fi

  if kubectl -n kube-system rollout status deploy/coredns --timeout=300s >/dev/null 2>&1 && [ -n "$(kubectl top node --no-headers 2>/dev/null)" ]; then
    pass "CoreDNS and metrics-server work"
  else
    fail "CoreDNS or metrics-server does not work"
  fi

  # Pod traffic between the first and the last node.
  local first second target
  first=$(jq -r 'keys[0]' <<<"$nodes")
  second=$(jq -r 'keys[-1]' <<<"$nodes")
  kubectl delete pod ping-a ping-b -n default --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kubectl run ping-a -n default --image=nginx:1.27-alpine --restart=Never \
    --overrides="{\"spec\":{\"nodeName\":\"$first\",\"tolerations\":[{\"operator\":\"Exists\"}]}}" >/dev/null
  kubectl -n default wait --for=condition=Ready pod/ping-a --timeout=180s >/dev/null 2>&1 || true
  target=$(kubectl -n default get pod ping-a -o jsonpath='{.status.podIP}')
  kubectl run ping-b -n default --image=curlimages/curl:8.11.1 --restart=Never \
    --overrides="{\"spec\":{\"nodeName\":\"$second\",\"tolerations\":[{\"operator\":\"Exists\"}]}}" \
    --command -- sh -c "curl -s -o /dev/null -w '%{http_code}' http://$target/" >/dev/null
  kubectl -n default wait --for=jsonpath='{.status.phase}'=Succeeded pod/ping-b --timeout=180s >/dev/null 2>&1 || true
  if [ "$(kubectl -n default logs ping-b 2>/dev/null || true)" = 200 ]; then
    pass "a pod on $second reaches a pod on $first"
  else
    fail "a pod on $second cannot reach a pod on $first"
  fi
  kubectl delete pod ping-a ping-b -n default --wait=false >/dev/null 2>&1 || true

  # Longhorn: the nodes have a schedulable disk, and a pod can write to a
  # volume.
  if kubectl -n longhorn-system rollout status ds/longhorn-manager --timeout=600s >/dev/null 2>&1; then
    pass "longhorn-manager runs"
  else
    fail "longhorn-manager does not run"
  fi
  local ready_nodes
  ready_nodes=$(kubectl -n longhorn-system get nodes.longhorn.io -o json 2>/dev/null |
    jq '[.items[] | select([.status.diskStatus[]?.conditions[]? | select(.type == "Schedulable" and .status == "True")] | length > 0)] | length' || echo 0)
  if [ "${ready_nodes:-0}" -ge 1 ]; then
    pass "$ready_nodes Longhorn nodes have a schedulable disk"
  else
    fail "no Longhorn node has a schedulable disk"
  fi
  kubectl delete pod lh-test -n default --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kubectl delete pvc lh-test -n default --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kubectl apply -n default -f - >/dev/null <<<"$LONGHORN_TEST"
  kubectl -n default wait --for=jsonpath='{.status.phase}'=Succeeded pod/lh-test --timeout=600s >/dev/null 2>&1 || true
  if [ "$(kubectl -n default logs lh-test 2>/dev/null || true)" = longhorn ]; then
    pass "a pod writes to a Longhorn volume"
  else
    fail "a pod cannot write to a Longhorn volume"
  fi
  kubectl delete pod lh-test -n default --wait=true >/dev/null 2>&1 || true
  kubectl delete pvc lh-test -n default --wait=false >/dev/null 2>&1 || true

  echo "INFO: EPHEMERAL of the first control plane node: $(talosctl -n "$first_ip" -e "$first_ip" get volumestatus EPHEMERAL -o jsonpath='{.spec.prettySize}' 2>/dev/null || true)"
  echo "$failures failures"
  [ "$failures" = 0 ]
}

ECHO_APP=$(
  cat <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: echo
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo
  namespace: echo
spec:
  replicas: 2
  selector: { matchLabels: { app: echo } }
  template:
    metadata: { labels: { app: echo } }
    spec:
      containers:
        - name: echo
          image: nginx:1.27-alpine
          ports: [{ containerPort: 80 }]
---
apiVersion: v1
kind: Service
metadata:
  name: echo
  namespace: echo
spec:
  selector: { app: echo }
  ports: [{ port: 80 }]
YAML
)

# Checks the Gateway, the certificate and the DNS records with a small web
# application at echo.<domain>.
verify_ingress() {
  local domain=${TF_VAR_ingress_domain:?Run with HA_INGRESS=1}
  local host="echo.$domain"
  kubectl apply -f - >/dev/null <<<"$ECHO_APP"
  kubectl apply -f - >/dev/null <<YAML
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: echo
  namespace: echo
spec:
  parentRefs: [{ name: public, namespace: gateway }]
  hostnames: ["$host"]
  rules:
    - backendRefs: [{ name: echo, port: 80 }]
YAML
  if kubectl -n gateway wait --for=condition=Programmed gateway/public --timeout=300s >/dev/null 2>&1; then
    pass "the Gateway is programmed"
  else
    fail "the Gateway is not programmed"
  fi
  if kubectl -n gateway wait --for=condition=Ready certificate/wildcard --timeout=900s >/dev/null 2>&1; then
    pass "cert-manager issued the wildcard certificate"
  else
    fail "the wildcard certificate is not ready"
  fi
  local ips="" _
  for _ in $(seq 1 30); do
    ips=$(dig +short "$host" @ns1.contabo.net | sort | tr '\n' ' ')
    [ -n "$ips" ] && break
    sleep 20
  done
  local want
  want=$(terraform output -json nodes | jq -r '[.[] | select(.role == "controlplane") | .public_ipv4] as $cp | [.[] | select(.role == "worker") | .public_ipv4] as $w | (if ($w | length) > 0 then $w else $cp end) | sort | join(" ")')
  if [ "${ips% }" = "$want" ]; then
    pass "external-dns points $host to the ingress nodes ($want)"
  else
    fail "the DNS record of $host is \"$ips\", expected \"$want\""
  fi
  local ip code issuer
  for ip in $want; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 --resolve "$host:443:$ip" "https://$host/" || true)
    if [ "$code" = 200 ]; then
      pass "HTTPS on $ip answers 200 with a trusted certificate"
    else
      fail "HTTPS on $ip answers \"$code\""
    fi
  done
  issuer=$(echo | openssl s_client -connect "${want%% *}:443" -servername "$host" 2>/dev/null | openssl x509 -noout -issuer 2>/dev/null || true)
  echo "INFO: certificate $issuer"
}

# Checks the paths through the tailnet: kubectl and talosctl on the tailnet
# names, the API server proxy of the operator, and the closed public
# Kubernetes API in the tailscale mode.
verify_tailscale() {
  runner_tailnet
  local nodes cp_name cp_ip host tailnet
  [ -n "${HA_TAILSCALE:-}${HA_HEADSCALE:-}" ] || { echo "Run with HA_TAILSCALE=1 or HA_HEADSCALE=1" >&2; exit 2; }
  nodes=$(terraform output -json nodes)
  tailnet=$(terraform output -json tailscale)
  cp_name=$(jq -r '[to_entries[] | select(.value.role == "controlplane")][0].key' <<<"$nodes")
  cp_ip=$(jq -r --arg n "$cp_name" '.[$n].public_ipv4' <<<"$nodes")
  host=$(jq -r --arg n "$cp_name" '.nodes[$n]' <<<"$tailnet")
  if [ -n "${HA_HEADSCALE:-}" ]; then
    local registered want_nodes
    want_nodes=$(jq -r '.nodes | keys | sort | join(" ")' <<<"$tailnet")
    registered=$(kubectl -n headscale exec deploy/headscale -- headscale nodes list -o json 2>/dev/null |
      jq -r '[.[] | select(.online == true and (((.tags // []) + (.valid_tags // []) + (.forced_tags // [])) | index("tag:k8s-node"))) | .given_name] | sort | join(" ")' || true)
    if [ "$registered" = "$want_nodes" ]; then
      pass "Headscale lists the nodes online with tag:k8s-node ($registered)"
    else
      fail "Headscale lists \"$registered\" online with tag:k8s-node, expected \"$want_nodes\""
    fi
  fi
  if ts status --json | jq -e --arg h "$cp_name" '.Peer[] | select(.HostName == $h and .Online)' >/dev/null; then
    pass "$cp_name is online in the tailnet"
  else
    fail "$cp_name is not online in the tailnet"
  fi
  if kubectl --server "https://$host:6443" get nodes >/dev/null 2>&1; then
    pass "kubectl reaches the Kubernetes API on $host"
  else
    fail "kubectl cannot reach the Kubernetes API on $host"
  fi
  # talosctl resolves names itself and cannot resolve MagicDNS names through
  # the proxy of a userspace tailscaled. openssl connects through the proxy
  # and shows the certificate of the Talos API instead.
  if echo | openssl s_client -proxy localhost:1055 -connect "$host:50000" -servername "$host" 2>/dev/null |
    openssl x509 -noout -ext subjectAltName 2>/dev/null | grep -q "DNS:$host"; then
    pass "the Talos API answers on $host with the tailnet name in its certificate"
  else
    fail "the Talos API does not answer on $host, or its certificate lacks the name"
  fi
  if [ "$(talosctl -n "$cp_ip" -e "$cp_ip" get links -o json 2>/dev/null | jq -r 'select(.metadata.id | startswith("tailscale")) | .metadata.id' | head -n 1)" = "" ]; then
    pass "Tailscale on $cp_name runs in userspace mode (no tailscale interface)"
  else
    fail "Tailscale on $cp_name created a network interface"
  fi
  local proxy proxy_config
  proxy=$(jq -r '.api_server_proxy // empty' <<<"$tailnet")
  if [ -n "$proxy" ]; then
    proxy_config="$WORK/kubeconfig-tailscale"
    rm -f "$proxy_config"
    local _
    for _ in $(seq 1 30); do
      KUBECONFIG="$proxy_config" ts configure kubeconfig "${proxy#https://}" >/dev/null 2>&1 && break
      sleep 10
    done
    # The proxy needs a few minutes for its first certificate.
    for _ in $(seq 1 30); do
      KUBECONFIG="$proxy_config" kubectl get nodes >/dev/null 2>&1 && break
      sleep 10
    done
    if KUBECONFIG="$proxy_config" kubectl get nodes >/dev/null 2>&1 && [ "$(KUBECONFIG="$proxy_config" kubectl auth can-i '*' '*' 2>/dev/null)" = yes ]; then
      pass "the API server proxy $proxy logs in with the Tailscale identity as cluster admin"
    else
      fail "the API server proxy $proxy does not work"
    fi
  fi
  if [ "${TF_VAR_admin_mode:-public}" = tailscale ]; then
    if env -u HTTPS_PROXY -u HTTP_PROXY timeout 5 bash -c "</dev/tcp/$cp_ip/6443" 2>/dev/null; then
      fail "the Kubernetes API answers on the public address $cp_ip"
    else
      pass "the Kubernetes API is closed on the public address $cp_ip"
    fi
    if [ "$(jq -r .clusters[0].cluster.server < <(kubectl config view --raw -o json))" = "https://$host:6443" ]; then
      pass "the kubeconfig uses the tailnet name"
    else
      fail "the kubeconfig does not use the tailnet name"
    fi
  fi
}

# Waits for the Headscale server and creates the API key of the Headscale
# provider. The key stays in the work folder.
headscale_init() {
  runner_tailnet
  if kubectl -n headscale rollout status deploy/headscale --timeout=900s >/dev/null 2>&1; then
    pass "the Headscale server runs"
  else
    fail "the Headscale server does not run: $(kubectl -n headscale get pods,certificate 2>&1 | tr '\n' ' ')"
    return
  fi
  local code _
  for _ in $(seq 1 30); do
    code=$(env -u HTTPS_PROXY -u HTTP_PROXY curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$HEADSCALE_ENDPOINT/health" || true)
    [ "$code" = 200 ] && break
    sleep 20
  done
  if [ "$code" = 200 ]; then
    pass "$HEADSCALE_ENDPOINT/health answers 200 with a trusted certificate"
  else
    fail "$HEADSCALE_ENDPOINT/health answers \"$code\""
  fi
  if [ ! -s "$WORK/headscale-api-key" ]; then
    (
      umask 077
      { kubectl -n headscale exec deploy/headscale -- headscale apikeys create --expiration 30d 2>/dev/null || true; } |
        tail -n 1 | tr -d '[:space:]' >"$WORK/headscale-api-key"
    ) || true
  fi
  if [ -s "$WORK/headscale-api-key" ]; then
    pass "the API key of the Headscale provider is in the work folder"
  else
    fail "Headscale created no API key"
  fi
}

LONGHORN_V2_TEST=$(
  cat <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: lh-v2-test
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: longhorn-v2
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: lh-v2-test
spec:
  restartPolicy: Never
  containers:
    - name: test
      image: busybox:1.37
      command: ["sh", "-c", "echo longhorn-v2 > /data/test && sync && cat /data/test"]
      volumeMounts: [{ name: data, mountPath: /data }]
  volumes:
    - name: data
      persistentVolumeClaim: { claimName: lh-v2-test }
YAML
)

# Checks the V2 Data Engine: the raw partition and the hugepages of every
# Longhorn node, the block disk in Longhorn, and a pod that writes to a v2
# volume.
verify_longhorn_v2() {
  runner_tailnet
  local nodes name ip size pages disks
  nodes=$(terraform output -json nodes)
  for name in $(jq -r 'to_entries[] | select(.value.role == "worker") | .key' <<<"$nodes"); do
    ip=$(jq -r --arg n "$name" '.[$n].public_ipv4' <<<"$nodes")
    size=$(talosctl -n "$ip" -e "$ip" get volumestatus r-longhorn-v2 -o json 2>/dev/null | jq -r 'select(.spec.phase == "ready") | .spec.prettySize' || true)
    if [ -n "$size" ]; then
      pass "$name has the raw partition of v2 ($size)"
    else
      echo "INFO: $name has no ready raw partition of v2 ($(talosctl -n "$ip" -e "$ip" get volumestatus r-longhorn-v2 -o jsonpath='{.spec.phase} {.spec.errorMessage}' 2>&1 | head -c 200))"
    fi
    echo "INFO: $name volumes: $(talosctl -n "$ip" -e "$ip" get volumestatus -o json 2>/dev/null | jq -r 'select(.metadata.id | test("^(EPHEMERAL|u-longhorn|r-longhorn-v2)$")) | "\(.metadata.id)=\(.spec.prettySize)"' | tr '\n' ' ')"
    pages=$(kubectl get node "$name" -o jsonpath='{.status.allocatable.hugepages-2Mi}' 2>/dev/null || true)
    if [ "$pages" = 2Gi ]; then
      pass "$name offers 2Gi of hugepages"
    else
      fail "$name offers \"$pages\" of hugepages, expected 2Gi"
    fi
    disks=$(kubectl -n longhorn-system get nodes.longhorn.io "$name" -o json 2>/dev/null |
      jq -r '[.status.diskStatus // {} | to_entries[] | select(.value.diskType == "block" and ([.value.conditions[]? | select(.type == "Schedulable" and .status == "True")] | length > 0)) | .key] | join(" ")' || true)
    if [ -n "$disks" ]; then
      pass "Longhorn has the schedulable block disk \"$disks\" on $name"
    else
      echo "INFO: Longhorn has no schedulable block disk on $name"
    fi
  done
  if [ "$(kubectl -n longhorn-system get settings.longhorn.io v2-data-engine -o jsonpath='{.value}' 2>/dev/null)" = true ]; then
    pass "the setting v2-data-engine is true"
  else
    fail "the setting v2-data-engine is not true"
  fi
  local blocks
  blocks=$({ kubectl -n longhorn-system get nodes.longhorn.io -o json 2>/dev/null || echo '{"items":[]}'; } | jq '[.items[].status.diskStatus // {} | to_entries[] | select(.value.diskType == "block")] | length' || echo 0)
  if [ "${blocks:-0}" -ge 1 ]; then
    pass "$blocks Longhorn block disks exist"
  else
    fail "Longhorn has no block disk"
  fi
  kubectl delete pod lh-v2-test -n default --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kubectl delete pvc lh-v2-test -n default --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kubectl apply -n default -f - >/dev/null <<<"$LONGHORN_V2_TEST"
  kubectl -n default wait --for=jsonpath='{.status.phase}'=Succeeded pod/lh-v2-test --timeout=600s >/dev/null 2>&1 || true
  if [ "$(kubectl -n default logs lh-v2-test 2>/dev/null || true)" = longhorn-v2 ]; then
    pass "a pod writes to a v2 volume (storage class longhorn-v2)"
  else
    fail "a pod cannot write to a v2 volume: $(kubectl -n default describe pod lh-v2-test 2>&1 | tail -n 5 | tr '\n' ' ')"
  fi
  local volume
  volume=$(kubectl -n default get pvc lh-v2-test -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)
  echo "INFO: v2 volume $volume: $(kubectl -n longhorn-system get volumes.longhorn.io "$volume" -o jsonpath='{.spec.dataEngine} {.status.robustness} replicas={.spec.numberOfReplicas}' 2>/dev/null || true)"
  kubectl delete pod lh-v2-test -n default --wait=true >/dev/null 2>&1 || true
  kubectl delete pvc lh-v2-test -n default --wait=false >/dev/null 2>&1 || true
}

BACKUP_TEST=$(
  cat <<'YAML'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: backup-test
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: backup-test
spec:
  restartPolicy: Never
  containers:
    - name: test
      image: busybox:1.37
      command: ["sh", "-c", "echo backup-data > /data/test && sync && sleep 3600"]
      volumeMounts: [{ name: data, mountPath: /data }]
  volumes:
    - name: data
      persistentVolumeClaim: { claimName: backup-test }
YAML
)

# s3 <path and query> calls the object storage with the S3 credentials of the
# backup Secret. The credentials stay in variables and are never printed.
s3() {
  local endpoint region access secret
  endpoint=$(kubectl -n longhorn-system get secret longhorn-backup-s3 -o jsonpath='{.data.AWS_ENDPOINTS}' | base64 -d)
  access=$(kubectl -n longhorn-system get secret longhorn-backup-s3 -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' | base64 -d)
  secret=$(kubectl -n longhorn-system get secret longhorn-backup-s3 -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' | base64 -d)
  region=$(sed -E 's#^https?://([^.]+)\..*#\1#' <<<"$endpoint")
  # curl reads the credentials from stdin, so they never show up in the
  # process list.
  printf 'user = "%s:%s"\n' "$access" "$secret" |
    curl -fsS -K - --aws-sigv4 "aws:amz:$region:s3" "$endpoint/$1" "${@:2}"
}

# Runs both backups once, checks the objects in the bucket, decrypts the etcd
# snapshot and restores the Longhorn backup into a new volume.
verify_backups() {
  runner_tailnet
  local job
  job="talos-backup-test-$(date +%s)"
  kubectl -n kube-system create job "$job" --from=cronjob/talos-backup >/dev/null
  if kubectl -n kube-system wait --for=condition=Complete "job/$job" --timeout=300s >/dev/null 2>&1; then
    pass "talos-backup saved an etcd snapshot"
  else
    fail "talos-backup failed: $(kubectl -n kube-system logs "job/$job" --tail=5 2>&1 | tr '\n' ' ')"
  fi
  local key
  key=$({ s3 "ha-live-backups?list-type=2&prefix=etcd/" || true; } | { grep -o '<Key>[^<]*</Key>' || true; } | sed 's/<[^>]*>//g' | sort | tail -n 1)
  # The key holds ":" characters, which the S3 signature needs URL-encoded.
  # A decrypted snapshot starts with the magic number of zstd (28 b5 2f fd).
  if [ -n "$key" ] && s3 "ha-live-backups/${key//:/%3A}" -o "$WORK/etcd-snapshot.age" &&
    age -d -i "$WORK/age-key.txt" -o "$WORK/etcd-snapshot" "$WORK/etcd-snapshot.age" &&
    [ "$(head -c 4 "$WORK/etcd-snapshot" | od -An -tx1 | tr -d ' ')" = 28b52ffd ]; then
    pass "the etcd snapshot $key decrypts with the age key into a zstd file ($(stat -c %s "$WORK/etcd-snapshot") bytes)"
  else
    fail "the etcd snapshot could not be downloaded or decrypted"
  fi
  rm -f "$WORK/etcd-snapshot" "$WORK/etcd-snapshot.age"

  if [ "$(kubectl -n longhorn-system get backuptargets.longhorn.io default -o jsonpath='{.status.available}' 2>/dev/null)" = true ]; then
    pass "the Longhorn backup target is available"
  else
    fail "the Longhorn backup target is not available: $(kubectl -n longhorn-system get backuptargets.longhorn.io default -o jsonpath='{.status.conditions}' 2>&1)"
  fi
  if kubectl -n longhorn-system get recurringjobs.longhorn.io backup >/dev/null 2>&1; then
    pass "the recurring backup job exists"
  else
    fail "the recurring backup job is missing"
  fi
  kubectl delete pod backup-test -n default --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kubectl delete pvc backup-test -n default --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kubectl apply -n default -f - >/dev/null <<<"$BACKUP_TEST"
  kubectl -n default wait --for=condition=Ready pod/backup-test --timeout=600s >/dev/null 2>&1 || true
  local volume snapshot
  snapshot="backup-test-$(date +%s)"
  volume=$(kubectl -n default get pvc backup-test -o jsonpath='{.spec.volumeName}')
  kubectl apply -f - >/dev/null <<YAML
apiVersion: longhorn.io/v1beta2
kind: Snapshot
metadata:
  name: $snapshot
  namespace: longhorn-system
spec:
  volume: $volume
  createSnapshot: true
---
apiVersion: longhorn.io/v1beta2
kind: Backup
metadata:
  name: $snapshot
  namespace: longhorn-system
  labels:
    backup-volume: $volume
spec:
  snapshotName: $snapshot
YAML
  local state="" url=""
  for _ in $(seq 1 60); do
    state=$(kubectl -n longhorn-system get backups.longhorn.io "$snapshot" -o jsonpath='{.status.state}' 2>/dev/null || true)
    [ "$state" = Completed ] || [ "$state" = Error ] && break
    sleep 10
  done
  url=$(kubectl -n longhorn-system get backups.longhorn.io "$snapshot" -o jsonpath='{.status.url}' 2>/dev/null || true)
  if [ "$state" = Completed ]; then
    pass "Longhorn backed up the volume $volume"
  else
    fail "the Longhorn backup ended in state \"$state\""
  fi
  if [ -n "$url" ]; then
    kubectl apply -f - >/dev/null <<YAML
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata:
  name: restore-test
  namespace: longhorn-system
spec:
  fromBackup: "$url"
  numberOfReplicas: 1
  size: "1073741824"
  frontend: blockdev
YAML
    local restored=""
    for _ in $(seq 1 60); do
      restored=$(kubectl -n longhorn-system get volumes.longhorn.io restore-test -o jsonpath='{.status.restoreRequired}/{.status.state}' 2>/dev/null || true)
      [ "$restored" = false/detached ] && break
      sleep 10
    done
    if [ "$restored" = false/detached ]; then
      pass "Longhorn restored the backup into a new volume"
    else
      fail "the restore of the Longhorn backup did not finish ($restored)"
    fi
    kubectl -n longhorn-system delete volumes.longhorn.io restore-test --wait=false >/dev/null 2>&1 || true
  fi
  kubectl delete pod backup-test -n default --wait=true >/dev/null 2>&1 || true
  kubectl delete pvc backup-test -n default --wait=false >/dev/null 2>&1 || true
}

case "${1:-}" in
  apply)
    init
    runner_tailnet
    if [ -n "${HA_BACKUPS:-}" ] && ! terraform state list 2>/dev/null | grep -q '^contabo_object_storage_bucket.backups'; then
      terraform apply -input=false -auto-approve -target=contabo_object_storage_bucket.backups
    fi
    terraform apply -input=false -auto-approve "${@:2}"
    runner_tailnet
    chmod 600 "$KUBECONFIG" "$TALOSCONFIG"
    echo "kubeconfig: $KUBECONFIG"
    ;;
  plan)
    init
    runner_tailnet
    terraform plan -input=false -detailed-exitcode "${@:2}"
    ;;
  verify)
    runner_tailnet
    verify
    ;;
  ingress)
    runner_tailnet
    verify_ingress
    echo "$failures failures"
    [ "$failures" = 0 ]
    ;;
  tailscale)
    verify_tailscale
    echo "$failures failures"
    [ "$failures" = 0 ]
    ;;
  backups)
    verify_backups
    echo "$failures failures"
    [ "$failures" = 0 ]
    ;;
  headscale-init)
    headscale_init
    echo "$failures failures"
    [ "$failures" = 0 ]
    ;;
  longhorn-v2)
    verify_longhorn_v2
    echo "$failures failures"
    [ "$failures" = 0 ]
    ;;
  destroy)
    init
    runner_tailnet
    terraform destroy -input=false -auto-approve "${@:2}"
    ;;
  tf)
    init
    runner_tailnet
    terraform "${@:2}"
    ;;
  *)
    echo "usage: $0 apply|plan|verify|ingress|tailscale|backups|headscale-init|longhorn-v2|destroy|tf" >&2
    exit 2
    ;;
esac
