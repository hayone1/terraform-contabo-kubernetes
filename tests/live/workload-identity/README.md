# Live test: workload identity

This live test checks the module `modules/workload-identity` against real services. The test builds a one-node Talos cluster on a Contabo instance, and the module publishes the issuer documents in a Contabo bucket. A test pod then exchanges its Kubernetes token for an Entra ID access token. The test creates resources in your Contabo account and in your Entra ID tenant.

## What you need

- A Contabo instance that runs Talos in maintenance mode, with a firewall that allows ports 50000 and 6443 only from your IP address. The instance can run Talos from a Talos ISO or from a Talos installation that was reset into maintenance mode.
- A Contabo object storage. The test creates the bucket `wi-live-oidc` in the object storage.
- The Azure CLI with an active login (`az login`). The test creates an app registration named `wi-live-wi-live`.
- Linux or WSL with `terraform`, `kubectl`, `talosctl`, `curl` and `jq`. `edge-cases.sh` also needs `cntb` (the Contabo CLI with a login) and `mc` (the MinIO client), because the script changes bucket objects on purpose.

## Run the test

1. Copy `tests/live/.env.example` to `tests/live/.env`, and fill in the values.
2. Run `./run.sh apply`. Terraform builds the cluster, publishes the documents, and creates the Entra ID objects. The first apply takes about five minutes.
3. Run `./run.sh test`. The script waits for the node and the webhook, starts a pod, and prints the answer of Entra ID. A working setup prints `HTTP 200` and `PASS: Entra ID accepted the pod token.`, and the script exits with an error otherwise.
4. Run `./edge-cases.sh` to test the issuer guard, the repair of changed or deleted documents, and the import of a document. The script breaks things on purpose and repairs them again.
5. Run `./run.sh destroy` when you are done. The destroy removes the bucket, the documents and the Entra ID objects. The destroy does not cancel the instance.

The scripts keep the Terraform state outside the repository, in `~/.cache/terraform-contabo-kubernetes/wi-live/work/`. The state contains the Talos machine secrets, so the state must never be committed.

The test cluster runs Kubernetes 1.36, because the Rancher example needs Kubernetes 1.36 or older. The harness applies every Talos patch in the folder `work/extra-patches`. The example tests in `tests/live/examples` put the API server patch of the Headlamp example there. `run.sh` and `edge-cases.sh` read the same folder, so a plan never removes a patch by accident.

The harness also runs the manifest sync step from the module README. Terraform runs `talosctl upgrade-k8s` whenever the webhook manifests change.

Your public IP address can change. The Contabo firewall then blocks the API server and Talos, and every command times out. Apply the firewall configuration again with the new address.

## What the test showed on 2026-11-05

- The documents that the API server served were identical to the documents that the module computed.
- Entra ID accepted the Contabo bucket as an issuer, and the token exchange returned HTTP 200.
- The issuer guard, the drift repair, the restore of a deleted document and the import worked.
- A key set that was uploaded by hand without a `Cache-Control` header stayed in the Contabo cache for about 30 minutes. Entra ID rejected logins with the error `AADSTS7000272` during that time, and logins worked again after the cache expired. The module README describes this problem in the section "Known problems that the module cannot fix".

By default, step 3 of `edge-cases.sh` uploads its wrong key set with a short `Cache-Control` header, so the cache forgets the wrong copy quickly. Run `POISON_CACHE=1 ./edge-cases.sh` to repeat the cache problem on purpose. After such a run, logins fail for about 30 minutes.

## What the test showed on 2026-11-06

- A reset of the node with `talosctl reset` and a new cluster with the same Talos machine secrets kept the issuer and the key ID. The token exchange returned HTTP 200 without any change in Entra ID. The reset does not count as a Contabo reinstall.
- With `additional_accepted_issuers`, Talos started kube-apiserver with both issuers and both API audiences. A token that carried only the old audience got HTTP 200 during the move and HTTP 401 after the move.
- Kubernetes 1.36.6 and the webhook chart 1.6.1 worked together, and the manifest sync step ran `talosctl upgrade-k8s` without changes.
