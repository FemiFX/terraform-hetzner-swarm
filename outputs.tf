output "cloudflare_nameservers" {
  description = <<-EOT
    Set THESE as the zone's nameservers at your registrar to activate Cloudflare.
    Until you do, the records exist but nothing resolves through Cloudflare —
    which is why it's safe to create them in advance and cut over later.
  EOT
  value       = var.manage_cloudflare ? cloudflare_zone.main[0].name_servers : []
}

output "r2_buckets" {
  description = "R2 buckets created."
  value       = var.manage_cloudflare ? [for b in cloudflare_r2_bucket.app : b.name] : []
}

output "dns_records" {
  description = "Hostnames managed in Cloudflare and the origins they round-robin across."
  value = var.manage_cloudflare ? {
    hostnames = local.app_hostnames
    origins   = local.manager_public_ips
  } : {}
}

output "node_public_ipv4" {
  description = "Public IPv4 per node (empty for private-only nodes)."
  value       = { for k, s in hcloud_server.node : k => s.ipv4_address }
}

output "node_private_ip" {
  description = "Private (subnet) IP per node — used for Swarm advertise addresses and database URLs."
  value       = { for k, n in var.nodes : k => n.private_ip }
}

output "swarm_managers" {
  description = "Nodes to init/join as Swarm managers (private IPs)."
  value       = { for k, n in var.nodes : k => n.private_ip if n.swarm_manager }
}

output "swarm_workers" {
  description = "Swarm worker nodes (join, don't manage)."
  value       = { for k, n in var.nodes : k => n.private_ip if n.swarm && !n.swarm_manager }
}

output "docker_node_labels" {
  description = "Intended docker node labels per node, for the configuration-management label step."
  value       = { for k, n in var.nodes : k => n.labels }
}

output "ansible_inventory_hint" {
  description = "Quick copy for an Ansible inventory (ssh_user@public-or-private address)."
  value = {
    for k, s in hcloud_server.node : k => {
      role       = var.nodes[k].role
      ssh_host   = s.ipv4_address != "" ? s.ipv4_address : var.nodes[k].private_ip
      private_ip = var.nodes[k].private_ip
      user       = var.ssh_user
    }
  }
}

output "turnstile_sitekey" {
  description = "Turnstile site key (public)."
  value       = var.manage_cloudflare && var.manage_turnstile ? cloudflare_turnstile_widget.main[0].sitekey : ""
}

output "turnstile_secret" {
  description = "Turnstile secret. Read with: terraform output -raw turnstile_secret"
  value       = var.manage_cloudflare && var.manage_turnstile ? cloudflare_turnstile_widget.main[0].secret : ""
  sensitive   = true
}
