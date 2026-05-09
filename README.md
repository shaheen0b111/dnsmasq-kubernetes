# dnsmasq: Node-Local DNS Caching for Kubernetes

A lightweight, observable DNS caching solution for Kubernetes clusters using dnsmasq.

Every Kubernetes cluster on a public cloud silently depends on the cloud provider's DNS service (Azure DNS at `168.63.129.16`, AWS at `169.254.169.253`). If that service goes down or degrades, DNS latency spikes, queries fail, and the cluster suffers. Every external DNS query adds latency and cost.

This project deploys dnsmasq as a daemon service on every Kubernetes node, providing node-local DNS caching and self-hosted resolution for cluster-critical domains. Two-layer caching (CoreDNS L1 + dnsmasq L2) dramatically reduces upstream DNS load and latency.

## What It Does

- Deploys dnsmasq as a daemon service on every Kubernetes node (port 53)
- Resolves `api.<domain>`, `api-int.<domain>`, and `*.apps.<domain>` locally via address records
- Caches all DNS queries at the node level (TTL-based, configurable cache size)
- Forwards non-cached queries to upstream DNS as usual
- CoreDNS (L1, 10s) + dnsmasq (L2, TTL-based) provides two-layer caching
- Survives upstream DNS outages — cluster infrastructure domains keep resolving

## Architecture

```
┌──────────── Node ────────────┐
│                              │
│  Pod -> CoreDNS Service      │
│          (Cluster DNS)       │
│              |               │
│        CoreDNS Pod           │   <- Layer 1 cache (10s TTL)
│          forwards to         │
│        {$HOST_IP}:53         │
│              |               │
│        dnsmasq daemon        │   <- Layer 2 cache (TTL-based)
│          port 53 (host)      │      address records for cluster domains
│              |               │      forwards to upstream
│        Upstream DNS          │   <- 8.8.8.8, 8.8.4.4
│                              │
└──────────────────────────────┘
```

Each node has its own independent dnsmasq instance. If a node goes down, other nodes are unaffected.

## Quick Start

### Prerequisites

- **Kind (local):** Docker or Podman, `make`
- **Azure:** `az` CLI, `jq`, SSH

### Configuration

All settings are in `config.env`:

```bash
# Shared
CLUSTER_NAME=dnsmasq
DOMAIN=dnsmasq.local
WORKER_COUNT=2

# Kind
CONTAINER_CLI=podman

# dnsmasq
UPSTREAM_DNS="8.8.8.8,8.8.4.4"
CACHE_SIZE=1000
ENABLE_LOGGING=true

# Azure
RESOURCE_GROUP=${CLUSTER_NAME}-rg
LOCATION=eastus
VM_SIZE=Standard_D8s_v5
# ... (see config.env for full list)
```

Edit `config.env` before running any targets.

### Kind (Local Demo)

```bash
# Full lifecycle: create cluster + deploy dnsmasq + verify
make demo

# Prove it survives upstream DNS failure
make demo-failover

# Deploy monitoring (Prometheus + Grafana)
make monitoring

# Tear down
make clean
```

### Azure (Cloud Demo)

```bash
# Full lifecycle: create infra + install k3s + deploy dnsmasq + verify
make azure-demo

# Prove it survives Azure DNS failure (blocks 168.63.129.16)
make azure-failover

# Tear down (double confirms before destroying)
make azure-clean
```

## Make Targets

| Target | Description |
|---|---|
| `make demo` | Full Kind lifecycle (cluster + deploy + verify) |
| `make demo-failover` | Upstream DNS failure simulation (Kind) |
| `make monitoring` | Deploy Prometheus + Grafana |
| `make status` | Show cluster and dnsmasq service status |
| `make clean` | Delete Kind cluster |
| `make azure-demo` | Full Azure lifecycle (infra + k3s + deploy + verify) |
| `make azure-failover` | Azure DNS failure simulation |
| `make azure-status` | Show Azure cluster status |
| `make azure-clean` | Destroy all Azure resources |

Run `make help` for the complete list.

## How It Works

### dnsmasq Configuration

Each node's dnsmasq is configured with:

1. **`api.<domain>`** and **`api-int.<domain>`** resolve to the control-plane IP (API server) via `address=` directives
2. **`*.apps.<domain>`** resolves to the ingress IP (first worker) via wildcard `address=` directive
3. **Everything else** is forwarded to upstream DNS and cached

