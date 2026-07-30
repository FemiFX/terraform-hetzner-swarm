variable "name" {
  description = "Project prefix for resource names."
  type        = string
  default     = "myapp"
}

variable "environment" {
  description = "Deployment environment (e.g. staging | prod). Drives resource names + labels."
  type        = string
}

variable "location" {
  description = "Default Hetzner location for nodes that don't override it."
  type        = string
  default     = "nbg1"
}

variable "network_zone" {
  description = "Hetzner network zone for the private subnet."
  type        = string
  default     = "eu-central"
}

variable "image" {
  type    = string
  default = "ubuntu-24.04"
}

variable "ssh_key_name" {
  description = "Name of an existing SSH key already uploaded to the Hetzner project."
  type        = string
}

variable "ssh_user" {
  description = "Non-root admin user created by cloud-init. Harden SSH afterwards, from configuration management — not in cloud-init, so a bad sshd change can't lock you out of a fresh VM."
  type        = string
  default     = "ops"
}

variable "ssh_allowed_cidrs" {
  description = "CIDRs allowed to reach port 22. Tighten to your IP/VPN before prod."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "web_ingress_cidrs" {
  description = <<-EOT
    CIDRs allowed to reach 80/443 on the app nodes. Defaults to Cloudflare's
    published ranges, so the origins only accept proxied traffic. Set to
    ["0.0.0.0/0", "::/0"] for direct testing without the proxy in front.
    Refresh from https://www.cloudflare.com/ips/ periodically — these change.
  EOT
  type        = list(string)
  default = [
    # Cloudflare IPv4
    "173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22",
    "141.101.64.0/18", "108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20",
    "197.234.240.0/22", "198.41.128.0/17", "162.158.0.0/15", "104.16.0.0/13",
    "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22",
    # Cloudflare IPv6
    "2400:cb00::/32", "2606:4700::/32", "2803:f800::/32", "2405:b500::/32",
    "2405:8100::/32", "2a06:98c0::/29", "2c0f:f248::/32",
  ]
}

variable "network_ip_range" {
  description = "Private network range. Note the gateway is the FIRST host of this range, not of the subnet."
  type        = string
  default     = "10.10.0.0/16"
}

variable "subnet_ip_range" {
  description = "Subnet the nodes get their private IPs from. Also the source range for all private-only firewall rules."
  type        = string
  default     = "10.10.1.0/24"
}

variable "database_port" {
  description = "Port opened on `database`/`monitor` role nodes, private subnet only."
  type        = string
  default     = "5432"
}

variable "nat_gateway_node" {
  description = <<-EOT
    Node key that acts as the NAT gateway giving private-only nodes outbound
    internet. Hetzner servers with no public IP have NO egress — attaching to a
    private network gives east-west connectivity only. Without this route they
    cannot apt-install anything. Empty string = no route (private nodes offline).

    The route alone is not sufficient: the gateway node also needs an iptables
    MASQUERADE rule and net.ipv4.ip_forward=1, which belong in configuration
    management.
  EOT
  type        = string
  default     = ""
}

variable "swarm_worker_join_token" {
  description = <<-EOT
    Swarm worker join token, ONLY for the cloud-init/swarm-join.yaml.tmpl path used
    to add workers to an already-running cluster. Pass via
    TF_VAR_swarm_worker_join_token — never commit it.
  EOT
  type        = string
  sensitive   = true
  default     = ""
}

# ---------------------------------------------------------------------------
# Cloudflare (zone + DNS + R2). Singletons: have ONE environment's state own them.
# ---------------------------------------------------------------------------
variable "manage_cloudflare" {
  description = "Create/manage the Cloudflare zone, DNS records, and R2 buckets. Enable in exactly one environment — these are shared singletons, not per-environment resources."
  type        = bool
  default     = false
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID (Dashboard → right sidebar). Required when manage_cloudflare=true."
  type        = string
  default     = ""
}

variable "dns_zone_name" {
  description = "Apex domain to manage in Cloudflare."
  type        = string
  default     = "example.com"
}

variable "app_hostnames" {
  description = <<-EOT
    Hostnames pointed at the app tier. Each becomes a proxied A record per public
    manager node, so traffic round-robins across origins. Use the apex domain
    itself for the root record, bare labels for subdomains, and `*.label` for
    wildcards. Wildcards are useful when a reverse proxy routes by Host header
    (e.g. per-tenant subdomains).
  EOT
  type        = list(string)
  default     = ["www"]
}

variable "r2_buckets" {
  description = <<-EOT
    R2 buckets to create. Bucket names are usually referenced by the application
    too — keep the two in sync, or the app will silently fail to find its objects.
  EOT
  type        = list(string)
  default     = []
}

variable "r2_location" {
  description = "R2 location hint. EEUR = Eastern Europe, closest to Hetzner eu-central."
  type        = string
  default     = "EEUR"
}

variable "manage_turnstile" {
  description = "Create a Cloudflare Turnstile widget for bot protection. Requires manage_cloudflare=true."
  type        = bool
  default     = false
}

variable "turnstile_mode" {
  description = "Turnstile challenge mode: managed | non-interactive | invisible."
  type        = string
  default     = "managed"
}

variable "nodes" {
  description = <<-EOT
    The fleet. One entry per VM. `role` selects the firewall and the intended
    workload:
      manager  — Swarm manager, app plane, public (proxy-fronted)
      worker   — Swarm worker, no public IP
      database — off-Swarm database (primary/standby), no public IP, data volume
      monitor  — off-Swarm failover monitor, no public IP
    `swarm`, `swarm_manager` and `labels` are recorded here and surfaced as
    outputs, but are APPLIED by configuration management, not by Terraform.
  EOT
  type = map(object({
    server_type   = string
    role          = string
    private_ip    = string
    location      = optional(string)
    public        = optional(bool, false)
    swarm         = optional(bool, false)
    swarm_manager = optional(bool, false)
    labels        = optional(list(string), [])
    volume_gb     = optional(number, 0)
  }))

  validation {
    condition     = alltrue([for n in var.nodes : contains(["manager", "worker", "database", "monitor"], n.role)])
    error_message = "Each node's role must be one of: manager, worker, database, monitor."
  }
}
