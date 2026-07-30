# A deliberately small variant: two VMs, no HA, no Cloudflare proxy. Useful for
# validating wiring cheaply before spending on the full fleet.
#
#   app-1 : single Swarm manager carrying every workload label
#   db-1  : single database node, no failover monitor
#
# Copy to staging.tfvars (gitignored) and edit.

name         = "myapp"
environment  = "staging"
location     = "nbg1"
ssh_key_name = "CHANGE_ME"

# No proxy in front, so open web ingress directly for testing.
web_ingress_cidrs = ["0.0.0.0/0", "::/0"]

nat_gateway_node = "app-1"

# The zone and R2 buckets are singletons owned by the prod state — never enable
# this in a second environment, or two states will fight over the same resources.
manage_cloudflare = false

nodes = {
  "app-1" = { server_type = "cx33", role = "manager", private_ip = "10.10.1.11", public = true, swarm = true, swarm_manager = true, labels = ["app", "batch"] }
  "db-1"  = { server_type = "cx33", role = "database", private_ip = "10.10.1.31", public = false, volume_gb = 20 }
}
