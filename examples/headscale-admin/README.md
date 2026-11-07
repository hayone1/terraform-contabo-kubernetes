# Admin access through Headscale

This example builds a cluster with one control plane node whose Kubernetes API is only reachable through a tailnet of your own [Headscale](https://headscale.net) server. Headscale is a control server for Tailscale clients that you run yourself, instead of the Tailscale service. The example uses the [Headscale Terraform provider](https://registry.terraform.io/providers/awlsring/headscale/latest/docs) to create the pre-auth key that the module needs. Use the example when you want to close the public Kubernetes API and you already run Headscale.

## What the example creates

- A reusable pre-auth key with the tag `tag:k8s-node`. The Tailscale node agent on the node joins the tailnet with the key. Nodes with a tag belong to no Headscale user.
- The cluster, with `admin_access.mode = "tailscale"`. The Contabo firewall and the Talos firewall close the public Kubernetes API.
- With `manage_policy = true`: the whole policy of the Headscale server (groups, tags and grants).

The Tailscale operator and its API server proxy need OAuth clients, which only the Tailscale service offers. The example therefore uses the node agent alone. Admins use the kubeconfig with the tailnet name of the node.

## What you need

1. Everything that the [module README](../../README.md#what-you-need) lists.
2. A Headscale server that the nodes reach on the internet, with a trusted TLS certificate. The example was tested with Headscale 0.29.7.
3. A Headscale API key in the environment variable `HEADSCALE_API_KEY`. Create the key on the Headscale server with `headscale apikeys create --expiration 90d`.
4. The Tailscale client on the computer that runs Terraform, logged in to the Headscale server with a user or a tag that `admin_sources` lets in, for example `tailscale up --login-server https://headscale.example.com`. The module runs `kubectl` and `talosctl upgrade-k8s` against the tailnet name of the node.

## Prepare the Headscale server

- **The domain of the tailnet.** Headscale gives every device a name below `dns.base_domain` (Tailscale calls this MagicDNS). Set `dns.base_domain` in the Headscale configuration, for example `tailnet.example.com`, and pass the same value as `tailnet_domain`. The node then gets the name `demo-cp-1.tailnet.example.com`. The name of the Headscale server must not be below `base_domain`: Headscale refuses `base_domain = example.com` with the server `headscale.example.com`.
- **The policy.** Headscale has no `autogroup:admin`, so the example uses the group `group:k8s-admins` for `admin_sources` and `tag_owners`. Choose one of two ways:
  - **Let Terraform own the policy.** Set `manage_policy = true`, and set `policy.mode: database` in the Headscale configuration. Pass your current policy as JSON without comments in `base_policy`, for example `base_policy = file("policy.json")`. The default `base_policy` puts the Headscale user `admin` into the group. Rules that are not in `base_policy` are lost.
  - **Change the policy yourself.** Keep `manage_policy = false`. Run `terraform plan`, and copy the tags and grants of the output `tailscale_policy` into your policy. Define the group `group:k8s-admins` there too. Then run `terraform apply`.
- **A reverse proxy.** Tailscale clients upgrade their HTTP connection with the protocol `tailscale-control-protocol`. A reverse proxy in front of Headscale must pass this upgrade on. See the [reverse proxy page of Headscale](https://headscale.net/stable/ref/integration/reverse-proxy/).

## Steps

1. Copy `terraform.tfvars.example` to `terraform.tfvars`, and set `product_id`, `headscale_url` and `tailnet_domain`.
2. Prepare the Headscale server (see above).
3. Run `terraform init` and `terraform apply`. The first apply takes 15 to 30 minutes.
4. Save the files:

   ```bash
   terraform output -raw kubeconfig > kubeconfig
   terraform output -raw talosconfig > talosconfig
   ```

   The kubeconfig uses the tailnet name of the node, for example `https://demo-cp-1.tailnet.example.com:6443`, and works on every computer in the tailnet that the grants let in.

## Known problems

- The pre-auth key expires after `key_lifetime`. Nodes that joined the tailnet stay in it, but a new node needs a valid key. Create a new key before you add or reinstall a node: `terraform apply -replace=headscale_pre_auth_key.nodes`.
- A new installation of a node creates a new node in Headscale. Delete the old node with `headscale nodes delete` before the apply. Otherwise the new node gets a name with a number at the end, and the certificates no longer match the name.
- The Talos API stays open on the public address for the computer that runs Terraform and `admin_cidrs`. A new node gets its first configuration through its public address, before the node joins the tailnet.
- The pre-auth key is in the Terraform state and in the Talos configuration of the node. Protect the state.
- Tailscale hands every connection from the tailnet to the local port of the node, so the Headscale policy is the only filter for tailnet traffic. Keep rules like "everybody may reach everything" out of the policy. An empty Headscale policy allows all traffic.
- Version 0.5 of the Headscale provider lists Headscale 0.28 as its supported version. The live test of the module used it with Headscale 0.29.7.
