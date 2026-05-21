# Admin runbook — managing developer mirrord access

This is a step-by-step for the **cluster admin** (the person with full
`kubectl` against the target cluster). Everything below is done from the
repo root.

## Prerequisites

| Tool | Install |
|---|---|
| Docker | <https://docs.docker.com/get-docker/> |
| kind | `brew install kind` |
| kubectl | `brew install kubectl` |
| Java 21+ | `brew install --cask temurin@21` |
| Maven | `brew install maven` |
| mirrord | `brew install metalbear-co/mirrord/mirrord` |
| openssl | preinstalled on macOS |

> The demo is kind-based for reproducibility. On a real k3s/EKS cluster
> you skip step 1 — everything else is unchanged.

## Overview: What you're building

The admin's job is to stand up the full infrastructure that developers
will attach to with mirrord:

```
  step 1-3: build & load Docker image into kind
  step 4:   create kind cluster + RBAC scaffold (ClusterRole + namespaces)
  step 5:   deploy MySQL + Spring Boot app into each namespace
  step 6:   issue kubeconfig for a developer (CSR-based identity)
  step 7:   grant developer access to one namespace (RoleBinding)
  step 8:   (optional) revoke access when no longer needed
```

---

## Step 1 — Build the Spring Boot application

The RBAC demo uses the same Spring Boot app from the repo root as the
workload. Build it first:

```bash
mvn -q package
```

Produces `target/mirrord-demo-0.0.1-SNAPSHOT.jar` (~23 MB).

---

## Step 2 — Build and load the Docker image into kind

mirrord needs a containerized workload to attach to. Build the image
and load it into the kind node:

```bash
docker build -t mirrord-demo:local .
kind load docker-image mirrord-demo:local --name mirrord-rbac-demo
```

The image tag `mirrord-demo:local` and the `imagePullPolicy: Never` in
the deployment manifests ensure kind uses the locally-loaded image
instead of trying to pull from a registry.

---

## Step 3 — Create the kind cluster (if not using existing one)

```bash
# Optional: create the kind cluster manually
kind create cluster --name mirrord-rbac-demo --config rbac/admin/kind-config.yaml
```

The cluster config (`rbac/admin/kind-config.yaml`) creates a single
control-plane node with no extra port mappings.

Verify:

```bash
kubectl --context kind-mirrord-rbac-demo cluster-info
```

---

## Step 4 — Apply the RBAC scaffold

The RBAC scaffold consists of four cluster-wide resources:

