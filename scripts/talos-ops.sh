#!/usr/bin/env bash
# Talos and Kubernetes operations of the terraform-contabo-kubernetes module.
#
# Terraform runs this script with local-exec. The script needs bash and
# talosctl on the computer that runs Terraform. The Talos upgrade also needs
# kubectl to drain the nodes (from Talos 1.18 on, because Talos then removes
# the legacy upgrade method).
#
#   talos-ops.sh upgrade-talos        upgrades the nodes in NODES one by one
#   talos-ops.sh upgrade-kubernetes   runs "talosctl upgrade-k8s" when the cluster exists
#   talos-ops.sh sync-kubernetes      waits for the cluster, then runs "talosctl upgrade-k8s"
#
# Environment:
#   TALOSCONFIG_CONTENT  the talosconfig of the cluster
#   BOOTSTRAP_NODE       public address of the first control plane node
#   CONTROL_PLANE_NODES  private addresses of the control plane nodes, comma-separated
#   WORKER_NODES         private addresses of the worker nodes, comma-separated (can be empty)
#   KUBERNETES_API_URL   the Kubernetes API address, for example https://203.0.113.10:6443
#   KUBERNETES_API_HOSTS one line per control plane node: "<public address> <Kubernetes API host>"
#   KUBERNETES_VERSION   the Kubernetes version, for example 1.36.6
#   TALOS_VERSION        the Talos version, for example v1.14.5
#   NODES                one line per node: "<public address> <installer image> <schematic id> <node name>"
#   NODE_ADDRESSES       one line per node: "<role> <public address> <private address>"
set -euo pipefail

# The skip works even when the tools below are missing.
if [ "${1:-}" = remove-node ] && [ -n "${TALOS_SKIP_NODE_REMOVAL:-}" ]; then
  printf '%s
' "TALOS_SKIP_NODE_REMOVAL is set. The node ${NODE_NAME:-} stays as it is."
  exit 0
fi

if ! command -v talosctl >/dev/null 2>&1; then
  echo "talosctl is not installed. Install talosctl ${TALOS_VERSION:-} on the computer that runs Terraform: https://docs.siderolabs.com/talos/latest/getting-started/talosctl" >&2
  exit 1
fi

talosconfig=$(mktemp)
trap 'rm -f "$talosconfig"' EXIT
printf '%s' "$TALOSCONFIG_CONTENT" >"$talosconfig"
export TALOSCONFIG="$talosconfig"

log() { printf '%s\n' "$*"; }

# limit <seconds> <command> runs the command with a time limit. macOS has no
# "timeout" by default; Homebrew coreutils installs it as "gtimeout".
if command -v timeout >/dev/null 2>&1; then
  limit() { timeout "$@"; }
elif command -v gtimeout >/dev/null 2>&1; then
  limit() { gtimeout "$@"; }
else
  echo "The module needs the command \"timeout\" (GNU coreutils). On macOS, run \"brew install coreutils\"." >&2
  exit 1
fi

# node_state <address> prints "configured", "maintenance" or "unreachable".
# Every call has a time limit, because talosctl waits a long time for a node
# that does not answer.
node_state() {
  if limit 20 talosctl -n "$1" -e "$1" version >/dev/null 2>&1; then
    echo configured
  elif limit 20 talosctl -n "$1" -e "$1" get disks --insecure >/dev/null 2>&1; then
    echo maintenance
  else
    echo unreachable
  fi
}

# wait_for_node <address> waits up to 15 minutes until the node answers.
wait_for_node() {
  local state deadline=$((SECONDS + 900))
  while [ "$SECONDS" -lt "$deadline" ]; do
    state=$(node_state "$1")
    if [ "$state" != unreachable ]; then
      echo "$state"
      return 0
    fi
    sleep 10
  done
  echo "The Talos API of $1 did not answer for 15 minutes." >&2
  return 1
}

