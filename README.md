# dnsmasq on Kubernetes Nodes

Node-level DNS caching for Kubernetes using dnsmasq as a daemon service.

> **📖 For a detailed step-by-step demo with expected outputs, see [DEMO.md](DEMO.md)**

## Overview

This project deploys dnsmasq as a daemon service on every Kubernetes node, providing:
- **Node-local DNS caching** - reduces latency and external DNS queries
- **Two-layer caching architecture** - CoreDNS (L1) + dnsmasq (L2)
- **Upstream DNS resilience** - survives temporary upstream DNS outages
- **Per-node observability** - query logging on each node

## Architecture

```
┌──────────── Node ────────────┐
│                              │
│  Pod → CoreDNS Service       │
│         (Cluster DNS)        │
│             ↓                │
│       CoreDNS Pod            │   ← Layer 1 cache (10s TTL)
│         forwards to          │
│       {$HOST_IP}:53          │
│             ↓                │
│       dnsmasq daemon         │   ← Layer 2 cache (TTL-based)
│         port 53 (host)       │      forwards to upstream
│             ↓                │
│       Upstream DNS           │   ← 8.8.8.8, 8.8.4.4
│                              │
└──────────────────────────────┘
```

**Two-Layer Caching Benefits:**
- **Layer 1 (CoreDNS)**: 10 second cache handles rapid query repeats
- **Layer 2 (dnsmasq)**: TTL-based cache handles longer-term caching and reduces upstream load

## Quick Start

### Prerequisites

- Docker or Podman
- kind >= 0.20.0
- kubectl >= 1.28.0

### Configuration

Edit `config.env`:

```bash
CLUSTER_NAME=dnsmasq-test
WORKER_COUNT=2
CONTAINER_CLI=docker
UPSTREAM_DNS="8.8.8.8,8.8.4.4"
CACHE_SIZE=1000
```

### Run Demo

```bash
# Full lifecycle: create cluster + deploy dnsmasq + verify
make demo

# Show cluster status
make status

# Tear down
make clean
```

**For detailed step-by-step walkthrough with expected outputs, see [DEMO.md](DEMO.md)**

## Make Targets

| Target | Description |
|---|---|
| `make demo` | Full lifecycle (cluster + deploy + verify) |
| `make status` | Show cluster and dnsmasq service status |
| `make clean` | Delete Kind cluster |
| `make prereqs` | Install kind and kubectl |
| `make cluster-up` | Create Kind cluster only |
| `make deploy` | Deploy dnsmasq service only |
| `make verify` | Run DNS verification tests (includes caching) |

Run `make help` for the complete list.

## How It Works

### dnsmasq Configuration

The dnsmasq daemon runs on each node with:
- **Cache size**: Configurable (default: 1000 entries)
- **Upstream DNS**: Multiple servers with automatic failover
- **Query logging**: Optional (configurable via `ENABLE_LOGGING`)
- **Port binding**: Listens on port 53 on all interfaces
- **TCP support**: Required for CoreDNS forwarding with `force_tcp`

### Service Management

dnsmasq runs as a daemon process on each node, which means:
- Installed via package manager (apt-get)
- Runs directly on the node (not containerized)
- Started with `/usr/sbin/dnsmasq`
- Configured via `/etc/dnsmasq.conf`
- One instance per node

### DNS Flow

1. **Pod query** → Kubernetes DNS Service (ClusterIP)
2. **CoreDNS** → Receives query, checks 10s cache
3. **Cache miss** → CoreDNS forwards to `{$HOST_IP}:53` (dnsmasq on same node)
4. **dnsmasq** → Checks TTL-based cache
5. **Cache miss** → dnsmasq forwards to upstream (8.8.8.8)
6. **Response** → Cached at both layers, returned to pod

## Project Structure

```
.
├── config.env                         # All configuration (edit this)
├── Makefile                           # Kind targets
├── README.md                          # This file
├── DEMO.md                            # Step-by-step demo guide
├── PROJECT-STRUCTURE.md               # Structure documentation
├── manifests/
│   └── dnsmasq.conf.template          # dnsmasq configuration template
└── scripts/
    ├── common.sh                      # Shared utilities
    ├── setup-kind.sh                  # Create Kind cluster
    ├── deploy-dnsmasq.sh              # Deploy dnsmasq to nodes
    └── verify-dns.sh                  # Verification tests
```

## Use Cases

- **High-traffic clusters** - reduce external DNS queries and latency
- **Cost optimization** - minimize cloud DNS query costs
- **Network resilience** - survive temporary upstream DNS failures
- **Air-gapped environments** - local DNS caching for limited connectivity
- **Multi-cloud** - consistent DNS caching across providers
- **Development/testing** - realistic DNS caching behavior in local clusters

## Verification Tests

The `make verify` target runs comprehensive tests:

1. **dnsmasq service status** - Verify dnsmasq is running on all nodes
2. **Node DNS resolution** - Each node can resolve external domains
3. **Pod DNS resolution** - Pods can resolve via CoreDNS → dnsmasq
4. **Cache verification** - Queries are cached at dnsmasq layer
5. **Multi-node verification** - dnsmasq works on all nodes

## Observability

dnsmasq provides comprehensive query logging on each node at `/var/log/dnsmasq.log`. Logs show:
- DNS queries received
- Cache hits (`cached <domain>`)
- Cache misses (`forwarded <domain> to <upstream>`)
- Query responses with IPs

**For detailed observability commands and examples, see [DEMO.md](DEMO.md#4-manual-exploration)**

## Technology

- [dnsmasq](https://thekelleys.org.uk/dnsmasq/doc.html) — Lightweight DNS forwarder and cache
- [CoreDNS](https://coredns.io/) — Kubernetes cluster DNS
- [Kubernetes](https://kubernetes.io/) — Container orchestration
- [kind](https://kind.sigs.k8s.io/) — Kubernetes in Docker

## License

Apache 2.0
