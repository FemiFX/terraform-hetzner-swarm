# Terraform state backend — any S3-compatible store.
#
# Copy to prod.backend.hcl / staging.backend.hcl (both gitignored) and fill in
# your own bucket and endpoint, then:
#   terraform init -backend-config=env/prod.backend.hcl
#
# Credentials come from the environment:
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
# For Cloudflare R2 those are an R2 API token's access key id + secret.
#
# One bucket, one key per environment => isolated state, shared codebase.

bucket = "CHANGE_ME-tfstate"
key    = "prod/terraform.tfstate"
region = "auto"

# Cloudflare R2 endpoint. Replace <ACCOUNT_ID> with your Cloudflare account ID.
#   R2      : https://<ACCOUNT_ID>.r2.cloudflarestorage.com
#             (add a jurisdiction prefix if your bucket has one, e.g. .eu.)
#   MinIO   : https://minio.example.com
#   Real S3 : omit the endpoints block entirely
endpoints = { s3 = "https://<ACCOUNT_ID>.r2.cloudflarestorage.com" }

# Native state locking via conditional PUT (writes a .tflock object). Terraform
# 1.10+ only — this is what removes the need for a DynamoDB lock table.
use_lockfile = true

# Required for non-AWS S3-compatible backends: these checks call AWS-only APIs.
skip_credentials_validation = true
skip_region_validation      = true
skip_metadata_api_check     = true
skip_requesting_account_id  = true