# health [configured] checks the cluster. With "configured", the check skips
# nodes that still wait for their first configuration, for example a new node
# in the same apply as an upgrade. NODE_ADDRESSES has one line per node:
# "<role> <public address> <private address>".
health() {
  local control_plane=$CONTROL_PLANE_NODES workers=${WORKER_NODES:-}
  if [ "${1:-}" = configured ]; then
    control_plane="" workers=""
    local role public private
    while read -r role public private; do
      [ -n "$public" ] || continue
      [ "$(node_state "$public")" = configured ] || continue
      if [ "$role" = controlplane ]; then
        control_plane="${control_plane:+$control_plane,}$private"
      else
        workers="${workers:+$workers,}$private"
      fi
    done <<<"$NODE_ADDRESSES"
  fi
  local args=(--control-plane-nodes "$control_plane" --wait-timeout 20m)
  if [ -n "$workers" ]; then
    args+=(--worker-nodes "$workers")
  fi
  talosctl -n "$BOOTSTRAP_NODE" -e "$BOOTSTRAP_NODE" health "${args[@]}"
}

# talosctl prints the changes of every manifest. The changes can contain the
# data of Secrets, so the script only prints the progress lines (" > ...").
# A failed attempt also prints its last lines without the changed lines.
# Right after a bootstrap, the API server can refuse a dry run for a short
# time, so the script tries 3 times.
upgrade_k8s() {
  local output status attempt
  output=$(mktemp)
  for attempt in 1 2 3; do
    set +e
    talosctl -n "$BOOTSTRAP_NODE" -e "$BOOTSTRAP_NODE" upgrade-k8s \
      --endpoint "$KUBERNETES_API_URL" \
      --to "$KUBERNETES_VERSION" \
      --with-docs=false --with-examples=false >"$output" 2>&1
    status=$?
    set -e
    grep -E '^[[:space:]]*>' "$output" || true
    if [ "$status" = 0 ]; then
      rm -f "$output"
      return 0
    fi
    { grep -E '^[[:space:]]*>|[Ee]rror|^[[:space:]]*[*]' "$output" || true; } | tail -n 20
    if [ "$attempt" -lt 3 ]; then
      log "talosctl upgrade-k8s failed. Trying again in 60 seconds (attempt $((attempt + 1)) of 3) ..."
      sleep 60
    fi
  done
  rm -f "$output"
  return "$status"
}

# The table of "talosctl get extensions" ends with the columns NAME and
# VERSION. Talos lists the schematic of the image as an extension named
# "schematic".
current_schematic() {
  { talosctl -n "$1" -e "$1" get extensions 2>/dev/null || true; } | awk '$(NF-1) == "schematic" { print $NF; exit }'
}

current_version() {
  { talosctl -n "$1" -e "$1" version 2>/dev/null || true; } | sed -n 's/^[[:space:]]*Tag:[[:space:]]*//p' | tail -n 1
}

# up_to_date <address> <schematic> succeeds when the node already runs the
# Talos version and the schematic of the module.
up_to_date() {
  [ "$(current_version "$1")" = "$TALOS_VERSION" ] && [ "$(current_schematic "$1")" = "$2" ]
}

# apply_extension_configs <address> sends the ExtensionServiceConfig documents
# of the new configuration to the node before its upgrade. A new extension
# that needs a configuration keeps the boot of Talos in the stage "booting"
# until the configuration exists, and both "talosctl upgrade --wait" and
# "talosctl health" wait for the end of the boot. EXTENSION_SERVICE_CONFIGS
# has one line per node: "<public address> <documents in base64>".
apply_extension_configs() {
  local encoded file status=0
  encoded=$(awk -v address="$1" '$1 == address { print $2; exit }' <<<"${EXTENSION_SERVICE_CONFIGS:-}")
  [ -n "$encoded" ] || return 0
  file=$(mktemp)
  printf '%s' "$encoded" | base64 -d >"$file"
  limit 120 talosctl -n "$1" -e "$1" patch machineconfig --mode=no-reboot --patch @"$file" >/dev/null 2>&1 || status=$?
  rm -f "$file"
  if [ "$status" != 0 ]; then
    log "Warning: the extension configurations could not be sent to $1 before the upgrade."
  fi
}

