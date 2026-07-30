# Copy to prod.tfvars / staging.tfvars (both gitignored) and edit.
#   terraform apply -var-file=env/prod.tfvars

name         = "myapp"
environment  = "prod"
location     = "nbg1"
ssh_key_name = "CHANGE_ME" # name of an SSH key already uploaded to your Hetzner project

# Lock this down before go-live — your operator IP or VPN only.
# 203.0.113.10 is RFC 5737 documentation space; replace it.
# ssh_allowed_cidrs = ["203.0.113.10/32"]

# Which node NATs egress for the private-only nodes. Must be a `public = true`
# node. Leave unset/"" if every node has a public IP.
nat_gateway_node = "app-1"

# --- Cloudflare: zone + DNS + R2. Enable in exactly ONE environment. ---
# Requires CLOUDFLARE_API_TOKEN in the environment (Zone:Edit, DNS:Edit, R2:Edit).
manage_cloudflare     = false
cloudflare_account_id = "" # Cloudflare dashboard → right sidebar
dns_zone_name         = "example.com"

# Hostnames pointed at the app tier. The apex record is added automatically.
# Wildcards are useful when a reverse proxy routes by Host header.
app_hostnames = ["www", "app", "*.app"]

# R2 buckets to create. Keep in sync with whatever names your application uses.
r2_buckets = []

manage_turnstile = false

# --- The fleet ---
# Confirm server_type SKU names in the Hetzner console before the first apply —
# available types differ by location and change over time.
nodes = {
  "app-1" = { server_type = "cx33", role = "manager", private_ip = "10.10.1.11", public = true, swarm = true, swarm_manager = true, labels = ["app"] }
  "app-2" = { server_type = "cx33", role = "manager", private_ip = "10.10.1.12", public = true, swarm = true, swarm_manager = true, labels = ["app"] }
  "app-3" = { server_type = "cx33", role = "manager", private_ip = "10.10.1.13", public = true, swarm = true, swarm_manager = true, labels = ["app"] }

  "worker-1" = { server_type = "cx43", role = "worker", private_ip = "10.10.1.21", public = false, swarm = true, labels = ["batch"] }

  "db-1"       = { server_type = "cx33", role = "database", private_ip = "10.10.1.31", public = false, volume_gb = 40 }
  "db-2"       = { server_type = "cx33", role = "database", private_ip = "10.10.1.32", public = false, volume_gb = 40 }
  "db-monitor" = { server_type = "cx23", role = "monitor", private_ip = "10.10.1.33", public = false }
}
