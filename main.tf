data "hcloud_ssh_key" "main" {
  name = var.ssh_key_name
}

# ---------------------------------------------------------------------------
# Private network (Swarm control-plane + service-to-service + database traffic)
# ---------------------------------------------------------------------------
resource "hcloud_network" "main" {
  name     = "${var.name}-${var.environment}-net"
  ip_range = var.network_ip_range
}

resource "hcloud_network_subnet" "main" {
  network_id   = hcloud_network.main.id
  type         = "cloud"
  network_zone = var.network_zone
  ip_range     = var.subnet_ip_range
}

# Default route for the private-only nodes, pointing at a manager that NATs their
# traffic out its public interface.
#
# WHY THIS EXISTS: a Hetzner server with no public IPv4 has no internet at all —
# the private network is east-west only, there is no implicit NAT. Without this
# route (plus an iptables MASQUERADE rule on the gateway node, which is a
# configuration-management concern, not a Terraform one) those nodes cannot reach
# apt/Docker repositories and cloud-init fails on them.
resource "hcloud_network_route" "internet" {
  count = var.nat_gateway_node != "" ? 1 : 0

  network_id  = hcloud_network.main.id
  destination = "0.0.0.0/0"
  gateway     = var.nodes[var.nat_gateway_node].private_ip

  depends_on = [hcloud_server.node, hcloud_network_subnet.main]
}

# ---------------------------------------------------------------------------
# Firewalls (one per role). Outbound is unrestricted (no `out` rules => allow).
# Swarm gossip/overlay and the database port are private-subnet only; nothing is
# open on 0.0.0.0/0 except SSH (restrict via ssh_allowed_cidrs) and 80/443 on the
# app nodes.
# ---------------------------------------------------------------------------
resource "hcloud_firewall" "app" {
  name = "${var.name}-${var.environment}-fw-app"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = var.ssh_allowed_cidrs
  }
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = var.web_ingress_cidrs
  }
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = var.web_ingress_cidrs
  }
  # Swarm control-plane + gossip + overlay (private subnet only)
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "2377"
    source_ips = [var.subnet_ip_range]
  }
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "7946"
    source_ips = [var.subnet_ip_range]
  }
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "7946"
    source_ips = [var.subnet_ip_range]
  }
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "4789"
    source_ips = [var.subnet_ip_range]
  }
}

resource "hcloud_firewall" "worker" {
  name = "${var.name}-${var.environment}-fw-worker"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = var.ssh_allowed_cidrs
  }
  # Swarm worker: gossip + overlay only (no inbound 2377, no public web)
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "7946"
    source_ips = [var.subnet_ip_range]
  }
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "7946"
    source_ips = [var.subnet_ip_range]
  }
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "4789"
    source_ips = [var.subnet_ip_range]
  }
}

resource "hcloud_firewall" "internal" {
  name = "${var.name}-${var.environment}-fw-internal"

  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = var.ssh_allowed_cidrs
  }
  # Database (primary/standby) + failover monitor — private subnet only.
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = var.database_port
    source_ips = [var.subnet_ip_range]
  }
}

locals {
  firewall_for = {
    manager  = hcloud_firewall.app.id
    worker   = hcloud_firewall.worker.id
    database = hcloud_firewall.internal.id
    monitor  = hcloud_firewall.internal.id
  }
}

# ---------------------------------------------------------------------------
# Servers (one per var.nodes entry). Cloud-init installs Docker and prepares the
# host only — Swarm membership, node labels, database clustering, and stack
# deploy are left to configuration management after apply.
# ---------------------------------------------------------------------------
resource "hcloud_server" "node" {
  for_each = var.nodes

  name        = "${var.environment}-${each.key}"
  image       = var.image
  server_type = each.value.server_type
  location    = coalesce(each.value.location, var.location)
  ssh_keys    = [data.hcloud_ssh_key.main.id]

  public_net {
    ipv4_enabled = each.value.public
    ipv6_enabled = each.value.public
  }

  # Attach the private network at CREATE time (inline) rather than via a separate
  # hcloud_server_network resource: a private-only server (public=false) has no
  # NIC to boot with until the network is attached, and the standalone resource
  # attaches too late — Hetzner errors "no public or private network interfaces
  # found, cannot start server".
  network {
    network_id = hcloud_network.main.id
    ip         = each.value.private_ip
  }

  firewall_ids = [local.firewall_for[each.value.role]]

  depends_on = [hcloud_network_subnet.main]

  user_data = templatefile("${path.module}/cloud-init/base.yaml.tmpl", {
    hostname = "${var.environment}-${each.key}"
    ssh_user = var.ssh_user
  })

  # Hetzner console labels, for filtering only. Docker node labels — which CAN be
  # a list like ["app","search"] — are exposed via the `docker_node_labels` output
  # and applied by configuration management. Don't cram a list into a Hetzner
  # label value: comma-separated values are rejected by Hetzner's k8s-style label
  # validation rules.
  labels = {
    env   = var.environment
    role  = each.value.role
    swarm = tostring(each.value.swarm)
  }
}

# ---------------------------------------------------------------------------
# Data volumes. Kept off the boot disk so they can be grown or snapshotted
# independently. Mounting and pointing the database at them is a configuration-
# management step.
# ---------------------------------------------------------------------------
resource "hcloud_volume" "data" {
  for_each = { for k, n in var.nodes : k => n if n.volume_gb > 0 }

  name     = "${var.environment}-${each.key}-data"
  size     = each.value.volume_gb
  location = coalesce(each.value.location, var.location)
  format   = "ext4"
}

resource "hcloud_volume_attachment" "data" {
  for_each  = hcloud_volume.data
  volume_id = each.value.id
  server_id = hcloud_server.node[each.key].id
  automount = true
}
