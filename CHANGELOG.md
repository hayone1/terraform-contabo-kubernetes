# Changelog

## v0.1.0 (2026-11-07)

The first release.

- Kubernetes clusters on Contabo Cloud VPS and VDS with Talos Linux: new or adopted instances, control plane and worker pools, a private network, the Contabo firewall and the Talos host firewall.
- Cilium with WireGuard, the Talos cloud controller manager, metrics-server, and upgrades of Talos and Kubernetes one node after the other.
- Graceful node removal before a reinstall, a replaced instance or a destroy.
- Optional: Longhorn (also the V2 Data Engine, a technical preview of Longhorn), the Gateway API with cert-manager and external-dns, admin access through Tailscale or Headscale, backups of etcd and Longhorn into Contabo object storage, and workload identity (`modules/workload-identity`).
- Examples: `minimal`, `adopt-prepaid`, `tailscale-admin`, `headscale-admin`, `longhorn-v2`, `headlamp-entra-login`, `rancher-entra-login`.