1. **ClusterRole `mirrord-developer`** (`01-mirrord-developer-clusterrole.yaml`)
   — the *capability* definition for namespace-scoped mirrord operations.
   Read it before applying; it documents every permission mirrord-agent
   needs and why. See the table in
   [§ Why ClusterRole needs these permissions](#why-clusterrole-needs-these-permissions) below.

2. **ClusterRole `mirrord-impersonator`** (`01b-mirrord-impersonator-clusterrole.yaml`)
   — a minimal, cluster-scoped role granting only `serviceaccounts: get, impersonate`.
   mirrord's agent WebSocket handshake impersonates the target pod's
   ServiceAccount; that check is cluster-scoped and cannot be satisfied
   by a namespace RoleBinding alone (you'd see a `403 Forbidden` on
   protocol upgrade). Per-user `ClusterRoleBinding`s reference this role.

3. **Namespaces** (`02-namespaces.yaml`) — two isolated workspaces
   (`team-a-dev`, `team-b-dev`), each labelled
   `pod-security.kubernetes.io/enforce=privileged` so mirrord-agent's
   `NET_ADMIN` / `SYS_PTRACE` capabilities aren't rejected.

4. **Echo workloads** (`03-test-workloads.yaml`) — tiny echo servers
   as a quick smoke-test workload.

Apply all four at once:

```bash
kubectl apply -f rbac/admin/manifests/01-mirrord-developer-clusterrole.yaml
kubectl apply -f rbac/admin/manifests/01b-mirrord-impersonator-clusterrole.yaml
kubectl apply -f rbac/admin/manifests/02-namespaces.yaml
kubectl apply -f rbac/admin/manifests/03-test-workloads.yaml
```

Verify:

```bash
kubectl get clusterrole mirrord-developer mirrord-impersonator
kubectl get ns team-a-dev team-b-dev
kubectl get deploy -n team-a-dev -n team-b-dev
```

---

## Step 5 — Deploy MySQL + Spring Boot app to each namespace

Each namespace needs its own MySQL instance (isolated databases) and the
Spring Boot app that connects to it.

### 5a. Deploy MySQL

MySQL is deployed from a template file where `TEAM` is substituted:

```bash
# team-a-dev
sed 's/TEAM/team-a-dev/g' rbac/admin/manifests/04-mysql-template.yaml | kubectl apply -f -

# team-b-dev
sed 's/TEAM/team-b-dev/g' rbac/admin/manifests/04-mysql-template.yaml | kubectl apply -f -
```

This creates a `Service` (port 3306) and a `Deployment` with:
- `MYSQL_DATABASE=mirrord_demo`
- `MYSQL_USER=demo` / `MYSQL_PASSWORD=demo`
- `MYSQL_ROOT_PASSWORD=root-demo`
- readiness/liveness probes via `mysqladmin ping`

### 5b. Deploy the Spring Boot app

The app connects to the in-cluster MySQL and exposes `/api/messages/current`:

```bash
# team-a-dev
sed 's/TEAM/team-a-dev/g' rbac/admin/manifests/05-app-template.yaml | kubectl apply -f -

# team-b-dev
sed 's/TEAM/team-b-dev/g' rbac/admin/manifests/05-app-template.yaml | kubectl apply -f -
```

Wait for all pods to be ready:

```bash
kubectl -n team-a-dev rollout status deployment/mysql --timeout=120s
kubectl -n team-a-dev rollout status deployment/app --timeout=120s
kubectl -n team-b-dev rollout status deployment/mysql --timeout=120s
kubectl -n team-b-dev rollout status deployment/app --timeout=120s
```

Verify the app can reach MySQL:

```bash
kubectl -n team-a-dev logs deployment/app --tail=10
# Look for: "HikariPool-1 - Start completed."

kubectl -n team-a-dev exec deployment/app -- curl -s http://localhost:8080/api/messages/current
# Expected: {"message":"hello from cluster","handledBy":"cluster"}
```

### Alternative: one-command bootstrap

Run `bootstrap-cluster.sh` to create the kind cluster and apply only the
ClusterRole + namespaces + echo workloads (steps 1-3 above combined):

```bash
bash rbac/admin/scripts/bootstrap-cluster.sh
```

This is idempotent — safe to re-run. After bootstrap, manually deploy
MySQL and the app (steps 5a-5b) as described above.

---

## Step 6 — Issue a kubeconfig for a developer

For each developer (here: `alice`):

```bash
bash rbac/admin/scripts/issue-developer-kubeconfig.sh alice
```

### How CSR-based kubeconfig issuance works

This script uses the Kubernetes CertificateSigningRequest (CSR) API to
issue a per-user client certificate. No external CA or OIDC dependency:

1. **Generate key pair** — `openssl genrsa 2048` → `rbac/.credentials/alice/alice.key` (mode `0600`).

2. **Create CSR** — `openssl req -new -subj "/CN=alice"` → `alice.csr`.
   The `CN` value becomes the Kubernetes username that RoleBindings reference.

3. **Submit CSR** — Create a `CertificateSigningRequest` resource in the
   cluster with:
   - `signerName: kubernetes.io/kube-apiserver-client` (standard client cert)
   - `expirationSeconds: 31536000` (1 year validity)
   - `usages: [client auth]` (cannot be used for server auth)

4. **Approve CSR** — `kubectl certificate approve mirrord-rbac-demo-alice`.
   This is the admin action; in production a webhook or cert-manager
   Controller might automate this based on policy.

5. **Download signed certificate** — Poll `status.certificate` on the CSR
   until the apisignersigner issues it (up to 30 seconds).

6. **Assemble kubeconfig** — Merge the cluster server URL, CA data, signed
   user cert, and private key into a standalone `Config` document. Write
   to `rbac/.credentials/alice.kubeconfig` (mode `0600`).

The certificate is valid for **one year**. Rotate by re-running the script
—the old CSR is deleted and replaced, invalidating the old cert.

**Crucial:** Alice has a working kubeconfig at this point, but **no
authorization**. Verify:

```bash
KUBECONFIG=rbac/.credentials/alice.kubeconfig kubectl auth whoami
# → alice

KUBECONFIG=rbac/.credentials/alice.kubeconfig kubectl auth can-i list pods -n team-a-dev
# → no  (expected: no RoleBinding yet)
```

---

## Step 7 — Grant a developer access to one namespace

```bash
bash rbac/admin/scripts/grant-namespace-access.sh alice team-a-dev
```

### How RoleBinding-based access control works

This script applies two bindings: a namespace-scoped `RoleBinding` that
grants the bulk of mirrord-developer powers, and a per-user
`ClusterRoleBinding` that grants the single cluster-scoped permission
mirrord needs (serviceaccount impersonation).

#### a. Namespace `RoleBinding` (mirrord-developer)

Rendered from `04-rolebinding-template.yaml`:

```yaml
kind: RoleBinding
metadata:
  name: mirrord-developer-alice
  namespace: team-a-dev
roleRef:
  kind: ClusterRole
  name: mirrord-developer
subjects:
  - kind: User
    name: alice
```

This binding says:

> *Inside namespace `team-a-dev`, user `alice` has every verb listed in
> ClusterRole `mirrord-developer`.*

The binding is scoped to a single namespace. Granting access to a second
namespace requires a second RoleBinding.

#### b. `ClusterRoleBinding` for impersonation (mirrord-impersonator)

Rendered from `04b-mirrord-impersonator-rolebinding.yaml`:

```yaml
kind: ClusterRoleBinding
metadata:
  name: mirrord-impersonator-alice
roleRef:
  kind: ClusterRole
  name: mirrord-impersonator   # serviceaccounts: get, impersonate
subjects:
  - kind: User
    name: alice
```

Why a `ClusterRoleBinding` here? mirrord's agent WebSocket handshake
authenticates as the target pod's `ServiceAccount`. Kubernetes evaluates
`serviceaccounts/impersonate` at cluster scope — a namespace `RoleBinding`
that grants the same verb does **not** satisfy it, and the tunnel upgrade
fails with `403 Forbidden`. The `mirrord-impersonator` ClusterRole is
narrow on purpose: only `get` and `impersonate` on `serviceaccounts`,
nothing else. One `ClusterRoleBinding` per user; revocation deletes it
when the user has no remaining namespace `RoleBinding`s.

### Why per-namespace RoleBindings instead of a single ClusterRoleBinding?

For the bulk of mirrord's permissions, a `ClusterRoleBinding` would give
the developer cluster-wide access. That's intentionally avoided because:

- **Least privilege** — developers only get access to the namespaces they
  actually need.
- **Easy revocation** — removing one RoleBinding revokes access to exactly
  one namespace. No need to audit other namespaces.
- **Namespace isolation** — a bug or misconfiguration in one namespace
  cannot escalate privileges to another.

The impersonation binding is the one deliberate exception: it must be
cluster-scoped because the verb itself is, but it grants nothing beyond
that single capability.

### Verify the bindings

The script automatically verifies via impersonation:

```bash
kubectl auth can-i list pods                  --as alice -n team-a-dev   # yes
kubectl auth can-i create jobs                --as alice -n team-a-dev   # yes
kubectl auth can-i list pods                  --as alice -n team-b-dev   # no
kubectl auth can-i impersonate serviceaccounts --as alice                # yes (cluster-wide)
```

---

## Step 8 — Hand off the kubeconfig

Send `rbac/.credentials/alice.kubeconfig` to alice via a secure channel
(1Password, vault, encrypted email, etc.). The file contains her private
key, so **never commit it to git**.

Tell alice:
- The kubeconfig file path and how to set `KUBECONFIG=`.
- The namespaces she's been granted (here: `team-a-dev`).
- The path to [`developer-runbook.md`](developer-runbook.md).

---

## Step 9 — Revoke when no longer needed

```bash
bash rbac/admin/scripts/revoke-namespace-access.sh alice team-a-dev
```

### What revocation actually does

This script runs `kubectl delete rolebinding mirrord-developer-alice -n
team-a-dev`. If alice has no remaining namespace `RoleBinding`s, it also
deletes the `mirrord-impersonator-alice` `ClusterRoleBinding`. (If she
still has access to another namespace, the impersonator binding is left
in place — otherwise mirrord in *that* namespace would break.) Alice's
certificate is **still valid for authentication** — she can still call
`kubectl auth whoami` and see her username — but every RBAC check
returns `forbidden`. That's the right shape: identity and authorization
are decoupled.

If alice leaves the org entirely and you want to invalidate the cert,
simply delete her kubeconfig file. The certificate expires after one year
anyway. With a real OIDC IDP you'd disable the user at the identity provider.

### Verify revocation

```bash
KUBECONFIG=rbac/.credentials/alice.kubeconfig kubectl auth can-i list pods -n team-a-dev
# → no  (binding was deleted)
```

---

## End-to-end regression check

To confirm the whole pipeline is still healthy after changes:

```bash
bash rbac/validate-rbac.sh
```

It runs the full sequence and asserts both the allow path (`team-a-dev`)
and the deny path (`team-b-dev`), including the cluster-scoped
impersonation check. Expected output:

```
Step 1/5  Admin bootstraps cluster + RBAC scaffold  → ✅
Step 2/5  Issue kubeconfig, deny everywhere         → ✅ 2 ns-denied + 1 cluster-denied
Step 3/5  Grant team-a-dev                          → ✅ 6 ns-allowed + 1 cluster-allowed + 3 ns-denied
Step 4/5  mirrord ls target discovery               → ✅ allowed + forbidden
Step 5/5  Revoke, deny-by-default returns           → ✅ 2 ns-denied + 1 cluster-denied
All RBAC assertions passed.
```

---

<a id="why-clusterrole-needs-these-permissions"></a>

## Why ClusterRole needs these permissions

The `ClusterRole/mirrord-developer` grants the minimum set of permissions
that the mirrord agent needs to function inside a namespace. Here is every
rule in the ClusterRole, with the **why**:

| API Resource | Verbs | Why mirrord needs it |
|---|---|---|
| `pods`, `services`, `configmaps`, `secrets`, `endpoints` | get, list, watch | **Discovery**: mirrord must find the target pod (by Deployment label selector), resolve in-cluster DNS via Services, and read ConfigMaps/Secrets that the app may mount (e.g. DB connection strings). Endpoints lets mirrord see which pod IPs back each Service. |
| `apps/deployments`, `apps/statefulsets`, `apps/daemonsets`, `apps/replicasets`, `argoproj.io/rollouts` | get, list, watch | **Workload resolution**: mirrord resolves the target path (e.g. `deployment/echo`) to a pod through these resources. |
| `batch/jobs` | get, list, watch, create, delete | **Agent lifecycle**: mirrord works by spawning a sidecar Job in the target namespace. This Job creates its own pod that intercepts traffic and streams it to the developer's local process. Read + create + delete are needed for this lifecycle. |
| `pods` | create, delete | **Pod creation**: the agent Job creates pods directly (bypassing a controller). mirrord also needs to delete orphaned pods if the Job cleanup fails. |
| `pods/ephemeralcontainers` | update, patch | **Ephemeral container mode** (optional): instead of spawning a new pod, mirrord can attach to an existing pod using the EphemeralContainers subresource. |
| `pods/log` | get | **I/O channels**: the mirrord CLI streams the agent's logs for debugging. Without this, developers can't see why the agent failed to start. |
| `pods/portforward` | create | **I/O channels**: mirrord uses port-forward to create a TCP tunnel between the pod and the local process. This is the data path for traffic mirroring/stealing. |
| `events` | get, list, watch | **Troubleshooting**: Kubernetes events explain why scheduling or validation failed (e.g. "Insufficient cpu", "PodSecurity violation"). mirrord reads them to produce better error messages. |
| `serviceaccounts` | get, impersonate | **Authentication (namespace half)**: `get` resolves the target pod's ServiceAccount identity in the workload namespace. `impersonate serviceaccounts` is granted here for completeness, but is **not** sufficient on its own — see [§ Why two bindings](#why-two-bindings). The cluster-scoped half (`impersonate users`) lives in a separate ClusterRole (`mirrord-impersonator`) bound via a per-user `ClusterRoleBinding`. Without **both**, the WebSocket tunnel handshake returns 403. |

### What the ClusterRole does NOT include

The ClusterRole is intentionally restrictive:

- **No `secrets` write** — developers cannot read or modify secrets.
- **No `clusterroles` or `clusterrolebindings`** — no privilege escalation.
- **No `nodes`** — no cluster-level enumeration.
- **No `pods/exec`** — developers cannot get a shell into arbitrary pods
  (only the mirrord agent pod that mirrord itself creates).
- **No `pod-security`** — developers cannot disable the PodSecurity admission.

If a developer finds they need something not in the ClusterRole, that's a
conversation with the admin team rather than something to work around.

---

<a id="why-two-bindings"></a>

## Why two bindings (RoleBinding + tiny ClusterRoleBinding)

A reasonable first question is *"can't we just use one `RoleBinding` for
everything?"*. The answer is **no**, and the reason is baked into the
Kubernetes RBAC subsystem rather than being a stylistic choice.

### Symptom

With a namespace `RoleBinding` alone (even one that lists
`impersonate serviceaccounts` in its rules), mirrord fails at agent
connection time with:

```
Failed to connect to the created mirrord-agent:
failed to upgrade to a WebSocket connection:
failed to switch protocol: 403 Forbidden
```

### Mechanics

When a client sets `Impersonate-User: system:serviceaccount:team-a-dev:default`
on a request — which is what kubectl `--as=...` does, and what the
in-cluster client mirrord uses produces — the kube-apiserver runs
**two impersonation authorization checks** before the request executes:

| Check | Resource | Scope | Can a RoleBinding satisfy it? |
|---|---|---|---|
| user-form impersonation | virtual `users` | **cluster-only** | **no** — `users` is a cluster-scoped virtual resource |
| SA-form impersonation | `serviceaccounts` in the SA's namespace | namespaced | yes |

Both must pass. The `users` resource is a virtual concept the RBAC
subsystem uses to express "the ability to impersonate user X" — there
is no actual `users` API object, and crucially **no namespace dimension**.
You can write `resources: ["users"]` in a `RoleBinding`'s ClusterRole,
but K8s will silently ignore it during authorization because the
resource has no namespace to scope to.

You can prove this yourself once alice is set up:

```bash
# RoleBinding grants SA impersonation in team-a-dev → yes
kubectl auth can-i impersonate serviceaccounts --as alice -n team-a-dev   # yes

# But the user-form check has nothing to satisfy it without the ClusterRoleBinding
kubectl auth can-i impersonate users --as alice                            # no
kubectl auth can-i impersonate users --as alice -n team-a-dev              # no  ← same answer

# Drop the cluster-scoped binding to reproduce the 403
kubectl delete clusterrolebinding mirrord-impersonator-alice
# rerun mirrord → 403 on WebSocket switch
```

The second `-n team-a-dev` check returning the same `no` is the point:
namespace scoping is irrelevant to `users`.

### Why we don't just give everyone a wide ClusterRoleBinding

A `ClusterRoleBinding` to `mirrord-developer` would clear the 403
trivially — and simultaneously give alice `list pods`, `create jobs`,
`pods/portforward`, etc. in **every** namespace, including
`kube-system`. The whole premise of the demo (per-namespace tenancy)
would be lost.

### The compromise

Split mirrord's permissions by scope, and use the binding type that
matches each:

- The many namespace-scoped verbs live in `ClusterRole/mirrord-developer`,
  bound per-namespace via `RoleBinding`s — easy to add, easy to revoke,
  no cross-namespace bleed.
- The one cluster-scoped verb lives alone in
  `ClusterRole/mirrord-impersonator` (a 3-line ClusterRole with exactly
  one rule), bound via a per-user `ClusterRoleBinding`. The blast radius
  is exactly "this user can impersonate ServiceAccounts" — they still
  can't list pods, read secrets, or create jobs anywhere they don't
  hold a namespace RoleBinding.

That's the smallest grant that satisfies the API server's impersonation
check while keeping the namespace-tenancy story intact.

---

## Operational notes

- **Default-deny.** A fresh kubeconfig has zero powers. Authorization is
  *only* the union of `RoleBinding`s pointing at the user. Audit by
  `kubectl get rolebindings -A -o yaml | yq '.items[] |
  select(.subjects[].name=="alice")'`.
- **One narrow `ClusterRoleBinding` per user.** The bulk
  `mirrord-developer` ClusterRole is only ever referenced by namespace
  `RoleBinding`s, so it stays scoped. The one exception is the per-user
  `mirrord-impersonator-<user>` `ClusterRoleBinding`, which grants only
  `serviceaccounts: get, impersonate` — required by mirrord's WebSocket
  handshake and not satisfiable by a namespace `RoleBinding`.
- **PodSecurity on kind.** Kind enables the PodSecurity admission
  plugin. mirrord-agent uses elevated capabilities, so the namespaces
  in this demo are labelled `pod-security.kubernetes.io/enforce=privileged`.
  In production you'd typically scope this to a small set of dev
  namespaces, or run agents as ephemeral containers (which avoids
  spawning a fresh privileged pod).
- **Audit logs.** Every mirrord operation goes through the API server
  as the user. Turning on K8s audit logging gives you a per-developer
  trail of "alice listed pods in team-a-dev at 14:03".
- **MySQL per namespace.** Each namespace has its own MySQL instance
  (isolated databases). Developers connecting via mirrord talk to the
  MySQL in their granted namespace, never to MySQL in another namespace.
- **Spring Boot app.** The app uses `imagePullPolicy: Never` so kind
  uses the locally-loaded image (`mirrord-demo:local`). If you rebuild
  the jar, remember to `docker build` + `kind load` + re-apply the
  deployment manifests.
