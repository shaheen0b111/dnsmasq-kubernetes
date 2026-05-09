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

### Step 10: Explore Prometheus Metrics

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

### Step 11: Check Alerts

In Prometheus UI -> Alerts:
- `DnsmasqDown` (critical) — dnsmasq not responding for 1m
- `DnsmasqExporterDown` (critical) — exporter unreachable for 1m
- `DnsmasqCacheHitRateLow` (info) — cache hit rate < 50% for 10m
- `DnsmasqCacheEvictionsHigh` (warning) — eviction rate > 10/s for 5m
- `DnsmasqHighForwardRate` (warning) — forward rate > 100/s for 5m
- `DnsmasqNoQueries` (warning) — zero queries for 10m
- `DnsmasqAvailabilitySLOBreach` (critical) — availability < 99.9% for 5m

### Step 12: Cleanup

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
