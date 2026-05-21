# mirrord RBAC governance demo

A standalone demo of how a **cluster admin** controls which **developers**
can use mirrord, and against which namespaces. Everything runs in a local
kind cluster, but the RBAC pattern transfers directly to k3s / EKS / GKE.

> This is separate from the Spring Boot app in the repo root (`mirrord-demo`).
> The RBAC demo uses its own kind cluster (`mirrord-rbac-demo`) and its own
> namespaces (`team-a-dev`, `team-b-dev`), each with its own MySQL instance
> and Spring Boot application workload — the *point* isn't the app, it's the
> governance plumbing around it.

## Architecture

```
  Your laptop
  ┌────────────────────────────────────────────────────┐
  │                                                    │
  │  1. mvn package                                   │  ← build Spring Boot jar
  │  2. docker build -t mirrord-demo:local .          │
  │  3. kind load docker-image mirrord-demo:local      │
  │  4. kubectl apply -f rbac/.../04-mysql-template    │
  │  5. kubectl apply -f rbac/.../05-app-template      │
  │                                                    │
  │  ┌──────────────────────────────┐                  │
  │  │  Developer (alice)           │                  │
  │  │  export KUBECONFIG=alice.kb  │                  │
  │  │  bash run-mirrord.sh         │                  │
  │  └──────────┬───────────────────┘                  │
  │             │ mirrord attaches via RBAC-scoped     │
  │             │ kubeconfig + ClusterRole binding     │
  └─────────────┼────────────────────────────────────-─┘
                │
  kind cluster  │  ┌────────────────────────────────────────────┐
  ┌─────────────▼───────────────────────────────────────────────┐│
  │  namespace: team-a-dev                                       ││
  │  ┌────────────┐   ┌────────────┐   ┌────────────┐          ││
  │  │  app:8080  │←──│  mysql:3306│   │  mirrord-  │          ││
  │  │ (Spring    │   │            │   │  agent     │          ││
  │  │  Boot)     │   │            │   │            │          ││
  │  └────────────┘   └────────────┘   └────────────┘          ││
  │                                                            ││
  │  namespace: team-b-dev (isolated — alice has NO access)    ││
  │  ┌────────────┐   ┌────────────┐                           ││
  │  │  app:8080  │←──│  mysql:3306│                           ││
  │  └────────────┘   └────────────┘                           ││
  └────────────────────────────────────────────────────────────┘│
```

## What this demo proves

1. A developer with a scoped kubeconfig can only use mirrord against
   namespaces they've been explicitly granted.
2. Default-deny: a fresh kubeconfig has **zero** permissions.
3. After granting access to one namespace, the developer can:
   - List pods, deployments, create mirrord-agent jobs, port-forward
   - But is **denied** access to all other namespaces.
4. Revoking the RoleBinding instantly removes all mirrord access.
5. `mirrord ls` respects RBAC — it discovers workloads only in
   granted namespaces.

## The mental model

```
                   Cluster admin                            Developer (alice)
                   ─────────────                            ─────────────────
   1.  defines     ClusterRole mirrord-developer
                   ↓ (what verbs mirrord needs)
   2.  builds      Spring Boot app + MySQL                   builds jar locally
                   deploys to each namespace
                   ↓
   3.  signs       client cert via K8s CSR API   ──────►   receives alice.kubeconfig
                                                            (identity, no permissions yet)
   4.  grants      RoleBinding alice → mirrord-developer
                   in namespace team-a-dev only
                                                          ◄  uses mirrord with that
                                                            kubeconfig; can target
                                                            workloads in team-a-dev
                                                            but is denied in team-b-dev
   5.  revokes     deletes the RoleBinding        ──────►   alice loses mirrord access
                                                            without losing her identity
```

Four primitives do all the work:

| Primitive | Owner | Scope | Purpose |
|---|---|---|---|
| `ClusterRole/mirrord-developer` | admin | cluster-wide definition | the *capability* — every verb mirrord-agent needs inside a namespace |
| `ClusterRole/mirrord-impersonator` | admin | cluster-wide definition | the *one* cluster-scoped verb (`serviceaccounts: impersonate`) mirrord's WebSocket handshake requires — narrowly scoped, nothing else |
| client cert + kubeconfig | admin issues, developer holds | per-user | the *identity* |
| `RoleBinding` + per-user `ClusterRoleBinding` | admin | one per namespace + one per user | the *grant* — `RoleBinding` for the namespace-scoped capability, narrow `ClusterRoleBinding` to satisfy the cluster-scoped impersonation check |

A developer with a kubeconfig but no `RoleBinding` is authenticated but
authorized for nothing. That's the default-deny posture.

