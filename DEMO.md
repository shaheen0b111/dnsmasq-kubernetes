# dnsmasq on Kubernetes Nodes — Demo Guide

**Complete step-by-step walkthrough** for demonstrating node-level DNS caching with dnsmasq.

This guide includes:
- Full demo execution with expected outputs
- Manual exploration commands
- Architecture verification steps
- Troubleshooting procedures

> **For a quick overview, see [README.md](README.md)**

## Prerequisites

- Docker or Podman installed
- `kind` and `kubectl` installed (or run `make prereqs`)
- 10-15 minutes

## Demo Flow

### 1. Configuration

```bash
# Review and edit configuration
cat config.env

# Key settings:
# - CLUSTER_NAME: dnsmasq-test
# - WORKER_COUNT: 2
# - UPSTREAM_DNS: 8.8.8.8,8.8.4.4
# - CACHE_SIZE: 1000
# - ENABLE_LOGGING: true
```

### 2. Create Cluster and Deploy dnsmasq

```bash
# Full automated setup
make demo
```

**What happens:**
1. Creates Kind cluster (1 control-plane + 2 workers)
2. Deploys dnsmasq as daemon service on each node
3. Configures CoreDNS to forward to dnsmasq
4. Runs comprehensive verification tests

**Expected output:**
```
════════════════════════════════════════════
  Kind Cluster Setup
════════════════════════════════════════════

  Cluster name:  dnsmasq-test
  Container CLI: docker
  Workers:       2

[INFO]  Checking prerequisites...
[OK]    Prerequisites satisfied.
...
[OK]    All 3 nodes are ready.

════════════════════════════════════════════
  dnsmasq Deployment
════════════════════════════════════════════

[INFO]  Discovered 3 node(s):
  - dnsmasq-test-control-plane
  - dnsmasq-test-worker
  - dnsmasq-test-worker2

[INFO]  --- Deploying to dnsmasq-test-control-plane ---
  Node IP: 172.18.0.7
[INFO]    Installing dnsmasq package...
[OK]      dnsmasq package installed.
[INFO]    Creating dnsmasq configuration...
[INFO]    Starting dnsmasq daemon...
[OK]      dnsmasq is running and listening on port 53.
...
[OK]    CoreDNS ConfigMap updated.
[OK]    HOST_IP environment variable added.
[OK]    CoreDNS rollout complete.

════════════════════════════════════════════
  Deployment Complete
════════════════════════════════════════════

  dnsmasq daemon deployed to all 3 node(s).
  CoreDNS configured to forward to dnsmasq on each node.

  DNS Flow:
    Pod → CoreDNS (10s cache) → dnsmasq (TTL cache) → Upstream DNS

════════════════════════════════════════════
  DNS Verification Tests
════════════════════════════════════════════

[INFO]  Test 1: Verify dnsmasq service is running on all nodes

  Checking dnsmasq-test-control-plane...
[OK]        ✓ dnsmasq running
      PID: 2125
      Command: /usr/sbin/dnsmasq
      Listening: port 53 (UDP)

  Explanation:
  • dnsmasq is running as a daemon service (not a pod) on each node
  • Each dnsmasq instance listens on port 53 (UDP) on all interfaces
  • This provides node-local DNS caching for queries from CoreDNS

[INFO]  Test 2: Node-level DNS resolution

  Testing dnsmasq-test-control-plane...
[OK]        ✓ Resolved google.com
      Query: nslookup google.com 127.0.0.1 (direct to dnsmasq)
      Result:
        → 142.251.43.14
        → 2404:6800:4009:802::200e
      Log: May  4 07:23:01 dnsmasq[2125]: reply google.com is 2404:6800:4009:817::200e

  Explanation:
  • Each node can directly query its local dnsmasq on 127.0.0.1:53
  • dnsmasq forwards queries to upstream DNS (8.8.8.8,8.8.4.4)
  • Responses are cached by dnsmasq for future queries (TTL-based)
  • Different nodes may receive different IPs due to DNS round-robin/geo-location

[INFO]  Test 3: Pod DNS resolution (CoreDNS → dnsmasq chain)

  Testing google.com...
[OK]        ✓ Resolved google.com
      Query: nslookup google.com (from pod on dnsmasq-test-worker)
      DNS Chain: Pod → CoreDNS → dnsmasq (on dnsmasq-test-worker) → Upstream
      Result:
        → 142.250.195.14
      dnsmasq log: May  4 07:23:02 dnsmasq[1164]: cached google.com is 142.250.195.14

  Explanation:
  • Pod sends DNS query to Kubernetes DNS service (ClusterIP)
  • CoreDNS receives the query and checks its 10-second cache
  • On cache miss, CoreDNS forwards to dnsmasq on the SAME node via {HOST_IP}:53
  • dnsmasq checks its TTL-based cache, then forwards to upstream if needed
  • Two-layer caching: CoreDNS (L1, 10s) + dnsmasq (L2, TTL-based)
  • This reduces latency and upstream DNS load significantly

[INFO]  Test 4: Verify dnsmasq caching behavior

[INFO]    Query 1 (cache miss)...
    Query: nslookup reddit.com 127.0.0.1
    Result (from upstream):
      → 151.101.1.140
      → 151.101.65.140

[INFO]    Query 2 (should be cached)...
    Query: nslookup reddit.com 127.0.0.1
    Result (from cache):
      → 151.101.1.140
      → 151.101.65.140

[OK]        ✓ First query forwarded to upstream
[OK]        ✓ Second query served from cache

  dnsmasq logs showing cache behavior:
    May  4 07:23:03 dnsmasq[2125]: query[A] reddit.com from 127.0.0.1
    May  4 07:23:03 dnsmasq[2125]: forwarded reddit.com to 8.8.8.8
    May  4 07:23:03 dnsmasq[2125]: reply reddit.com is 151.101.1.140
    May  4 07:23:04 dnsmasq[2125]: query[A] reddit.com from 127.0.0.1
    May  4 07:23:04 dnsmasq[2125]: cached reddit.com is 151.101.1.140

  Explanation:
  • Query 1: Cache miss → dnsmasq forwards to upstream (8.8.8.8/8.8.4.4)
  • Query 2: Cache hit → dnsmasq serves from local cache (no upstream query)
  • Logs show 'forwarded' for cache misses and 'cached' for cache hits
  • TTL from upstream DNS determines how long entries stay cached
  • This dramatically reduces DNS query latency (cache: <1ms vs upstream: 10-50ms)

[INFO]  Test 5: Multi-node distribution

  Testing test-dns-1 (on dnsmasq-test-worker2)...
[OK]        ✓ DNS resolution working
      Query: nslookup stackoverflow.com
      DNS Chain: test-dns-1 → CoreDNS → dnsmasq (on dnsmasq-test-worker2) → Upstream
      Result:
        → 198.252.206.1
      dnsmasq log (dnsmasq-test-worker2): May  4 07:23:06 dnsmasq[2495]: reply stackoverflow.com is 198.252.206.1

  Explanation:
  • Each pod uses CoreDNS on its scheduled node
  • CoreDNS forwards to dnsmasq on the SAME node (node-local caching)
  • test-dns-1 on worker2 → uses dnsmasq on worker2
  • test-dns-2 on worker → uses dnsmasq on worker
  • This ensures optimal performance with minimal network hops
  • Each node's dnsmasq maintains its own independent cache

════════════════════════════════════════════
  Verification Complete
════════════════════════════════════════════

  ✓ dnsmasq service running on all nodes
  ✓ Node-level DNS resolution working
  ✓ Pod DNS resolution working (CoreDNS → dnsmasq)
  ✓ dnsmasq caching verified
  ✓ Multi-node distribution working
```

