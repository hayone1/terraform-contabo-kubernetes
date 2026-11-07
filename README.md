# Kubernetes on Contabo with Talos Linux

This Terraform module builds a Kubernetes cluster on Contabo Cloud VPS and VDS servers. The servers run [Talos Linux](https://www.talos.dev), an operating system that only runs Kubernetes and has no SSH and no shell. The module orders the servers or adopts servers that you already pay for, installs Talos, and sets up the network, the firewalls and the basic cluster services.

The module is for people who want a production-style cluster on Contabo, the cheapest well-known cloud provider in Europe, without managing servers by hand. Every setting lives in Terraform, so you can rebuild or change the cluster with `terraform apply`.

The module works with Terraform 1.9 or newer and with OpenTofu 1.9 or newer.

## What the module builds

- **Nodes.** A node is one Contabo instance (a server) in the cluster. The module orders new instances, or it adopts instances that you already pay for. Control plane nodes run the Kubernetes API and etcd, the database of the cluster. Worker nodes run your applications.
- **Talos Linux** on every node, installed from the [Talos Image Factory](https://factory.talos.dev).
- **A private network.** The nodes talk to each other only through a Contabo private network. Cilium encrypts this traffic with WireGuard.
- **Two firewalls.** The Contabo firewall filters traffic before the traffic reaches a node. The Talos host firewall filters the traffic again on every node.
- **Cilium**, the network plugin. Cilium also replaces kube-proxy and gives LoadBalancer services the public addresses of the nodes, because Contabo has no load balancer product.
- **The Talos cloud controller manager.** This controller writes the public and private addresses into every Kubernetes node, and the controller approves the certificates that `kubectl logs` and metrics-server need.
- **metrics-server**, which makes `kubectl top` and the horizontal pod autoscaler work.
- **Upgrades.** A new Talos version or Kubernetes version upgrades the running cluster one node after the other.
- **Longhorn (optional).** Longhorn keeps persistent volumes on the disks of the nodes, because Contabo has no cloud volumes. The V2 Data Engine of Longhorn is optional too.
- **Ingress, certificates and DNS (optional).** The Gateway API of Cilium receives web traffic on the ingress nodes. cert-manager gets certificates from Let's Encrypt, and external-dns creates DNS records in Contabo DNS.
- **Admin access through Tailscale (optional).** Admins reach the Talos API and the Kubernetes API through a tailnet, and the public Kubernetes API can stay closed. The Tailscale Kubernetes operator lets admins log in with their Tailscale identity. The node agent also works with Headscale, a control server that you run yourself.
- **Backups (optional).** talos-backup saves encrypted etcd snapshots, and Longhorn backs up the volumes, both into a bucket of a Contabo object storage.
- **Graceful node removal.** Before Terraform erases or cancels a node, the module drains the node, removes the node from etcd and from Kubernetes, and wipes Talos.
- **Workload identity (optional).** Pods can log in to Microsoft Entra ID and other clouds with their Kubernetes token instead of a password. See [modules/workload-identity](modules/workload-identity/README.md).
- **VNC passwords.** Contabo cannot turn off the VNC console of a server, so the module sets a random VNC password on every node.

## What you need

1. A Contabo account and its API credentials. The Contabo Customer Control Panel shows the credentials under **Account > Security > API**. Set them as the environment variables `CNTB_OAUTH2_CLIENT_ID`, `CNTB_OAUTH2_CLIENT_SECRET`, `CNTB_OAUTH2_USER` and `CNTB_OAUTH2_PASS`.
2. Terraform 1.9 or newer, or OpenTofu 1.9 or newer.
3. `talosctl`, `kubectl`, `bash` and GNU `timeout` on the computer that runs Terraform. On macOS, `brew install coreutils` provides `timeout`. The module calls `talosctl` for upgrades and for health checks, and `kubectl` to drain nodes. Linux, macOS and Windows Subsystem for Linux (WSL) work. Use a `talosctl` version that matches the Talos version of the cluster, for example `talosctl` 1.14 for Talos 1.14.
4. Outgoing SSH (port 22) from the computer that runs Terraform. The module uses SSH once per node during the installation.
5. With `admin_access.mode = "tailscale"`: the Tailscale client on the computer that runs Terraform, logged in to the tailnet (see "Admin access through Tailscale").

The module uses the Contabo provider [`hayone1/contabo`](https://registry.terraform.io/providers/hayone1/contabo/latest). The official provider `contabo/contabo` misses features that the module needs, for example the reinstall resource and the adoption of existing instances.

## Quick start

The module is on the [Terraform Registry](https://registry.terraform.io/modules/hayone1/kubernetes/contabo/latest) as `hayone1/kubernetes/contabo`. Pin a version:

```hcl
module "kubernetes" {
  source  = "hayone1/kubernetes/contabo"
  version = "~> 0.1"

  cluster_name = "demo"
  control_plane_pools = [{ name = "cp", product_id = "V91", count = 1 }]
}
```

The examples use `source = "../.."`, because they live in this repository. Replace that line with the two lines above in your own copy.

1. Copy the folder [examples/minimal](examples/minimal) to a new folder.
2. Copy `terraform.tfvars.example` to `terraform.tfvars`, and set `product_id` to a Contabo product, for example `"V91"` for a Cloud VPS 10.
3. Run `terraform init` and `terraform apply`. The first apply takes 15 to 30 minutes. Most of the time goes to the installation of Ubuntu and Talos.
4. Save the access files:

   ```sh
   terraform output -raw kubeconfig > kubeconfig
   terraform output -raw talosconfig > talosconfig
   kubectl --kubeconfig kubeconfig get nodes
   ```

The minimal example orders one instance. Contabo bills a new instance for the whole contract period, by default one month, even when you destroy the instance after one hour.

## How the installation works

Contabo can only boot its own images, unless you buy the Custom Images Storage add-on in the control panel. Even with that add-on, Talos cannot read the network settings that Contabo hands to an image, so every node would need its own image. The module therefore needs no custom image and installs Talos in six steps:

1. The module orders the instance with a standard Ubuntu image and an SSH key that the module creates. An adopted instance gets the same Ubuntu installation through a reinstall.
2. The module adds the instance to the private network and to the Contabo firewall. Contabo asks for a new installation after an instance joins a private network, so new instances get Ubuntu a second time.
3. The module connects with SSH and runs [scripts/install-talos.sh](scripts/install-talos.sh). The script downloads the Talos kernel and initramfs of the node from the Image Factory and starts them from memory with `kexec`. Ubuntu stops, and Talos runs from memory without touching the disk. The whole step took about 2 minutes in the live test.
4. Talos waits in maintenance mode for its configuration. The Contabo firewall only lets the admin addresses (`admin_access`) and the private network reach the node at this time. Maintenance mode has no password, so anyone who reached the node first could take the node over.
5. The module sends the Talos configuration. Talos installs itself on the disk, erases Ubuntu, and starts again from the disk.
6. The module starts etcd on the first control plane node and waits until the cluster is healthy.

An earlier version of the module wrote the Talos disk image over the disk of the running Ubuntu system. The live tests showed that the old Ubuntu kernel then writes into the new Talos partitions and crashes at random, so the module now uses `kexec`.

Contabo has no DHCP, so the network settings of the public interface are kernel arguments in a Talos Image Factory schematic. A schematic is a description of a Talos image. Every node gets its own schematic, which costs nothing. Talos upgrades keep the kernel arguments.

The installation erases the disk. After the installation, the SSH key has no use, because Talos has no SSH server.

## Nodes and pools

Nodes come in pools. A pool is a group of nodes with the same settings, for example the same product and the same Kubernetes labels.

```hcl
control_plane_pools = [{
  name       = "cp"
  product_id = "V91"
  count      = 3
}]

worker_pools = [{
  name       = "worker"
  product_id = "V94"
  count      = 2
  labels     = { "example.com/tier" = "web" }
}]
```

A node is called `<cluster name>-<pool name>-<key>`, for example `prod-cp-1`. New nodes get the keys `1`, `2`, `3` and so on. Lowering `count` removes the node with the highest key.

The cluster needs an odd number of control plane nodes, for example 1, 3 or 5. etcd keeps working while more than half of the control plane nodes run. A cluster with 3 control plane nodes survives the loss of 1 node.

Without worker pools, the control plane nodes run your applications too. The module then removes the control plane taint.

Every node gets the label `nodepool=<pool name>`, so a workload can choose a pool with a node selector. Talos sets labels with the credentials of kubelet, and Kubernetes refuses labels below `kubernetes.io` and `k8s.io` from kubelet. Use labels like `example.com/tier`, or the prefixes `node.kubernetes.io/` and `kubelet.kubernetes.io/`. The module checks the label names.

Taints of a pool apply when a node joins the cluster. Kubernetes does not let kubelet change the taints later, so a changed taint only reaches new nodes. Use `kubectl taint` for nodes that already exist.

### Adopt instances that you already pay for

Contabo bills instances by the month, so an existing instance is often cheaper than a new one. List the existing instances in `existing_instances`:

```hcl
control_plane_pools = [{
  name               = "cp"
  existing_instances = { a = "200000001", b = "200000002", c = "200000003" }
}]

adoption = {
  allow_reinstall   = true
  cancel_on_destroy = false
}
```

The keys (`a`, `b`, `c`) become part of the node names, for example `prod-cp-a`. The module erases every adopted instance, so `adoption.allow_reinstall = true` is required. With `cancel_on_destroy = false`, `terraform destroy` does not cancel the instances, and the instances keep costing money. The graceful node removal still wipes Talos and powers the instances off (see "Removing a node").

The example [examples/adopt-prepaid](examples/adopt-prepaid) shows a full configuration.

### Erase and reinstall one node

Raise the reinstall generation of a node to erase the node and install Talos again:

```hcl
control_plane_pools = [{
  name                  = "cp"
  existing_instances    = { a = "200000003" }
  reinstall_generations = { a = 2 }
}]
```

The module sends the Talos configuration to the new installation, and the node joins the cluster again. Only raise the number. A lower number or a removed entry is a change too, and every change erases the node.

Before the reinstall, the module removes the node from the cluster: the module drains the node, and a control plane node leaves etcd. After the reinstall, the node joins the cluster again as a new member.

A cluster with one control plane node loses the whole cluster in a reinstall of that node, because etcd has no other member. Start etcd again with `terraform apply -replace='module.<name of the module>.talos_machine_bootstrap.this'`. The machine secrets stay the same, so the kubeconfig and the talosconfig keep working.

## Network and firewalls

### Private network

By default, the module creates a private network for the cluster and adds every node. The provider orders the private networking add-on for every instance that lacks it. Contabo charges for this add-on every month.

`private_network.existing_id` uses a network that already exists. The module then never changes that network, so every node must already be a member. This setting only works with adopted instances. In an existing network, the nodes only trust the private addresses of the other nodes, because the network can hold other servers.

### Which ports are open

| Port | Service | Who may connect |
|---|---|---|
| 6443 | Kubernetes API (control plane nodes) | `admin_access`, the private network. In the `tailscale` mode: the tailnet and the private network only |
| 50000 | Talos API | `admin_access`, the private network, and the tailnet with the node agent |
| 22 | SSH of the temporary Ubuntu system | `admin_access` |
| `public_ports` | for example an ingress controller | everybody, only on the ingress nodes |
| everything else | | the private network only, or nobody |

The Contabo firewall limits the Talos API and the Kubernetes API to `admin_access`. The Talos host firewall does not repeat this limit while the Contabo firewall is on. After a new address of your computer, Terraform could otherwise not reach the nodes to change their Talos firewall. Terraform can always change the Contabo firewall through the Contabo API. Both APIs need client certificates in any case. Without the Contabo firewall, the Talos host firewall limits both APIs to `admin_access`.

Cilium handles the traffic of Kubernetes services (NodePort, LoadBalancer and host ports) before the Talos host firewall sees the traffic. Only the Contabo firewall filters that traffic, so keep the Contabo firewall on, and open service ports only with `public_ports` or `contabo_firewall.extra_inbound_rules`.

The ingress nodes are the worker nodes. In a cluster without worker nodes, the control plane nodes are the ingress nodes.

`admin_access.include_runner_ip` adds the public IPv4 address of the computer that runs Terraform. The address can change, for example when your internet provider gives you a new address. Run `terraform apply` again after a change. Until then, `kubectl` and `talosctl` cannot reach the cluster.

## Upgrades

Change `talos_version` or `kubernetes_version`, and run `terraform apply`. The module follows the order that the Talos documentation recommends:

1. The module upgrades Talos on every node, first the control plane nodes and then the workers, one node at a time. The module waits for a healthy cluster before and after every node.
2. The module runs `talosctl upgrade-k8s`, which upgrades Kubernetes in the right order.
3. The module sends the new Talos configuration to every node.
4. The module runs `talosctl upgrade-k8s` to the current version once more. This step applies changed manifests, for example a new Cilium version, because Talos does not apply changed manifests by itself.

Upgrade Kubernetes by one minor version at a time, for example from 1.35 to 1.36. Kubernetes does not support larger steps.

## Workload identity

Workload identity gives pods a token that Microsoft Entra ID (and other clouds) accept instead of a password. The module publishes the public key of the cluster in a public Contabo bucket and sets the Kubernetes issuer to the address of that bucket.

```hcl
workload_identity = {
  enabled = true
  issuer = {
    object_storage = { object_storage_id = "00000000-0000-4000-8000-000000000000" }
  }
  azure = { tenant_id = "8a8b2a3c-0000-4000-8000-000000000000" }
}
```

Turn on workload identity when you create the cluster. The issuer is part of every token, and a later change makes every existing token invalid. The [module README](modules/workload-identity/README.md) explains the details, including a change of the issuer.

The examples [headlamp-entra-login](examples/headlamp-entra-login) and [rancher-entra-login](examples/rancher-entra-login) use workload identity for logins with Entra ID.

## Your own Talos patches and manifests

- `talos.control_plane_config_patches` and `talos.worker_config_patches` add Talos configuration patches to all control plane nodes or all workers. The `config_patches` setting of a pool adds patches to the nodes of one pool. Write the patches for Talos 1.14, which uses one YAML document per topic, for example `KubeAPIServerConfig`.
- `extra_manifests` adds Kubernetes manifests that Talos applies, for example namespaces.

The module applies a changed manifest with `talosctl upgrade-k8s`. Talos keeps a list of the objects of all manifests (the ConfigMap `talos-bootstrap-manifests-inventory` in `kube-system`), and `talosctl upgrade-k8s` deletes the objects of a removed manifest. A removed manifest with a namespace therefore deletes the namespace and every volume claim in it. Move data out first.

## Storage with Longhorn

Contabo has no cloud volumes, so the module can install [Longhorn](https://longhorn.io), which stores persistent volumes on the disks of the nodes and keeps copies on other nodes.

```hcl
longhorn = {
  enabled            = true
  ephemeral_max_size = "50GiB"
}
```

Talos normally uses the whole disk for its EPHEMERAL volume, which holds container images, logs and the data of pods. With Longhorn, the module limits EPHEMERAL to `ephemeral_max_size` and gives the rest of the disk to Longhorn. A Cloud VPS 6 with 200 GB keeps about 140 GB for Longhorn. The module also adds the Talos extensions `iscsi-tools` and `util-linux-tools`, which Longhorn needs.

Longhorn runs on the worker nodes. In a cluster without workers, Longhorn runs on the control plane nodes. The first worker pool therefore moves Longhorn: the control plane nodes lose the Longhorn extensions, their Longhorn disk and the Longhorn pods. Move the volumes to the workers first, or create the cluster with workers from the start. After the move, turn off scheduling on the old Longhorn nodes, so that Longhorn does not wait for them: `kubectl -n longhorn-system patch nodes.longhorn.io <node name> --type merge -p '{"spec":{"allowScheduling":false}}'`. Every volume has 3 copies, or fewer when the cluster has fewer than 3 Longhorn nodes. The storage class `longhorn` is the default storage class.

Turn on Longhorn when you create the cluster. Talos reads the disk layout only from the first configuration of a node and never shrinks an existing EPHEMERAL volume. For a running cluster, install the nodes again one at a time (see "Erase and reinstall one node").

Before the module erases a Longhorn node, the module deletes the Longhorn record of the node. After a finished reset, the module also deletes the records of the volume copies (replicas) on the node, because the reset erased their data. Longhorn then copies the volumes to the other nodes again. If Longhorn still refuses to delete the record of the node, the apply shows a warning, and a node that comes back with the same name keeps its old Longhorn disks. Longhorn marks such a disk with the reason `DiskFilesystemChanged`. Replace the old disk in two steps:

```bash
kubectl -n longhorn-system patch nodes.longhorn.io <node name> --type merge \
  -p '{"spec":{"disks":{"<old disk name>":{"allowScheduling":false}}}}'
kubectl -n longhorn-system patch nodes.longhorn.io <node name> --type merge \
  -p '{"spec":{"disks":{"<old disk name>":null,"longhorn":{"path":"/var/mnt/longhorn","allowScheduling":true,"diskType":"filesystem","storageReserved":0,"tags":[]}}}}'
```

With the V2 Data Engine, add the block disk `{"path":"/dev/disk/by-partlabel/r-longhorn-v2","allowScheduling":true,"diskType":"block","diskDriver":"auto","storageReserved":0,"tags":[]}` as `longhorn-v2` in the second command too.

### The V2 Data Engine of Longhorn

> **Warning:** Longhorn calls the V2 Data Engine a technical preview. The module tested the engine for about 4 hours on two Cloud VPS 6 workers with node restarts, replica rebuilds, backups and a restore, and no data was lost. A preview can still change or break with a new Longhorn version. Keep backups of v2 volumes, and use the default engine (storage class `longhorn`) for data that you cannot lose. The engine needs a new installation of the Longhorn nodes, and it keeps 2 CPU cores of every Longhorn node busy unless you turn on `interrupt_mode`.

The V2 Data Engine of Longhorn uses SPDK, a storage engine that talks to the disk directly instead of through a file system. V2 volumes are faster, but Longhorn still calls the engine a technical preview. The module runs the V2 Data Engine next to the default engine.

```hcl
longhorn = {
  enabled = true
  v2      = { enabled = true, size = "80GiB" }
}
```

With `v2`, every Longhorn node gets a raw partition of `size` for the V2 Data Engine. A raw partition is a part of the disk without a file system. Every Longhorn node also gets 2 GiB of hugepages and the kernel modules of SPDK. Hugepages are large blocks of memory that SPDK reserves for itself. The module reserves the hugepages with kernel arguments in the Image Factory schematic of the node. A running node therefore gets one Talos upgrade (a restart) when you turn `v2` on, one node after the other. The restart is needed, because kubelet counts the hugepages only when kubelet starts, and Longhorn refuses the V2 Data Engine while one Longhorn node offers no hugepages. Talos creates the raw partition before the Longhorn volume of the default engine, so the default engine gets the rest of the disk. The module also creates the storage class `longhorn-v2`. The storage class `longhorn` keeps the default engine and stays the default storage class.

The V2 Data Engine keeps 2 CPU cores of every Longhorn node busy, because SPDK asks the disk for new work all the time (polling) instead of waiting for a signal from the disk (an interrupt). A dedicated server (VDS) has its own cores. On a VPS, the cores are shared with other customers, so set `interrupt_mode = true` there. The plan shows a warning when a Longhorn node is not a VDS and interrupt mode is off. In the live test on a Cloud VPS 6, the engine used about 2 cores per node in the default mode and about 0.1 core in interrupt mode. Longhorn changes the interrupt mode only while no v2 volume is attached, so stop the pods with v2 volumes before the apply.

Like the rest of the disk layout, the raw partition only comes with the first configuration of a node. Turn `v2` on when you create the cluster, or install the Longhorn nodes again. A running node without the partition keeps working, but Longhorn gets no V2 disk on that node. Longhorn still runs the V2 Data Engine on that node, with its busy cores. Set the label `node.longhorn.io/disable-v2-data-engine=true` on such a node (in the `labels` of its pool) to stop the engine there. Longhorn adds the disks of a new node from a node annotation that the module sets. The annotation only works on a node without Longhorn disks, and a new installation through the module removes the old Longhorn node first. The example [examples/longhorn-v2](examples/longhorn-v2) builds a cluster with three storage workers.

To turn `v2` off again, delete every v2 volume first, because a v2 volume stops working without the engine. Then set `v2.enabled = false` and run `terraform apply`. The Longhorn nodes get one more Talos upgrade without the hugepages. The raw partitions stay on the disks until the next installation of a node.

## Ingress, certificates and DNS

Contabo has no load balancer. The module therefore lets Envoy, the proxy of Cilium, listen on the ports 80 and 443 of the ingress nodes. The ingress nodes are the workers, or the control plane nodes in a cluster without workers.

```hcl
gateway_api  = { enabled = true, domain = "apps.example.com" }
cert_manager = { enabled = true, acme_email = "admin@example.com" }
external_dns = { enabled = true }

contabo_dns_credentials = {
  client_id     = "INT-12345678"
  client_secret = var.contabo_dns_client_secret
  api_user      = "dns-user@example.com"
  api_password  = var.contabo_dns_api_password
}
```

With these settings, the module installs the following parts:

- The Gateway API CRDs and the Gateway API of Cilium. The module opens the ports 80 and 443 on the ingress nodes.
- cert-manager with the [Contabo DNS webhook](https://github.com/hayone1/cert-manager-webhook-contabo), and the ClusterIssuers `letsencrypt-staging` and `letsencrypt-production`. cert-manager proves the ownership of a domain with a DNS record (DNS-01), so port 80 does not need to be open for certificates.
- external-dns with the [Contabo DNS webhook](https://github.com/hayone1/external-dns-contabo-webhook). external-dns creates DNS records for HTTPRoutes and LoadBalancer services. The owner id of the records is the cluster name, so clusters that share a DNS zone do not change the records of each other.
- The Gateway `public` in the namespace `gateway`, with a wildcard certificate for `apps.example.com` and `*.apps.example.com`. An HTTPRoute in any namespace can use the Gateway. external-dns points the names of the routes to the public addresses of the ingress nodes.

The domain must use the Contabo name servers (`ns1.contabo.net`, `ns2.contabo.net` and `ns3.contabo.net`), and the DNS zone must exist in Contabo DNS.

An HTTPRoute for an application looks like this:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop
  namespace: shop
spec:
  parentRefs: [{ name: public, namespace: gateway }]
  hostnames: ["shop.apps.example.com"]
  rules:
    - backendRefs: [{ name: shop, port: 80 }]
```

The module writes the DNS credentials into a Kubernetes Secret. The Secret is an inline manifest, so the credentials are also in the Talos configuration of the control plane nodes and in the Terraform state. Use a Contabo user whose role allows only the DNS API. The credentials of your main Contabo user can cancel every server of the account.

## Admin access through Tailscale

[Tailscale](https://tailscale.com) connects your computer and the nodes in a tailnet, a private network that Tailscale encrypts with WireGuard. With Tailscale, admins do not need open public ports to reach the cluster. The module never sends traffic between the nodes or between pods through Tailscale.

The module offers two parts, and you can use them together:

- **The node agent** runs Tailscale on every control plane node, and on the workers with `workers = true`. The module adds the Talos extension `siderolabs/tailscale`. Every node joins the tailnet as `<node name>.<tailnet domain>`, for example `prod-cp-1.tail1234.ts.net`. The Talos API and the Kubernetes API of the node answer on that name, and the module adds the name to the certificates. The node agent also works while Kubernetes is broken, because Talos runs the agent.
- **The operator** installs the [Tailscale Kubernetes operator](https://tailscale.com/kb/1236/kubernetes-operator) with its API server proxy. Admins run `tailscale configure kubeconfig <cluster name>-k8s` and log in to Kubernetes with their Tailscale identity. No kubeconfig file with a client certificate is needed. The operator needs the Tailscale service: Headscale has no OAuth clients.

```hcl
admin_access = { mode = "tailscale" }

tailscale = {
  tailnet_domain = "tail1234.ts.net"
  node_agent     = { enabled = true }
  operator       = { enabled = true }
}

tailscale_auth_key     = "${var.nodes_oauth_secret}?ephemeral=false&preauthorized=true"
tailscale_oauth_client = { client_id = var.operator_client_id, client_secret = var.operator_client_secret }
```

`admin_access.mode = "tailscale"` closes the public Kubernetes API in both firewalls. The kubeconfig output then uses the tailnet name of the first control plane node. The Talos API stays open for `admin_access`, because a new node gets its first configuration through its public address, before the node joins the tailnet. The computer that runs Terraform must be in the tailnet, because the module runs `kubectl` and `talosctl upgrade-k8s` against the Kubernetes API. `api_hostname` does not work in this mode, because the name points to the public addresses.

Turn Tailscale on in two applies for a running cluster. First turn on the node agent and run `terraform apply`: the control plane nodes get the extension through a Talos upgrade and join the tailnet. Then set `admin_access.mode = "tailscale"` and run `terraform apply` again. In one single apply, the module would try to reach nodes through tailnet names that do not exist yet.

The tailnet needs some preparation:

1. Add the tags and grants of the output `tailscale_policy` to your tailnet policy. The output is JSON. The tags are `tag:k8s-node` for the nodes, `tag:k8s-operator` for the operator and `tag:k8s` for the proxies of the operator. The grants let `tailscale.admin_sources` (by default every admin of the tailnet) reach both APIs, and they map the admins to the Kubernetes group `tailnet:cluster-admins`. The module binds that group to the ClusterRole `cluster-admin` (`tailscale.operator.cluster_role_bindings`).
2. Turn on HTTPS in the DNS settings of the tailnet. The API server proxy needs a certificate for its tailnet name. Tailscale then publishes the names of devices with certificates in the public Certificate Transparency logs.
3. Create an OAuth client with the scope `auth_keys` and the tag `tag:k8s-node` for the node agent. Pass its secret with `?ephemeral=false&preauthorized=true` as `tailscale_auth_key`. An OAuth client secret never expires, while an auth key expires after 90 days at most. A new node needs a valid key.
4. Create an OAuth client with write access to `devices:core`, `auth_keys` and `services` and the tag `tag:k8s-operator` for the operator. Pass it as `tailscale_oauth_client`.

The example [examples/tailscale-admin](examples/tailscale-admin) does steps 1 to 4 with the [Tailscale Terraform provider](https://registry.terraform.io/providers/tailscale/tailscale/latest/docs).

Tailscale runs in userspace mode on the nodes. Userspace mode creates no network interface and changes no route and no firewall rule, so Tailscale cannot disturb Cilium. Tailscale hands every connection from the tailnet to the local port of the node, and the Talos host firewall does not see these connections. The tailnet policy is therefore the only filter for tailnet traffic to the nodes. Give `tag:k8s-node` only the grants of `tailscale_policy` (the ports 6443 and 50000). A rule like "everybody may reach everything", which a new tailnet has by default, lets every device of the tailnet reach every local port of the nodes, for example the metrics of etcd.

The keys are in the Terraform state and in the Talos configuration of the nodes. Protect the state.

A node keeps its tailnet device after a restart or an upgrade. A new installation of a node (a reinstall or a replaced instance) creates a new device. Delete the old device on the Machines page of the Tailscale admin console before the apply. Otherwise Tailscale gives the new device a name with a number at the end, for example `prod-cp-1-1`, and the certificates and the kubeconfig no longer match.

### Headscale instead of the Tailscale service

[Headscale](https://headscale.net) is a control server for Tailscale clients that you run yourself. The node agent works with Headscale. The operator does not, because Headscale has no OAuth clients.

```hcl
admin_access = { mode = "tailscale" }

tailscale = {
  tailnet_domain = "tailnet.example.com"
  login_server   = "https://headscale.example.com"
  admin_sources  = ["group:k8s-admins"]
  tag_owners     = ["group:k8s-admins"]
  node_agent     = { enabled = true }
}

tailscale_auth_key = var.headscale_pre_auth_key
```

- `tailnet_domain` is the `dns.base_domain` of the Headscale configuration. The nodes get names below this domain, for example `prod-cp-1.tailnet.example.com`.
- `tailscale_auth_key` is a pre-auth key of Headscale. A pre-auth key lets a device join the tailnet without a login in the browser. The key must be reusable and carry the node tag, for example from `headscale preauthkeys create --reusable --tags tag:k8s-node --expiration 90d`. The nodes get their tags from the key. With Headscale, the module therefore does not ask for the tags of `node_agent.tags` itself, because Headscale refuses tags that a device asks for when its key belongs to no user. A new node needs a valid key, so create a new key before the old key expires.
- Headscale has no `autogroup:admin`. Set `admin_sources` and `tag_owners` to Headscale users (for example `alice@`), groups or tags. Otherwise Headscale refuses the output `tailscale_policy`, and the plan shows a warning. A group like `group:k8s-admins` must exist in the `groups` of the Headscale policy.

The node agent normally logs in only once and keeps its login in a state folder on the node. The module gives every login server its own state folder. A node that moves from the Tailscale service to Headscale, or to another Headscale server, therefore logs in again with the new auth key. To move a running cluster, follow three steps:

1. Set `admin_access.mode = "public"`, turn the operator off, and run `terraform apply`.
2. Change `login_server`, `tailnet_domain`, `admin_sources`, `tag_owners` and `tailscale_auth_key`, and run `terraform apply`. The nodes join the Headscale tailnet. Log in the computer that runs Terraform to Headscale too.
3. Set `admin_access.mode = "tailscale"` again, and run `terraform apply`.

The module then removes the manifest of the operator, and `talosctl upgrade-k8s` deletes the objects of the operator, for example the namespace `tailscale`. The old devices of the nodes and the operator stay in the tailnet of the Tailscale service: delete them in the admin console.

A reverse proxy is a web server that passes requests on to Headscale, for example nginx. Tailscale clients change their HTTP connection to the protocol `tailscale-control-protocol` (an HTTP upgrade), and a reverse proxy in front of Headscale must pass this upgrade on. The Gateway of the module (Envoy) does not do that, so do not put Headscale behind the Gateway. The example [examples/headscale-admin](examples/headscale-admin) creates the pre-auth key and the policy with the [Headscale Terraform provider](https://registry.terraform.io/providers/awlsring/headscale/latest/docs).

## Backups

The module can back up etcd and the Longhorn volumes into a bucket of a Contabo object storage.

```hcl
backups = {
  object_storage_id = "00000000-0000-4000-8000-000000000000"
  bucket            = "prod-backups"
  etcd              = { enabled = true, age_public_keys = ["age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p"] }
  longhorn          = { enabled = true, retain = 7 }
}
```

- **etcd.** [talos-backup](https://github.com/siderolabs/talos-backup) runs as a CronJob, every 6 hours by default. talos-backup takes an etcd snapshot through the Talos API, compresses the snapshot, encrypts it with [age](https://age-encryption.org) and uploads it to `etcd/<cluster name>/` in the bucket. An etcd snapshot holds every Secret of the cluster, so the module always encrypts the snapshots. Create the key with `age-keygen -o backup-key.txt`, and put the public key into `age_public_keys`. Keep `backup-key.txt` outside the cluster, for example in a password manager. Without the key, nobody can read the snapshots, and you cannot restore the cluster.
- **Longhorn.** The bucket becomes the backup target of Longhorn (`longhorn/<cluster name>/`). A recurring job backs up every volume once a day by default and keeps the last `retain` backups of each volume. Longhorn can restore a backup into a new volume, also in a new cluster.

The bucket must exist before the apply. The module never creates or deletes the bucket, so `terraform destroy` keeps the backups. talos-backup never deletes old snapshots, so delete old snapshots from time to time, or set a lifecycle rule on the bucket.

Without `backup_s3_credentials`, the module reads the S3 credentials of the Contabo API user for the object storage. Those credentials open every bucket of the object storage, so the cluster could read and delete all buckets there. Pass other credentials if other data lives in the object storage. The credentials are in the Terraform state and in the Talos configuration of the control plane nodes.

To restore etcd, download a snapshot, decrypt it with `age -d -i backup-key.txt snapshot.age | zstd -d > db.snapshot`, and follow the [disaster recovery guide of Talos](https://docs.siderolabs.com/talos/latest/build-and-extend-talos/cluster-operations-and-maintenance/disaster-recovery) (`talosctl bootstrap --recover-from=db.snapshot`).

## Inputs

| Name | What the input does | Default |
|---|---|---|
| `cluster_name` | The name of the cluster. It must not change later. | none |
| `region` | The Contabo region of all nodes. | `"EU"` |
| `talos_version` | The Talos version. A change upgrades every node. | `"v1.14.5"` |
| `kubernetes_version` | The Kubernetes version. A change upgrades the cluster. | `"1.36.6"` |
| `control_plane_pools` | The control plane nodes. | none |
| `worker_pools` | The worker nodes. | `[]` |
| `new_instance_period` | The first contract period of new instances in months. | `1` |
| `adoption` | `allow_reinstall` and `cancel_on_destroy` for adopted instances. | both `false` |
| `private_network` | An existing network (`existing_id`) and the private interface name. | new network, `"eth1"` |
| `kubernetes_network` | The pod and service address ranges. | `10.244.0.0/16`, `10.96.0.0/12` |
| `admin_access` | Who may reach the Talos API and the Kubernetes API. | the computer that runs Terraform |
| `public_ports` | TCP ports that everybody may reach on the ingress nodes. | `[]` |
| `contabo_firewall` | The Contabo firewall and extra firewall rules. | on |
| `installer` | The temporary Ubuntu image, the disk, and the installation settings. | Ubuntu 24.04, `/dev/sda` |
| `talos` | Extensions, kernel arguments, DNS servers and extra patches. | `1.1.1.1`, `8.8.8.8` |
| `api_hostname` | A DNS name for the Kubernetes API. You create the DNS records. | none |
| `service_account_issuer` | The token issuer without workload identity. | `https://kubernetes.default.svc.cluster.local` |
| `cilium` | Chart version, WireGuard, Hubble and extra Helm values. | `1.20.4`, WireGuard on |
| `talos_ccm` | Chart version and extra Helm values of the Talos cloud controller manager. | `0.5.8` |
| `metrics_server` | metrics-server on or off, chart version, extra Helm values. | on, `3.14.0` |
| `extra_manifests` | Extra Kubernetes manifests. | `{}` |
| `longhorn` | Longhorn storage, the size of EPHEMERAL, replicas, the V2 Data Engine. | off |
| `gateway_api` | The Gateway API of Cilium and the shared Gateway of a domain. | off |
| `cert_manager` | cert-manager with the Contabo DNS webhook. | off |
| `external_dns` | external-dns with the Contabo DNS webhook. | off |
| `contabo_dns_credentials` | Contabo API credentials for cert-manager and external-dns (sensitive). | none |
| `workload_identity` | Workload identity settings. | off |
| `tailscale` | The Tailscale node agent and the Tailscale operator, or Headscale with `login_server`. | off |
| `tailscale_auth_key` | The auth key of the node agent (sensitive). | none |
| `tailscale_oauth_client` | The OAuth client of the operator (sensitive). | none |
| `backups` | Backups of etcd and Longhorn to an object storage bucket. | off |
| `backup_s3_credentials` | Other S3 credentials for the backups (sensitive). | the Contabo API user |
| `vnc_passwords` | Random VNC passwords on every node. | `true` |

The file [variables.tf](variables.tf) describes every setting in detail.

## Outputs

| Name | What the output contains |
|---|---|
| `kubeconfig` | A kubeconfig file with admin rights (sensitive). |
| `kubernetes_client` | The API address and the admin certificates for the `kubernetes` and `helm` providers (sensitive). |
| `talosconfig` | A talosconfig file with admin rights (sensitive). |
| `kubernetes_api_url` | The address of the Kubernetes API in the kubeconfig. |
| `tailscale` | The tailnet names of the nodes and the address of the API server proxy, or null. |
| `tailscale_policy` | The tags and grants that the tailnet policy needs, as JSON, or null. |
| `nodes` | Every node with role, pool, instance id and addresses. |
| `private_network` | The id and the address range of the private network. |
| `contabo_firewall_id` | The id of the Contabo firewall. |
| `admin_cidrs` | The ranges that may reach the APIs. |
| `vnc` | The VNC address and password of every node (sensitive). |
| `service_account_issuer` | The issuer of the service account tokens. |
| `workload_identity` | The issuer address and the Entra ID values, or null. |
| `talos_installer_images` | The Talos installer image of every node, for manual upgrades. |

## Costs

- Contabo bills every new instance for the whole contract period (`new_instance_period`, by default 1 month). `terraform destroy` cancels new instances, but Contabo still bills the rest of the period.
- The private networking add-on costs money for every node, every month.
- The module needs no custom image storage, because the module starts Talos from a standard Ubuntu installation.
- Backups use space in the object storage. Contabo bills the object storage by its size.

## Security notes

- The Terraform state holds the Talos machine secrets, the admin certificates, the SSH key of the installation and the VNC passwords. Anyone with the state controls the cluster. Keep the state in a protected backend, for example an S3 bucket with encryption and limited access.
- Losing the state loses the machine secrets. A new `talos_machine_secrets` resource means a new cluster, so back up the state.
- The Contabo API credentials can cancel every server of the account. Keep them out of the cluster.
- The Tailscale keys and the S3 credentials of the backups are in the Terraform state and in the Talos configuration of the nodes.
- Without the Contabo firewall, a new node accepts a configuration from anyone during the installation. The module therefore refuses `contabo_firewall.enabled = false` unless you also set `installer.allow_unprotected_install = true`.

## Known problems

### Contabo limits reinstalls per day

Contabo limits how often you can reinstall an instance on one day. The exact limit is not documented, but the live tests reinstalled one instance four times on one day without a problem. Every new node uses two installations, and every adopted node uses one. Plan large clusters over more than one day.

Contabo also reports a reinstall as finished before the instance has started. In one live test, the instance answered SSH only 16 minutes later. The module waits up to `installer.ssh_timeout` (30 minutes) for SSH.

### The first control plane node is special

The private address of the first control plane node (by name order) is the cluster endpoint, and the kubeconfig output uses its public address. Inside the cluster, KubePrism on every node knows all control plane nodes, so the cluster keeps working when the first node is down. The kubeconfig output stops working while that node is down. Set `api_hostname` and point the name to all control plane nodes to avoid this problem. Create the DNS records before the first apply, because the upgrade steps use the name.

The module remembers the first control plane node. A new pool whose name sorts earlier does not move the endpoint. To retire the first node, follow these steps:

1. Make sure that enough other control plane nodes run. The number of control plane nodes must stay odd, so remove two nodes at a time, for example from 5 to 3.
2. Run `talosctl -n <first node> reset --graceful`, so that the node leaves etcd.
3. Remove the node from `existing_instances`, and run `terraform apply -replace='module.<name of the module>.terraform_data.bootstrap_node'` in the same step. Terraform picks the first remaining node by name and changes the cluster endpoint on every node. The replace does not start a new bootstrap.

A pool with `count` always removes its highest key, so the node `cp-1` of a count pool cannot be retired alone. Adopted nodes with their own keys do not have this limit.

### Nested Contabo networks are not supported

An instance can be a member of several Contabo private networks. The module configures only one private interface (`private_network.interface`, by default `eth1`). Do not use instances that are in more than one private network.

### The cluster cannot grow on its own

Contabo bills by the month and needs minutes to deliver a server, so the module has no cluster autoscaler. Change `count` to add or remove nodes.

### Removing a node

Lower `count`, or remove the entry from `existing_instances`, and run `terraform apply`. Before Terraform cancels the instance, the module removes the node from the cluster:

1. For a control plane node, the module checks etcd first. etcd keeps working while more than half of its members answer. When the removal would leave too few healthy members, the module stops the apply, and nothing changes.
2. The module drains the node with `kubectl`. A drain that does not finish in 5 minutes, for example because of a PodDisruptionBudget, only prints a warning.
3. The module resets the node with `talosctl reset --graceful`. A control plane node leaves etcd during the reset. The reset wipes Talos and powers the node off, so a cancelled node never waits unprotected for a new configuration until the end of its contract period. When the graceful reset of a control plane node fails while other etcd members exist, the module stops the apply.
4. The module deletes the Kubernetes node object and the Longhorn record of the node. After a finished graceful reset, the module also deletes the Longhorn records of the volume copies (replicas) on the node, because the reset erased their data. For a node that does not answer, the module only removes its etcd member and its node object, and the module keeps the Longhorn records: the disk of the node may still hold the last good copy of a volume.

The same removal runs before a reinstall and during `terraform destroy`. A full `terraform destroy` removes all control plane nodes at the same time, and the last ones cannot leave etcd cleanly. Set the environment variable `TALOS_SKIP_NODE_REMOVAL=1` for a full destroy, and for any removal that you want to skip.

The number of control plane nodes must stay odd, so remove two control plane nodes at a time, for example from 5 to 3. Run such an apply with `terraform apply -parallelism=1`, so that the nodes leave etcd one after the other. A new pool name is a new pool: Terraform removes every node of the old pool and creates new nodes. Do not rename pools.

### Changes reach all nodes at the same time

Terraform sends a changed configuration to all nodes in parallel. A change that every control plane node gets, for example a new control plane node in the certificate names of the API server, restarts kube-apiserver on all control plane nodes at once. The Kubernetes API is then down for about one minute. Run such applies with `terraform apply -parallelism=1`, so that Terraform changes one node after the other.

### An interrupted installation

When the installation stops halfway, for example because the SSH connection breaks after Talos started from memory, the next apply cannot reach Ubuntu any more. Raise the reinstall generation of the node by one (`reinstall_generations`). Terraform then installs Ubuntu and Talos again. A failure before the `kexec` step changes nothing on the node, and the next apply simply tries again.

A node that restarts while Talos waits in memory comes back as Ubuntu, because Talos did not touch the disk yet. The next apply then waits for Talos and fails after 30 minutes. Run `terraform apply -replace='module.<name of the module>.terraform_data.install["<node key>"]'` to start Talos again without a Contabo reinstall.

### Talos upgrades need kubectl

The upgrade method of `talosctl` drains the node through the cluster endpoint, which is a private address that your computer cannot reach. The module therefore drains the node itself with `kubectl` through the public API address, and then runs `talosctl upgrade --drain=false`. Without `kubectl`, the module falls back to `talosctl upgrade --legacy`, where the node drains itself. Talos removes the legacy method in Talos 1.18, so install `kubectl` before you upgrade to Talos 1.18.

## Tested versions

The table lists the Talos and Kubernetes versions that the live tests used on real Contabo instances. A version that is not in the table can work, but nobody tested it with the module. The newest test is at the top.

| Module version | Talos | Kubernetes | What the test did | Result | Date |
|---|---|---|---|---|---|
| v0.1.0 | v1.14.5 | 1.36.6 | The V2 Data Engine of Longhorn 1.13.0 on two reinstalled Cloud VPS 6 workers. A writer pod checked its data on a v2 volume with two replicas for about 4 hours, while the test deleted the pod, restarted the node of the engine and the node of the other replica, and made backups. No file was damaged, and a backup was restored into a new v2 volume. Interrupt mode passed the same checks. | Passed | 2026-11-07 |
| v0.1.0 | v1.14.5 | 1.36.6 | The node agents of a running cluster moved from the Tailscale service to Headscale 0.29.7 (pre-auth key and policy from the Headscale Terraform provider 0.5.1). All three nodes joined the Headscale tailnet, and `admin_access.mode = "tailscale"` closed the public Kubernetes API. kubectl and the Talos API worked on the tailnet names. | Passed | 2026-11-07 |
| v0.1.0 | v1.14.5 | 1.36.6 | Tailscale on a running cluster: the node agent came to the control plane node and to two workers through a Talos upgrade, the operator started its API server proxy, and `admin_access.mode = "tailscale"` closed the public Kubernetes API. Backups: talos-backup saved an etcd snapshot that decrypted with the age key, and a Longhorn backup was restored into a new volume. | Passed | 2026-11-07 |
| v0.1.0 | v1.14.5 | 1.36.6 | An existing one-node cluster was applied again with the newer module code (graceful node removal, `kexec` installer). The apply needed no new installation, and all checks passed. | Passed | 2026-11-07 |
| v0.1.0 | v1.14.5 | 1.36.6 | Gateway API, cert-manager and external-dns with the Contabo webhooks; graceful removal of two control plane nodes; adoption of the two instances as workers; new installation of a worker with `kexec`. | Passed | 2026-11-07 |
| v0.1.0 | v1.14.4 to v1.14.5 | 1.36.5 to 1.36.6 | Rolling upgrade of three control plane nodes. The module drained every node with `kubectl` and ran `talosctl upgrade --drain=false`, without the legacy method. | Passed | 2026-11-07 |
| v0.1.0 | v1.14.4 | 1.36.5 | New cluster with three control plane nodes on three new Cloud VPS 6 instances, a private network from the module, and Longhorn. | Passed | 2026-11-07 |
| v0.1.0 | v1.14.5 | 1.36.6 | New one-node cluster on an adopted instance with workload identity. The Headlamp and Rancher examples ran on the cluster. | Passed | 2026-11-07 |
| v0.1.0 | v1.14.4 to v1.14.5 | 1.36.5 to 1.36.6 | Upgrade of a one-node cluster with `talosctl upgrade --legacy` and `talosctl upgrade-k8s`. | Passed | 2026-11-06 |
| v0.1.0 | v1.14.4 | 1.36.5 | New one-node cluster on an adopted instance in an existing private network. | Passed | 2026-11-06 |

A "Failed" row stays in the table, together with the reason, so that you know which combination to avoid.

## Tests

- `terraform test` in the repository root runs plan-only tests with mocked providers. The tests need Terraform 1.11 or newer.
- [tests/live/cluster](tests/live/cluster) builds a real cluster on an adopted Contabo instance. The test erases the instance.
- [tests/live/ha](tests/live/ha) orders three new instances and builds a cluster with three control plane nodes and Longhorn. The test also checks the ingress, Tailscale and the backups. The instances cost money for a whole month.

## Repository layout

| Path | Content |
|---|---|
| `*.tf` | The root module. |
| `scripts/` | The installation script and the upgrade script. |
| `modules/workload-identity/` | The workload identity module. |
| `examples/` | Example configurations. |
| `tests/` | Mocked tests and live tests. |
