#!/usr/bin/env bash
#
# deploy-monitoring.sh — Build dnsmasq-exporter and deploy monitoring stack.
#
# Usage:
#   ./deploy-monitoring.sh [basic|full]
#
#   basic — CHAOS TXT metrics only (native dnsmasq stats). No log parsing.
#   full  — CHAOS TXT + log-based metrics (queries, forwards, responses).
#
# Steps:
#   1. Build dnsmasq-exporter container image
#   2. Load image into Kind cluster
#   3. Deploy dnsmasq-exporter DaemonSet (hostNetwork)
#   4. Deploy Prometheus (scrapes dnsmasq-exporter pods)
#   5. Deploy Grafana (pre-configured datasource + dashboard)
#
# Reads configuration from config.env.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "${SCRIPT_DIR}/common.sh"

load_project_config

MONITOR_MODE="${1:-basic}"
if [ "$MONITOR_MODE" != "basic" ] && [ "$MONITOR_MODE" != "full" ]; then
    error "Usage: $0 [basic|full]"
fi

CLI="${CONTAINER_CLI:-podman}"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"
EXPORTER_IMAGE="docker.io/library/dnsmasq-exporter:latest"

header "Monitoring Stack Deployment (${MONITOR_MODE} mode)"

info "Configuration:"
echo "  Cluster:       ${CLUSTER_NAME}"
echo "  Context:       ${KUBE_CONTEXT}"
echo "  Container CLI: ${CLI}"
echo "  Mode:          ${MONITOR_MODE}"
echo ""

# ── Check cluster is reachable ──────────────────────────────────────

if ! kubectl get nodes --context "$KUBE_CONTEXT" &>/dev/null; then
    error "Cannot reach cluster '${CLUSTER_NAME}'. Is it running? Try: make cluster-up"
fi

# ── Build dnsmasq-exporter image ────────────────────────────────────

info "[1/5] Building dnsmasq-exporter image..."

NODE_ARCH=$(${CLI} exec "${CLUSTER_NAME}-control-plane" uname -m 2>/dev/null || echo "")
case "$NODE_ARCH" in
    x86_64)  BUILD_PLATFORM="linux/amd64" ;;
    aarch64) BUILD_PLATFORM="linux/arm64" ;;
    *)       BUILD_PLATFORM="" ;;
esac

if [ -n "$BUILD_PLATFORM" ]; then
    info "  Node architecture: ${NODE_ARCH} -> building for ${BUILD_PLATFORM}"
    ${CLI} build --platform "${BUILD_PLATFORM}" -t "${EXPORTER_IMAGE}" "${REPO_DIR}/exporter/"
else
    ${CLI} build -t "${EXPORTER_IMAGE}" "${REPO_DIR}/exporter/"
fi

success "Image built: ${EXPORTER_IMAGE}"

# ── Load image into Kind ────────────────────────────────────────────

info "[2/5] Loading image into Kind cluster..."

EXPORTER_TAR="$(mktemp /tmp/dnsmasq-exporter-XXXXXX.tar)"
trap "rm -f '${EXPORTER_TAR}'" EXIT
${CLI} save -o "${EXPORTER_TAR}" "${EXPORTER_IMAGE}"
kind load image-archive "${EXPORTER_TAR}" --name "${CLUSTER_NAME}"

success "Image loaded into Kind."

# ── Ensure monitoring namespace exists ──────────────────────────────

kubectl create namespace monitoring --context "$KUBE_CONTEXT" --dry-run=client -o yaml | \
    kubectl apply --context "$KUBE_CONTEXT" -f -

# ── Deploy dnsmasq-exporter DaemonSet ───────────────────────────────

info "[3/5] Deploying dnsmasq-exporter DaemonSet (${MONITOR_MODE})..."

if [ "$MONITOR_MODE" = "basic" ]; then
    EXPORTER_MANIFEST="${REPO_DIR}/monitoring/dnsmasq-exporter-basic.yaml"
else
    EXPORTER_MANIFEST="${REPO_DIR}/monitoring/dnsmasq-exporter.yaml"
fi

kubectl apply --context "$KUBE_CONTEXT" \
    -f "$EXPORTER_MANIFEST"

