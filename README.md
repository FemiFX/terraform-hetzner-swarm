# terraform-hetzner-swarm

Terraform for a **role-segmented Docker Swarm cluster on Hetzner Cloud**, with
Cloudflare managed as code (zone, DNS, R2, Turnstile) and Terraform state in an
S3-compatible bucket using native locking — no DynamoDB table.

Extracted from a production deployment. Terraform provisions infrastructure only:
network, firewalls, servers, volumes, DNS. Swarm membership, node labels, database
clustering, and stack deploys are left to configuration management, which is the
right boundary — Terraform is bad at sequencing a cluster join and worse at
re-running it idempotently.

## What it builds

```
                      Cloudflare (proxied, origins hidden)
                                   │
                        A records round-robin
                                   │
        ┌──────────────────────────┼──────────────────────────┐
        │                          │                          │
   ┌─────────┐                ┌─────────┐                ┌─────────┐
   │  app-1  │                │  app-2  │                │  app-3  │   role=manager
   │ public  │                │ public  │                │ public  │   fw: 22,80,443
   └────┬────┘                └────┬────┘                └────┬────┘   + swarm ports
        │                          │                          │
════════╪══════════════════════════╪══════════════════════════╪════════
        │        private network (east-west only, no NAT)      │
════════╪══════════════════════════╪══════════════════════════╪════════
        │                          │                          │
   ┌────┴────┐   ┌──────────┐  ┌───┴──────┐  ┌──────────┐  ┌──┴───────┐
   │worker-1 │   │   db-1   │  │   db-2   │  │db-monitor│  │  volumes │
   │no public│   │no public │  │no public │  │no public │  │  (db-*)  │
   └─────────┘   └──────────┘  └──────────┘  └──────────┘  └──────────┘
    fw: gossip    fw: 5432 from subnet only, SSH only otherwise
    + overlay
```

Egress for the private-only nodes goes back out through a manager acting as a NAT
gateway (see below — this is the part that surprises people).

## Three role-scoped firewalls, not one

Every node gets exactly the ingress its role needs:

