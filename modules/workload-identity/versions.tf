terraform {
  required_version = ">= 1.9.0"

  required_providers {
    contabo = {
      source = "hayone1/contabo"
      # 0.3.1 fixes a bucket update that turned public sharing off.
      version = ">= 0.3.1, < 0.4.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }
}
