# Project Structure

This project deploys **dnsmasq as a daemon service** on Kubernetes nodes for node-local DNS caching. It follows the same organizational pattern as [custom-dns-kubernetes](../custom-dns-kubernetes), with comprehensive verification that shows detailed query results, dnsmasq logs, and explanations.

## Directory Layout

```
dnsmasq-on-k8Node/
├── config.env                          # Central configuration file
├── Makefile                            # Automation targets (Kind-based)
├── README.md                           # Project overview and quick start
├── DEMO.md                             # Step-by-step demo guide
├── PROJECT-STRUCTURE.md                # This file
├── .gitignore                          # Git ignore patterns
│
├── manifests/                          # Configuration templates
│   └── dnsmasq.conf.template          # dnsmasq configuration template
│
└── scripts/                            # Shell scripts (Kind-based)
    ├── common.sh                       # Shared utility functions
    ├── setup-kind.sh                   # Create Kind cluster
    ├── deploy-dnsmasq.sh              # Deploy dnsmasq to all nodes
    └── verify-dns.sh                  # Run verification tests
```

## File Descriptions

### Configuration
- **config.env**: All configuration in one place. Edit before running any targets.
  - Cluster settings (name, worker count)
  - Container runtime (docker/podman)
  - dnsmasq settings (cache size, upstream DNS, logging)

### Automation
- **Makefile**: Primary interface for all operations
  - `make demo`: Full lifecycle (cluster + deploy + verify)
  - `make status`: Show cluster status
  - `make clean`: Delete cluster

### Documentation
- **README.md**: Project overview, architecture, quick start
- **DEMO.md**: Step-by-step demo guide with expected outputs
- **PROJECT-STRUCTURE.md**: This file

### Manifests
- **dnsmasq.conf.template**: dnsmasq configuration template
  - Shows the configuration structure
  - Variables replaced by deploy script
  - Deployed to `/etc/dnsmasq.conf` on each node

### Scripts
All scripts follow the same pattern:
1. Source `common.sh` for utilities
2. Load configuration from `config.env`
3. Perform operations with colored output
4. Provide clear success/error messages

- **common.sh**: Shared utilities
  - Color functions (info, success, warn, error)
  - Header formatting
  - Config loading helpers

- **setup-kind.sh**: Create Kind cluster
  - Validates prerequisites
  - Generates cluster config
  - Creates cluster with 1 control-plane + N workers
  - Sets restart policy on containers

- **deploy-dnsmasq.sh**: Deploy dnsmasq
  - Discovers all cluster nodes
  - Installs dnsmasq package on each node
  - Creates dnsmasq configuration on each node
  - Starts dnsmasq daemon on each node
  - Updates CoreDNS to forward to dnsmasq
  - Adds HOST_IP environment variable to CoreDNS

- **verify-dns.sh**: Run verification tests (with detailed output)
  - Test 1: Verify dnsmasq service running on all nodes
    - Shows PID, command, and listening port for each dnsmasq instance
    - Explains daemon service deployment model
  - Test 2: Node-level DNS resolution
    - Shows query, resolved IPs, and dnsmasq logs for each node
    - Explains direct node-to-dnsmasq communication
  - Test 3: Pod DNS resolution (CoreDNS → dnsmasq)
    - Shows complete DNS chain with node mapping
    - Displays query results and dnsmasq logs
    - Explains two-layer caching architecture
  - Test 4: Verify caching behavior
    - Demonstrates cache miss vs cache hit with actual query results
    - Shows dnsmasq logs with 'forwarded' and 'cached' entries
    - Explains latency benefits and TTL-based caching
  - Test 5: Multi-node distribution
    - Verifies independent caching on each node
    - Shows per-node DNS chain and logs
    - Explains node-local optimization

## Usage Patterns

### Quick Demo
```bash
make demo       # Create cluster, deploy dnsmasq, verify (includes caching tests)
make clean      # Delete cluster
```

### Step-by-Step
```bash
make prereqs      # Install prerequisites
make cluster-up   # Create cluster only
make deploy       # Deploy dnsmasq only
make verify       # Run tests only
make status       # Check status
make clean        # Delete cluster
```

### Manual Exploration
```bash
# After make demo
docker ps | grep dnsmasq-test
docker exec dnsmasq-test-worker ps aux | grep dnsmasq
docker exec dnsmasq-test-worker cat /var/log/dnsmasq.log
docker exec dnsmasq-test-worker cat /etc/dnsmasq.conf
```

## Key Features

### Deployment Model
- **Daemon service** (not pod): dnsmasq runs as `/usr/sbin/dnsmasq` directly on each node
- **One instance per node**: Each node has independent dnsmasq with its own cache
- **Port 53 binding**: Listens on all interfaces (0.0.0.0:53 UDP)
- **Node-local routing**: CoreDNS uses `{$HOST_IP}:53` to reach dnsmasq on same node

## Future Enhancements

### Potential Additions
1. **Cloud support**: Add `<cloud provider>/` directory with necessary scripts
2. **Metrics collection**: Parse dnsmasq logs for metrics
3. **Grafana dashboards**: Visualize cache hit rates, query latency from logs
4. **E2E tests**: Automated testing framework
5. **systemd integration**: Proper service management on real nodes (non-kind)

## Contributing

When adding new features, follow the existing patterns:
- Update `config.env` for new configuration
- Add Makefile targets for new operations
- Create scripts in `scripts/` directory
- Use `common.sh` utility functions
- Add documentation to README.md
- Update DEMO.md with demo steps
