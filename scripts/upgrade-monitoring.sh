#!/usr/bin/env bash
#
# upgrade-monitoring.sh — Upgrade from basic to full monitoring mode.
#
# Replaces the basic dnsmasq-exporter (CHAOS TXT only) with the full
# exporter (CHAOS TXT + log parsing), upgrades Prometheus rules and
# alerts, and swaps the Grafana dashboard to show all metrics.
#
# Reads configuration from config.env.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "${SCRIPT_DIR}/common.sh"

load_project_config

CLI="${CONTAINER_CLI:-podman}"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"

header "Upgrading Monitoring: basic -> full"

info "This adds log-derived metrics to the exporter:"
echo "  - dnsmasq_queries_total{type}     — queries by type (A, AAAA, etc.)"
echo "  - dnsmasq_forwards_total{to}      — forwards by upstream server"
echo "  - dnsmasq_responses_total{source} — responses (cached/forwarded/local)"
echo ""

# ── Upgrade dnsmasq-exporter DaemonSet ──────────────────────────────

info "[1/3] Upgrading dnsmasq-exporter to full mode..."

kubectl apply --context "$KUBE_CONTEXT" \
    -f "${REPO_DIR}/monitoring/dnsmasq-exporter.yaml"

kubectl rollout restart daemonset/dnsmasq-exporter \
    --context "$KUBE_CONTEXT" \
    --namespace monitoring

success "dnsmasq-exporter upgraded to full mode."

# ── Upgrade Prometheus rules/alerts ──────────────────────────────────

info "[2/3] Upgrading Prometheus rules and alerts..."

kubectl apply --context "$KUBE_CONTEXT" \
    -f "${REPO_DIR}/monitoring/prometheus.yaml"

# Reload Prometheus config
kubectl exec -n monitoring --context "$KUBE_CONTEXT" \
    deploy/prometheus -- kill -SIGHUP 1 2>/dev/null || true

success "Prometheus rules upgraded (added log-based alerts)."

# ── Upgrade Grafana dashboard ────────────────────────────────────────

info "[3/3] Upgrading Grafana dashboard..."

kubectl create configmap grafana-dashboard-dnsmasq \
    --context "$KUBE_CONTEXT" \
    --namespace monitoring \
    --from-file=dnsmasq-dns.json="${REPO_DIR}/monitoring/grafana-dashboard.json" \
    --dry-run=client -o yaml | \
    kubectl apply --context "$KUBE_CONTEXT" -f -

kubectl rollout restart deployment/grafana \
    --context "$KUBE_CONTEXT" \
    --namespace monitoring

success "Grafana dashboard upgraded to full view."

# ── Wait for rollouts ───────────────────────────────────────────────

info "Waiting for dnsmasq-exporter rollout..."
kubectl rollout status daemonset/dnsmasq-exporter \
    --context "$KUBE_CONTEXT" \
    --namespace monitoring \
    --timeout=120s 2>/dev/null || warn "dnsmasq-exporter not ready yet"

info "Waiting for Prometheus rollout..."
kubectl rollout status deployment/prometheus \
    --context "$KUBE_CONTEXT" \
    --namespace monitoring \
    --timeout=120s 2>/dev/null || warn "Prometheus not ready yet"

info "Waiting for Grafana rollout..."
kubectl rollout status deployment/grafana \
    --context "$KUBE_CONTEXT" \
    --namespace monitoring \
    --timeout=120s 2>/dev/null || warn "Grafana not ready yet"

# ── Restart port-forwards ───────────────────────────────────────────

info "Restarting port-forwards..."

for PF in prometheus grafana; do
    PIDFILE="/tmp/${PF}-pf-${CLUSTER_NAME}.pid"
    if [ -f "$PIDFILE" ]; then
        PID=$(cat "$PIDFILE")
        if kill -0 "$PID" 2>/dev/null; then
            kill "$PID" 2>/dev/null || true
        fi
        rm -f "$PIDFILE"
    fi
done

sleep 2

kubectl wait --for=condition=Ready pod -l app=prometheus -n monitoring \
    --context "$KUBE_CONTEXT" --timeout=60s 2>/dev/null || true
kubectl wait --for=condition=Ready pod -l app=grafana -n monitoring \
    --context "$KUBE_CONTEXT" --timeout=60s 2>/dev/null || true

kubectl port-forward -n monitoring svc/prometheus "${PROMETHEUS_PORT}:9090" \
    --context "$KUBE_CONTEXT" &>/dev/null &
echo $! > "/tmp/prometheus-pf-${CLUSTER_NAME}.pid"

kubectl port-forward -n monitoring svc/grafana "${GRAFANA_PORT}:3000" \
    --context "$KUBE_CONTEXT" &>/dev/null &
echo $! > "/tmp/grafana-pf-${CLUSTER_NAME}.pid"

success "Port-forwards restarted."

# ── Restart traffic generator if it was running ─────────────────────

TRAFFIC_PIDFILE="/tmp/dns-traffic-${CLUSTER_NAME}.pid"
if [ -f "$TRAFFIC_PIDFILE" ]; then
    TRAFFIC_PID=$(cat "$TRAFFIC_PIDFILE")
    if kill -0 "$TRAFFIC_PID" 2>/dev/null; then
        info "Restarting traffic generator..."
        kill "$TRAFFIC_PID" 2>/dev/null || true
        rm -f "$TRAFFIC_PIDFILE"
        sleep 1
        "${SCRIPT_DIR}/dns-traffic.sh" --background
        success "Traffic generator restarted."
    else
        rm -f "$TRAFFIC_PIDFILE"
    fi
fi

# ── Summary ──────────────────────────────────────────────────────────

echo ""
kubectl get pods --context "$KUBE_CONTEXT" -n monitoring -o wide

header "Monitoring Upgrade Complete"

echo "  Mode: full (CHAOS TXT + log parsing)"
echo ""
echo "  New metrics available:"
echo "    - dnsmasq_queries_total{type}     — queries by type"
echo "    - dnsmasq_forwards_total{to}      — forwards by upstream"
echo "    - dnsmasq_responses_total{source} — responses by source"
echo ""
echo "  New Grafana panels:"
echo "    - Total QPS                        (queries by type)"
echo "    - Queries by Type (A, AAAA, etc.)  (timeseries)"
echo "    - Responses by Source              (cached/forwarded/local)"
echo "    - Queries by Node                  (timeseries)"
echo "    - Forwards by Upstream             (timeseries)"
echo ""
echo "  New Prometheus alerts:"
echo "    - DnsmasqHighForwardRate (warning) — forward rate > 100/s for 5m"
echo "    - DnsmasqNoQueries (warning)       — zero queries for 10m"
echo ""
echo "  Prometheus:  http://localhost:${PROMETHEUS_PORT}"
echo "  Grafana:     http://localhost:${GRAFANA_PORT}"
echo ""
