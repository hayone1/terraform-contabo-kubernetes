# Plan-only tests of the root module with mocked providers. They need no
# Contabo account, no cluster and no network. Run them with "terraform test"
# in the repository root. The tests need Terraform 1.11 or newer
# (override_during).

mock_provider "contabo" {
  # The mocked values are known during the plan, so the Talos configuration
  # of every node can be checked.
  override_during = plan

  mock_resource "contabo_instance" {
    defaults = {
      id          = "100"
      status      = "running"
      region      = "EU"
      cancel_date = ""
      ip_config = [{
        v4 = [{ ip = "203.0.113.10", gateway = "203.0.113.1", netmask_cidr = 24 }]
        v6 = []
      }]
    }
  }
  mock_resource "contabo_private_network" {
    defaults = {
      id   = "7"
      cidr = "10.0.0.0/22"
      instances = [{
        instance_id       = 100
        private_ip_config = [{ v4 = [{ ip = "10.0.0.5", gateway = "10.0.0.0", netmask_cidr = 22 }] }]
      }]
    }
  }
  mock_data "contabo_private_network" {
    defaults = {
      id   = "12345"
      cidr = "10.0.0.0/22"
      instances = [{
        instance_id       = 100
        private_ip_config = [{ v4 = [{ ip = "10.0.0.3", gateway = "10.0.0.0", netmask_cidr = 22 }] }]
      }]
    }
  }
  mock_resource "contabo_secret" {
    defaults = { id = "42" }
  }
}

mock_provider "talos" {
  override_during = plan

  mock_resource "talos_image_factory_schematic" {
    defaults = { id = "376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba" }
  }
}