# api_peer <address> prints the public address of a control plane node other
# than <address>, or <address> when the cluster has one control plane node.
# The Kubernetes API of the node in the upgrade goes down during its restart.
api_peer() {
  local role public private
  while read -r role public private; do
    if [ "$role" = controlplane ] && [ "$public" != "$1" ] && [ "$(node_state "$public")" = configured ]; then
      echo "$public"
      return 0
    fi
  done <<<"$NODE_ADDRESSES"
  echo "$1"
}

# api_host <public address> prints the Kubernetes API host of a control plane
# node: its tailnet name in the tailscale mode, otherwise the public address.
# KUBERNETES_API_HOSTS has one line per control plane node:
# "<public address> <host>".
api_host() {
  local host
  host=$(awk -v address="$1" '$1 == address { print $2; exit }' <<<"${KUBERNETES_API_HOSTS:-}")
  echo "${host:-$1}"
}

# kube <peer> <kubectl arguments> runs kubectl against the Kubernetes API of
# <peer>. The admin kubeconfig of Talos names the private cluster endpoint,
# which this computer cannot reach, so --server replaces it.
kubeconfig=""
kube() {
  local peer=$1
  shift
  if [ -z "$kubeconfig" ]; then
    kubeconfig=$(mktemp)
    trap 'rm -f "$talosconfig" "$kubeconfig"' EXIT
  fi
  if [ ! -s "$kubeconfig" ]; then
    talosctl -n "$peer" -e "$peer" kubeconfig --merge=false - >"$kubeconfig" 2>/dev/null
  fi
  kubectl --kubeconfig "$kubeconfig" --server "https://$(api_host "$peer"):6443" --request-timeout 30s "$@"
}

# upgrade_node <address> <installer image> <Kubernetes node name>
#
# With kubectl, the script drains the node itself and runs the upgrade with
# --drain=false. The drain of talosctl uses the admin kubeconfig of the node,
# which names the private cluster endpoint, and fails from outside the private
# network. Without kubectl, the script uses the legacy upgrade method, where
# the node drains itself. Talos removes the legacy method in Talos 1.18.
upgrade_node() {
  local address=$1 image=$2 name=$3 peer
  if command -v kubectl >/dev/null 2>&1; then
    peer=$(api_peer "$address")
    kube "$peer" cordon "$name" >/dev/null || log "Warning: kubectl could not cordon $name."
    # Like the drain of Talos, a drain that does not finish in 5 minutes
    # (for example because of a PodDisruptionBudget) only prints a warning.
    if ! kube "$peer" drain "$name" --ignore-daemonsets --delete-emptydir-data --timeout=5m >/dev/null 2>&1; then
      log "Warning: the drain of $name did not finish in 5 minutes. The upgrade continues."
    fi
    local status=0
    talosctl -n "$address" -e "$address" upgrade --drain=false --image "$image" --wait --timeout 30m || status=$?
    # The node is back when its kubelet reports Ready. The uncordon also runs
    # after a failed upgrade, because the node then still runs the old version.
    local _
    for _ in $(seq 1 60); do
      if kube "$peer" uncordon "$name" >/dev/null 2>&1; then
        break
      fi
      sleep 10
    done
    return "$status"
  fi
  local help
  help=$(talosctl upgrade --help 2>/dev/null || true)
  if grep -q -- '--legacy' <<<"$help"; then
    talosctl -n "$address" -e "$address" upgrade --legacy --image "$image" --wait --timeout 30m
    return
  fi
  echo "The upgrade needs kubectl on the computer that runs Terraform. This talosctl has no legacy upgrade method any more." >&2
  return 1
}