dnsmasq runs as a daemon service, which means:
- Installed via package manager (not containerized)
- Runs directly on the node with `/usr/sbin/dnsmasq`
- Configured via `/etc/dnsmasq.conf`
- One independent instance per node
- Restarts are handled by the process manager

### Two-Layer Caching

The DNS flow through two cache layers:

1. **Pod query** -> Kubernetes DNS Service (ClusterIP)
2. **CoreDNS** -> Receives query, checks 10s cache (L1)
3. **Cache miss** -> CoreDNS forwards to `{$HOST_IP}:53` (dnsmasq on same node)
4. **dnsmasq** -> Checks TTL-based cache (L2), serves address records for cluster domains
5. **Cache miss** -> dnsmasq forwards to upstream (8.8.8.8)
6. **Response** -> Cached at both layers, returned to pod

### Observability

A custom **dnsmasq-exporter** (Go) runs as a DaemonSet on every node and exports Prometheus metrics:

- **CHAOS TXT queries** — dnsmasq exposes cache stats via DNS (hits, misses, cache size, insertions, evictions). The exporter queries these on each Prometheus scrape.
- **Log file parsing** — tails `/var/log/dnsmasq.log` for query counts by type, forward destinations, and response sources (cached/forwarded/local).

Metrics exported on `:9153`:
- `dnsmasq_up` — dnsmasq responding (1/0)
- `dnsmasq_cache_size`, `dnsmasq_cache_hits_total`, `dnsmasq_cache_misses_total`
- `dnsmasq_cache_insertions_total`, `dnsmasq_cache_evictions_total`
- `dnsmasq_queries_total{type}` — queries by DNS type (A, AAAA, etc.)
- `dnsmasq_forwards_total{to}` — forwards by upstream server
- `dnsmasq_responses_total{source}` — responses by source (cached/forwarded/local)

The monitoring stack (Prometheus + Grafana) provides dashboards and alerting.

## Project Structure

```
.
├── config.env                         # All configuration (edit this)
├── Makefile                           # Kind + Azure + Monitoring targets
├── demo.md                           # Step-by-step presenter guide
├── exporter/                         # dnsmasq Prometheus exporter (Go)
│   ├── main.go                       # CHAOS TXT collector + log parser
│   ├── go.mod                        # Go module
│   ├── go.sum                        # Dependency checksums
│   └── Dockerfile                    # Multi-stage build
├── manifests/
│   └── dnsmasq.conf.template         # dnsmasq config (reference)
├── monitoring/
│   ├── dnsmasq-exporter.yaml         # Exporter DaemonSet (hostNetwork)
│   ├── prometheus.yaml               # Prometheus + alerts + SLO rules
│   ├── grafana.yaml                  # Grafana deployment
│   └── grafana-dashboard.json        # dnsmasq observability dashboard
├── scripts/                          # Kind scripts
│   ├── common.sh                     # Shared utilities
│   ├── setup-kind.sh                 # Create Kind cluster
│   ├── deploy-dnsmasq.sh            # Deploy dnsmasq to Kind nodes
│   ├── verify-dns.sh                # 7-test verification suite
│   ├── demo-failover.sh             # Upstream failure simulation
│   └── deploy-monitoring.sh         # Build exporter + deploy stack
└── azure/                           # Azure scripts
    ├── setup-azure.sh               # Create Azure infrastructure
    ├── install-k3s.sh               # Install k3s on VMs
    ├── deploy-dnsmasq-azure.sh      # Deploy dnsmasq to Azure VMs
    ├── verify-dns-azure.sh          # Verification via SSH
    ├── demo-failover-azure.sh       # Azure DNS failure simulation
    └── teardown-azure.sh            # Destroy Azure resources
```

## Use Cases

- **High-traffic clusters** — reduce external DNS queries and latency
- **Cost optimization** — minimize cloud DNS query costs
- **Regulated industries** (DORA, NIS2) requiring DNS resilience
- **Air-gapped clusters** with limited external DNS access
- **Edge / telco** deployments with unreliable connectivity
- **Multi-cloud** environments needing consistent DNS caching
- **Security-conscious** teams wanting to reduce DNS metadata exposure

## Technology

- [dnsmasq](https://thekelleys.org.uk/dnsmasq/doc.html) — Lightweight DNS forwarder and cache
- [CoreDNS](https://coredns.io/) — Kubernetes cluster DNS
- [Kubernetes](https://kubernetes.io/) — Container orchestration
- [Prometheus](https://prometheus.io/) — Metrics and observability
- [k3s](https://k3s.io/) — Lightweight Kubernetes (Azure path)
