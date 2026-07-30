# ===========================================================================
# Cloudflare: zone-as-code + DNS records + R2 buckets + Turnstile.
#
# Gated by `manage_cloudflare`. The zone and the R2 buckets are SINGLETONS shared
# across environments, not per-environment resources — so exactly one
# environment's state should own them.
#
# Creating the zone here means Terraform hands you the Cloudflare nameservers to
# set at your registrar (see the `cloudflare_nameservers` output). Nothing
# resolves through Cloudflare until that NS change is made, which is precisely
# why it's safe to create all the records in advance and cut over later.
# ===========================================================================

resource "cloudflare_zone" "main" {
  count = var.manage_cloudflare ? 1 : 0

  account = { id = var.cloudflare_account_id }
  name    = var.dns_zone_name
  type    = "full"
}

locals {
  # Node KEYS of the public app-tier managers, e.g. ["app-1","app-2","app-3"].
  # Derived from var.nodes (static config) so they are known at PLAN time — this
  # matters: for_each map keys may never be unknown-until-apply. The IPs go in the
  # map VALUES instead, where unknown is fine.
  manager_keys = var.manage_cloudflare ? sort([
    for k, n in var.nodes : k
    if n.role == "manager" && n.public
  ]) : []

  # Public IPv4 of every app-tier manager — only known after apply. Safe in values
  # and outputs, never in keys. Records round-robin across them and are proxied,
  # so Cloudflare hides these origins.
  manager_public_ips = [for k in local.manager_keys : hcloud_server.node[k].ipv4_address]

  # The apex record is expressed as the zone name itself; everything else is a
  # bare label or a wildcard.
  app_hostnames = concat([var.dns_zone_name], var.app_hostnames)

  # Keyed "<hostname>::<node-key>" — both halves are static, so the full key set
  # is resolvable at plan time. The apply-time IP lives only in the value.
  app_records = var.manage_cloudflare ? {
    for pair in setproduct(local.app_hostnames, local.manager_keys) :
    "${pair[0]}::${pair[1]}" => {
      name = pair[0]
      ip   = hcloud_server.node[pair[1]].ipv4_address
    }
  } : {}
}

resource "cloudflare_dns_record" "app" {
  for_each = local.app_records

  zone_id = cloudflare_zone.main[0].id
  name    = each.value.name
  type    = "A"
  content = each.value.ip
  # Proxied records must use ttl = 1 ("automatic"); Cloudflare rejects anything else.
  ttl     = 1
  proxied = true
  comment = "managed by terraform"
}

# ---------------------------------------------------------------------------
# Turnstile (bot protection for login / signup / contact forms).
# Provisioning it here means the site key and secret stop being hand-copied
# values that drift between environments.
#
# CAVEAT: `secret` lands in Terraform state. Even with state in a private,
# versioned bucket, treat the state file as sensitive material accordingly.
# ---------------------------------------------------------------------------
resource "cloudflare_turnstile_widget" "main" {
  count = var.manage_cloudflare && var.manage_turnstile ? 1 : 0

  account_id = var.cloudflare_account_id
  name       = "${var.name}-${var.environment}"
  # The widget is valid for these hostnames only. Wildcard entries in
  # app_hostnames are skipped — Turnstile expects concrete hostnames.
  domains = concat(
    [var.dns_zone_name],
    [for h in var.app_hostnames : "${h}.${var.dns_zone_name}" if !startswith(h, "*")],
  )
  mode           = var.turnstile_mode
  bot_fight_mode = false
  region         = "world"
}

# ---------------------------------------------------------------------------
# R2 buckets.
#
# prevent_destroy because these hold production objects: a `terraform destroy`
# on this state would otherwise take the object store with it. Removing a bucket
# from var.r2_buckets will also fail until you delete the lifecycle block — that
# friction is deliberate.
# ---------------------------------------------------------------------------
resource "cloudflare_r2_bucket" "app" {
  for_each = var.manage_cloudflare ? toset(var.r2_buckets) : toset([])

  account_id = var.cloudflare_account_id
  name       = each.value
  location   = var.r2_location

  lifecycle {
    prevent_destroy = true
  }
}
