# dnsmasq on Kubernetes Nodes — Demo Guide

Step-by-step presenter guide for demonstrating node-local DNS caching with dnsmasq.

Two paths available:
- **Part A** — Kind (local, ~10 minutes)
- **Part B** — Azure (cloud VMs, ~20 minutes)

---

## Part A: Kind (Local Demo)

### Step 0: Prerequisites

```bash
# Check prerequisites
make prereqs

# Review configuration
cat config.env
```

Key settings:
- `CLUSTER_NAME=dnsmasq`
- `DOMAIN=dnsmasq.local`
- `WORKER_COUNT=2`
- `CONTAINER_CLI=podman`
- `UPSTREAM_DNS="8.8.8.8,8.8.4.4"`
- `CACHE_SIZE=1000`

### Step 1: Create Cluster

```bash
make cluster-up
```

Creates a Kind cluster with 1 control-plane + 2 workers.

### Step 2: Deploy dnsmasq

```bash
make deploy
```

What happens:
1. Installs dnsmasq on each node container
2. Configures address records for `api.dnsmasq.local`, `api-int.dnsmasq.local`, `*.apps.dnsmasq.local`
3. Starts dnsmasq daemon on each node
4. Updates CoreDNS to forward to dnsmasq via `{$HOST_IP}:53`
5. Reconfigures each node's `/etc/resolv.conf` to use local dnsmasq

### Step 3: Verify DNS

```bash
make verify
```

Runs 7 tests on each node:
1. dnsmasq process running
2. `api.dnsmasq.local` resolves (address record)
3. `api-int.dnsmasq.local` resolves (address record)
4. `myapp.apps.dnsmasq.local` resolves (wildcard address record)
5. `google.com` forwards to upstream
6. dnsmasq caching works (cache hit detected)
7. `/etc/resolv.conf` points to local dnsmasq

### Step 4: Full Demo (Steps 1-3 Combined)

```bash
# Or run everything at once:
make demo
```

### Step 5: Check Status

```bash
make status
```

Shows node status, dnsmasq service on each node, and CoreDNS pods.

### Step 6: Manual Exploration

```bash
# View dnsmasq configuration on a node
podman exec dnsmasq-control-plane cat /etc/dnsmasq.conf

# View dnsmasq logs (cache hits and misses)
podman exec dnsmasq-worker cat /var/log/dnsmasq.log

# Follow live queries
podman exec dnsmasq-worker tail -f /var/log/dnsmasq.log

# Test DNS directly on a node
podman exec dnsmasq-worker dig api.dnsmasq.local @<node-ip>

# Test from a pod
kubectl run testpod --image=busybox:1.36 -- sleep 3600
kubectl exec testpod -- nslookup api.dnsmasq.local

# Check CoreDNS forwarding config
kubectl get cm coredns -n kube-system -o yaml | grep -A 5 "forward"
```

### Step 7: Observe Caching

```bash
# Terminal 1: Watch dnsmasq logs
podman exec dnsmasq-worker tail -f /var/log/dnsmasq.log

# Terminal 2: Make queries — watch "forwarded" vs "cached" in logs
kubectl exec testpod -- nslookup github.com
kubectl exec testpod -- nslookup github.com   # should show "cached"
```

### Step 8: DNS Failover Demo

```bash
make demo-failover
```

Four phases:
1. **Before** — cluster domains AND google.com resolve
2. **Break** — blocks upstream DNS via iptables on all nodes
3. **After** — cluster domains STILL resolve (dnsmasq address records), external FAILS
4. **Restore** — unblocks upstream DNS

### Step 9: Deploy Monitoring

```bash
make monitoring
```

Builds the dnsmasq-exporter image, loads it into Kind, and deploys:
- **dnsmasq-exporter** DaemonSet (hostNetwork, reads /var/log/dnsmasq.log, queries CHAOS TXT records)
- **Prometheus** (scrapes dnsmasq-exporter pods)
- **Grafana** (pre-configured datasource + dnsmasq dashboard)

```bash
# Access Prometheus
make prometheus-ui    # http://localhost:9090

# Access Grafana
make grafana-ui       # http://localhost:3000
```

