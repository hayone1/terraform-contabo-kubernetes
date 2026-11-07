terraform {
  required_version = ">= 1.9.0"

  required_providers {
    contabo = {
      source  = "hayone1/contabo"
      version = ">= 0.3.4, < 0.4.0"
    }
    headscale = {
      source  = "awlsring/headscale"
      version = ">= 0.5.1, < 0.6.0"
    }
  }
}

# The provider reads the Contabo API credentials from the environment
# variables CNTB_OAUTH2_CLIENT_ID, CNTB_OAUTH2_CLIENT_SECRET, CNTB_OAUTH2_USER
# and CNTB_OAUTH2_PASS.
provider "contabo" {}

# The provider reads a Headscale API key from the environment variable
# HEADSCALE_API_KEY. Create the key on the Headscale server with
# "headscale apikeys create --expiration 90d".
provider "headscale" {
  endpoint = var.headscale_url
}
