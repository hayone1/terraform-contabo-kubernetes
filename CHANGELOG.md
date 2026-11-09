# Changelog

## v0.1.1 (2026-11-09)

Two fixes for the first build of a cluster with the Gateway API and cert-manager, and for clusters in an existing private network. Both problems showed up in the first production build with this module.

- The cert-manager.io resources (the ClusterIssuers, the wildcard Certificate of the Gateway and the Certificates of the Contabo webhook) moved into the new inline manifest `zz-cert-manager-resources`. Talos applies the inline manifests in the order of their names, and Talos stops at the first error. On a new cluster, the cert-manager webhook cannot answer yet, so a Certificate in the manifest `cert-manager` blocked every later manifest. The blocked manifests included the Talos cloud controller manager, which removes the taint `node.cloudprovider.kubernetes.io/uninitialized`. No pod could start, also not the webhook, and the first apply timed out. Talos now applies the cert-manager.io resources last.
- In an existing private network (`private_network.existing_id`), the open rules of the Talos host firewall (for example the Talos API with `talos_api_cidrs = ["0.0.0.0/0"]`) excluded the private network with `except`. Talos applies an `except` to every subnet of a rule, so the nodes lost access to the Talos API of the other nodes. `talosctl health` timed out, and the cloud controller manager could not initialize the workers. The excluded 0.0.0.0/0 now has its own rule `<name>-any`, and the nodes keep their own rule. An existing cluster gets the new rules with the next apply, without a restart.

## v0.1.0 (2026-11-07)

The first release.

- Kubernetes clusters on Contabo Cloud VPS and VDS with Talos Linux: new or adopted instances, control plane and worker pools, a private network, the Contabo firewall and the Talos host firewall.
- Cilium with WireGuard, the Talos cloud controller manager, metrics-server, and upgrades of Talos and Kubernetes one node after the other.
- Graceful node removal before a reinstall, a replaced instance or a destroy.
- Optional: Longhorn (also the V2 Data Engine, a technical preview of Longhorn), the Gateway API with cert-manager and external-dns, admin access through Tailscale or Headscale, backups of etcd and Longhorn into Contabo object storage, and workload identity (`modules/workload-identity`).
- Examples: `minimal`, `adopt-prepaid`, `tailscale-admin`, `headscale-admin`, `longhorn-v2`, `headlamp-entra-login`, `rancher-entra-login`.
