#!/usr/bin/env bash
#
# deploy-dnsmasq.sh — Deploy dnsmasq as a service to all nodes in a Kind cluster.
#
# This script:
#   1. Discovers all node containers for the given Kind cluster
#   2. Discovers the control-plane IP (API server) and first worker IP (Ingress)
#   3. Installs dnsmasq on each node with domain resolution + caching
#   4. Starts dnsmasq as a daemon on each node
#   5. Updates CoreDNS to forward to dnsmasq
#   6. Reconfigures each node's /etc/resolv.conf to use local dnsmasq
#
# Reads configuration from config.env.
# Usage: ./deploy-dnsmasq.sh [cluster-name] [container-cli]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "${SCRIPT_DIR}/common.sh"

load_project_config

CLUSTER_NAME="${1:-${CLUSTER_NAME}}"
CLI="${2:-${CONTAINER_CLI}}"
UPSTREAM_DNS="${UPSTREAM_DNS:-8.8.8.8,8.8.4.4}"
CACHE_SIZE="${CACHE_SIZE:-1000}"
DNS_FORWARD_MAX="${DNS_FORWARD_MAX:-10000}"
ENABLE_LOGGING="${ENABLE_LOGGING:-true}"

header "dnsmasq Deployment"

echo "  Cluster:       ${CLUSTER_NAME}"
echo "  Container CLI: ${CLI}"
echo "  Domain:        ${DOMAIN}"
echo "  Upstream DNS:  ${UPSTREAM_DNS}"
echo "  Cache size:    ${CACHE_SIZE}"
echo "  Logging:       ${ENABLE_LOGGING}"
echo ""

# ── 1. Discover node containers ──────────────────────────────────────

NODES=$($CLI ps --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" \
    --format '{{.Names}}' 2>/dev/null | sort)

if [ -z "$NODES" ]; then
    error "No nodes found for cluster '${CLUSTER_NAME}'. Is the cluster running?"
fi

NODE_COUNT=$(echo "$NODES" | wc -l | tr -d ' ')
info "Discovered ${NODE_COUNT} node(s):"
echo "$NODES" | while read -r node; do echo "  - ${node}"; done
echo ""

# ── 2. Discover node IPs ────────────────────────────────────────────

# Control-plane IP serves as the "API server load balancer" IP
CP_NODE=$(echo "$NODES" | grep "control-plane" | head -1)
CP_IP=$($CLI inspect "$CP_NODE" \
    --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)

# First worker IP serves as the "Ingress load balancer" IP
WORKER_NODE=$(echo "$NODES" | grep -v "control-plane" | head -1 || true)
if [ -n "$WORKER_NODE" ]; then
    INGRESS_IP=$($CLI inspect "$WORKER_NODE" \
        --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)
else
    INGRESS_IP="$CP_IP"
fi

info "IP Assignments (simulating load balancers):"
echo "  API Server (api.${DOMAIN}):          ${CP_IP}"
echo "  API Internal (api-int.${DOMAIN}):    ${CP_IP}"
echo "  Ingress (*.apps.${DOMAIN}):          ${INGRESS_IP}"
echo ""

# ── 3. Deploy to each node ──────────────────────────────────────────

echo "$NODES" | while read -r NODE; do
    info "--- Deploying to ${NODE} ---"

    # Get this node's IP
    NODE_IP=$($CLI inspect "$NODE" \
        --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null)

    echo "  Node IP: ${NODE_IP}"

    # Install dnsmasq and DNS utilities
    info "  Installing dnsmasq package..."
    $CLI exec "$NODE" bash -c '
        apt-get update -qq >/dev/null 2>&1 &&
        apt-get install -y dnsmasq dnsutils >/dev/null 2>&1
    ' || error "Failed to install dnsmasq on ${NODE}"
    success "  dnsmasq package installed."

    # Save original resolv.conf
    $CLI exec "$NODE" cp /etc/resolv.conf /etc/resolv.conf.original 2>/dev/null || true

    # Create upstream DNS configuration
    info "  Creating upstream DNS configuration..."
    NAMESERVERS=$(echo "$UPSTREAM_DNS" | tr ',' '\n')
    $CLI exec "$NODE" bash -c "cat > /etc/resolv.conf.upstream <<EOF
$(echo "$NAMESERVERS" | while read -r ns; do echo "nameserver $ns"; done)
EOF"

    # Create dnsmasq configuration with domain resolution
    info "  Creating dnsmasq configuration..."

    LOG_CONFIG=""
    if [ "$ENABLE_LOGGING" = "true" ]; then
        LOG_CONFIG="log-queries
log-facility=/var/log/dnsmasq.log"
    fi

    $CLI exec "$NODE" bash -c "cat > /etc/dnsmasq.conf <<'DNSCONF'
resolv-file=/etc/resolv.conf.upstream
dns-forward-max=${DNS_FORWARD_MAX}
cache-size=${CACHE_SIZE}
bind-interfaces
listen-address=0.0.0.0

# Local domain resolution (cluster-critical domains)
address=/api.${DOMAIN}/${CP_IP}
address=/api-int.${DOMAIN}/${CP_IP}
address=/.apps.${DOMAIN}/${INGRESS_IP}

${LOG_CONFIG}
DNSCONF"

    # Stop any existing dnsmasq processes
    $CLI exec "$NODE" killall dnsmasq 2>/dev/null || true
    sleep 1

    # Start dnsmasq daemon
    info "  Starting dnsmasq daemon..."
    $CLI exec "$NODE" /usr/sbin/dnsmasq

    # Wait for dnsmasq to start listening on port 53
    info "  Waiting for dnsmasq to start..."
    STARTED=false
    for i in $(seq 1 30); do
        if $CLI exec "$NODE" sh -c \
            "ss -ulnp 2>/dev/null | grep -q ':53 ' || netstat -ulnp 2>/dev/null | grep -q ':53 '" \
            2>/dev/null; then
            STARTED=true
            break
        fi
        sleep 1
    done

    if [ "$STARTED" = true ]; then
        success "  dnsmasq is running and listening on port 53."
    else
        error "dnsmasq failed to start on ${NODE}"
    fi

    # Reconfigure DNS to use local dnsmasq
    $CLI exec "$NODE" sh -c "
        cat > /etc/resolv.conf <<RESOLV
nameserver ${NODE_IP}
nameserver $(echo "$UPSTREAM_DNS" | tr ',' '\n' | head -1)
search ${DOMAIN}
RESOLV
    "
    info "  /etc/resolv.conf updated: nameserver ${NODE_IP} (local dnsmasq)"

    echo ""
done

# ── 4. Update CoreDNS to forward to dnsmasq ────────────────────────────

info "Configuring CoreDNS to forward to dnsmasq..."

# Backup original CoreDNS ConfigMap
kubectl get configmap coredns -n kube-system -o yaml \
    --context "kind-${CLUSTER_NAME}" > "${REPO_DIR}/coredns-backup.yaml" 2>/dev/null || true

# Update CoreDNS ConfigMap with correct forward directive and cache TTL
cat > /tmp/corefile-patch.yaml <<'EOFPATCH'
data:
  Corefile: |
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        prometheus :9153
        forward . {$HOST_IP}:53 {
          max_concurrent 1000
          policy sequential
          force_tcp
        }
        cache 10 {
           disable success cluster.local
           disable denial cluster.local
        }
        loop
        reload
        loadbalance
    }
