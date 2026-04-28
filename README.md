# mirrord demo on kind

A minimal Spring Boot demo for learning how to use `mirrord` with a Kubernetes-hosted service and database.

## Architecture

```
  Your laptop
  ┌────────────────────────────────────────────────────┐
  │                                                    │
  │  $ make run-local                                  │
  │  ┌──────────────────────────────┐                  │
  │  │  Local Java process          │                  │
  │  │  (Spring Boot :8080)         │◄── curl :8080    │
  │  │                              │                  │
  │  │  mirrord agent               │                  │
  │  └──────────┬───────────────────┘                  │
  │             │  intercepts DB calls                 │
  │             │  + steals matching HTTP requests     │
  └─────────────┼────────────────────────────────────-─┘
                │ mirrord tunnels to pod
  kind cluster  │
  ┌─────────────▼────────────────────────────────────-─┐
  │                                                    │
  │  namespace: mirrord-demo                           │
  │  ┌─────────────────┐     ┌──────────────────────┐  │
  │  │  mirrord-demo   │     │  mysql               │  │
  │  │  Deployment     │────►│  Deployment :3306    │  │
  │  │  NodePort 30080 │     └──────────────────────┘  │
  │  └────────┬────────┘                               │
  └───────────┼────────────────────────────────────────┘
              │ kind port mapping
  curl :18080 ▼
  127.0.0.1:18080
```

What the demo proves:

1. A local process can read and write the **in-cluster MySQL** database through mirrord.
2. Requests carrying `x-mirrord-mode: steal` are **stolen** to the local process; all other requests continue hitting the in-cluster pod.

## Prerequisites

| Tool | Install |
|------|---------|
| Docker | https://docs.docker.com/get-docker/ |
| kind | `brew install kind` |
| kubectl | `brew install kubectl` |
| Java 21+ | `brew install --cask temurin@21` |
| Maven | `brew install maven` |
| mirrord | `brew install metalbear-co/mirrord/mirrord` |

## Quick start

```bash
make deploy    # build image → load into kind → deploy MySQL + app
make validate  # run end-to-end assertions
```

## Local debug flow

```bash
make deploy      # one-time setup

make run-local   # start the app locally with mirrord
```

In a second terminal:

```bash
# 1. Confirm the local process responds (handledBy: local)
curl http://127.0.0.1:8080/api/messages/current

# 2. Write through the local process
curl -X POST \
  -H 'Content-Type: application/json' \
  -d '{"message":"updated through local"}' \
  http://127.0.0.1:8080/api/messages/current

# 3. Confirm the cluster sees the update (same MySQL, handledBy: cluster)
curl http://127.0.0.1:18080/api/messages/current

# 4. Send a steal-header request through the cluster NodePort — local handles it
curl -H 'x-mirrord-mode: steal' http://127.0.0.1:18080/api/messages/current
```

## All make targets

```
make help        Show available targets
make build       Compile and test (produces target/*.jar)
make deploy      Create kind cluster + build image + deploy k8s resources
make run-local   Run app locally with mirrord
make validate    Run end-to-end validation
make status      Show pod status in the demo namespace
make clean       Delete the kind cluster
```

## About header-based stealing on kind

The `.mirrord/mirrord.json` config steals only requests that carry `x-mirrord-mode: steal`:

```json
{
  "target": {
    "namespace": "mirrord-demo",
    "path": "deployment/mirrord-demo"
  },
  "feature": {
    "network": {
      "incoming": {
        "mode": "steal",
        "http_filter": {
          "header_filter": "^x-mirrord-mode: steal$"
        }
      }
    }
  }
}
```

The important detail is **how** the request enters the cluster.

- Use the NodePort exposed by kind on `http://127.0.0.1:18080`
- Do **not** use `kubectl port-forward` for the incoming-traffic part of the demo

`kubectl port-forward` bypasses the normal pod network path, so mirrord cannot intercept those requests. This repo uses a kind port mapping plus a NodePort service so incoming requests traverse the path mirrord hooks into.

## Scripts reference

The Makefile targets delegate to these scripts, which can also be run directly:

| Script | Purpose |
|--------|---------|
| `bash scripts/deploy-demo.sh` | Full cluster + app deployment |
| `bash scripts/run-local-with-mirrord.sh` | Run local app via mirrord |
| `bash scripts/validate-demo.sh` | End-to-end assertions |
