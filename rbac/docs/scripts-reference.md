# Scripts reference — how each script works

This is a reference for anyone auditing or modifying the scripts. It is
**not** a user guide — for "what do I do first?" see the admin and
developer runbooks.

## Shared library — `lib.sh`

All admin scripts source this file. It defines environment, helpers, and
the two core functions that `bootstrap-cluster.sh` calls.

```
lib.sh
├── Constants
│   ├── RBAC_ROOT          ← absolute path to rbac/
│   ├── KIND_CLUSTER_NAME  ← "mirrord-rbac-demo"
│   ├── KIND_CONTEXT       ← "kind-mirrord-rbac-demo"
│   ├── CLUSTER_ROLE       ← "mirrord-developer"
│   ├── DEMO_NAMESPACES    ← ("team-a-dev" "team-b-dev")
│   └── CREDENTIALS_DIR    ← rbac/.credentials/
│
├── Helpers
│   ├── log()              ← timestamped stdout message
│   ├── die()              ← stderr message + exit 1
│   └── require_cmd(...)   ← pre-flight: die if any command not on PATH
│
├── ensure_kind_cluster()  ← idempotent: skip if cluster exists, else kind create
└── apply_admin_manifests() ← kubectl apply each 01/02/03/04/05 manifest, then
                              kubectl rollout status for each namespace
```

## Manifest files

```
manifests/
├── 01-mirrord-developer-clusterrole.yaml   ← ClusterRole: defines mirrord-agent permissions
├── 02-namespaces.yaml                      ← Namespaces: team-a-dev, team-b-dev with PS=privileged
├── 03-test-workloads.yaml                  ← Echo server: quick smoke-test workload
├── 04-mysql-template.yaml                  ← MySQL template: Service + Deployment (TEAM placeholder)
├── 05-app-template.yaml                    ← Spring Boot app template: Deployment + Service (TEAM placeholder)
└── 04-rolebinding-template.yaml            ← RoleBinding template: binds User → ClusterRole (namespace-scoped)
```

**Templates (04-mysql-template.yaml, 05-app-template.yaml):** These files
use `TEAM` as a placeholder for the namespace name. They are rendered with
`sed 's/TEAM/<namespace>/g'` before `kubectl apply`. This avoids needing
`envsubst` as a dependency. The RoleBinding template (04-rolebinding-template.yaml)
uses `__USER__` and `__NAMESPACE__` placeholders.

**Template file naming:** `04-mysql-template.yaml` is numbered 04 to slot
before the rolebinding (04-rolebinding-template.yaml). The script applies
templates after the fixed manifests (01-03).

**Idempotency guarantees:**

| Function | Safe to re-run? | Why |
|---|---|---|
| `ensure_kind_cluster` | Yes | Checks `kind get clusters`; skips creation |
| `apply_admin_manifests` | Yes | `kubectl apply` is a declarative merge; re-applies the same YAML is a no-op |

## Dependency graph