| Firewall | Roles | Inbound |
|---|---|---|
| `app` | `manager` | 22 (restricted CIDR), 80/443 (Cloudflare ranges by default), Swarm 2377/7946 tcp+udp, overlay 4789 udp — **all Swarm ports from the private subnet only** |
| `worker` | `worker` | 22, gossip 7946, overlay 4789. **No 2377** (workers don't accept control-plane connections) and no public web |
| `internal` | `database`, `monitor` | 22, and the database port **from the private subnet only** — never from the internet |

Outbound is unrestricted (Hetzner treats "no `out` rules" as allow-all).

## Four things worth knowing

**1. A Hetzner server with no public IPv4 has no internet at all.**
Attaching it to a private network gives east-west connectivity only — there is no
implicit NAT. Without a default route it cannot reach apt or Docker repos, and
cloud-init fails on it. `hcloud_network_route.internet` programs Hetzner's routing
fabric to send `0.0.0.0/0` at a designated gateway node.

The route alone isn't enough: that gateway node also needs
`net.ipv4.ip_forward=1` and an iptables `MASQUERADE` rule. Those belong in
configuration management — this module sets `nat_gateway_node` and leaves a note.

**2. The private network must be attached inline, at create time.**
Using a separate `hcloud_server_network` resource attaches too late: a
`public = false` server has no NIC to boot with, and Hetzner refuses with
*"no public or private network interfaces found, cannot start server."* Hence the
inline `network { }` block in `hcloud_server.node`.

**3. The private-network gateway is the first host of the NETWORK range, not the subnet.**
With `network_ip_range = 10.10.0.0/16` and `subnet_ip_range = 10.10.1.0/24`, the
gateway is `10.10.0.1` — not `10.10.1.1`. Easy to get wrong, and the failure looks
like a routing problem rather than an addressing one.

**4. `for_each` keys may never be unknown at plan time.**
The Cloudflare DNS records fan out over
`setproduct(hostnames, manager_node_keys)`. Both halves come from static config,
so the key set resolves at plan time; the server's public IP — unknown until apply
— lives only in the map *value*. Keying on the IP instead produces
*"Invalid for_each argument: the for_each map includes keys derived from resource
attributes that cannot be determined until apply."*

## Cloudflare as code

- **Zone created by Terraform**, which then hands you the nameservers to set at
  your registrar (`terraform output cloudflare_nameservers`). Nothing resolves
  through Cloudflare until that NS change — so every record can be created in
  advance and the cutover is a single registrar edit.
- **Proxied A records**, one per public manager, so traffic round-robins and the
  origin IPs stay hidden. `ttl = 1` is mandatory for proxied records; Cloudflare
  rejects any other value.
- **`web_ingress_cidrs` defaults to Cloudflare's published ranges**, so origins
  won't answer traffic that bypasses the proxy. Refresh them periodically from
  <https://www.cloudflare.com/ips/> — they do change.
- **R2 buckets carry `prevent_destroy`**, because a `terraform destroy` on this
  state would otherwise take production objects with it.
- **Turnstile provisioned as a resource**, so the site key and secret stop being
  hand-copied values that drift between environments. Note the caveat: the secret
  lands in Terraform state.

`manage_cloudflare` gates all of it. The zone and buckets are **singletons shared
across environments**, so enable it in exactly one environment's state.

## State backend

Cloudflare R2 (or any S3-compatible store) with Terraform 1.10+
`use_lockfile = true` — locking via conditional PUT, which means **no DynamoDB
table to provision, pay for, or forget about**. Partial backend config keeps one
codebase across environments:

```bash
terraform init -backend-config=env/prod.backend.hcl
terraform apply -var-file=env/prod.tfvars
```

The four `skip_*_validation` flags in the backend config are required for any
non-AWS S3-compatible backend — they disable checks that call AWS-only APIs.

## Requirements

- Terraform ≥ 1.10 (for `use_lockfile`)
- `HCLOUD_TOKEN` in the environment
- `CLOUDFLARE_API_TOKEN` (Zone:Read+Edit, DNS:Edit, Workers R2 Storage:Edit) when
  `manage_cloudflare = true`
- `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` for the state bucket
- An SSH key already uploaded to the Hetzner project, referenced by name

## Usage

```bash
cp env/example.backend.hcl env/prod.backend.hcl
cp env/example.tfvars      env/prod.tfvars
$EDITOR env/prod.backend.hcl env/prod.tfvars    # both gitignored

export HCLOUD_TOKEN=...
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=...

terraform init -backend-config=env/prod.backend.hcl
terraform plan  -var-file=env/prod.tfvars
terraform apply -var-file=env/prod.tfvars
```

Then hand the fleet to configuration management:

```bash
terraform output -json ansible_inventory_hint
terraform output -json swarm_managers
terraform output -json docker_node_labels
```

`env/example.minimal.tfvars` is a two-VM variant for validating wiring cheaply
before committing to the full fleet.

### Provider lock file

`.terraform.lock.hcl` is committed with checksums for `darwin_arm64`,
`linux_amd64` and `linux_arm64` — so a laptop and a CI runner resolve identical
provider builds. A lock file generated on only one platform makes `terraform init`
fail on the others with a checksum mismatch. To add a platform:

```bash
terraform providers lock -platform=windows_amd64
```

## Key variables

| Variable | Default | Notes |
|---|---|---|
| `name` | `myapp` | Prefix for all resource names |
| `environment` | *required* | Drives names + labels |
| `nodes` | *required* | The fleet; `role` ∈ `manager`/`worker`/`database`/`monitor` (validated) |
| `nat_gateway_node` | `""` | Node key that NATs egress for private-only nodes |
| `ssh_allowed_cidrs` | `0.0.0.0/0` | **Tighten before prod** |
| `web_ingress_cidrs` | Cloudflare ranges | Set to `0.0.0.0/0` to test without the proxy |
| `network_ip_range` | `10.10.0.0/16` | Gateway = first host of *this*, not the subnet |
| `subnet_ip_range` | `10.10.1.0/24` | Source range for private-only firewall rules |
| `database_port` | `5432` | Opened on `database`/`monitor` from the subnet only |
| `manage_cloudflare` | `false` | Enable in exactly one environment |
| `app_hostnames` | `["www"]` | Apex added automatically; `*.label` for wildcards |
| `r2_buckets` | `[]` | `prevent_destroy` is set on each |

## Not included

- **Swarm init/join, node labels, stack deploy.** Deliberate — see above.
- **The NAT gateway's iptables/sysctl config.** Terraform programs the route;
  the host-side rule is configuration management's job.
- **TLS certificates.** Handled at the reverse-proxy layer inside the cluster.
- **Postgres itself.** Pairs with
  [ansible-postgres-autofailover](https://github.com/FemiFX/ansible-postgres-autofailover),
  which expects exactly this `database` + `monitor` node layout.

## Licence

MIT — see [LICENSE](LICENSE).
