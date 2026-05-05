#!/usr/bin/env bash
#
# setup-kind.sh — Create a Kind cluster for dnsmasq testing.
#
# This script:
#   1. Validates prerequisites (kind, kubectl, container CLI)
#   2. Generates a Kind cluster configuration
#   3. Creates the cluster with control-plane + N workers
#   4. Waits for all nodes to be ready
#
# Reads configuration from config.env.
# Usage: ./setup-kind.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
source "${SCRIPT_DIR}/common.sh"

load_project_config

CLUSTER_NAME="${CLUSTER_NAME:-dnsmasq-test}"
CLI="${CONTAINER_CLI:-docker}"
WORKER_COUNT="${WORKER_COUNT:-2}"

header "Kind Cluster Setup"

echo "  Cluster name:  ${CLUSTER_NAME}"
echo "  Container CLI: ${CLI}"
echo "  Workers:       ${WORKER_COUNT}"
echo ""

# ── 1. Check prerequisites ────────────────────────────────────────────

info "Checking prerequisites..."

if ! command -v "$CLI" >/dev/null 2>&1; then
    error "$CLI not found. Install Docker or Podman first."
fi

if ! command -v kind >/dev/null 2>&1; then
    error "kind not found. Install it: brew install kind"
fi

if ! command -v kubectl >/dev/null 2>&1; then
    error "kubectl not found. Install it: brew install kubectl"
fi

success "Prerequisites satisfied."
echo "  $CLI: $(command -v $CLI)"
echo "  kind: $(kind version 2>&1 | head -1)"
echo "  kubectl: $(kubectl version --client --short 2>/dev/null | head -1 || echo $(kubectl version --client 2>&1 | head -1))"
echo ""

# ── 2. Generate Kind configuration ────────────────────────────────────

info "Generating Kind cluster configuration..."

CONFIG_FILE="${REPO_DIR}/kind-config.yaml"

cat > "$CONFIG_FILE" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: ${CLUSTER_NAME}
nodes:
  - role: control-plane
EOF

for i in $(seq 1 "$WORKER_COUNT"); do
    echo "  - role: worker" >> "$CONFIG_FILE"
done

success "Configuration written to kind-config.yaml"
echo ""

# ── 3. Create the cluster ──────────────────────────────────────────────

info "Creating Kind cluster '${CLUSTER_NAME}'..."

if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    warn "Cluster '${CLUSTER_NAME}' already exists."
    if ! confirm "Delete and recreate?"; then
        info "Keeping existing cluster."
        exit 0
    fi
    kind delete cluster --name "$CLUSTER_NAME"
fi

# Set environment variable for Podman if needed
if [ "$CLI" = "podman" ]; then
    export KIND_EXPERIMENTAL_PROVIDER=podman
fi

kind create cluster --config "$CONFIG_FILE"

success "Cluster created."
echo ""

# ── 4. Wait for nodes to be ready ──────────────────────────────────────

info "Waiting for all nodes to be ready..."

kubectl wait --for=condition=Ready nodes --all --timeout=120s \
    --context "kind-${CLUSTER_NAME}" >/dev/null 2>&1 || \
    error "Nodes did not become ready in time."

TOTAL_NODES=$((WORKER_COUNT + 1))
success "All ${TOTAL_NODES} nodes are ready."
echo ""

# ── 5. Set container restart policy ────────────────────────────────────

info "Setting restart policy on node containers..."

NODES=$($CLI ps --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" \
    --format '{{.Names}}' 2>/dev/null | sort)

for node in $NODES; do
    $CLI update --restart=unless-stopped "$node" >/dev/null 2>&1
    echo "  ✓ ${node}"
done

echo ""
success "Restart policy set to 'unless-stopped' (survives Docker/Podman restart)."
echo ""

# ── 6. Summary ──────────────────────────────────────────────────────────

header "Cluster Ready"

echo "  Cluster: ${CLUSTER_NAME}"
echo "  Nodes:   ${TOTAL_NODES} (1 control-plane + ${WORKER_COUNT} workers)"
echo ""
echo "  View nodes:"
echo "    kubectl get nodes --context kind-${CLUSTER_NAME}"
echo ""
echo "  Next step: make deploy"
echo ""
