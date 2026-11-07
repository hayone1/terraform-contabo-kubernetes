terraform {
  required_version = ">= 1.9.0"

  required_providers {
    contabo = {
      source  = "hayone1/contabo"
      version = ">= 0.3.4, < 0.4.0"
    }
    tailscale = {
      source  = "tailscale/tailscale"
      version = ">= 0.29.3, < 0.30.0"
    }
  }
}

# The provider reads the Contabo API credentials from the environment
# variables CNTB_OAUTH2_CLIENT_ID, CNTB_OAUTH2_CLIENT_SECRET, CNTB_OAUTH2_USER
# and CNTB_OAUTH2_PASS.
provider "contabo" {}

# The provider reads a Tailscale API access token from the environment
# variable TAILSCALE_API_KEY. The token belongs to a user, and the user must
# be an admin of the tailnet: the policy lets admins own the tags of the new
# OAuth clients, and only admins may change the policy and the settings.
provider "tailscale" {}