case "${1:-}" in
  upgrade-talos)
    while read -r address image schematic name; do
      [ -n "$address" ] || continue
      state=$(wait_for_node "$address")
      if [ "$state" = maintenance ]; then
        log "Node $address waits for its first configuration. Nothing to upgrade."
        continue
      fi
      version=$(current_version "$address")
      installed=$(current_schematic "$address")
      if [ "$version" = "$TALOS_VERSION" ] && [ "$installed" = "$schematic" ]; then
        log "Node $address already runs Talos $version with schematic $schematic."
        continue
      fi
      log "Node $address runs Talos ${version:-unknown} with schematic ${installed:-unknown}. Upgrading to $TALOS_VERSION ($schematic) ..."
      health configured
      apply_extension_configs "$address"
      # A lost connection, for example during a restart of the node, fails
      # the upgrade. The script then waits for the node and tries again.
      attempt=1
      until upgrade_node "$address" "$image" "$name"; do
        if [ "$attempt" -ge 3 ]; then
          echo "The upgrade of $address failed 3 times." >&2
          exit 1
        fi
        attempt=$((attempt + 1))
        log "The upgrade of $address failed. Trying again in 30 seconds (attempt $attempt of 3) ..."
        sleep 30
        wait_for_node "$address" >/dev/null
        # --wait can give up after the node already restarted with the new
        # version. Another upgrade would only restart the node again.
        if up_to_date "$address" "$schematic"; then
          break
        fi
        health configured
      done
      sleep 10
      wait_for_node "$address" >/dev/null
      health configured
      log "Node $address upgraded."
    done <<<"$NODES"
    ;;
  upgrade-kubernetes)
    state=$(wait_for_node "$BOOTSTRAP_NODE")
    if [ "$state" = maintenance ]; then
      log "The cluster does not exist yet. Nothing to upgrade."
      exit 0
    fi
    health configured
    upgrade_k8s
    ;;
  sync-kubernetes)
    wait_for_node "$BOOTSTRAP_NODE" >/dev/null
    health
    upgrade_k8s
    health
    ;;
  remove-node)
    # Environment: NODE_NAME, NODE_ROLE, NODE_ADDRESS (public address) and
    # PEERS (public addresses of the other control plane nodes).
    # A peer is another control plane node whose etcd answers.
    peer="" healthy=0
    for candidate in ${PEERS:-}; do
      if limit 20 talosctl -n "$candidate" -e "$candidate" etcd status >/dev/null 2>&1; then
        [ -n "$peer" ] || peer=$candidate
        healthy=$((healthy + 1))
      fi
    done
    if [ "$NODE_ROLE" = controlplane ] && [ -n "${PEERS:-}" ] && [ -z "$peer" ]; then
      echo "No other control plane node of $NODE_NAME has a working etcd. The module does not remove the node, because the node may hold the last good copy of etcd. Repair etcd first, or set TALOS_SKIP_NODE_REMOVAL=1." >&2
      exit 1
    fi
    has_kubectl=""
    command -v kubectl >/dev/null 2>&1 && has_kubectl=1

    # etcd keeps working while more than half of its members answer. The
    # removal must leave enough healthy members behind.
    member_id=""
    others=0
    if [ "$NODE_ROLE" = controlplane ] && [ -n "$peer" ]; then
      members=$(limit 30 talosctl -n "$peer" -e "$peer" etcd members 2>/dev/null | tail -n +2 || true)
      if [ -z "$members" ]; then
        echo "The etcd members could not be read from $peer. The module does not remove $NODE_NAME. Run the apply again, or set TALOS_SKIP_NODE_REMOVAL=1." >&2
        exit 1
      fi
      member_id=$(awk -v name="$NODE_NAME" '$3 == name { print $2; exit }' <<<"$members")
      others=$(awk -v name="$NODE_NAME" 'NF > 0 && $3 != name' <<<"$members" | grep -c . || true)
      if [ "$others" -gt 0 ] && [ "$healthy" -lt $((others / 2 + 1)) ]; then
        echo "The removal of $NODE_NAME would leave etcd with $others members, of which only $healthy answer. etcd would stop working. Repair the other control plane nodes first, or set TALOS_SKIP_NODE_REMOVAL=1 to skip the removal." >&2
        exit 1
      fi
    fi

    state=$(node_state "$NODE_ADDRESS")
    # Set only after a graceful reset that finished: only then is the data
    # of the node surely erased.
    wiped=""
    if [ "$state" = configured ]; then
      if [ -n "$peer" ] && [ -n "$has_kubectl" ]; then
        log "Draining $NODE_NAME ..."
        kube "$peer" cordon "$NODE_NAME" >/dev/null 2>&1 || true
        if ! kube "$peer" drain "$NODE_NAME" --ignore-daemonsets --delete-emptydir-data --timeout=5m >/dev/null 2>&1; then
          log "Warning: the drain of $NODE_NAME did not finish in 5 minutes. The removal continues."
        fi
      fi
      # A graceful reset leaves etcd cleanly. Both resets wipe Talos and power
      # off the node, so the node never waits unprotected in maintenance mode.
      log "Resetting $NODE_NAME ($NODE_ROLE) ..."
      if limit 900 talosctl -n "$NODE_ADDRESS" -e "$NODE_ADDRESS" reset --graceful --reboot=false --wait --timeout 10m >/dev/null 2>&1; then
        wiped=1
      else
        if [ "$NODE_ROLE" = controlplane ] && [ "$others" -gt 0 ]; then
          echo "The graceful reset of $NODE_NAME failed, and other etcd members exist. The node stays in the cluster. Check etcd, then run the apply again, or set TALOS_SKIP_NODE_REMOVAL=1." >&2
          exit 1
        fi
        log "The graceful reset of $NODE_NAME failed. Resetting without leaving etcd ..."
        limit 120 talosctl -n "$NODE_ADDRESS" -e "$NODE_ADDRESS" reset --graceful=false --reboot=false --wait=false >/dev/null 2>&1 ||
          log "Warning: the reset of $NODE_NAME failed."
      fi
    else
      # The node does not answer, or it waits in maintenance mode. The other
      # control plane nodes still remove its etcd member and its node object.
      log "Warning: $NODE_NAME ($NODE_ADDRESS) does not run a configured Talos ($state). The module only removes it from etcd and Kubernetes."
      if [ -n "$member_id" ]; then
        limit 60 talosctl -n "$peer" -e "$peer" etcd remove-member "$member_id" >/dev/null 2>&1 ||
          log "Warning: the etcd member $member_id of $NODE_NAME could not be removed."
      fi
    fi
    if [ -n "$peer" ] && [ -n "$has_kubectl" ]; then
      kube "$peer" delete node "$NODE_NAME" --wait=false >/dev/null 2>&1 || true
      # Longhorn keeps a record of every node, and a stale record blocks new
      # volumes. Longhorn only deletes a record without scheduling.
      if kube "$peer" -n longhorn-system get nodes.longhorn.io "$NODE_NAME" >/dev/null 2>&1; then
        kube "$peer" -n longhorn-system patch nodes.longhorn.io "$NODE_NAME" --type merge -p '{"spec":{"allowScheduling":false}}' >/dev/null 2>&1 || true
        # Longhorn refuses the deletion while volumes still have replicas on
        # the node. After a finished reset, the data of these replicas is
        # gone, so the module deletes their records, and Longhorn rebuilds the
        # volumes on the other nodes. A stale record would keep the old disks
        # when a new installation comes back with the same name. Without a
        # finished reset, the replicas may hold the last good copy of a
        # volume, so the module keeps them.
        if [ -n "$wiped" ]; then
          kube "$peer" -n longhorn-system delete replicas.longhorn.io -l "longhornnode=$NODE_NAME" --wait=false >/dev/null 2>&1 || true
        fi
        deleted=""
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
          if kube "$peer" -n longhorn-system delete nodes.longhorn.io "$NODE_NAME" --wait=false >/dev/null 2>&1; then
            deleted=1
            break
          fi
          sleep 10
        done
        [ -n "$deleted" ] ||
          log "Warning: Longhorn keeps its record of $NODE_NAME. If the node comes back with the same name, replace its old Longhorn disks (see \"Storage with Longhorn\" in the README)."
      fi
    fi
    log "The node $NODE_NAME left the cluster."
    ;;
  *)
    echo "usage: $0 upgrade-talos|upgrade-kubernetes|sync-kubernetes|remove-node" >&2
    exit 2
    ;;
esac