### 3. Check Status

```bash
make status
```

**Shows:**
- Cluster nodes status
- dnsmasq services on each node
- CoreDNS pods

**Note:** Comprehensive caching verification is included in `make verify` (Test 4), which shows:
- Cache misses (forwarded to upstream)
- Cache hits (served from local cache)
- Detailed dnsmasq logs with timestamps
- Two-layer caching behavior (CoreDNS + dnsmasq)

### 4. Manual Exploration

```bash
# Get node names
docker ps --filter "name=dnsmasq-test"

# View dnsmasq logs on a node
docker exec dnsmasq-test-worker cat /var/log/dnsmasq.log

# Follow live queries
docker exec dnsmasq-test-worker tail -f /var/log/dnsmasq.log

# Test DNS from a node directly
docker exec dnsmasq-test-worker nslookup google.com 127.0.0.1

# View dnsmasq process
docker exec dnsmasq-test-worker ps aux | grep dnsmasq

# Create a test pod and query
kubectl run testpod --image=busybox:1.36 -- sleep 3600
kubectl exec testpod -- nslookup github.com

# Check CoreDNS configuration
kubectl get cm coredns -n kube-system -o yaml | grep -A 10 "forward"
```

### 5. View dnsmasq Configuration

```bash
# On any node
docker exec dnsmasq-test-worker cat /etc/dnsmasq.conf
```