Grafana dashboard includes:
- Total QPS, Instances Up, Cache Hit Rate, Cache Size
- Availability SLI, Local Resolution Rate, Cache Evictions/s
- Queries by type (A, AAAA, etc.) and by node
- Responses by source (cached / forwarded / local)
- Cache hits vs misses, insertions vs evictions
- Forwards by upstream destination

### Step 10: Generate DNS Traffic

Start the traffic generator to populate dashboards with dense, realistic data:

```bash
make traffic
```

What happens:
1. Forks a background process that continuously sends DNS queries to all nodes
2. Round-robins queries across control-plane + workers
3. Prints periodic stats to a log file

**Traffic categories (per batch, every 2 seconds):**

| Category | Count | What it exercises |
|----------|-------|-------------------|
| Local domains (`api.*`, `*.apps.*`) | 10 | dnsmasq address records, `responses{source=local}`, query types (A/AAAA/MX/TXT) |
| Repeated external (`google.com`, etc.) | 8 | Cache hits, `responses{source=cached}` |
| Unique external (`rnd-N.fwd.test`) | 5 | Cache misses, `forwards_total{to=8.8.8.8}` |
| NXDOMAIN (`nx-N.nxdomain.test`) | 3 | Error responses, ~11% NXDOMAIN rate |
| Cache eviction flood | 0 (opt-in) | Set `TRAFFIC_EVICT_COUNT=50` to trigger evictions |
| Cluster-internal (`kubernetes.default.svc`, etc.) | 3 | Resolved by kube-dns, NOT dnsmasq — shows separation |

Watch the live log:

```bash
tail -f /tmp/dns-traffic-dnsmasq.log
```

Stop the generator:

```bash
make traffic-stop
```

### Step 11: Observe Dense Dashboards

After ~30 seconds of traffic, open the dashboards:

```bash
# Terminal 1:
make grafana-ui       # http://localhost:3000

# Terminal 2:
make prometheus-ui    # http://localhost:9090
```

**In Grafana** — navigate to Dashboards -> dnsmasq dashboard. Panels to highlight:

- **Total QPS** — shows sustained query rate across nodes
- **Responses by Source** — three distinct lines: `local` (address records), `cached` (repeat queries), `forwarded` (external domains). This is the key chart: it shows dnsmasq handling three different query paths.
- **Queries by Type** — A, AAAA, MX, TXT breakdown from the traffic mix
- **Cache Hit Rate** — should be ~69% with default settings (18 hits vs 8 misses per batch)
- **Forwards by Upstream** — shows queries going to `8.8.8.8` and `8.8.4.4`
- **SLI / SLO panels** — availability and local resolution rate targets

### Step 12: Trigger Alerts

Override traffic parameters to deliberately fire specific alerts:

```bash
# First stop the default traffic
make traffic-stop

# Trigger DnsmasqCacheHitRateLow (<50% cache hit rate for 10m):
TRAFFIC_LOCAL_COUNT=2 TRAFFIC_CACHED_COUNT=2 TRAFFIC_FORWARD_COUNT=20 make traffic

# Trigger DnsmasqHighForwardRate (>100 forwards/s for 5m):
# make traffic-stop first, then:
# TRAFFIC_FORWARD_COUNT=30 TRAFFIC_INTERVAL=0.2 make traffic

# Trigger DnsmasqCacheEvictionsHigh (>10 evictions/s for 5m):
# make traffic-stop first, then:
# TRAFFIC_EVICT_COUNT=100 TRAFFIC_INTERVAL=1 make traffic
```

In Prometheus UI -> Alerts, watch the alert state transition from `inactive` -> `pending` -> `firing`.

When done experimenting:

```bash
make traffic-stop
```

### Step 13: Show Cluster-Internal DNS Separation

Demonstrate that Kubernetes service DNS (`.svc.cluster.local`) bypasses dnsmasq entirely and is handled by the default kube-dns CoreDNS:

