# Example: Rancher with Entra ID login

This example installs [Rancher](https://www.rancher.com), a web platform to manage Kubernetes clusters, and turns on the Microsoft Entra ID login of Rancher. Members of your Entra ID admin groups become Rancher administrators. Nobody has to type or store a client secret.

Rancher can only log in to Entra ID with a client secret. Rancher does not support federated credentials. The example therefore uses workload identity in a different way: a small job in the cluster logs in to Entra ID with its Kubernetes service account token. The job creates a short-lived client secret for Rancher and hands the secret to Rancher. The module `modules/workload-identity` of this repository sets workload identity up.

## How the secret rotation works

The example creates two app registrations in Entra ID:

- The app registration `Rancher (<hostname>)` is the app that people log in to. Rancher reads users and groups with this app registration. Rancher uses a client secret for this app registration.
- The app registration `Rancher secret rotator (<hostname>)` has no secret at all. A federated credential lets the job in the cluster log in as this app registration. The rotator app registration may only change apps that the rotator owns, and the rotator owns only the Rancher app registration.

The job runs once a day, and once after every `terraform apply` that changes the chart or its values. Terraform passes a checksum of the chart files as a value, so a new version of `rotate.sh` also counts as a change. Each run follows these steps:

1. The job waits until Rancher has created its Entra ID settings object, the AuthConfig `azuread`.
2. The job logs in to Microsoft Graph with its service account token.
3. The job checks the client secret that Rancher has. The job creates a new client secret when Rancher has no secret yet, when the secret no longer exists, or when the secret ends within 10 days.
4. The job tests a new secret with a real token request. Only a working secret goes into the Kubernetes Secret `cattle-global-data/azureadconfig-applicationsecret`, which Rancher reads.
5. The job turns on the Entra ID login in Rancher with the settings from Terraform.
6. The job removes old secrets. After a normal rotation, the job keeps the previous secret until the next rotation, so a Rancher pod that still uses the previous secret keeps working. After a forced rotation, the job removes the previous secret at once. The job also removes a secret that a failed run left behind.

With the default settings, a client secret is valid for 30 days, and the job replaces the secret 10 days before the end. The job has 10 daily attempts before Rancher loses the Entra ID login.

The client secret never appears in Terraform, in the Terraform state, in a command line or in a log. The job keeps the secret in a memory-backed folder until the job writes the secret into the Kubernetes Secret.

## What the example creates

In Entra ID:

- The two app registrations and their service principals.
- The Microsoft Graph application permissions `User.Read.All` and `GroupMember.Read.All` for Rancher, with admin consent. Rancher needs these permissions to find users and groups.
- The Microsoft Graph application permission `Application.ReadWrite.OwnedBy` for the rotator, with admin consent.
- The rotator as an owner of the Rancher app registration.
- A federated credential on the rotator for the service account `rancher-entra-auth/entra-secret-rotator`.
- An assignment of each admin group and user group to the Rancher app registration. Entra ID refuses the login of everybody else, and Rancher only lets the listed groups in (access mode "required").

In Kubernetes:

- Rancher from the official Helm chart in the namespace `cattle-system`, with an Ingress and a TLS certificate from cert-manager.
- The local chart `charts/rancher-entra-auth` in the namespace `rancher-entra-auth`. The chart has the rotation job, a CronJob for the daily run, the RBAC for the job and the Rancher global role bindings for the groups.

## What you need

- A cluster with the module `modules/workload-identity` and the Azure workload identity webhook (`azure.enabled = true`).
- Kubernetes 1.36 or older. Rancher 2.15 does not support Kubernetes 1.37 yet, and the Rancher Helm chart refuses to install.
- An ingress controller, for example Traefik, and a cert-manager ClusterIssuer that issues publicly trusted certificates.
- A DNS record that points the host name to the ingress controller.
- At least one Entra ID group for the administrators.
- An Azure CLI login (`az login`) or other `azuread` provider credentials with the right to grant admin consent for Microsoft Graph application permissions. The Entra ID role "Privileged Role Administrator" or "Global Administrator" can do this.

## Use the example

1. Copy `terraform.tfvars.example` to `terraform.tfvars`, and fill in the values.
2. Run `terraform init` and `terraform apply`. The first apply takes about 10 minutes, because Rancher needs time to start.
3. Open the `url` output in a browser.
4. Choose "Log in with Microsoft Entra ID", and log in as a member of an admin group.

`terraform apply` only reports success when the job has given Rancher a working secret and has turned on the Entra ID login.

## Emergency login

The local Rancher user `admin` keeps working as an emergency login. The `bootstrap_password` output shows the first password of `admin`:

```sh
terraform output -raw bootstrap_password
```

Rancher asks for a new password at the first login with the local user. Store the new password in a password manager. Use the local user only when the Entra ID login fails.

## Rotate the secret at once

Run the `rotate_now_command` output after a leak, or to test the rotation. The command starts the job with `FORCE_ROTATION=true`, so the job creates a new secret even when the current secret is still valid. The job removes the old secret as soon as Rancher has the new secret, so a leaked secret stops working within a few minutes. Access tokens that somebody already got with the leaked secret stay valid until they expire, which takes 60 to 90 minutes. Rancher also keeps its own Microsoft Graph token in the Secret `cattle-global-data/azuread-access-token` for that time.

```sh
eval "$(terraform output -raw rotate_now_command)"
kubectl -n rancher-entra-auth logs -l app.kubernetes.io/name=rancher-entra-auth --tail=50
```

## Change the settings

The job writes the Entra ID settings into Rancher on every run. Change the settings in Terraform, and not in the Rancher user interface. A change in the user interface lasts only until the next run of the job.

The job also sets the annotation `management.cattle.io/auth-provider-cleanup: user-locked` on the AuthConfig. Without the annotation, Rancher deletes the client secret, the global role bindings of the groups and every Entra ID user when somebody turns the Entra ID login off in the user interface. With the annotation, Rancher keeps these objects, and the next run of the job turns the login on again. To turn the Entra ID login off for good, remove this example with `terraform destroy`.

To add a group, add the group object ID to `admin_group_object_ids` or `user_group_object_ids`, and run `terraform apply`. Terraform assigns the group to the app registration, and the job adds the group to the allowed principals of Rancher.

## Watch the job

A failed job is the only sign that the secret rotation has stopped. Add an alert for failed jobs in the namespace `rancher-entra-auth`, for example with the kube-state-metrics metric `kube_job_status_failed`. Check the logs of the newest job when the alert fires:

```sh
kubectl -n rancher-entra-auth get jobs
kubectl -n rancher-entra-auth logs job/<job name>
```

## Inputs

| Name | What the input does | Default |
|---|---|---|
| `kubeconfig_path`, `kubeconfig_context` | The kubeconfig file and context for Terraform. | none, current context |
| `tenant_id` | The Entra ID tenant of the people who log in. | none |
| `issuer_url` | The service account issuer of the cluster, from the `issuer_url` output of the workload identity module. | none |
| `hostname` | The public host name of Rancher. | none |
| `ingress` | The ingress class, the cert-manager ClusterIssuer and extra Ingress annotations. | none |
| `admin_group_object_ids` | Entra ID groups whose members become Rancher administrators. At least one group is needed. | none |
| `user_group_object_ids` | Entra ID groups whose members become standard Rancher users. | `[]` |
| `rancher` | The chart version, the number of Rancher pods and extra Helm values. | `2.15.3`, 3 pods |
| `secret_rotation` | The lifetime of a secret, the renewal time, the schedule, the namespace and the image of the job. | 30 days, 10 days, daily at 03:17 UTC |

## Outputs

| Name | What the output contains |
|---|---|
| `url` | The address of Rancher. |
| `bootstrap_password` | The first password of the local user `admin` (sensitive). |
| `rancher_client_id` | The client ID of the app registration that people log in to. |
| `rotator_client_id` | The client ID of the rotator app registration. |
| `rotate_now_command` | A command that creates a new client secret at once. |

## Security notes

- The permission `Application.ReadWrite.OwnedBy` lets the rotator change only the apps that the rotator owns, and the rotator owns only the Rancher app registration. The permission is still strong. A stolen rotator token can change the redirect addresses, the federated credentials and the owners of the Rancher app, can create a secret for the Rancher app, and can create new app registrations. A secret of the Rancher app can read every user and every group membership in the tenant.
- Everybody who can start a pod with the service account `rancher-entra-auth/entra-secret-rotator` gets a rotator token. Give only cluster administrators access to the namespace `rancher-entra-auth`.
- The rotator job can read and change only the Secret `azureadconfig-applicationsecret` and the AuthConfig `azuread`. The chart creates the empty Secret, so the job does not need the right to create Secrets.
- Rancher itself never gets the right to change its own app registration. A stolen Rancher secret is valid for 30 days at most.
- The bootstrap password is in the Terraform state. Keep the state in a protected backend, and change the password after the first login.

## Known problems

### Rancher refuses Kubernetes 1.37

The Rancher 2.15 Helm chart has the requirement `kubeVersion: < 1.37.0-0`. Helm refuses to install Rancher on a newer cluster. Use Kubernetes 1.36 until a newer Rancher release supports Kubernetes 1.37.

### Rancher on Talos is not a supported setup of SUSE

SUSE supports the Rancher server on RKE2, K3s and the managed Kubernetes services of the large clouds. Rancher runs on Talos, and the live test of this example worked, but SUSE support may ask you to reproduce a problem on a supported distribution.

### Removing Rancher leaves objects behind

`terraform destroy` uninstalls the Helm releases, but Rancher creates many namespaces, custom resources and webhooks by itself. Helm does not remove these objects. Run the [Rancher resource cleanup script](https://github.com/rancher/rancher-cleanup) after the destroy if you want to keep using the cluster.

### A changed group list needs one more job run

The Rancher global role bindings for the groups change with `terraform apply` at once. The list of allowed principals of Rancher changes when the job runs after the apply. The apply waits for the job, so both changes are done when `terraform apply` ends.

### Nested groups do not count for the app assignment

Entra ID only lets direct members of an assigned group log in. A person who is a member of a group inside an assigned group gets an error from Entra ID. Rancher itself would see the nested membership, but the person never reaches Rancher. Assign the groups that people are direct members of.

### The first apply can fail while Rancher is still starting

Rancher installs its own admission webhook a few minutes after Rancher starts. If the webhook is not ready when the chart creates the global role bindings, the apply fails with a webhook error. Run `terraform apply` again. The live test on 2026-11-06 did not hit this problem.

### Settings from the Rancher user interface

The chart takes over the Secret `cattle-global-data/azureadconfig-applicationsecret` if somebody turned on the Entra ID login in the Rancher user interface before. The job then replaces the settings of the user interface with the settings from Terraform. The client secret that the person typed into the user interface stays valid in Entra ID, because the job only removes its own secrets. Delete that secret in the Entra ID portal under "Certificates & secrets" of the Rancher app registration.
