# MPIIT Automation Data
Fetch, process, and export MPIIT automation data.

Requirements:
- `podman`/`docker`
- `make`

Fetch and output latest JSON:
```bash
make
```

Build with caching enabled and attach to container:
```bash
make dev
```

Output the job verification results:
```bash
make verify
```