> **Why two bindings?** Kubernetes evaluates impersonation against a
> cluster-scoped virtual resource (`users`), which a `RoleBinding`
> physically cannot grant. So mirrord's permissions split by scope:
> the bulk lives in a per-namespace `RoleBinding`, and one tiny
> cluster-scoped binding handles the impersonation step. See
> [admin-runbook § Why two bindings](docs/admin-runbook.md#why-two-bindings)
> for the API-server-level details.

## Layout

```
rbac/
├── README.md                       ← this file
├── docs/
│   ├── admin-runbook.md            ← step-by-step for the cluster admin
│   ├── developer-runbook.md        ← step-by-step for the developer
│   └── scripts-reference.md        ← how each script works internally
├── admin/
│   ├── kind-config.yaml
│   ├── manifests/
│   │   ├── 01-mirrord-developer-clusterrole.yaml        ← ClusterRole (namespace-scoped verbs)
│   │   ├── 01b-mirrord-impersonator-clusterrole.yaml    ← ClusterRole (impersonate only, 1 rule)
│   │   ├── 02-namespaces.yaml                            ← team-a-dev, team-b-dev
│   │   ├── 03-test-workloads.yaml                        ← echo server (quick test)
│   │   ├── 04-mysql-template.yaml                        ← MySQL per namespace (template)
│   │   ├── 04-rolebinding-template.yaml                  ← per-namespace RoleBinding template
│   │   ├── 04b-mirrord-impersonator-rolebinding.yaml     ← per-user ClusterRoleBinding template
│   │   └── 05-app-template.yaml                          ← Spring Boot app per namespace (template)
│   └── scripts/
│       ├── bootstrap-cluster.sh                     ← one-command cluster setup
│       ├── issue-developer-kubeconfig.sh            ← CSR-based kubeconfig issuance
│       ├── grant-namespace-access.sh                ← create RoleBinding
│       ├── revoke-namespace-access.sh               ← delete RoleBinding
│       └── lib.sh                                   ← shared helpers
├── developer/
│   ├── mirrord.json                                 ← example mirrord config
│   └── scripts/
│       ├── whoami.sh                                ← identity + permission matrix
│       └── run-mirrord.sh                           ← launch mirrord + local cmd
└── validate-rbac.sh                                 ← end-to-end regression test
```

## TL;DR

```bash
# ── Prerequisites ──────────────────────────────────────────────────────
# Install: Docker, kind, kubectl, Java 21+, Maven, mirrord

# ── Build & deploy workloads (one-time setup) ─────────────────────────
mvn -q package
docker build -t mirrord-demo:local .
kind load docker-image mirrord-demo:local --name mirrord-rbac-demo

# ── Admin: bootstrap RBAC scaffold ────────────────────────────────────
bash rbac/admin/scripts/bootstrap-cluster.sh

# ── Admin: deploy MySQL + Spring Boot app to each namespace ───────────
sed 's/TEAM/team-a-dev/g' rbac/admin/manifests/04-mysql-template.yaml | kubectl apply -f -
sed 's/TEAM/team-a-dev/g' rbac/admin/manifests/05-app-template.yaml | kubectl apply -f -
sed 's/TEAM/team-b-dev/g' rbac/admin/manifests/04-mysql-template.yaml | kubectl apply -f -
sed 's/TEAM/team-b-dev/g' rbac/admin/manifests/05-app-template.yaml | kubectl apply -f -

# Wait for pods to be ready
kubectl -n team-a-dev rollout status deployment/mysql --timeout=120s
kubectl -n team-a-dev rollout status deployment/app --timeout=120s
kubectl -n team-b-dev rollout status deployment/mysql --timeout=120s
kubectl -n team-b-dev rollout status deployment/app --timeout=120s

# ── Admin: issue kubeconfig for a developer ───────────────────────────
bash rbac/admin/scripts/issue-developer-kubeconfig.sh alice
bash rbac/admin/scripts/grant-namespace-access.sh alice team-a-dev
# hand alice the file at rbac/.credentials/alice.kubeconfig

# ── Developer (alice) ─────────────────────────────────────────────────
export KUBECONFIG=rbac/.credentials/alice.kubeconfig
bash rbac/developer/scripts/whoami.sh           # see what's allowed
bash rbac/developer/scripts/run-mirrord.sh      # mirror traffic from deployment/app

# ── Admin: revoke access ──────────────────────────────────────────────
bash rbac/admin/scripts/revoke-namespace-access.sh alice team-a-dev

# ── Regression check (always) ─────────────────────────────────────────
bash rbac/validate-rbac.sh
```

## Why the Spring Boot app + MySQL?

The RBAC demo needs realistic workloads so developers can actually verify
they can reach in-cluster services through mirrord. Each namespace gets:

- **MySQL 8.4** — a real database that Spring Boot connects to. This proves
  that mirrord's outbound network tunneling works for TCP connections to
  cluster-internal services (not just simple HTTP echo servers).
- **Spring Boot app** — the same app from the repo root. It exposes
  `/api/messages/current` which reads from MySQL. When a developer runs
  mirrord against this deployment, their local process can read and write
  the in-cluster database.

This is more valuable than a bare echo server because it validates the
full mirrord data path: local process → mirrord-layer → agent pod →
in-cluster MySQL → back through mirrord to the local process.

## Why default-deny + per-namespace RoleBindings

mirrord-agent runs as a `Job` inside the target namespace and needs to
`create` pods, attach to existing ones (`pods/ephemeralcontainers`),
stream logs (`pods/log`), and port-forward (`pods/portforward`). Those
are *real* powers — anyone holding them in a namespace effectively has
shell access to every pod in that namespace.

The pattern in this demo:

- The dangerous verbs live in a **ClusterRole** so they're defined once
  and centrally reviewed.
- Each developer–namespace pairing is a separate **RoleBinding**.
  Granting access is one `kubectl apply`; revoking is one `kubectl delete`.
- The **one** `ClusterRoleBinding` per user is the narrowest possible:
  it points at a `ClusterRole` with a single rule (impersonate
  serviceaccounts) — required by mirrord's WebSocket handshake, and not
  satisfiable by a RoleBinding because Kubernetes evaluates that check
  against a cluster-scoped virtual resource (`users`). A developer
  never gains pod/job/log/portforward rights cluster-wide.

You can swap the K8s CSR-issued cert for whatever your IDP gives you
(OIDC `sub`, SA token, etc.) — only the `subjects:` field of the
RoleBinding changes.
