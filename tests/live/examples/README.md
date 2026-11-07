# Live tests: Headlamp and Rancher examples

These live tests run `examples/headlamp-entra-login` and `examples/rancher-entra-login` on the one-node test cluster of `tests/live/cluster`, which the root module builds. The tests create real objects in your Contabo account, in your Entra ID tenant and in the cluster.

## What you need

- A running test cluster. Run `tests/live/cluster/run.sh apply` first. Rancher 2.15 needs Kubernetes 1.36 or older, so the test cluster uses Kubernetes 1.36.
- A DNS zone on the Contabo name servers. Set `EXAMPLES_DNS_ZONE` in `tests/live/.env`, for example `EXAMPLES_DNS_ZONE=codetrekker.io`.
- A Contabo firewall on the test instance that allows port 443 from your IP address and port 80 from everywhere. Let's Encrypt checks the HTTP-01 challenge on port 80 from many places on the internet.
- An Azure CLI login (`az login`) with the right to create groups and app registrations and to grant admin consent.
- Linux or WSL with `terraform`, `kubectl`, `talosctl`, `curl`, `jq` and the Azure CLI.

## Run the tests

1. Run `./run.sh platform apply`. The platform step installs Traefik on the host ports 80 and 443, installs cert-manager with Let's Encrypt ClusterIssuers, creates the DNS records `headlamp-wi-live` and `rancher-wi-live`, and creates the Entra ID group `wi-live-k8s-admins` with you as the only member.
2. Run `./run.sh headlamp apply`. The script applies the Headlamp example, saves the `talos_config_patch` output in the work folder of the cluster, and applies the cluster again. The API server then trusts the ID tokens of the Headlamp app registration.
3. Run `./run.sh headlamp verify`. The script checks the certificate, the login redirect, the federated credential of oauth2-proxy, the API server settings and the RBAC.
4. Run `./run.sh rancher apply`. The first apply takes about 10 minutes.
5. Run `./run.sh rancher verify`. Run `ROTATE=1 ./verify-rancher.sh` to force a secret rotation as well.
6. Open both addresses in a browser, and log in with your Entra ID account. The verify scripts print the addresses. A real login needs a person, so the scripts cannot test this step.
7. Run `./run.sh rancher destroy`, `./run.sh headlamp destroy` and `./run.sh platform destroy` when you are done.

The scripts keep every Terraform state outside the repository, in `~/.cache/terraform-contabo-kubernetes/examples-<name>/state/`. The states hold the cookie secret of oauth2-proxy and the bootstrap password of Rancher. The scripts write a `backend_override.tf` file into each example folder. Git ignores these files.

## Known problems of the test setup

- Your public IP address can change. The firewall then blocks the API server, Talos and the browser. Apply the firewall configuration again with your new address.
- `./run.sh rancher destroy` uninstalls Rancher with Helm, but Rancher leaves namespaces and custom resources behind. Reset the test cluster when you need a clean cluster.
- The test cluster uses Flannel, which ignores network policies. The network policy of the Headlamp example only works with a network plugin like Cilium.
