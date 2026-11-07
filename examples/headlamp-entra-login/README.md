# Example: Headlamp with Entra ID login

This example installs [Headlamp](https://headlamp.dev), a web user interface for Kubernetes, and puts a Microsoft Entra ID login in front of Headlamp. People log in with their Entra ID account. Kubernetes then applies RBAC to each person, so every person sees only what their Entra ID groups allow.

The example needs no client secret. The login proxy proves its identity to Entra ID with the token of its Kubernetes service account. This feature is called workload identity, and the module `modules/workload-identity` of this repository sets workload identity up.

## How the login works

A request travels through four parts:

1. The browser opens `https://headlamp.example.com`. The ingress controller sends the request to oauth2-proxy.
2. oauth2-proxy is a login proxy. oauth2-proxy sends a person without a session to the Entra ID login page.
3. Entra ID sends the person back with a one-time code. oauth2-proxy exchanges the code for an ID token. An ID token is a signed text that names the person and the person's groups. For the exchange, oauth2-proxy shows Entra ID its Kubernetes service account token instead of a client secret.
4. oauth2-proxy passes the ID token to Headlamp in the header `X-Forwarded-Id-Token`. Headlamp sends the ID token to the Kubernetes API server with every request.
5. The API server checks the ID token against Entra ID, and the API server turns the token into a Kubernetes user. RBAC decides what the user may do.

Headlamp's own service account has no permissions. Headlamp always acts with the token of the person who uses Headlamp.

## What the example creates

In Entra ID:

- An app registration named `Headlamp (<hostname>)`. People log in to this app registration.
- A federated credential on the app registration. The federated credential trusts the service account `headlamp/oauth2-proxy` of your cluster.
- An assignment of each admin group and viewer group to the app. Entra ID refuses the login of everybody who is not in an assigned group.
- Admin consent for the scopes `openid`, `profile`, `email`, `offline_access` and `User.Read`, so that nobody sees a consent prompt.

In Kubernetes:

- The namespace `headlamp` with the Pod Security level `restricted`.
- Headlamp and oauth2-proxy, both from their official Helm charts.
- An Ingress for oauth2-proxy with a TLS certificate from cert-manager.
- A network policy that lets only oauth2-proxy reach Headlamp.
- A ClusterRoleBinding to `cluster-admin` for every admin group, and to `view` for every viewer group.

## What you need

- A cluster with the module `modules/workload-identity` and the Azure workload identity webhook (`azure.enabled = true`).
- Kubernetes 1.34 or newer. The API server needs the structured authentication configuration, which became stable in Kubernetes 1.34.
- An ingress controller, for example Traefik, and a cert-manager ClusterIssuer that issues publicly trusted certificates.
- A DNS record that points the host name to the ingress controller.
- An Entra ID group for the administrators. You can create the group with the `azuread_group` resource.
- An Azure CLI login (`az login`) or other `azuread` provider credentials with the right to create app registrations and to grant admin consent. The Entra ID role "Cloud Application Administrator" is enough.

## Use the example

1. Copy `terraform.tfvars.example` to `terraform.tfvars`, and fill in the values.
2. Run `terraform init` and `terraform apply`. Terraform creates the Entra ID objects and installs Headlamp and oauth2-proxy.
3. Add the `talos_config_patch` output to the configuration of every control plane node. The patch makes the API server trust the ID tokens of the app registration. Talos applies the patch without a reboot.

   ```sh
   terraform output -raw talos_config_patch > headlamp-auth.yaml
   talosctl -n <control plane IP> patch machineconfig --patch @headlamp-auth.yaml
   ```

   If your cluster is not a Talos cluster, give the `authentication_configuration_yaml` output to kube-apiserver with the flag `--authentication-config`. Remove the flag `--anonymous-auth` at the same time, because kube-apiserver refuses to start when both the flag and the `anonymous` block of the file are set.

4. Open the `url` output in a browser, and log in as a member of an admin group.

The patch must be part of the configuration that builds your cluster. Otherwise the next configuration change removes the patch again. The main module of this repository will take the authenticator as an input later.

## How Kubernetes names Entra ID users and groups

The API server builds the Kubernetes user from claims in the ID token. A claim is one named value inside the token.

| Kubernetes field | Value | Example |
|---|---|---|
| User name | `entra:` and the object ID of the person | `entra:73ee4a6e-05c9-4193-8fba-e839cab716bf` |
| Groups | `entra:` and the object ID of each group | `entra:3d1c5a7e-9b2f-4c1d-8e6a-5f0b2c4d6e8f` |
| Extra field `entra.microsoft.com/preferred-username` | The login name of the person | `ana@example.com` |

The example uses object IDs and not names. A person or an administrator can change a name or an email address, but an object ID never changes. RBAC that depends on a name could therefore give access to the wrong person.

To give a group access to one namespace only, bind a Role to the group name:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: billing-team-edit
  namespace: billing
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: edit
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: entra:3d1c5a7e-9b2f-4c1d-8e6a-5f0b2c4d6e8f
```

Assign the same group to the app registration as well. Otherwise Entra ID refuses the login of the group members, and the ID token does not list the group.

## Log in with kubectl

Set `kubectl_login = true` to use the same app registration with kubectl. The app registration then also accepts the [kubelogin](https://github.com/int128/kubelogin) plugin, which logs in without a secret. kubelogin opens a browser and receives the answer of Entra ID on `http://localhost:8000`. The device code flow (`--grant-type=device-code`) does not work, because the example keeps the public client fallback of the app registration off. The fallback would also allow logins with a password, which skip the browser checks of Entra ID. The `kubectl_user_exec` output contains the user entry for your kubeconfig file.

```sh
kubectl krew install oidc-login
kubectl config set-credentials entra --exec-api-version=client.authentication.k8s.io/v1 \
  --exec-command=kubectl \
  --exec-arg=oidc-login --exec-arg=get-token \
  --exec-arg=--oidc-issuer-url=https://login.microsoftonline.com/<tenant ID>/v2.0 \
  --exec-arg=--oidc-client-id=<client_id output> \
  --exec-arg=--oidc-extra-scope=profile --exec-arg=--oidc-extra-scope=offline_access \
  --exec-arg=--oidc-pkce-method=S256
kubectl --user=entra get nodes
```

## Inputs

| Name | What the input does | Default |
|---|---|---|
| `kubeconfig_path`, `kubeconfig_context` | The kubeconfig file and context for Terraform. | none, current context |
| `tenant_id` | The Entra ID tenant of the people who log in. | none |
| `issuer_url` | The service account issuer of the cluster, from the `issuer_url` output of the workload identity module. | none |
| `hostname` | The public host name of Headlamp. | none |
| `ingress` | The ingress class, the cert-manager ClusterIssuer, extra Ingress annotations, and the addresses that may set `X-Forwarded-*` headers (`trusted_proxy_cidrs`). | none, `trusted_proxy_cidrs` is `["10.244.0.0/16"]` |
| `admin_group_object_ids` | Entra ID groups with the `cluster-admin` role. | `[]` |
| `viewer_group_object_ids` | Entra ID groups with the `view` role. | `[]` |
| `kubectl_login` | Whether kubelogin may use the app registration. | `false` |
| `claim_prefix` | The prefix of Kubernetes user and group names. | `"entra:"` |
| `namespace` | The namespace of Headlamp and oauth2-proxy. | `"headlamp"` |
| `app_display_name` | The name of the app registration. | `"Headlamp (<hostname>)"` |
| `session` | How long a login lasts (`expire`) and how often oauth2-proxy gets a new token (`refresh`). | `8h` and `30m` |
| `chart_versions` | The Helm chart versions of Headlamp and oauth2-proxy. | `0.46.0` and `10.7.2` |

## Outputs

| Name | What the output contains |
|---|---|
| `url` | The address of Headlamp. |
| `client_id` | The client ID of the app registration. The API server expects this value as the token audience. |
| `talos_config_patch` | A Talos `KubeAuthenticationConfig` document for the control plane nodes. |
| `jwt_authenticator` | The Entra ID authenticator alone, for clusters that already have other authenticators. |
| `authentication_configuration_yaml` | A complete authentication configuration file for other Kubernetes distributions. |
| `kubectl_user_exec` | The kubeconfig user entry for kubelogin, or null. |

## Security notes

- Only oauth2-proxy may reach Headlamp. Headlamp trusts the identity headers of every request, so a pod that talks to Headlamp directly could pretend to be another person in the user interface. The API server still checks the ID token, so a forged header gives no extra Kubernetes permissions. The network policy closes this gap, but only with a network plugin that enforces network policies, such as Cilium.
- oauth2-proxy removes the identity headers that a browser sends, and oauth2-proxy sets the headers again from the session.
- oauth2-proxy only trusts `X-Forwarded-*` headers from the addresses in `ingress.trusted_proxy_cidrs`. The default is the Talos pod network `10.244.0.0/16`, where the ingress controller pods run. Set the node addresses instead when your ingress controller uses the host network.
- The API server refuses tokens that an app gets for itself (`idtyp` is `app`), because only people should log in.
- The cookie secret of oauth2-proxy is in the Terraform state. Keep the state in a protected backend.

## Known problems

### A person in more than 200 groups

The example puts only the groups that are assigned to the app registration into the ID token. A person can be in thousands of groups, and the ID token stays small. Entra ID lists a group only when the person is a direct member of the assigned group. Membership through a nested group does not count, so assign the groups that people are direct members of.

### A new group needs a new login

The ID token lists the groups at login time. After you add a person to a group, the person must log out and log in again. oauth2-proxy also refreshes the token every 30 minutes by default, and the refresh brings the new groups too.

### A broken authentication configuration stops the API server

kube-apiserver checks the authentication configuration when kube-apiserver starts. A configuration with an error, for example a wrong CEL expression, makes kube-apiserver stop at once. Talos does not check the expressions before Talos applies the patch. The whole cluster API is then down until the configuration is fixed.

The live test of this example hit this problem on 2026-11-06. The first version of the group expression used `claims.groups.map(...)`, and kube-apiserver refused the expression with the error `expression of type 'any' cannot be range of a comprehension`. The example now uses `dyn(claims.groups).map(...)`.

Follow these rules when you change `authentication.tf`:

1. Test every change on a test cluster first.
2. Keep `talosctl` access to the control plane nodes. `talosctl` works while the Kubernetes API is down, and `talosctl` can remove the broken patch.
3. When kube-apiserver does not come back after a change, read the log of kube-apiserver, and apply the configuration again without the patch:

   ```sh
   talosctl -n <control plane IP> logs --namespace cri <kube-apiserver container ID> | tail
   ```

   The command `talosctl -n <control plane IP> containers --namespace cri` lists the container IDs.

### The control plane patch is a separate step

Terraform cannot change the API server from this example, because the control plane configuration belongs to the configuration that builds the cluster. Until you apply the `talos_config_patch` output, every login ends with a Headlamp error page that says that the user is not authorized.

### Headlamp shows only one group

oauth2-proxy sends every group of the person as a separate value of the header `X-Forwarded-Group`. Headlamp reads only the first value, so the user menu of Headlamp shows one group. Permissions do not depend on this header. The API server reads the groups from the ID token, so RBAC sees every group.