mock_provider "helm" {
  mock_data "helm_template" {
    defaults = { manifest = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: test\n" }
  }
}

# terraform_data.bootstrap_node only knows its output after the apply.
override_resource {
  target          = terraform_data.bootstrap_node
  override_during = plan
  values          = { output = "cp-1" }
}

mock_provider "http" {}
mock_provider "random" {}
mock_provider "tls" {}

variables {
  cluster_name = "test"
  control_plane_pools = [{
    name       = "cp"
    product_id = "V91"
    count      = 1
  }]
  admin_access = {
    cidrs             = ["198.51.100.7/32"]
    include_runner_ip = false
  }
}

run "single_node_cluster" {
  command = plan

  assert {
    condition     = keys(contabo_instance.node) == ["cp-1"]
    error_message = "A pool with count = 1 must create the node cp-1."
  }
  assert {
    condition     = contabo_instance.node["cp-1"].display_name == "test-cp-1"
    error_message = "The node name must be <cluster>-<pool>-<key>."
  }
  assert {
    condition     = contabo_instance.node["cp-1"].cancel_on_destroy && contabo_instance.node["cp-1"].product_id == "V91"
    error_message = "A new instance must use the product of the pool and be cancelled on destroy."
  }
  assert {
    condition     = length(contabo_private_network.this) == 1 && length(contabo_firewall.this) == 1
    error_message = "The module must create a private network and a firewall by default."
  }
  assert {
    condition     = length(contabo_instance_reinstall.node) == 1
    error_message = "A new instance must be installed again after it joins the private network."
  }
  assert {
    condition     = length(contabo_instance_vnc.node) == 1
    error_message = "Every node needs a VNC password."
  }
  assert {
    condition     = strcontains(talos_image_factory_schematic.node["cp-1"].schematic, "ip=203.0.113.10::203.0.113.1:255.255.255.0::eth0:off:1.1.1.1:8.8.8.8")
    error_message = "The schematic must carry the network settings of the public interface."
  }
  assert {
    condition     = local.cluster_endpoint == "https://10.0.0.5:6443"
    error_message = "The cluster endpoint must be the private address of the first control plane node."
  }
  assert {
    condition     = local.kubernetes_api_url == "https://203.0.113.10:6443"
    error_message = "The kubeconfig must use the public address of the first control plane node."
  }
  # One node runs the workloads, so the control plane taint must be gone.
  assert {
    condition     = !strcontains(join("\n", local.node_patches["cp-1"]), "NoSchedule")
    error_message = "A cluster without workers must not taint the control plane."
  }
  assert {
    condition     = strcontains(join("\n", local.node_patches["cp-1"]), "\"issuerURL\": \"https://kubernetes.default.svc.cluster.local\"")
    error_message = "Without workload identity, the issuer must not depend on a node address."
  }
  assert {
    condition     = length([for patch in local.node_patches["cp-1"] : patch if strcontains(patch, "\"kind\": \"KubeInlineManifestConfig\"")]) == 3
    error_message = "The control plane must carry Cilium, the Talos CCM and metrics-server as inline manifests."
  }
}

run "workers_get_the_public_ports" {
  command = plan

  variables {
    worker_pools = [{ name = "w", product_id = "V91", count = 2 }]
    public_ports = [80, 443]
  }

  assert {
    condition     = keys(contabo_instance.node) == ["cp-1", "w-1", "w-2"]
    error_message = "The module must create one control plane node and two workers."
  }
  assert {
    condition     = strcontains(join("\n", local.node_patches["cp-1"]), "\"node-role.kubernetes.io/control-plane\": \"NoSchedule\"")
    error_message = "With workers, the control plane must keep its taint."
  }
  assert {
    condition     = !strcontains(join("\n", local.node_patches["cp-1"]), "\"name\": \"public\"")
    error_message = "The control plane must not open the public ports when workers exist."
  }
  assert {
    condition     = strcontains(join("\n", local.node_patches["w-1"]), "\"name\": \"public\"")
    error_message = "The workers must open the public ports."
  }
  assert {
    condition     = !strcontains(join("\n", local.node_patches["w-1"]), "KubeInlineManifestConfig")
    error_message = "Workers must not carry inline manifests."
  }
  assert {
    condition     = local.talos_ops_environment.WORKER_NODES == "10.0.0.5,10.0.0.5"
    error_message = "The health check must know the workers."
  }
}

run "adopted_node_in_existing_network" {
  command = plan

  override_resource {
    target          = terraform_data.bootstrap_node
    override_during = plan
    values          = { output = "cp-a" }
  }

  variables {
    control_plane_pools = [{ name = "cp", existing_instances = { a = "200000001" } }]
    private_network     = { existing_id = "12345" }
    adoption            = { allow_reinstall = true }
  }

  assert {
    condition     = contabo_instance.node["cp-a"].existing_instance_id == "200000001" && !contabo_instance.node["cp-a"].cancel_on_destroy
    error_message = "An adopted instance must not be cancelled on destroy by default."
  }
  assert {
    condition     = length(contabo_private_network.this) == 0
    error_message = "The module must not create a network when existing_id is set."
  }
  assert {
    condition     = local.trusted_cidrs == ["10.0.0.3/32"]
    error_message = "In an existing network, the nodes must only trust the addresses of the nodes."
  }
  assert {
    condition     = length(contabo_instance_reinstall.node) == 1
    error_message = "An adopted instance must be installed again."
  }
}

run "even_control_plane_count" {
  command = plan
  variables {
    control_plane_pools = [{ name = "cp", product_id = "V91", count = 2 }]
  }
  expect_failures = [var.control_plane_pools]
}

run "adoption_needs_permission" {
  command = plan
  variables {
    control_plane_pools = [{ name = "cp", existing_instances = { a = "200000001" } }]
  }
  expect_failures = [terraform_data.validation]
}

run "existing_network_refuses_new_instances" {
  command = plan
  variables {
    private_network = { existing_id = "12345" }
  }
  expect_failures = [terraform_data.validation]
}

run "firewall_off_needs_permission" {
  command = plan
  variables {
    contabo_firewall = { enabled = false }
  }
  expect_failures = [terraform_data.validation]
}

run "storage_vps_is_refused" {
  command = plan
  variables {
    control_plane_pools = [{ name = "cp", product_id = "V93", count = 1 }]
  }
  expect_failures = [terraform_data.validation]
}

run "new_instances_need_a_product" {
  command = plan
  variables {
    control_plane_pools = [{ name = "cp", count = 1 }]
  }
  expect_failures = [terraform_data.validation]
}

run "pool_names_must_be_unique" {
  command = plan
  variables {
    worker_pools = [{ name = "cp", product_id = "V91", count = 1 }]
  }
  expect_failures = [terraform_data.validation]
}

run "node_keys_must_be_unique" {
  command = plan
  variables {
    control_plane_pools = [{ name = "cp", product_id = "V91", count = 1, existing_instances = { "1" = "200000001", "b" = "200000002" } }]
    adoption            = { allow_reinstall = true }
  }
  expect_failures = [terraform_data.validation]
}

run "world_needs_permission" {
  command = plan
  variables {
    admin_access = { cidrs = ["0.0.0.0/0"], include_runner_ip = false }
  }
  expect_failures = [var.admin_access]
}

run "nobody_could_reach_the_cluster" {
  command = plan
  variables {
    admin_access = { include_runner_ip = false }
  }
  expect_failures = [var.admin_access]
}

run "bad_cluster_name" {
  command = plan
  variables {
    cluster_name = "Prod_1"
  }
  expect_failures = [var.cluster_name]
}

run "talos_too_old" {
  command = plan
  variables {
    talos_version = "v1.13.12"
  }
  expect_failures = [var.talos_version]
}

run "talos_ports_cannot_be_public" {
  command = plan
  variables {
    public_ports = [6443]
  }
  expect_failures = [var.public_ports]
}

run "workload_identity_needs_an_issuer" {
  command = plan
  variables {
    workload_identity = { enabled = true }
  }
  expect_failures = [var.workload_identity]
}

run "port_ranges_stay_strings" {
  command = plan

  # Talos refuses a single port written as a string, for example "50001".
  assert {
    condition     = strcontains(join("\n", local.node_patches["cp-1"]), "- 50001\n") && strcontains(join("\n", local.node_patches["cp-1"]), "- \"2379-2380\"")
    error_message = "Single ports must be numbers and port ranges must be strings in the Talos firewall rules."
  }
}

run "labels_taints_and_api_rules" {
  command = plan

  variables {
    worker_pools = [{
      name       = "w"
      product_id = "V91"
      count      = 1
      labels     = { "example.com/tier" = "web" }
      taints     = { dedicated = "db:NoSchedule", spot = "PreferNoSchedule" }
    }]
  }

  assert {
    condition     = strcontains(join("\n", local.node_patches["w-1"]), "\"nodepool\": \"w\"") && strcontains(join("\n", local.node_patches["w-1"]), "\"example.com/tier\": \"web\"")
    error_message = "A worker must get the nodepool label and the pool labels."
  }
  assert {
    condition     = strcontains(join("\n", local.node_patches["w-1"]), "\"key\": \"dedicated\"") && strcontains(join("\n", local.node_patches["w-1"]), "\"value\": \"db\"") && strcontains(join("\n", local.node_patches["w-1"]), "\"effect\": \"PreferNoSchedule\"")
    error_message = "Pool taints must become registerWithTaints entries."
  }
  # Behind the Contabo firewall, the Talos firewall must not lock out a new
  # admin address.
  assert {
    condition     = strcontains(join("\n", local.node_patches["cp-1"]), "\"subnet\": \"0.0.0.0/0\"")
    error_message = "With the Contabo firewall, the Talos firewall must open the API ports."
  }
  assert {
    condition     = local.bootstrap_key == "cp-1"
    error_message = "The first control plane node must bootstrap the cluster."
  }
}

run "talos_firewall_limits_apis_without_contabo_firewall" {
  command = plan

  variables {
    contabo_firewall = { enabled = false }
    installer        = { allow_unprotected_install = true }
  }

  assert {
    condition     = !strcontains(join("\n", local.node_patches["cp-1"]), "\"subnet\": \"0.0.0.0/0\"")
    error_message = "Without the Contabo firewall, the Talos firewall must limit the API ports to admin_access."
  }
}

run "kubelet_cannot_set_kubernetes_io_labels" {
  command = plan
  variables {
    control_plane_pools = [{ name = "cp", product_id = "V91", count = 1, labels = { "contabo.kubernetes.io/pool" = "cp" } }]
  }
  expect_failures = [terraform_data.validation]
}

run "bad_taint_effect" {
  command = plan
  variables {
    control_plane_pools = [{ name = "cp", product_id = "V91", count = 1, taints = { dedicated = "db:Never" } }]
  }
  expect_failures = [terraform_data.validation]
}

run "bootstrap_node_choice_is_the_first_control_plane_node" {
  command = plan

  # The kept value (output) stays "zz-1", while a new choice (input) would be
  # "aa-1".
  override_resource {
    target          = terraform_data.bootstrap_node
    override_during = plan
    values          = { output = "zz-1" }
  }

  variables {
    control_plane_pools = [
      { name = "zz", product_id = "V91", count = 1 },
      { name = "aa", product_id = "V91", count = 2 },
    ]
  }

  assert {
    condition     = terraform_data.bootstrap_node.input == "aa-1"
    error_message = "A new cluster must bootstrap on the first control plane node by name."
  }
  assert {
    condition     = local.cluster_endpoint == "https://10.0.0.5:6443" && local.bootstrap_key == "zz-1"
    error_message = "The kept bootstrap node must stay the cluster endpoint."
  }
}

run "removed_bootstrap_node_stops_the_plan" {
  command = plan

  override_resource {
    target          = terraform_data.bootstrap_node
    override_during = plan
    values          = { output = "old-1" }
  }

  expect_failures = [talos_machine_configuration_apply.node]
}

run "shared_network_excludes_other_servers" {
  command = plan

  override_resource {
    target          = terraform_data.bootstrap_node
    override_during = plan
    values          = { output = "cp-a" }
  }

  variables {
    control_plane_pools = [{ name = "cp", existing_instances = { a = "200000001" } }]
    private_network     = { existing_id = "12345" }
    adoption            = { allow_reinstall = true }
  }

  assert {
    condition     = strcontains(join("\n", local.node_patches["cp-a"]), "\"except\": \"10.0.0.0/22\"")
    error_message = "In an existing network, the open API rule must exclude the private network."
  }
}

run "new_instances_order_private_networking" {
  command = plan

  assert {
    condition     = [for addon in contabo_instance.node["cp-1"].add_ons : addon.id] == ["1477"]
    error_message = "A new instance must order the private networking add-on."
  }
}

run "longhorn_only_on_workers" {
  command = plan

  variables {
    worker_pools = [{ name = "w", product_id = "V91", count = 1 }]
    longhorn     = { enabled = true, ephemeral_max_size = "40GiB" }
  }

  assert {
    condition     = local.longhorn_keys == tolist(["w-1"])
    error_message = "Longhorn must run on the workers when the cluster has workers."
  }
  assert {
    condition     = strcontains(join("\n", local.node_patches["w-1"]), "\"maxSize\": \"40GiB\"") && strcontains(join("\n", local.node_patches["w-1"]), "\"kind\": \"UserVolumeConfig\"")
    error_message = "The workers must get the disk layout of Longhorn."
  }
  assert {
    condition     = !strcontains(join("\n", local.node_patches["cp-1"]), "UserVolumeConfig")
    error_message = "The tainted control plane must not get the disk layout of Longhorn."
  }
  assert {
    condition     = local.node_extensions["w-1"] == tolist(["siderolabs/iscsi-tools", "siderolabs/util-linux-tools"]) && length(local.node_extensions["cp-1"]) == 0
    error_message = "Only the Longhorn nodes need the Longhorn extensions."
  }
  assert {
    condition     = local.longhorn_replica_count == 1
    error_message = "One Longhorn node can only hold one replica."
  }
}

run "gateway_with_certificates_and_dns" {
  command = plan

  variables {
    gateway_api             = { enabled = true, domain = "apps.example.com" }
    cert_manager            = { enabled = true, acme_email = "admin@example.com" }
    external_dns            = { enabled = true }
    contabo_dns_credentials = { client_id = "INT-1", client_secret = "s", api_user = "u@example.com", api_password = "p" }
  }

  override_data {
    target = data.http.gateway_api_crds[0]
    values = { status_code = 200, response_body = "apiVersion: apiextensions.k8s.io/v1\nkind: CustomResourceDefinition\n" }
  }

  assert {
    condition     = local.public_ports == tolist([80, 443])
    error_message = "The Gateway must open the ports 80 and 443."
  }
  assert {
    condition     = local.inline_manifests[0].name == "gateway-api-crds"
    error_message = "The Gateway API CRDs must come before Cilium."
  }
  assert {
    condition     = strcontains(join("\n", local.node_patches["cp-1"]), "\"node.kubernetes.io/ingress\": \"true\"")
    error_message = "The ingress node must get the ingress label."
  }
  assert {
    condition     = strcontains(local.shared_gateway_manifest, "external-dns.kubernetes.io/target") && strcontains(local.shared_gateway_manifest, "\"*.apps.example.com\"")
    error_message = "The shared Gateway must point external-dns to the ingress nodes and cover the wildcard name."
  }
  assert {
    condition     = strcontains(local.cilium_gateway_values, "\"create\": \"true\"")
    error_message = "Cilium must render the GatewayClass, because helm_template cannot ask the cluster."
  }
  assert {
    condition     = local.external_dns_domains == tolist(["apps.example.com"])
    error_message = "external-dns must default to the domain of the Gateway."
  }
}

run "external_dns_needs_credentials" {
  command = plan

  variables {
    external_dns = { enabled = true, domain_filters = ["example.com"] }
  }

  expect_failures = [terraform_data.validation]
}

run "every_node_has_a_removal" {
  command = plan

  variables {
    control_plane_pools = [{ name = "cp", product_id = "V91", count = 3 }]
  }

  assert {
    condition     = keys(terraform_data.node_removal) == ["cp-1", "cp-2", "cp-3"]
    error_message = "Every node must have a removal step."
  }
}

run "tailscale_mode_closes_the_public_kubernetes_api" {
  command = plan

  variables {
    admin_access       = { mode = "tailscale", cidrs = ["198.51.100.7/32"], include_runner_ip = false }
    tailscale          = { tailnet_domain = "tail1234.ts.net", node_agent = { enabled = true } }
    tailscale_auth_key = "tskey-auth-test"
  }

  assert {
    condition     = contains(local.node_extensions["cp-1"], "siderolabs/tailscale")
    error_message = "The control plane node must get the Tailscale extension."
  }
  assert {
    condition     = strcontains(local.tailscale_patches["cp-1"], "TS_USERSPACE=true") && strcontains(local.tailscale_patches["cp-1"], "TS_HOSTNAME=test-cp-1") && strcontains(local.tailscale_patches["cp-1"], "--advertise-tags=tag:k8s-node")
    error_message = "The node agent must run in userspace mode with the node name and the node tags."
  }
  assert {
    condition     = local.kubernetes_api_url == "https://test-cp-1.tail1234.ts.net:6443"
    error_message = "The kubeconfig must use the tailnet name of the first control plane node."
  }
  assert {
    condition     = contains(local.api_cert_sans, "test-cp-1.tail1234.ts.net")
    error_message = "The API server certificate must cover the tailnet name."
  }
  assert {
    condition     = one([for rule in local.firewall_rules["cp-1"] : rule.subnets if rule.name == "kube-apiserver"]) == tolist(["10.0.0.0/22", "10.244.0.0/16"])
    error_message = "The Talos firewall must close the public Kubernetes API in the tailscale mode."
  }
  assert {
    condition     = one([for rule in local.firewall_rules["cp-1"] : rule.subnets if rule.name == "apid"])[0] == "0.0.0.0/0"
    error_message = "The Talos API must stay reachable for the first configuration of new nodes."
  }
  assert {
    condition     = local.kubernetes_api_hosts == "203.0.113.10 test-cp-1.tail1234.ts.net"
    error_message = "The scripts must reach the Kubernetes API through the tailnet names."
  }
  assert {
    condition     = jsondecode(output.tailscale_policy).grants[0].ip == ["tcp:6443", "tcp:50000"]
    error_message = "The policy must let the admins reach both APIs of the nodes."
  }
  assert {
    condition     = length(local.extension_service_documents["cp-1"]) == 1 && startswith(local.extension_service_configs, "203.0.113.10 ")
    error_message = "The upgrade must send the Tailscale configuration before the node restarts with the extension."
  }
}

run "tailscale_mode_needs_the_node_agent" {
  command = plan

  variables {
    admin_access = { mode = "tailscale", cidrs = ["198.51.100.7/32"], include_runner_ip = false }
    tailscale    = { tailnet_domain = "tail1234.ts.net" }
  }

  expect_failures = [terraform_data.validation]
}

run "node_agent_needs_an_auth_key" {
  command = plan

  variables {
    tailscale = { tailnet_domain = "tail1234.ts.net", node_agent = { enabled = true } }
  }

  expect_failures = [terraform_data.validation]
}

run "tailscale_operator_with_rbac" {
  command = plan

  variables {
    tailscale = {
      tailnet_domain = "tail1234.ts.net"
      operator       = { enabled = true, cluster_role_bindings = { "tailnet:cluster-admins" = "cluster-admin", "tailnet:readers" = "view" } }
    }
    tailscale_oauth_client = { client_id = "kTEST", client_secret = "tskey-client-test" }
  }

  assert {
    condition     = contains([for manifest in local.inline_manifests : manifest.name], "tailscale-operator")
    error_message = "The operator must be an inline manifest."
  }
  assert {
    condition     = strcontains(local.tailscale_operator_manifest, "\"name\": \"tailscale:tailnet-readers\"") && strcontains(local.tailscale_operator_manifest, "\"client_id\": \"kTEST\"")
    error_message = "The operator manifest must hold the OAuth Secret and the RBAC bindings."
  }
  assert {
    condition     = length(local.tailscale_keys) == 0 && !contains(local.node_extensions["cp-1"], "siderolabs/tailscale")
    error_message = "The operator alone must not install the node agent."
  }
  assert {
    condition     = output.tailscale.api_server_proxy == "https://test-k8s.tail1234.ts.net"
    error_message = "The proxy address must use the operator hostname."
  }
  assert {
    condition     = jsondecode(output.tailscale_policy).tagOwners["tag:k8s"] == ["tag:k8s-operator"] && length(jsondecode(output.tailscale_policy).grants) == 2
    error_message = "The policy must let the operator own the proxy tag and grant the impersonation."
  }
}

run "backups_of_etcd_and_longhorn" {
  command = plan

  variables {
    longhorn = { enabled = true }
    backups = {
      object_storage_id = "00000000-0000-0000-0000-000000000001"
      bucket            = "test-backups"
      etcd              = { enabled = true, age_public_keys = ["age1ql3z7hjy54pw3hyww5ayyfg7zqgvc7w3j2elw8zmrj2kg5sfn9aqmcac8p"] }
      longhorn          = { enabled = true, retain = 3 }
    }
  }

  override_data {
    target = data.contabo_object_storage.backups[0]
    values = { s3_url = "https://eu2.contabostorage.com", status = "READY" }
  }
  override_data {
    target = data.contabo_object_storage_credentials.backups[0]
    values = { access_key = "AKTEST", secret_key = "SKTEST" }
  }

  assert {
    condition     = local.backup_s3_region == "eu2"
    error_message = "The S3 region must come from the S3 address."
  }
  assert {
    condition     = contains([for manifest in local.inline_manifests : manifest.name], "etcd-backup") && strcontains(local.etcd_backup_manifest, "\"AGE_RECIPIENT_PUBLIC_KEY\"")
    error_message = "The etcd backup must be an inline manifest with encryption."
  }
  assert {
    condition     = strcontains(join("\n", local.control_plane_patches), "os:etcd:backup")
    error_message = "talos-backup needs the Talos role os:etcd:backup."
  }
  assert {
    condition     = strcontains(local.longhorn_backup_values, "s3://test-backups@eu2/longhorn/test/") && strcontains(local.longhorn_manifest, "\"kind\": \"RecurringJob\"")
    error_message = "Longhorn must back up to the bucket on a schedule."
  }
}

run "etcd_backups_need_an_age_key" {
  command = plan

  variables {
    backups = {
      object_storage_id = "00000000-0000-0000-0000-000000000001"
      bucket            = "test-backups"
      etcd              = { enabled = true }
    }
  }

  override_data {
    target = data.contabo_object_storage.backups[0]
    values = { s3_url = "https://eu2.contabostorage.com", status = "READY" }
  }
  override_data {
    target = data.contabo_object_storage_credentials.backups[0]
    values = { access_key = "AKTEST", secret_key = "SKTEST" }
  }

  expect_failures = [terraform_data.validation]
}

run "tailscale_mode_refuses_api_hostname" {
  command = plan

  variables {
    admin_access       = { mode = "tailscale", cidrs = ["198.51.100.7/32"], include_runner_ip = false }
    api_hostname       = "k8s.example.com"
    tailscale          = { tailnet_domain = "tail1234.ts.net", node_agent = { enabled = true } }
    tailscale_auth_key = "tskey-auth-test"
  }

  expect_failures = [terraform_data.validation]
}

run "headscale_gets_its_own_state_and_policy_names" {
  command = plan

  variables {
    tailscale = {
      tailnet_domain = "tailnet.example.com"
      login_server   = "https://headscale.example.com:8443"
      admin_sources  = ["group:k8s-admins"]
      tag_owners     = ["admin@"]
      node_agent     = { enabled = true }
    }
    tailscale_auth_key = "hskey-auth-test"
  }

  assert {
    condition     = strcontains(local.tailscale_patches["cp-1"], "--login-server=https://headscale.example.com:8443") && strcontains(local.tailscale_patches["cp-1"], "TS_STATE_DIR=/var/lib/tailscale/headscale.example.com-8443") && !strcontains(local.tailscale_patches["cp-1"], "--advertise-tags")
    error_message = "The node agent must log in to Headscale with its own state directory."
  }
  assert {
    condition     = jsondecode(output.tailscale_policy).tagOwners["tag:k8s-node"] == ["admin@"] && jsondecode(output.tailscale_policy).grants[0].src == ["group:k8s-admins"]
    error_message = "The policy must use the tag owners and admin sources of the variables."
  }
}

run "tailscale_service_keeps_the_default_state" {
  command = plan

  variables {
    tailscale          = { tailnet_domain = "tail1234.ts.net", node_agent = { enabled = true } }
    tailscale_auth_key = "tskey-auth-test"
  }

  assert {
    condition     = !strcontains(local.tailscale_patches["cp-1"], "TS_STATE_DIR") && jsondecode(output.tailscale_policy).tagOwners["tag:k8s-node"] == ["autogroup:admin"]
    error_message = "The Tailscale service must keep the state directory of the extension and autogroup:admin."
  }
}

run "bad_login_server" {
  command = plan

  variables {
    tailscale = { login_server = "headscale.example.com" }
  }

  expect_failures = [var.tailscale]
}

run "longhorn_v2_on_workers" {
  command = plan

  variables {
    worker_pools = [{ name = "w", product_id = "V8", count = 2 }]
    longhorn     = { enabled = true, v2 = { enabled = true, size = "60GiB" } }
  }

  assert {
    condition     = strcontains(join("\n", local.node_patches["w-1"]), "\"kind\": \"RawVolumeConfig\"") && strcontains(join("\n", local.node_patches["w-1"]), "\"maxSize\": \"60GiB\"")
    error_message = "The Longhorn nodes must get the raw partition of v2."
  }
  assert {
    condition     = strcontains(talos_image_factory_schematic.node["w-1"].schematic, "hugepages=1024") && !strcontains(talos_image_factory_schematic.node["cp-1"].schematic, "hugepages") && length([for patch in local.node_patches["w-1"] : patch if strcontains(patch, "KernelModuleConfig")]) == 4
    error_message = "The Longhorn nodes must get the hugepages and the kernel modules of v2."
  }
  assert {
    condition     = strcontains(join("\n", local.node_patches["w-1"]), "node.longhorn.io/default-disks-config") && strcontains(join("\n", local.node_patches["w-1"]), "\"node.longhorn.io/create-default-disk\": \"config\"")
    error_message = "The Longhorn nodes must get the label and the annotation for the default disks."
  }
  assert {
    condition     = !strcontains(join("\n", local.node_patches["cp-1"]), "RawVolumeConfig")
    error_message = "The control plane must not get the raw partition."
  }
  assert {
    condition     = strcontains(local.longhorn_manifest, "\"dataEngine\": \"v2\"") && strcontains(local.longhorn_manifest, "\"name\": \"longhorn-v2\"")
    error_message = "The manifest must hold the storage class longhorn-v2."
  }
}

run "longhorn_v2_needs_longhorn" {
  command = plan

  variables {
    longhorn = { v2 = { enabled = true } }
  }

  expect_failures = [terraform_data.validation]
}
