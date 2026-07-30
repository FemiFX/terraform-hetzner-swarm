terraform {
  required_version = ">= 1.10.0" # 1.10+ needed for S3-backend native `use_lockfile`

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = ">= 1.45"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }

  # Partial backend config — the concrete values live in env/<env>.backend.hcl
  # so multiple environments share one codebase but keep separate state keys.
  #   terraform init -backend-config=env/prod.backend.hcl
  # Any S3-compatible store works. Cloudflare R2 is used here because it supports
  # conditional writes, which gives Terraform 1.10+ native state locking with no
  # DynamoDB table to maintain.
  # Credentials come from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY.
  backend "s3" {}
}

# HCLOUD_TOKEN is read from the environment.
provider "hcloud" {}

# CLOUDFLARE_API_TOKEN is read from the environment.
# Token needs: Zone:Read+Edit, DNS:Edit, and Workers R2 Storage:Edit.
provider "cloudflare" {}
