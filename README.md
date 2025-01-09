# MPIIT Automation Data
Fetch, process, and export MPIIT automation data.

Requirements:
- `podman`/`docker`
- `make`

Fetch and output latest JSON:
```bash
make
```

Output JSON from cache (if present):
```bash
make dev
```