```
bootstrap-cluster.sh
├── admin/scripts/lib.sh
│   ├── ensure_kind_cluster()
│   └── apply_admin_manifests()
│       └── kubectl apply manifests/01-mirrord-developer-clusterrole.yaml
│       └── kubectl apply manifests/02-namespaces.yaml
│       └── kubectl apply manifests/03-test-workloads.yaml
│       └── kubectl rollout status (wait for echo pods ready)

issue-developer-kubeconfig.sh
├── admin/scripts/lib.sh
│   ├── require_cmd(kubectl openssl base64)
│   ├── openssl genrsa         ← generate private key
│   ├── openssl req -new       ← create CSR
│   ├── kubectl apply CSR      ← submit to API server
│   ├── kubectl certificate approve  ← admin approves
│   ├── kubectl get csr (poll)   ← wait for signed cert
│   └── kubectl config view      ← extract server + CA URL
│                                   (from existing admin kubeconfig)
│       ↓
│   └── writes kubeconfig (cert + key + CA + server)

grant-namespace-access.sh
├── admin/scripts/lib.sh
│   ├── require_cmd(kubectl)
│   ├── kubectl get namespace (pre-flight check)
│   ├── sed template substitution (envsubst-lite via sed)
│   │   └── reads manifests/04-rolebinding-template.yaml
│   │       replaces __USER__ and __NAMESPACE__
│   └── kubectl apply -f -   ← render + apply in one pipeline
│       ↓
│   └── kubectl auth can-i --as=<user> (verify)

revoke-namespace-access.sh
├── admin/scripts/lib.sh
│   ├── require_cmd(kubectl)
│   ├── kubectl delete rolebinding --ignore-not-found
│   └── kubectl auth can-i --as=<user> (verify denial)

validate-rbac.sh
├── admin/scripts/lib.sh
│   ├── bootstrap-cluster.sh              ← step 1/5
│   ├── issue-developer-kubeconfig.sh     ← step 2/5
│   ├── grant-namespace-access.sh         ← step 3/5
│   │   │   assert_allowed()              ← kubectl auth can-i must succeed
│   │   │   assert_denied()               ← kubectl auth can-i must fail
│   │   ├── mirrord ls -n team-a-dev    ← step 4/5 (optional, needs mirrord CLI)
│   │   ├── mirrord ls -n team-b-dev    ← expects failure
│   └── revoke-namespace-access.sh        ← step 5/5

whoami.sh (developer)
└── (self-contained, no shared library)
    └── kubectl auth whoami
    └── kubectl auth can-i <verb> -n <namespace>

run-mirrord.sh (developer)
└── (self-contained, no shared library)
    └── mirrord exec -f <mirrord.json> -- <command>
```

## `bootstrap-cluster.sh`

**Purpose:** One-command setup of the RBAC scaffold (ClusterRole + namespaces
+ echo workloads). Note: this script does **not** deploy the MySQL or Spring
Boot app — those are deployed separately (see admin runbook step 5).

**Flow:**

1. **Pre-flight:** Check `kind` and `kubectl` are on PATH.
2. **Cluster:** Call `ensure_kind_cluster()`. If a kind cluster named
   `mirrord-rbac-demo` already exists, skip. Otherwise, create one using
   `admin/kind-config.yaml` (single control-plane node, no extra
   port-mappings or containerd snippets).
3. **RBAC scaffold:** Call `apply_admin_manifests()`, which applies the
   YAML manifests in order:
   - `01-mirrord-developer-clusterrole.yaml` — the ClusterRole
   - `02-namespaces.yaml` — team-a-dev, team-b-dev with
     `pod-security.kubernetes.io/enforce=privileged`
   - `03-test-workloads.yaml` — echo Deployment + Service in each
     namespace
4. **Wait for readiness:** `kubectl rollout status deployment/echo` for
   each namespace, timeout 120 s.

**Output:** Prints next-steps hints pointing to the developer kubeconfig
script and the grant script.

**What it does NOT do:** MySQL and the Spring Boot app are not deployed by
this script. The admin must deploy those separately using the template files
(`04-mysql-template.yaml` and `05-app-template.yaml`) as described in the
admin runbook.

**Key detail:** The manifests are applied cluster-wide (`kubectl apply -f`
without `-n`), so the ClusterRole lands at cluster scope while the
Namespaces and Deployments land in their respective namespaces.

## `issue-developer-kubeconfig.sh`

**Purpose:** Produce a standalone kubeconfig for a single developer using
the K8s CSR API — no external CA or OIDC dependency.

**Flow:**

1. **Pre-flight:** Validate username matches `[a-z0-9-]+` (prevents
   shell injection in template strings). Require `kubectl`, `openssl`,
   `base64`.
2. **Generate key pair:** `openssl genrsa 2048` → `<user>.key` (mode
   `0600`).