success "dnsmasq-exporter DaemonSet applied (${MONITOR_MODE})."

# ── Deploy Prometheus ────────────────────────────────────────────────

info "[4/5] Deploying Prometheus..."

if [ "$MONITOR_MODE" = "basic" ]; then
    PROMETHEUS_MANIFEST="${REPO_DIR}/monitoring/prometheus-basic.yaml"
else
    PROMETHEUS_MANIFEST="${REPO_DIR}/monitoring/prometheus.yaml"
fi

kubectl apply --context "$KUBE_CONTEXT" \
    -f "$PROMETHEUS_MANIFEST"

success "Prometheus resources applied."

# ── Create Grafana dashboard ConfigMap + deploy Grafana ──────────────

info "[5/5] Deploying Grafana..."

if [ "$MONITOR_MODE" = "basic" ]; then
    DASHBOARD_FILE="${REPO_DIR}/monitoring/grafana-dashboard-basic.json"
else
    DASHBOARD_FILE="${REPO_DIR}/monitoring/grafana-dashboard.json"
fi

kubectl create configmap grafana-dashboard-dnsmasq \
    --context "$KUBE_CONTEXT" \
    --namespace monitoring \
    --from-file=dnsmasq-dns.json="$DASHBOARD_FILE" \
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

header "Monitoring Stack Ready (${MONITOR_MODE} mode)"

echo "  Access locally via port-forward:"
echo ""
echo "    Prometheus:  make prometheus-ui    (http://localhost:${PROMETHEUS_PORT})"
echo "    Grafana:     make grafana-ui       (http://localhost:${GRAFANA_PORT})"
echo ""
echo "  Background:  make port-forward      (starts both in background)"
echo "  Stop:        make port-forward-stop"
echo ""
echo "  Or manually:"
echo "    kubectl port-forward -n monitoring svc/prometheus ${PROMETHEUS_PORT}:9090 --context ${KUBE_CONTEXT}"
echo "    kubectl port-forward -n monitoring svc/grafana ${GRAFANA_PORT}:3000 --context ${KUBE_CONTEXT}"
echo ""
echo "  Grafana login: anonymous access enabled (no password needed)"
echo ""
echo "  dnsmasq-exporter metrics (per node) — native via CHAOS TXT:"
echo "    - dnsmasq_up                    — dnsmasq responding (1/0)"
echo "    - dnsmasq_cache_size            — configured cache size"
echo "    - dnsmasq_cache_hits_total      — cache hits"
echo "    - dnsmasq_cache_misses_total    — cache misses"
echo "    - dnsmasq_cache_insertions_total — cache insertions"
echo "    - dnsmasq_cache_evictions_total — cache evictions"
if [ "$MONITOR_MODE" = "full" ]; then
echo ""
echo "  Log-derived metrics (parsed from /var/log/dnsmasq.log):"
echo "    - dnsmasq_queries_total{type}   — queries by type (A, AAAA, etc.)"
echo "    - dnsmasq_forwards_total{to}    — forwards by upstream server"
echo "    - dnsmasq_responses_total{source} — responses (cached/forwarded/local)"
fi
echo ""
echo "  Prometheus alerts:"
echo "    - DnsmasqDown (critical) — dnsmasq not responding for 1m"
echo "    - DnsmasqExporterDown (critical) — exporter unreachable for 1m"
echo "    - DnsmasqCacheHitRateLow (info) — cache hit rate < 50% for 10m"
echo "    - DnsmasqCacheEvictionsHigh (warning) — eviction rate > 10/s for 5m"
if [ "$MONITOR_MODE" = "full" ]; then
echo "    - DnsmasqHighForwardRate (warning) — forward rate > 100/s for 5m"
echo "    - DnsmasqNoQueries (warning) — zero queries for 10m"
fi
echo "    - DnsmasqAvailabilitySLOBreach (critical) — availability < 99.9% for 5m"
echo ""
if [ "$MONITOR_MODE" = "basic" ]; then
echo "  To upgrade to full monitoring (adds log-based query/forward/response metrics):"
echo "    make monitoring-full"
echo ""
fi