**Expected content:**
```
resolv-file=/etc/resolv.conf.upstream
dns-forward-max=10000
cache-size=1000
bind-interfaces
listen-address=0.0.0.0
log-queries
log-facility=/var/log/dnsmasq.log
```

### 6. Observe Query Flow

```bash
# Terminal 1: Watch dnsmasq logs
docker exec dnsmasq-test-worker tail -f /var/log/dnsmasq.log

# Terminal 2: Make queries
kubectl exec testpod -- nslookup twitter.com
kubectl exec testpod -- nslookup facebook.com

# Watch the logs in Terminal 1 show:
# - "forwarded twitter.com to 8.8.8.8" (first query)
# - "cached twitter.com is <IP>" (subsequent queries)
```

### 7. Architecture Verification

```bash
# Verify CoreDNS forwards to dnsmasq
kubectl get cm coredns -n kube-system -o yaml | grep -A 5 "forward"

# Should show:
#   forward . {$HOST_IP}:53 {
#     max_concurrent 1000
#     policy sequential
#     force_tcp
#   }

# Verify HOST_IP env var in CoreDNS
kubectl get deploy coredns -n kube-system -o yaml | grep -A 5 "env:"

# Should show:
#   env:
#   - name: HOST_IP
#     valueFrom:
#       fieldRef:
#         fieldPath: status.hostIP
```

### 8. Cleanup

```bash
make clean
```

## Summary

### Problem Statement
- Kubernetes pods make many DNS queries (service discovery, external APIs)
- Every query goes to upstream DNS (8.8.8.8, cloud DNS)
- This adds latency and creates external dependencies
- No caching at the node level by default

### Solution
- Deploy dnsmasq as a daemon service on each node
- CoreDNS forwards to local dnsmasq
- Two-layer caching:
  - Layer 1 (CoreDNS): 10s TTL for rapid repeats
  - Layer 2 (dnsmasq): TTL-based for longer-term caching

### Benefits
- **Performance**: Cached queries served in ~5-10ms instead of ~40-50ms
- **Reliability**: Survives temporary upstream DNS outages
- **Cost**: Reduces cloud DNS query costs
- **Observability**: Query logs on each node
- **Simplicity**: Daemon service, no external dependencies

### Key Technical Details
- **Daemon service**: Runs directly on node, not as a pod
- **Port binding**: Listens on port 53 (UDP) on all interfaces (0.0.0.0)
- **CoreDNS integration**: Uses Downward API for `{$HOST_IP}`
- **TCP forwarding**: Required for kind (`force_tcp` in CoreDNS)
- **Per-node deployment**: Each node has its own independent dnsmasq instance
- **Node-local caching**: Pods query CoreDNS on same node → dnsmasq on same node

## Troubleshooting

### dnsmasq service not starting
```bash
# Check dnsmasq process on node
docker exec dnsmasq-test-worker ps aux | grep dnsmasq

# Check if port 53 is bound
docker exec dnsmasq-test-worker netstat -ulnp | grep :53

# View dnsmasq configuration
docker exec dnsmasq-test-worker cat /etc/dnsmasq.conf

# Restart dnsmasq manually
docker exec dnsmasq-test-worker killall dnsmasq
docker exec dnsmasq-test-worker /usr/sbin/dnsmasq
```

### DNS queries not reaching dnsmasq
```bash
# Verify CoreDNS configuration
kubectl get cm coredns -n kube-system -o yaml

# Verify HOST_IP env var
kubectl get deploy coredns -n kube-system -o yaml | grep -A 5 HOST_IP

# Check CoreDNS logs
kubectl logs -n kube-system -l k8s-app=kube-dns
```

### No logs appearing
```bash
# Check if logging is enabled
cat config.env | grep ENABLE_LOGGING

# Check log file
docker exec dnsmasq-test-worker ls -la /var/log/dnsmasq.log

# Check dnsmasq config
docker exec dnsmasq-test-worker cat /etc/dnsmasq.conf
```
