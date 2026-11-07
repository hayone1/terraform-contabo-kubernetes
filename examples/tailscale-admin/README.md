# Admin access through Tailscale

This example builds a cluster with one control plane node whose Kubernetes API is only reachable through a tailnet, a private network of [Tailscale](https://tailscale.com). The example uses the [Tailscale Terraform provider](https://registry.terraform.io/providers/tailscale/tailscale/latest/docs) to create the credentials that the module needs. Use the example when you want to close the public Kubernetes API, or when admins should log in to Kubernetes with their Tailscale identity.

## What the example creates

- An OAuth client for the Tailscale node agent on the node. The node joins the tailnet with the secret of this client. The secret never expires, so new nodes can join the tailnet at any time.
- An OAuth client for the Tailscale Kubernetes operator. The operator runs the API server proxy, where admins log in with their Tailscale identity.
- The cluster, with `admin_access.mode = "tailscale"`. The Contabo firewall and the Talos firewall close the public Kubernetes API.
- With `manage_tailnet = true`: the whole tailnet policy (tags and grants) and the HTTPS setting of the tailnet.

## What you need

1. Everything that the [module README](../../README.md#what-you-need) lists.
2. A Tailscale API access token in the environment variable `TAILSCALE_API_KEY`. The Tailscale admin console creates tokens on the **Settings > Keys** page. The token belongs to your user, so your user must be an admin of the tailnet.
3. The Tailscale client on the computer that runs Terraform, logged in to the tailnet as an admin. The module runs `kubectl` and `talosctl upgrade-k8s` against the tailnet name of the node.
4. The MagicDNS domain of the tailnet, for example `tail1234.ts.net`. The admin console shows the domain on the **DNS** page.

## Prepare the tailnet

The OAuth clients need their tags in the tailnet policy, and the API server proxy needs HTTPS. Choose one of two ways:

- **Let Terraform own the policy.** Set `manage_tailnet = true`. Terraform then replaces the whole tailnet policy and turns on HTTPS. Save your current policy as JSON without comments, and pass it as `base_policy`, for example `base_policy = file("policy.json")`. The example merges its tags and grants into `base_policy`. Rules that are not in `base_policy` are lost.
- **Change the policy yourself.** Keep `manage_tailnet = false`. Run `terraform plan`, and copy the tags and grants of the output `tailscale_policy` into your policy in the admin console. Turn on HTTPS on the **DNS** page. Then run `terraform apply`.

Turning on HTTPS makes Tailscale publish the names of devices with certificates in the public Certificate Transparency logs. Choose node names that reveal nothing secret.

## Steps

1. Copy `terraform.tfvars.example` to `terraform.tfvars`, and set `product_id` and `tailnet_domain`.
2. Prepare the tailnet (see above).
3. Run `terraform init` and `terraform apply`. The first apply takes 15 to 30 minutes.
4. Save the files:

   ```bash
   terraform output -raw kubeconfig > kubeconfig
   terraform output -raw talosconfig > talosconfig
   ```

   The kubeconfig uses the tailnet name of the node, for example `https://demo-cp-1.tail1234.ts.net:6443`, and works on every computer in the tailnet that the grants let in.

5. Log in through the API server proxy instead, without a kubeconfig file:

   ```bash
   tailscale configure kubeconfig demo-k8s
   kubectl get nodes
   ```

   The proxy passes your Tailscale identity to Kubernetes. The grant in `tailscale_policy` puts the admins of the tailnet into the Kubernetes group `tailnet:cluster-admins`, and the module binds that group to the ClusterRole `cluster-admin`.

## Known problems

- A new installation of a node creates a new device in the tailnet. Delete the old device on the **Machines** page of the admin console before the apply. Otherwise the new device gets a name with a number at the end, and the certificates no longer match the name.
- The Talos API stays open on the public address for the computer that runs Terraform and `admin_cidrs`. A new node gets its first configuration through its public address, before the node joins the tailnet. The Talos API needs a client certificate in any case.
- The OAuth client secrets are in the Terraform state and in the Talos configuration of the node. Protect the state.
- Tailscale hands every connection from the tailnet to the local port of the node, so the tailnet policy is the only filter for tailnet traffic. Remove rules like "everybody may reach everything" from `base_policy`. Otherwise every device of the tailnet reaches every local port of the node.
