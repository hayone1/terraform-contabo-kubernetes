terraform {
  required_version = ">= 1.9.0"

  required_providers {
    contabo = {
      source = "hayone1/contabo"
      # 0.3.3 fixes the private network data source
      # (private_network.existing_id). 0.3.4 is the tested release.
      version = ">= 0.3.4, < 0.4.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = ">= 0.12.0, < 0.13.0"
    }
    helm = {
      source = "hashicorp/helm"
      # The module only renders charts (helm_template). It never connects to
      # the cluster through Helm.
      version = ">= 3.1.1, < 4.0.0"
    }
    http = {
      source  = "hashicorp/http"
      version = ">= 3.4.0, < 4.0.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0, < 4.0.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0.0, < 5.0.0"
    }
  }
}
