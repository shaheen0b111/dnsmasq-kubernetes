#!/usr/bin/env bash
# deploy-dnsmasq-azure.sh — Deploy dnsmasq to all Azure k3s nodes.
#
# This script:
#   1. Installs dnsmasq on each VM via SSH
#   2. Configures dnsmasq with domain resolution + upstream forwarding + caching
#   3. Enables and starts dnsmasq via systemd on each VM
#   4. Reconfigures /etc/resolv.conf to use local dnsmasq
#
# Reads config from config.env + azure/.env (runtime IPs).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "${REPO_DIR}/scripts/common.sh"

load_project_config

ENVFILE="${SCRIPT_DIR}/.env"
UPSTREAM_DNS="${UPSTREAM_DNS:-8.8.8.8,8.8.4.4}"
CACHE_SIZE="${CACHE_SIZE:-1000}"
DNS_FORWARD_MAX="${DNS_FORWARD_MAX:-10000}"
ENABLE_LOGGING="${ENABLE_LOGGING:-true}"

# ── Load runtime state ────────────────────────────────────────────

if [ ! -f "$ENVFILE" ]; then
    error "azure/.env not found. Run 'make azure-infra' first."
fi

load_config "$ENVFILE"

header "dnsmasq Deployment (Azure)"

info "Configuration:"
echo "  Cluster:          ${CLUSTER_NAME}"
echo "  Domain:           ${DOMAIN}"
echo "  Control plane:    ${CP_VM} (${CP_PRIVATE_IP})"
echo "  Ingress IP:       ${INGRESS_IP}"
echo "  Workers:          ${WORKER_COUNT}"
echo "  Cache size:       ${CACHE_SIZE}"
echo ""
echo "  IP Assignments (simulating load balancers):"
echo "    api.${DOMAIN}:          ${CP_PRIVATE_IP}"
echo "    api-int.${DOMAIN}:      ${CP_PRIVATE_IP}"
echo "    *.apps.${DOMAIN}:       ${INGRESS_IP}"
echo ""

# ── Build VM/IP lists ──────────────────────────────────────────────

ALL_VMS="${CP_VM} ${WORKER_VMS}"
ALL_PUBLIC="${CP_PUBLIC_IP} ${WORKER_PUBLIC_IPS}"
ALL_PRIVATE="${CP_PRIVATE_IP} ${WORKER_PRIVATE_IPS}"

VM_COUNT=$(echo "$ALL_VMS" | wc -w | tr -d ' ')

# ── Deploy to each VM ──────────────────────────────────────────────

VM_INDEX=1
for VM in $ALL_VMS; do
    PUB_IP=$(echo "$ALL_PUBLIC"  | awk "{print \$${VM_INDEX}}")
    PRIV_IP=$(echo "$ALL_PRIVATE" | awk "{print \$${VM_INDEX}}")

    echo ""
    info "--- Deploying to ${VM} (${PRIV_IP}) ---"

    # Discover upstream DNS on the VM
    UPSTREAM=$(ssh_exec "$PUB_IP" \
        "grep '^nameserver' /etc/resolv.conf | head -1 | awk '{print \$2}'" 2>/dev/null || echo "")

    # On Azure, the upstream is typically 168.63.129.16 (Azure DNS wire server)
    if [ -z "$UPSTREAM" ]; then
        UPSTREAM="168.63.129.16"
    fi

    echo "  Node IP:       ${PRIV_IP}"
    echo "  Upstream DNS:  ${UPSTREAM}"

    # Install dnsmasq
    info "  Installing dnsmasq..."
    ssh_exec "$PUB_IP" "
        sudo apt-get update -qq >/dev/null 2>&1
        sudo apt-get install -y -qq dnsmasq dnsutils >/dev/null 2>&1
    " || error "Failed to install dnsmasq on ${VM}"
    success "  dnsmasq package installed."

    # Save upstream DNS
    ssh_exec "$PUB_IP" "
        sudo cp /etc/resolv.conf /etc/resolv.conf.upstream 2>/dev/null || true
        echo 'nameserver ${UPSTREAM}' | sudo tee /etc/resolv.conf.upstream >/dev/null
    "

    # Build logging config
    LOG_CONFIG=""
    if [ "$ENABLE_LOGGING" = "true" ]; then
        LOG_CONFIG="log-queries
log-facility=/var/log/dnsmasq.log"
    fi

    # Create dnsmasq configuration with domain resolution
    info "  Creating dnsmasq configuration..."
    ssh_exec "$PUB_IP" "
        sudo systemctl stop dnsmasq 2>/dev/null || true
        sudo killall dnsmasq 2>/dev/null || true

        sudo tee /etc/dnsmasq.conf >/dev/null <<'DNSCONF'
resolv-file=/etc/resolv.conf.upstream
dns-forward-max=${DNS_FORWARD_MAX}
cache-size=${CACHE_SIZE}
bind-interfaces
listen-address=0.0.0.0

# Local domain resolution (cluster-critical domains)
address=/api.${DOMAIN}/${CP_PRIVATE_IP}
address=/api-int.${DOMAIN}/${CP_PRIVATE_IP}
address=/.apps.${DOMAIN}/${INGRESS_IP}

${LOG_CONFIG}
DNSCONF
    "

    # Start dnsmasq via systemd
    info "  Starting dnsmasq service..."
    ssh_exec "$PUB_IP" "sudo systemctl enable --now dnsmasq"

    # Wait for dnsmasq to start
    info "  Waiting for dnsmasq to start..."
    STARTED=false
    for attempt in $(seq 1 30); do
        if ssh_exec "$PUB_IP" "ss -ulnp 2>/dev/null | grep -q ':53 '" 2>/dev/null; then
            STARTED=true
            break
        fi
        sleep 1
    done

    if [ "$STARTED" = true ]; then
        success "  dnsmasq is listening on port 53."
    else
        warn "  dnsmasq may not be ready yet."
    fi

    VM_INDEX=$((VM_INDEX + 1))
done

# ── Reconfigure resolv.conf ──────────────────────────────────────────

echo ""
info "Reconfiguring /etc/resolv.conf on all VMs..."

VM_INDEX=1
for VM in $ALL_VMS; do
    PUB_IP=$(echo "$ALL_PUBLIC"  | awk "{print \$${VM_INDEX}}")
    PRIV_IP=$(echo "$ALL_PRIVATE" | awk "{print \$${VM_INDEX}}")

    UPSTREAM=$(ssh_exec "$PUB_IP" \
        "grep '^nameserver' /etc/resolv.conf.upstream 2>/dev/null | head -1 | awk '{print \$2}'" \
        2>/dev/null || echo "168.63.129.16")

    ssh_exec "$PUB_IP" "
        echo 'nameserver ${PRIV_IP}
nameserver ${UPSTREAM}
search ${DOMAIN}' | sudo tee /etc/resolv.conf >/dev/null
    "

    info "  ${VM}: /etc/resolv.conf -> ${PRIV_IP} (local dnsmasq)"
    VM_INDEX=$((VM_INDEX + 1))
done

# ── Summary ──────────────────────────────────────────────────────────

header "Deployment Complete (Azure)"

echo "  dnsmasq deployed to ${VM_COUNT} VMs."
echo ""
echo "  Domains resolved locally (no Azure DNS):"
echo "    api.${DOMAIN}         -> ${CP_PRIVATE_IP}"
echo "    api-int.${DOMAIN}     -> ${CP_PRIVATE_IP}"
echo "    *.apps.${DOMAIN}      -> ${INGRESS_IP}"
echo ""
echo "  Next step:  make azure-verify    (run DNS verification tests)"
echo ""
