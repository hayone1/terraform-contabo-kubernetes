# Live test of the root module

This test builds a real one-node cluster with the root module. The test adopts one Contabo instance that you already pay for, erases the instance, installs Talos and turns on workload identity. The test also creates an Entra ID application, so that a pod can log in to Entra ID with its Kubernetes token.

The test erases the instance. Choose an instance that holds nothing you need.

## What you need

- A Contabo instance that is a member of a private network. The test uses the network as an existing network, so the test never changes the network.
- A Contabo object storage for the issuer bucket `wi-live-oidc`.
- An Azure CLI login (`az login`) with the right to create app registrations.
- `terraform`, `talosctl`, `kubectl`, `jq` and `curl` in WSL or Linux.
- The file `tests/live/.env` with the values from `tests/live/.env.example`: the Contabo credentials, `TF_VAR_instance_id`, `TF_VAR_private_network_id` and `TF_VAR_object_storage_id`.

## Run the test

1. Run `./run.sh apply`. The first apply takes 15 to 30 minutes. Contabo installs Ubuntu, the module writes Talos over the disk, and the module waits until the cluster is healthy.
2. Run `./run.sh verify`. The script checks the node, Cilium, the Talos cloud controller manager, metrics-server, DNS in a pod, the Talos host firewall and the public issuer documents. Every check prints PASS or FAIL.
3. Run `./run.sh test`. A pod exchanges its Kubernetes token for an Entra ID token. The test passes when Entra ID answers with HTTP 200.
4. Run `./run.sh plan`. The plan must show no changes. The exit code is 0 for no changes and 2 for changes.

To test an upgrade, apply first with older versions, and then apply again with the defaults:

```sh
TF_VAR_talos_version=v1.14.4 TF_VAR_kubernetes_version=1.36.5 ./run.sh apply
./run.sh apply
```

The state and the files with secrets (`kubeconfig`, `talosconfig`) are in `~/.cache/terraform-contabo-kubernetes/cluster-live/work`, outside the repository.

## Clean up

Run `./run.sh destroy`. The command deletes the bucket, the Entra ID application and the Contabo firewall, and the command forgets the instance. The instance keeps running Talos, and Contabo keeps billing the instance.

Never run `run.sh` with `bash -x`. The script reads `tests/live/.env`, and `bash -x` prints the Contabo credentials.
