#!/usr/bin/env bash
#
# deploy-monitoring.sh — Build dnsmasq-exporter and deploy monitoring stack.
#
# Steps:
#   1. Build dnsmasq-exporter container image
#   2. Load image into Kind cluster
#   3. Deploy dnsmasq-exporter DaemonSet (hostNetwork, reads /var/log/dnsmasq.log)
#   4. Deploy Prometheus (scrapes dnsmasq-exporter pods)
#   5. Deploy Grafana (pre-configured datasource + dashboard)
#
# Reads configuration from config.env.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "${SCRIPT_DIR}/common.sh"

load_project_config

CLI="${CONTAINER_CLI:-podman}"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"
EXPORTER_IMAGE="dnsmasq-exporter:latest"

header "Monitoring Stack Deployment"

info "Configuration:"
echo "  Cluster:       ${CLUSTER_NAME}"
echo "  Context:       ${KUBE_CONTEXT}"
echo "  Container CLI: ${CLI}"
echo ""

# ── Check cluster is reachable ──────────────────────────────────────

if ! kubectl get nodes --context "$KUBE_CONTEXT" &>/dev/null; then
    error "Cannot reach cluster '${CLUSTER_NAME}'. Is it running? Try: make cluster-up"
fi

# ── Build dnsmasq-exporter image ────────────────────────────────────

info "[1/5] Building dnsmasq-exporter image..."

${CLI} build -t "${EXPORTER_IMAGE}" "${REPO_DIR}/exporter/"

success "Image built: ${EXPORTER_IMAGE}"

# ── Load image into Kind ────────────────────────────────────────────

info "[2/5] Loading image into Kind cluster..."

kind load docker-image "${EXPORTER_IMAGE}" --name "${CLUSTER_NAME}"

success "Image loaded into Kind."

# ── Deploy dnsmasq-exporter DaemonSet ───────────────────────────────

info "[3/5] Deploying dnsmasq-exporter DaemonSet..."

kubectl apply --context "$KUBE_CONTEXT" \
    -f "${REPO_DIR}/monitoring/dnsmasq-exporter.yaml"

success "dnsmasq-exporter DaemonSet applied."

# ── Deploy Prometheus ────────────────────────────────────────────────

info "[4/5] Deploying Prometheus..."

kubectl apply --context "$KUBE_CONTEXT" \
    -f "${REPO_DIR}/monitoring/prometheus.yaml"

success "Prometheus resources applied."

# ── Create Grafana dashboard ConfigMap + deploy Grafana ──────────────

info "[5/5] Deploying Grafana..."

kubectl create configmap grafana-dashboard-dnsmasq \
    --context "$KUBE_CONTEXT" \
    --namespace monitoring \
    --from-file=dnsmasq-dns.json="${REPO_DIR}/monitoring/grafana-dashboard.json" \
    --dry-run=client -o yaml | \
    kubectl apply --context "$KUBE_CONTEXT" -f -

kubectl apply --context "$KUBE_CONTEXT" \
    -f "${REPO_DIR}/monitoring/grafana.yaml"

success "Grafana resources applied."

# ── Wait for pods ────────────────────────────────────────────────────

info "Waiting for dnsmasq-exporter to be ready..."
kubectl rollout status daemonset/dnsmasq-exporter \
    --context "$KUBE_CONTEXT" \
    --namespace monitoring \
    --timeout=120s 2>/dev/null || warn "dnsmasq-exporter not ready yet"

info "Waiting for Prometheus to be ready..."
kubectl rollout status deployment/prometheus \
    --context "$KUBE_CONTEXT" \
    --namespace monitoring \
    --timeout=120s 2>/dev/null || warn "Prometheus not ready yet"

info "Waiting for Grafana to be ready..."
kubectl rollout status deployment/grafana \
    --context "$KUBE_CONTEXT" \
    --namespace monitoring \
    --timeout=120s 2>/dev/null || warn "Grafana not ready yet"

# ── Summary ──────────────────────────────────────────────────────────

echo ""
kubectl get pods --context "$KUBE_CONTEXT" -n monitoring -o wide

header "Monitoring Stack Ready"

echo "  Access locally via port-forward:"
echo ""
echo "    Prometheus:  make prometheus-ui    (http://localhost:9090)"
echo "    Grafana:     make grafana-ui       (http://localhost:3000)"
echo ""
echo "  Or manually:"
echo "    kubectl port-forward -n monitoring svc/prometheus 9090:9090 --context ${KUBE_CONTEXT}"
echo "    kubectl port-forward -n monitoring svc/grafana 3000:3000 --context ${KUBE_CONTEXT}"
echo ""
echo "  Grafana login: anonymous access enabled (no password needed)"
echo ""
echo "  dnsmasq-exporter metrics (per node):"
echo "    - dnsmasq_up                    — dnsmasq responding (1/0)"
echo "    - dnsmasq_cache_size            — configured cache size"
echo "    - dnsmasq_cache_hits_total      — cache hits"
echo "    - dnsmasq_cache_misses_total    — cache misses"
echo "    - dnsmasq_cache_insertions_total — cache insertions"
echo "    - dnsmasq_cache_evictions_total — cache evictions"
echo "    - dnsmasq_queries_total{type}   — queries by type (A, AAAA, etc.)"
echo "    - dnsmasq_forwards_total{to}    — forwards by upstream server"
echo "    - dnsmasq_responses_total{source} — responses (cached/forwarded/local)"
echo ""
echo "  Prometheus alerts:"
echo "    - DnsmasqDown (critical) — dnsmasq not responding for 1m"
echo "    - DnsmasqExporterDown (critical) — exporter unreachable for 1m"
echo "    - DnsmasqCacheHitRateLow (info) — cache hit rate < 50% for 10m"
echo "    - DnsmasqCacheEvictionsHigh (warning) — eviction rate > 10/s for 5m"
echo "    - DnsmasqHighForwardRate (warning) — forward rate > 100/s for 5m"
echo "    - DnsmasqNoQueries (warning) — zero queries for 10m"
echo "    - DnsmasqAvailabilitySLOBreach (critical) — availability < 99.9% for 5m"
echo ""