3. **Create CSR:** `openssl req -new -subj "/CN=<user>"` → `<user>.csr`.
   The `CN` becomes the Kubernetes username that RoleBindings reference.
4. **Submit CSR:** Base64-encode the CSR PEM, apply a
   `CertificateSigningRequest` resource with:
   - `signerName: kubernetes.io/kube-apiserver-client` (standard client
     cert signer, not the old `kubernetes.io/kube-apiserver-client-approve`
     alpha API)
   - `expirationSeconds: 31536000` (1 year)
   - `usages: [client auth]` (cannot be used for server auth)
5. **Approve:** `kubectl certificate approve` — this is the admin
   approval step. In production, a webhook or cert-manager Controller
   might automate this based on policy.
6. **Poll for signed cert:** Loop up to 30 times, checking
   `status.certificate` on the CSR. The apisignersigner issues the cert
   asynchronously after approval.
7. **Extract cluster info:** Read `server` URL and `certificate-authority-data`
   from the *admin* kubeconfig's cluster entry. This means the script
   must be run with admin-level kubeconfig loaded in the environment.
8. **Assemble kubeconfig:** Merge server + CA + user cert + user key into
   a standalone `Config` document. Write to
   `.credentials/<user>.kubeconfig` (mode `0600`).

**Security notes:**

- The private key and kubeconfig both contain the user's secret material.
  They live under `.credentials/` (mode `700` / `0600`) and are gitignored.
- The CSR mechanism means the **cluster's CA signed the cert**, so the
  kubeconfig works with any cluster that trusts that CA — no need to
  distribute a separate CA file.
- Rotation: re-running the script deletes the old CSR and creates a new
  one. The old cert is immediately invalid once the new one is issued.

## `grant-namespace-access.sh`

**Purpose:** Create a `RoleBinding` that scopes the ClusterRole to one
namespace for one user.

**Flow:**

1. **Pre-flight:** Require `kubectl`. Check the target namespace exists
   (`kubectl get namespace`) — catches typos before they produce a
   silent no-op.
2. **Render template:** Read `manifests/04-rolebinding-template.yaml`,
   substitute `__USER__` and `__NAMESPACE__` via `sed` (no `envsubst`
   dependency). This is a simple string replacement — the template
   contains exactly two placeholders.
3. **Apply:** Pipe the rendered YAML into `kubectl apply -f -`.
4. **Verify:** Run `kubectl auth can-i list pods --as=<user>` and
   `create jobs --as=<user>` in the target namespace to confirm the
   binding took effect.

**Why `sed` instead of `envsubst`?** The script header says "Use a heredoc
rather than envsubst to avoid an extra dependency." The grant script
actually uses `sed` (consistent choice). The comment in the template file
mentions `envsubst`, but the implementation uses `sed -e ... -e ...`.

**RoleBinding name:** `mirrord-developer-<user>` — unique per user,
scoped to the namespace. If the same user is granted access to multiple
namespaces, each gets its own RoleBinding resource with the same name
but in a different namespace.

## `revoke-namespace-access.sh`

**Purpose:** Remove a single RoleBinding, testing that authorization
revokes instantly.

**Flow:**

1. **Pre-flight:** Same username/namespace validation.
2. **Delete:** `kubectl delete rolebinding` with `--ignore-not-found`
   (safe to call when the binding was already removed).
3. **Verify:** `kubectl auth can-i list pods --as=<user>` — must return
   failure. If it succeeds, the script exits with an error, indicating
   a stale binding or a duplicate binding elsewhere.

**What it does NOT do:** It does not delete the user's certificate.
The user can still authenticate to the API server, but all RBAC checks
return forbidden. This is the intended decoupling.

## `whoami.sh` (developer)

**Purpose:** Give the developer a self-service diagnostic that shows
their identity and a permission matrix.

**Flow:**

