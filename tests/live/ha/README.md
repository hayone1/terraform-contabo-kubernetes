# Live test: cluster with several nodes

This test orders three new Contabo instances and builds a cluster with three control plane nodes. The module creates the private network, and Longhorn stores volumes on the nodes. Use the test before a release, because the one-node test in [../cluster](../cluster) cannot check etcd with several members, rolling upgrades, or node removal.

The test costs money. Contabo bills every new instance for a whole month, also when you destroy the instance after one hour. Three Cloud VPS 6 (`V154`) with private networking cost about 30 EUR per month.

## Run the test

1. Fill in the Contabo credentials in `tests/live/.env` (see `../.env.example`).
2. Run `./run.sh apply` in WSL or Linux. The first apply takes about 30 minutes.
3. Run `./run.sh verify`. The script checks every node, etcd, Cilium, pod traffic between nodes and a Longhorn volume.
4. Upgrade the cluster: set `TF_VAR_talos_version` and `TF_VAR_kubernetes_version` to newer versions, and run `./run.sh apply` and `./run.sh verify` again.

## Check the ingress

1. Make sure that `EXAMPLES_DNS_ZONE` in `tests/live/.env` names a DNS zone on the Contabo name servers.
2. Run `HA_INGRESS=1 ./run.sh apply`. The module installs the Gateway API, cert-manager and external-dns for the domain `ha-live.<zone>`. Keep `HA_INGRESS=1` for every later run, because the setting is not stored.
3. Run `HA_INGRESS=1 ./run.sh ingress`. The script starts a small web application at `echo.ha-live.<zone>` and checks the Gateway, the Let's Encrypt certificate, the DNS records and HTTPS on every ingress node.

## Check the access through Tailscale

The test changes the tailnet: it replaces the tailnet policy, turns on HTTPS and creates two OAuth clients and an auth key. The policy keeps the rules of the default policy of a new tailnet (everybody may connect, and the SSH rule). Use a test tailnet, or put the rules of your own policy into `tailscale_policy` in `main.tf` first.

1. Set `TAILSCALE_ACCESS_TOKEN` (an API access token of a tailnet admin) and `TAILSCALE_TAILNET_DOMAIN` (for example `tail1234.ts.net`) in `tests/live/.env`.
2. Install the Tailscale client. The test needs no root rights: `run.sh` starts its own `tailscaled` in userspace mode, joins the tailnet as `ha-live-runner` with the tag `tag:k8s-admin`, and reaches the tailnet through the HTTP proxy of `tailscaled` on `localhost:1055`.
3. Run `HA_TAILSCALE=1 ./run.sh apply`. The control plane node gets the Tailscale extension (a Talos upgrade), and the operator starts. Keep `HA_TAILSCALE=1` for every later run.
4. Run `HA_TAILSCALE=1 ./run.sh tailscale`. The script checks `kubectl` and `talosctl` on the tailnet name and a login through the API server proxy.
5. Run `HA_TAILSCALE=1 HA_ADMIN_MODE=tailscale ./run.sh apply`, and then the same with `./run.sh tailscale`. The script now also checks that the public Kubernetes API is closed.

## Check the backups

1. Set `TF_VAR_object_storage_id` in `tests/live/.env` to an object storage. The test creates the bucket `ha-live-backups` in it.
2. Run `HA_BACKUPS=1 ./run.sh apply`. `run.sh` creates an age key in the work folder for the encryption of the etcd snapshots.
3. Run `HA_BACKUPS=1 ./run.sh backups`. The script runs talos-backup once, downloads and decrypts the snapshot, backs up a Longhorn volume and restores the backup into a new volume.

## Check the access through Headscale

The test runs a Headscale server in the cluster itself, at `headscale.ha-live.<EXAMPLES_DNS_ZONE>:8443`. Headscale serves HTTPS itself with a certificate from cert-manager, because the Envoy of the Gateway does not pass on the HTTP upgrade of the Tailscale clients. A real cluster should use a Headscale server outside the cluster. The test needs `HA_INGRESS=1`.

1. Run `HA_HEADSCALE_SERVER=1 ./run.sh apply` (with your other flags). The module opens port 8443 on the ingress nodes, and Talos applies the manifests of `headscale.yaml.tftpl`.
2. Run `HA_HEADSCALE_SERVER=1 ./run.sh headscale-init`. The script waits for the server and saves an API key for the Headscale provider in the work folder.
3. Run `HA_HEADSCALE=1 ./run.sh apply` without `HA_TAILSCALE`. The Headscale provider creates the user `admin`, the policy and two pre-auth keys. The node agents log in to Headscale with their own state directory, and Terraform deletes the Tailscale resources of the test. `talosctl upgrade-k8s` deletes the objects of the Tailscale operator, because the manifest of the operator is gone.
4. Run `HA_HEADSCALE=1 ./run.sh tailscale`. `run.sh` starts a second `tailscaled` for Headscale, and the script checks the node list of Headscale and the APIs on the tailnet names (`*.hs.internal`).
5. Run `HA_HEADSCALE=1 HA_ADMIN_MODE=tailscale ./run.sh apply`, and then `./run.sh tailscale` again.

Keep `HA_HEADSCALE=1` and `HA_INGRESS=1` for every later run, also for `./run.sh destroy`. Use `TALOS_SKIP_NODE_REMOVAL=1` for the destroy, so that Terraform deletes the Headscale keys before a node with the Headscale server goes away.

## Check the V2 Data Engine of Longhorn

1. Raise the reinstall generation of one worker, and run `HA_LONGHORN_V2=1 ./run.sh apply`. Only a new installation gets the raw partition of v2. Every Longhorn node gets the hugepages and the kernel modules.
2. Run `HA_LONGHORN_V2=1 ./run.sh longhorn-v2`. The script checks the raw partition, the hugepages, the block disk in Longhorn and a pod that writes to a volume of the storage class `longhorn-v2`.

## Move two control plane nodes into the worker pool

The move checks the graceful removal of nodes and the adoption of instances. Use two applies, so that the nodes leave etcd before Terraform erases them:

1. Remove the instances from the state, so that Terraform does not cancel them: `./run.sh tf state rm 'module.cluster.contabo_instance.node["cp-2"]' 'module.cluster.contabo_instance.node["cp-3"]'`.
2. Set `TF_VAR_control_plane_count=1`, and run `./run.sh apply -parallelism=1`. The module drains cp-2 and cp-3, the nodes leave etcd one after the other, and Talos wipes and powers off both nodes.
3. Set `TF_VAR_worker_instances='{"a":"<id of cp-2>","b":"<id of cp-3>"}'`, and run `./run.sh apply`. The module installs Talos again, and the nodes join as workers.
4. Run `./run.sh verify`.

Every adoption uses one Contabo reinstall of the instance. Contabo limits reinstalls per day.

## Clean up

Run `./run.sh destroy`. Terraform cancels the instances, and Contabo stops them at the end of the contract period. Set `TALOS_SKIP_NODE_REMOVAL=1` to skip the graceful removal of every node.

Never run `run.sh` with `bash -x`, because the script reads the Contabo credentials from `tests/live/.env`.