```bash
# Query a Kubernetes service — resolved by kube-dns, NOT dnsmasq
podman exec dnsmasq-worker dig +short kubernetes.default.svc.cluster.local

# Query a custom domain — resolved by dnsmasq
podman exec dnsmasq-worker dig +short api.dnsmasq.local

# Check dnsmasq logs — the kubernetes.default query does NOT appear
podman exec dnsmasq-worker tail -20 /var/log/dnsmasq.log | grep -c "kubernetes.default" || echo "0 matches — kube-dns handled it"
podman exec dnsmasq-worker tail -20 /var/log/dnsmasq.log | grep "api.dnsmasq" | tail -3
```

The DNS resolution path:
- `kubernetes.default.svc.cluster.local` → CoreDNS (kube-dns) → Kubernetes plugin → ClusterIP answer. **dnsmasq never sees this query.**
- `api.dnsmasq.local` → CoreDNS (kube-dns) → forwards to `{$HOST_IP}:53` → dnsmasq → address record answer. **dnsmasq handles this.**

This proves that dnsmasq only adds a caching and self-hosted resolution layer for infrastructure domains. Native Kubernetes service discovery (`*.svc.cluster.local`) continues to work through kube-dns exactly as before.

### Step 14: Explore Prometheus Metrics

```bash
# In Prometheus UI (http://localhost:9090), try:
dnsmasq_up
dnsmasq_cache_size
dnsmasq_cache_hits_total
dnsmasq_cache_misses_total
dnsmasq_queries_total
dnsmasq_forwards_total
dnsmasq_responses_total
```

### Step 15: Check Alerts

In Prometheus UI -> Alerts:
- `DnsmasqDown` (critical) — dnsmasq not responding for 1m
- `DnsmasqExporterDown` (critical) — exporter unreachable for 1m
- `DnsmasqCacheHitRateLow` (info) — cache hit rate < 50% for 10m
- `DnsmasqCacheEvictionsHigh` (warning) — eviction rate > 10/s for 5m
- `DnsmasqHighForwardRate` (warning) — forward rate > 100/s for 5m
- `DnsmasqNoQueries` (warning) — zero queries for 10m
- `DnsmasqAvailabilitySLOBreach` (critical) — availability < 99.9% for 5m

### Step 16: Cleanup

```bash
make clean
```

---

## Part B: Azure (Cloud Demo)

### Step B0: Prerequisites

```bash
# Azure CLI, jq, SSH
az version
jq --version
ssh -V

# Login to Azure
az login

# Review Azure configuration in config.env
cat config.env
```

### Step B1: Create Infrastructure

```bash
make azure-infra
```

Creates: Resource Group, VNet, Subnet, NSG, Public IPs, VMs.

### Step B2: Install k3s

```bash
make azure-cluster
```

Installs k3s server + agents, fetches kubeconfig.

### Step B3: Deploy dnsmasq

```bash
make azure-deploy
```

Installs dnsmasq on each VM with address records for cluster domains. Configures `/etc/resolv.conf` to use local dnsmasq.

### Step B4: Verify

```bash
make azure-verify
```

Runs 7 tests on each VM via SSH (same as Kind verification).

### Step B5: Failover Demo

```bash
make azure-failover
```

Blocks Azure DNS (168.63.129.16). Cluster domains survive. External domains fail.

### Step B6: Teardown

```bash
make azure-clean
```

Double-confirms, then deletes the entire resource group.

---

## Troubleshooting

### dnsmasq service not starting
```bash
podman exec <node> ps aux | grep dnsmasq
podman exec <node> netstat -ulnp | grep :53
podman exec <node> cat /etc/dnsmasq.conf
podman exec <node> killall dnsmasq && podman exec <node> /usr/sbin/dnsmasq
```

### DNS queries not reaching dnsmasq
```bash
kubectl get cm coredns -n kube-system -o yaml
kubectl get deploy coredns -n kube-system -o yaml | grep -A 5 HOST_IP
kubectl logs -n kube-system -l k8s-app=kube-dns
```

### No logs appearing
```bash
cat config.env | grep ENABLE_LOGGING
podman exec <node> ls -la /var/log/dnsmasq.log
podman exec <node> cat /etc/dnsmasq.conf | grep log
```