EOFPATCH

# Apply the patch
kubectl patch configmap coredns -n kube-system --context "kind-${CLUSTER_NAME}" \
    --patch-file /tmp/corefile-patch.yaml >/dev/null 2>&1
rm -f /tmp/corefile-patch.yaml

success "CoreDNS ConfigMap updated."
echo ""

# ── 5. Add HOST_IP environment variable to CoreDNS ──────────────────────

info "Adding HOST_IP environment variable to CoreDNS deployment..."

# Check if HOST_IP already exists
if kubectl get deployment coredns -n kube-system -o yaml \
    --context "kind-${CLUSTER_NAME}" | grep -q "name: HOST_IP"; then
    warn "HOST_IP already exists in CoreDNS deployment, skipping..."
else
    kubectl patch deployment coredns -n kube-system \
        --context "kind-${CLUSTER_NAME}" \
        --type=json \
        -p='[{"op":"add","path":"/spec/template/spec/containers/0/env","value":[{"name":"HOST_IP","valueFrom":{"fieldRef":{"fieldPath":"status.hostIP"}}}]}]' \
        >/dev/null 2>&1
    success "HOST_IP environment variable added."
fi

echo ""

# ── 6. Wait for CoreDNS rollout ──────────────────────────────────────────

info "Waiting for CoreDNS rollout to complete..."

kubectl rollout status deployment coredns -n kube-system \
    --context "kind-${CLUSTER_NAME}" \
    --timeout=120s >/dev/null 2>&1

success "CoreDNS rollout complete."
echo ""

# ── 7. Summary ──────────────────────────────────────────────────────────

header "Deployment Complete"

echo "  dnsmasq deployed to all ${NODE_COUNT} node(s)."
echo "  CoreDNS configured to forward to dnsmasq on each node."
echo ""
echo "  Domains resolved locally (no external DNS):"
echo "    api.${DOMAIN}         -> ${CP_IP}"
echo "    api-int.${DOMAIN}     -> ${CP_IP}"
echo "    *.apps.${DOMAIN}      -> ${INGRESS_IP}"
echo ""
echo "  DNS Flow:"
echo "    Pod -> CoreDNS (10s cache) -> dnsmasq (TTL cache) -> Upstream DNS"
echo ""
echo "  Next step: make verify"
echo ""
