# ── Configuration ──────────────────────────────────────────────────
# All config comes from config.env. Edit that file to change defaults.

include config.env

# Kind needs this env var when using Podman
export KIND_EXPERIMENTAL_PROVIDER := $(CONTAINER_CLI)

.PHONY: help prereqs cluster-up deploy verify demo status clean

# ═══════════════════════════════════════════════════════════════════
#  Help
# ═══════════════════════════════════════════════════════════════════

help: ## Show available targets
	@echo ""
	@echo "dnsmasq on Kubernetes Nodes — Makefile Targets"
	@echo "=============================================="
	@echo ""
	@echo "  Kind (local):"
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
	    awk 'BEGIN {FS = ":.*?## "}; {printf "    \033[36m%-18s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Edit config.env to change cluster name, worker count, etc."
	@echo ""

# ═══════════════════════════════════════════════════════════════════
#  Kind (local) targets
# ═══════════════════════════════════════════════════════════════════

prereqs: ## Install kind and kubectl if missing
	@echo "Checking prerequisites..."
	@command -v $(CONTAINER_CLI) >/dev/null || \
	    (echo "ERROR: $(CONTAINER_CLI) not found. Install it first." && exit 1)
	@command -v kind >/dev/null || \
	    (echo "Installing kind..." && brew install kind)
	@command -v kubectl >/dev/null || \
	    (echo "Installing kubectl..." && brew install kubectl)
	@echo "All prerequisites installed."
	@echo "  Container CLI: $(CONTAINER_CLI)"
	@echo "  kind:          $$(kind version 2>/dev/null)"
	@echo "  kubectl:       $$(kubectl version --client --short 2>/dev/null || kubectl version --client 2>/dev/null | head -1)"

cluster-up: prereqs ## Create the Kind cluster
	@chmod +x scripts/setup-kind.sh
	@./scripts/setup-kind.sh

deploy: ## Deploy dnsmasq as a service to all nodes
	@chmod +x scripts/deploy-dnsmasq.sh
	@./scripts/deploy-dnsmasq.sh

verify: ## Run DNS verification tests on all nodes
	@chmod +x scripts/verify-dns.sh
	@./scripts/verify-dns.sh

demo: cluster-up deploy verify ## Full demo: create cluster, deploy dnsmasq, verify

status: ## Show cluster and dnsmasq service status
	@echo "Cluster: $(CLUSTER_NAME)"
	@echo ""
	@echo "Nodes:"
	@kubectl get nodes --context kind-$(CLUSTER_NAME) 2>/dev/null || echo "  Cluster not running"
	@echo ""
	@echo "dnsmasq Status on Nodes:"
	@for node in $$($(CONTAINER_CLI) ps --filter "label=io.x-k8s.kind.cluster=$(CLUSTER_NAME)" --format '{{.Names}}' | sort); do \
		echo "  $$node:"; \
		$(CONTAINER_CLI) exec $$node ps aux | grep -v grep | grep -q dnsmasq && echo "    ✓ Running" || echo "    ✗ Not running"; \
	done
	@echo ""
	@echo "CoreDNS Pods:"
	@kubectl get pods -n kube-system --context kind-$(CLUSTER_NAME) -l k8s-app=kube-dns 2>/dev/null || true

clean: ## Delete the Kind cluster and generated files
	@kind delete cluster --name $(CLUSTER_NAME) 2>/dev/null || true
	@rm -f kind-config.yaml
	@echo "Cluster '$(CLUSTER_NAME)' deleted."