1. **KUBECONFIG resolution:** Accept path as `$1` or from the
   `KUBECONFIG` env var. Die if neither is set.
2. **Identity check:** `kubectl auth whoami` — shows the user subject
   the current kubeconfig authenticates as. Falls back to reading the
   kubeconfig's user name directly if `kubectl auth whoami` is unavailable.
3. **Permission matrix:** Iterates over the two demo namespaces and six
   verb checks that map to the ClusterRole rules. For each combination,
   runs `kubectl auth can-i <verb> -n <namespace>` and prints yes/NO.
4. **Output format:** Fixed-width table for readability.

**Why this matters:** Before mirrord fails with a cryptic RBAC error,
the developer can run this to verify whether their RoleBinding was
actually applied. "All NO" means "ping your admin" — no mirrord
involvement needed to diagnose.

## `run-mirrord.sh` (developer)

**Purpose:** Launch a local process under mirrord's interception context.

**Flow:**

1. **Pre-flight:** Check `KUBECONFIG` is set and `mirrord` CLI is on
   PATH. Die with instructions if either is missing.
2. **Command resolution:** The default command is a `curl` probe that
   hits the app Service, proving cluster DNS resolution works through
   mirrord:
   ```
   curl -sS http://app.team-a-dev.svc.cluster.local:8080/api/messages/current
   ```
   This hits the Spring Boot app's `/api/messages/current` endpoint, which
   returns a message from the in-cluster MySQL database.
   If the user passes `--` followed by arguments, those replace the
   default curl. This uses bash's `shift` pattern to separate flags
   from the user's command.
3. **Launch:** `exec mirrord exec -f <mirrord.json> -- <command>`.
   - `exec` replaces the shell process (no orphan).
   - `-f` passes the mirrord config that specifies target namespace and
     workload path.
   - `--` separates mirrord options from the user's command.

**Why `exec`?** Without it, the shell would spawn a subprocess, run
mirrord, then exit and leave a zombie shell. `exec` ensures the
mirrord process inherits the shell's PID and signal handling.

**Config source:** `mirrord.json` at `rbac/developer/mirrord.json`.
The developer edits `target.namespace` and `target.path` before running.
`target.path` defaults to `deployment/app` (the Spring Boot app). To target
the echo server instead, change it to `deployment/echo`.

## `validate-rbac.sh`

**Purpose:** Regression test that validates the entire RBAC lifecycle
end-to-end. Safe to run after any script modification.

**Flow (5 steps, each with assertions):**

| Step | Action | Assertions |
|---|---|---|
| 1/5 | `bootstrap-cluster.sh` | (implicit: script succeeds, cluster exists) |
| 2/5 | `issue-developer-kubeconfig.sh alice` | Cert authenticates as "alice"; denied in both namespaces |
| 3/5 | `grant-namespace-access.sh alice team-a-dev` | Allowed 6 operations in team-a-dev; denied 3 operations in team-b-dev |
| 4/5 | `mirrord ls` (optional) | Lists `deployment/echo` in team-a-dev; forbidden in team-b-dev |
| 5/5 | `revoke-namespace-access.sh alice team-a-dev` | Denied again in team-a-dev |

**Assertion helpers:**

- `assert_allowed(kubeconfig, verb, namespace)` — `kubectl auth can-i`
  must **succeed**. Dies with error message on failure.
- `assert_denied(kubeconfig, verb, namespace)` — `kubectl auth can-i`
  must **fail**. Dies with error message on success.

**Mirrord check:** Steps 4/5 is gated on whether `mirrord` is on PATH.
If not installed, the script skips it (doesn't fail). The mirrord CLI
check provides an additional layer: it confirms not just that RBAC
allows the operations, but that mirrord actually uses them to discover
targets.

**What it does NOT test:** It does not test actual traffic mirroring
(i.e., sending requests and verifying they're mirrored). That requires
a live app and mirrord agent, which this script intentionally avoids
to keep the regression lightweight.
