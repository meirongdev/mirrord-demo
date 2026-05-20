# mirrord RBAC governance demo

A standalone demo of how a **cluster admin** controls which **developers**
can use mirrord, and against which namespaces. Everything runs in a local
kind cluster, but the RBAC pattern transfers directly to k3s / EKS / GKE.

> This is unrelated to the Spring Boot app in the repo root. It uses its
> own kind cluster (`mirrord-rbac-demo`), its own namespaces
> (`team-a-dev`, `team-b-dev`), and a tiny echo workload — the *point*
> isn't the app, it's the governance plumbing around it.

## The mental model

```
                   Cluster admin                            Developer (alice)
                   ─────────────                            ─────────────────
   1.  defines     ClusterRole mirrord-developer
                   ↓ (what verbs mirrord needs)
   2.  signs       client cert via K8s CSR API   ──────►   receives alice.kubeconfig
                                                            (identity, no permissions yet)
   3.  grants      RoleBinding alice → mirrord-developer
                   in namespace team-a-dev only
                                                          ◄  uses mirrord with that
                                                            kubeconfig; can target
                                                            workloads in team-a-dev
                                                            but is denied in team-b-dev
   4.  revokes     deletes the RoleBinding        ──────►   alice loses mirrord access
                                                            without losing her identity
```

Three primitives do all the work:

| Primitive | Owner | Scope | Purpose |
|---|---|---|---|
| `ClusterRole/mirrord-developer` | admin | cluster-wide definition | the *capability* (what verbs mirrord-agent needs) |
| client cert + kubeconfig | admin issues, developer holds | per-user | the *identity* |
| `RoleBinding` | admin | namespace | the *grant* — binds an identity to the capability inside one namespace |

A developer with a kubeconfig but no `RoleBinding` is authenticated but
authorized for nothing. That's the default-deny posture.

## Layout

```
rbac/
├── README.md                       this file
├── docs/
│   ├── admin-runbook.md            ← step-by-step for the cluster admin
│   └── developer-runbook.md        ← step-by-step for the developer
├── admin/
│   ├── kind-config.yaml
│   ├── manifests/                  ClusterRole, namespaces, workloads, RoleBinding template
│   └── scripts/                    bootstrap / issue kubeconfig / grant / revoke
├── developer/
│   ├── mirrord.json                example mirrord config
│   └── scripts/                    whoami + run-mirrord
└── validate-rbac.sh                end-to-end: allow + deny assertions
```

## TL;DR

```bash
# As admin
bash rbac/admin/scripts/bootstrap-cluster.sh
bash rbac/admin/scripts/issue-developer-kubeconfig.sh alice
bash rbac/admin/scripts/grant-namespace-access.sh alice team-a-dev
# hand alice the file at rbac/.credentials/alice.kubeconfig

# As developer (alice's laptop)
export KUBECONFIG=rbac/.credentials/alice.kubeconfig
bash rbac/developer/scripts/whoami.sh           # see what's allowed
bash rbac/developer/scripts/run-mirrord.sh      # mirror traffic from deployment/echo

# Regression check (admin)
bash rbac/validate-rbac.sh
```

Detailed walkthroughs:

- [`docs/admin-runbook.md`](docs/admin-runbook.md) — what the admin does
- [`docs/developer-runbook.md`](docs/developer-runbook.md) — what the developer does

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
- No `ClusterRoleBinding` is used. A developer can never gain mirrord
  rights across the whole cluster by accident.

You can swap the K8s CSR-issued cert for whatever your IDP gives you
(OIDC `sub`, SA token, etc.) — only the `subjects:` field of the
RoleBinding changes.
