#!/usr/bin/env bash
#
# walkthrough.sh — Interactive feature walkthrough for the dnsmasq demo.
#
# Assumes `make demo` has already been run (cluster up, dnsmasq deployed,
# demo-apps deployed, monitoring deployed, port-forwards running).
#
# Walks through every feature with pauses between steps, showing the
# command before executing it. Press any key to advance.
#
# Usage: ./walkthrough.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "${SCRIPT_DIR}/common.sh"

load_project_config

CLI="${CONTAINER_CLI:-podman}"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"
CP_NODE="${CLUSTER_NAME}-control-plane"
WORKER_NODE="${CLUSTER_NAME}-worker"

# ── Preflight check ──────────────────────────────────────────────────

NODES=$($CLI ps --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" \
    --format '{{.Names}}' 2>/dev/null | sort)

if [ -z "$NODES" ]; then
    error "Cluster '${CLUSTER_NAME}' not running. Run 'make demo' first."
fi

CP_IP=$($CLI inspect "$CP_NODE" \
    --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)
WORKER_IP=$($CLI inspect "$WORKER_NODE" \
    --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)

# Ensure dig is available
$CLI exec "$CP_NODE" sh -c "command -v dig >/dev/null 2>&1" 2>/dev/null || \
    $CLI exec "$CP_NODE" sh -c \
        "apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq dnsutils >/dev/null 2>&1" \
        2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════
#  Start
# ═══════════════════════════════════════════════════════════════════

header "dnsmasq on Kubernetes — Interactive Walkthrough"

echo "  Cluster:     ${CLUSTER_NAME}"
echo "  Domain:      ${DOMAIN}"
echo "  Control-plane: ${CP_NODE} (${CP_IP})"
echo "  Worker:      ${WORKER_NODE} (${WORKER_IP})"
echo "  Prometheus:  http://localhost:${PROMETHEUS_PORT}"
echo "  Grafana:     http://localhost:${GRAFANA_PORT}"

pause "Start the walkthrough?"

# ═══════════════════════════════════════════════════════════════════
#  1. Cluster Overview
# ═══════════════════════════════════════════════════════════════════

header "1. Cluster Overview"

echo "  Show the Kind cluster nodes and verify dnsmasq is running on each."
echo ""
show_cmd "kubectl get nodes -o wide --context ${KUBE_CONTEXT}"

pause

kubectl get nodes -o wide --context "$KUBE_CONTEXT"

echo ""
echo "  dnsmasq process on each node:"
echo ""

for NODE in $NODES; do
    show_cmd "${CLI} exec ${NODE} ps aux | grep dnsmasq"
    PID=$($CLI exec "$NODE" pidof dnsmasq 2>/dev/null || echo "NOT RUNNING")
    echo -e "  ${NODE}: ${_GREEN}PID ${PID}${_RESET}"
done

pause "Next: DNS configuration"

# ═══════════════════════════════════════════════════════════════════
#  2. DNS Configuration
# ═══════════════════════════════════════════════════════════════════

header "2. DNS Configuration"

echo "  The dnsmasq config defines address records for cluster infrastructure"
echo "  domains and forwards everything else to upstream DNS."
echo ""
show_cmd "${CLI} exec ${CP_NODE} cat /etc/dnsmasq.conf"

pause

$CLI exec "$CP_NODE" cat /etc/dnsmasq.conf

echo ""
echo "  Each node's /etc/resolv.conf points to its own dnsmasq (local IP first)."
echo ""
show_cmd "${CLI} exec ${CP_NODE} cat /etc/resolv.conf"

pause

echo -e "  ${_BOLD}Current /etc/resolv.conf:${_RESET}"
$CLI exec "$CP_NODE" cat /etc/resolv.conf
echo ""
echo -e "  ${_BOLD}Original (before dnsmasq):${_RESET}"
$CLI exec "$CP_NODE" cat /etc/resolv.conf.upstream

pause "Next: local DNS resolution"

# ═══════════════════════════════════════════════════════════════════
#  3. Local DNS Resolution
# ═══════════════════════════════════════════════════════════════════

header "3. Local DNS Resolution"

echo "  Cluster infrastructure domains resolve locally via dnsmasq address"
echo "  records. No upstream DNS involved — sub-millisecond response."
echo ""

for QDOMAIN in "api.${DOMAIN}" "api-int.${DOMAIN}" "myapp.apps.${DOMAIN}"; do
    show_cmd "${CLI} exec ${CP_NODE} dig +short ${QDOMAIN} @${CP_IP}"
done

pause

echo ""
for QDOMAIN in "api.${DOMAIN}" "api-int.${DOMAIN}" "myapp.apps.${DOMAIN}"; do
    RESULT=$($CLI exec "$CP_NODE" dig +short +timeout=3 "$QDOMAIN" "@${CP_IP}" 2>/dev/null)
    echo -e "  ${QDOMAIN}  ->  ${_GREEN}${RESULT:-FAIL}${_RESET}"
done

echo ""
echo "  Full dig output showing authoritative answer (aa flag) and query time:"
echo ""
show_cmd "${CLI} exec ${CP_NODE} dig api.${DOMAIN} @${CP_IP}"

pause

$CLI exec "$CP_NODE" dig "api.${DOMAIN}" "@${CP_IP}" 2>/dev/null

pause "Next: external DNS forwarding"

# ═══════════════════════════════════════════════════════════════════
#  4. External DNS Forwarding
# ═══════════════════════════════════════════════════════════════════

header "4. External DNS Forwarding"

echo "  Domains dnsmasq doesn't own are forwarded to upstream DNS."
echo "  Notice: no 'aa' flag, higher query time (network round-trip)."
echo ""
show_cmd "${CLI} exec ${CP_NODE} dig google.com @${CP_IP}"

pause

$CLI exec "$CP_NODE" dig "google.com" "@${CP_IP}" 2>/dev/null

pause "Next: DNS caching"

# ═══════════════════════════════════════════════════════════════════
#  5. DNS Caching
# ═══════════════════════════════════════════════════════════════════

header "5. DNS Caching"

echo "  dnsmasq caches upstream responses. The first query is forwarded,"
echo "  the second is served from cache (visible in the log)."
echo ""

CACHE_DOMAIN="github.com"
echo "  Query 1 (forwarded):"
show_cmd "${CLI} exec ${CP_NODE} dig +short ${CACHE_DOMAIN} @${CP_IP}"

pause

$CLI exec "$CP_NODE" dig +short +timeout=3 "$CACHE_DOMAIN" "@${CP_IP}" 2>/dev/null
echo ""

echo "  Query 2 (should be cached):"
show_cmd "${CLI} exec ${CP_NODE} dig +short ${CACHE_DOMAIN} @${CP_IP}"

pause

$CLI exec "$CP_NODE" dig +short +timeout=3 "$CACHE_DOMAIN" "@${CP_IP}" 2>/dev/null
echo ""

echo "  Check the dnsmasq log for 'cached' vs 'forwarded':"
show_cmd "${CLI} exec ${CP_NODE} tail -10 /var/log/dnsmasq.log | grep ${CACHE_DOMAIN}"

pause

$CLI exec "$CP_NODE" tail -20 /var/log/dnsmasq.log 2>/dev/null | grep "$CACHE_DOMAIN" | tail -5 || echo "  (no log entries found)"

pause "Next: Kubernetes DNS separation"

# ═══════════════════════════════════════════════════════════════════
#  6. Kubernetes DNS Separation
# ═══════════════════════════════════════════════════════════════════

header "6. Kubernetes DNS Separation"

echo "  The DNS separation works at the pod level. Inside a pod, CoreDNS"
echo "  (kube-dns) handles *.svc.cluster.local via its kubernetes plugin"
echo "  — the query never reaches dnsmasq. Custom domains are forwarded"
echo "  by CoreDNS to dnsmasq on the node."
echo ""
echo "  Note: from the node itself, ALL queries go through dnsmasq"
echo "  (the node's resolv.conf points to it). The separation only"
echo "  applies to pod-level DNS resolution."
echo ""

# Clear dnsmasq logs on all nodes to get a clean baseline
for NODE in $NODES; do
    $CLI exec "$NODE" sh -c "echo '' > /var/log/dnsmasq.log" 2>/dev/null || true
done

echo "  Query a Kubernetes service FROM A POD (resolved by kube-dns):"
show_cmd "kubectl exec dns-test -- nslookup kubernetes.default.svc.cluster.local"

pause

kubectl exec dns-test --context "$KUBE_CONTEXT" -- nslookup kubernetes.default.svc.cluster.local 2>/dev/null || true

echo ""
echo "  Query a custom domain FROM A POD (forwarded by CoreDNS to dnsmasq):"
show_cmd "kubectl exec dns-test -- nslookup api.${DOMAIN}"

pause

kubectl exec dns-test --context "$KUBE_CONTEXT" -- nslookup "api.${DOMAIN}" 2>/dev/null || true

# Brief pause for logs to flush
sleep 1

echo ""
echo "  Check dnsmasq logs on ALL nodes — only api.${DOMAIN} should appear,"
echo "  not kubernetes.default:"
echo ""

pause

K8S_COUNT=0
CUSTOM_COUNT=0
for NODE in $NODES; do
    echo -e "  ${_BOLD}${NODE}:${_RESET}"
    NODE_LOGS=$($CLI exec "$NODE" tail -30 /var/log/dnsmasq.log 2>/dev/null | grep -E "kubernetes.default|api\.${DOMAIN}" | tail -5 || true)
    if [ -n "$NODE_LOGS" ]; then
        echo "$NODE_LOGS" | while read -r line; do echo "    $line"; done
    else
        echo "    (no matching entries)"
    fi
    NODE_K8S=$($CLI exec "$NODE" tail -30 /var/log/dnsmasq.log 2>/dev/null | grep -c "kubernetes.default" || true)
    NODE_CUSTOM=$($CLI exec "$NODE" tail -30 /var/log/dnsmasq.log 2>/dev/null | grep -c "api\.${DOMAIN}" || true)
    K8S_COUNT=$((K8S_COUNT + NODE_K8S))
    CUSTOM_COUNT=$((CUSTOM_COUNT + NODE_CUSTOM))
done
echo ""
echo -e "  kubernetes.default in dnsmasq logs (all nodes): ${_GREEN}${K8S_COUNT} (kube-dns handled it)${_RESET}"
echo -e "  api.${DOMAIN} in dnsmasq logs (all nodes):  ${_GREEN}${CUSTOM_COUNT} (dnsmasq handled it)${_RESET}"

pause "Next: Prometheus metrics"

# ═══════════════════════════════════════════════════════════════════
#  7. Raw Prometheus Metrics
# ═══════════════════════════════════════════════════════════════════

header "7. Prometheus Metrics (from dnsmasq-exporter)"

echo "  Each node runs a dnsmasq-exporter that exposes metrics on :9153."
echo "  Key metrics: dnsmasq_up, cache hits/misses, queries, forwards."
echo ""
show_cmd "${CLI} exec ${CP_NODE} curl -s http://127.0.0.1:9153/metrics | grep dnsmasq_"

pause

echo ""
$CLI exec "$CP_NODE" curl -s http://127.0.0.1:9153/metrics 2>/dev/null | grep -E "^dnsmasq_(up|cache_size|cache_hits|cache_misses|queries_total|forwards_total|responses_total)" | head -20

pause "Next: dashboards"

# ═══════════════════════════════════════════════════════════════════
#  8. Dashboards
# ═══════════════════════════════════════════════════════════════════

header "8. Grafana & Prometheus Dashboards"

echo "  Port-forwards should already be running from 'make demo'."
echo ""
echo -e "  ${_BOLD}Grafana:${_RESET}     http://localhost:${GRAFANA_PORT}"
echo "               Navigate to Dashboards -> dnsmasq dashboard"
echo ""
echo -e "  ${_BOLD}Prometheus:${_RESET}  http://localhost:${PROMETHEUS_PORT}"
echo "               Navigate to Alerts to see configured alert rules"
echo ""
echo "  Key Grafana panels: Total QPS, Instances Up, Cache Hit Rate,"
echo "  Responses by Source (local/cached/forwarded), Queries by Type."

pause "Next: DNS failover demo"

# ═══════════════════════════════════════════════════════════════════
#  9. DNS Failover
# ═══════════════════════════════════════════════════════════════════

header "9. DNS Failover Demo"

echo "  This runs the interactive failover script that blocks upstream DNS"
echo "  and proves cluster domains survive the outage."
echo ""
show_cmd "make -C ${REPO_DIR} demo-failover"

pause "Run the failover demo?"

"${SCRIPT_DIR}/demo-failover.sh"

pause "Next: traffic generation"

# ═══════════════════════════════════════════════════════════════════
#  10. Traffic Generation
# ═══════════════════════════════════════════════════════════════════

header "10. DNS Traffic Generation"

echo "  Start continuous DNS traffic to populate the Grafana dashboard"
echo "  with dense, realistic data across all nodes."
echo ""
echo "  Traffic mix per batch (every 2s):"
echo "    10 local domains, 8 cached external, 5 unique external,"
echo "    3 NXDOMAIN, 4 cluster-internal (bypasses dnsmasq)"
echo ""
show_cmd "make -C ${REPO_DIR} traffic"

pause "Start traffic generator?"

make -C "$REPO_DIR" traffic

echo ""
echo -e "  ${_BOLD}Check the Grafana dashboard now:${_RESET} http://localhost:${GRAFANA_PORT}"
echo ""
echo "  Watch for:"
echo "    - Total QPS increasing"
echo "    - Responses by Source: local, cached, forwarded lines diverging"
echo "    - Cache Hit Rate stabilizing around 60-70%"
echo "    - Queries by Type: A, AAAA, MX, TXT breakdown"

pause "Next: instance failure simulation"

# ═══════════════════════════════════════════════════════════════════
#  11. Instance Failure Simulation
# ═══════════════════════════════════════════════════════════════════

header "11. Instance Failure — Grafana Dashboard Impact"

echo "  We'll kill dnsmasq on the worker node and watch the Grafana"
echo "  'Instances Up' gauge drop from 3 to 2."
echo ""
echo "  Step 1: Find the dnsmasq PID on ${WORKER_NODE}"
show_cmd "${CLI} exec ${WORKER_NODE} pidof dnsmasq"

pause

DNSMASQ_PID=$($CLI exec "$WORKER_NODE" pidof dnsmasq 2>/dev/null || echo "")
if [ -z "$DNSMASQ_PID" ]; then
    warn "dnsmasq not running on ${WORKER_NODE}. Skipping."
else
    echo -e "  PID: ${_GREEN}${DNSMASQ_PID}${_RESET}"

    echo ""
    echo "  Step 2: Kill dnsmasq on ${WORKER_NODE}"
    show_cmd "${CLI} exec ${WORKER_NODE} kill ${DNSMASQ_PID}"

    pause "Kill dnsmasq?"

    $CLI exec "$WORKER_NODE" kill "$DNSMASQ_PID" 2>/dev/null || true

    echo ""
    echo "  Step 3: Verify port 53 is no longer bound"
    show_cmd "${CLI} exec ${WORKER_NODE} ss -ulnp | grep :53"

    pause

    PORT_CHECK=$($CLI exec "$WORKER_NODE" ss -ulnp 2>/dev/null | grep ":53" || true)
    if [ -z "$PORT_CHECK" ]; then
        echo -e "  ${_GREEN}Port 53 is unbound — dnsmasq is down.${_RESET}"
    else
        echo -e "  ${_YELLOW}Port 53 still bound:${_RESET} ${PORT_CHECK}"
    fi

    echo ""
    echo -e "  ${_BOLD}Check Grafana now:${_RESET} http://localhost:${GRAFANA_PORT}"
    echo "  Wait 15-30 seconds for the next Prometheus scrape."
    echo "  'Instances Up' should drop from 3 to 2."
    echo "  'DnsmasqDown' alert should transition to pending/firing."

    pause "Restore dnsmasq?"

    echo ""
    echo "  Step 4: Restart dnsmasq on ${WORKER_NODE}"
    show_cmd "${CLI} exec ${WORKER_NODE} /usr/sbin/dnsmasq"

    $CLI exec "$WORKER_NODE" /usr/sbin/dnsmasq 2>/dev/null || true

    echo ""
    echo "  Step 5: Verify dnsmasq is back"
    show_cmd "${CLI} exec ${WORKER_NODE} ss -ulnp | grep :53"

    PORT_CHECK=$($CLI exec "$WORKER_NODE" ss -ulnp 2>/dev/null | grep ":53" || true)
    if [ -n "$PORT_CHECK" ]; then
        echo -e "  ${_GREEN}dnsmasq is back on port 53.${_RESET}"
    else
        echo -e "  ${_RED}dnsmasq did not restart.${_RESET}"
    fi

    echo ""
    echo "  Grafana 'Instances Up' should return to 3 on the next scrape."
fi

# ═══════════════════════════════════════════════════════════════════
#  12. Stop Traffic & Wrap Up
# ═══════════════════════════════════════════════════════════════════

header "12. Wrap Up"

echo "  Stopping the traffic generator and cleaning up."
show_cmd "make -C ${REPO_DIR} traffic-stop"

pause

make -C "$REPO_DIR" traffic-stop 2>/dev/null || true

header "Walkthrough Complete"

echo "  Dashboards still running:"
echo "    Grafana:     http://localhost:${GRAFANA_PORT}"
echo "    Prometheus:  http://localhost:${PROMETHEUS_PORT}"
echo ""
echo "  To tear down: make clean"
echo ""
