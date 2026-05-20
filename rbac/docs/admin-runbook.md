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
| openssl | preinstalled on macOS |

> The demo is kind-based for reproducibility. On a real k3s/EKS cluster
> you skip step 1 — everything else is unchanged.

## Step 1 — Provision the cluster + RBAC scaffold

```bash
bash rbac/admin/scripts/bootstrap-cluster.sh
```

This is idempotent. What it does:

1. Creates a kind cluster named **`mirrord-rbac-demo`** if one doesn't
   already exist (config: `rbac/admin/kind-config.yaml`).
2. Applies `rbac/admin/manifests/01-mirrord-developer-clusterrole.yaml`
   — the `mirrord-developer` ClusterRole. Read it; it documents exactly
   which verbs mirrord-agent needs and why.
3. Creates two namespaces (`team-a-dev`, `team-b-dev`) labelled
   `pod-security.kubernetes.io/enforce=privileged` so mirrord-agent's
   `NET_ADMIN` / `SYS_PTRACE` capabilities aren't rejected by the kind
   Pod Security admission plugin.
4. Deploys an echo workload (`deployment/echo`) into each namespace so
   developers have something to target.

Verify:

```bash
kubectl --context kind-mirrord-rbac-demo get clusterrole mirrord-developer
kubectl --context kind-mirrord-rbac-demo get ns team-a-dev team-b-dev
kubectl --context kind-mirrord-rbac-demo get deploy -A | grep echo
```

## Step 2 — Issue a kubeconfig for a developer

For each developer (here: `alice`):

```bash
bash rbac/admin/scripts/issue-developer-kubeconfig.sh alice
```

What this does — read the script if you want the full detail, but
conceptually:

1. Generates an RSA private key locally
   (`rbac/.credentials/alice/alice.key`).
2. Builds a Certificate Signing Request with `CN=alice`.
3. Submits a `CertificateSigningRequest` resource to the cluster with
   `signerName: kubernetes.io/kube-apiserver-client`.
4. Approves it (`kubectl certificate approve`) — this is the admin
   action; in production the policy might be "only the platform team
   approves CSRs".
5. Downloads the signed certificate from `status.certificate`.
6. Writes `rbac/.credentials/alice.kubeconfig` embedding the cluster
   CA, server URL, signed cert, and private key.

The certificate is valid for **one year** (`expirationSeconds:
31536000`). Rotate by re-running the script — the old CSR is deleted
and replaced.

**Crucial:** Alice has a working kubeconfig at this point, but **no
authorization**. The next step is what actually gives her power.

```bash
KUBECONFIG=rbac/.credentials/alice.kubeconfig kubectl auth can-i list pods -n team-a-dev
# → no
```

## Step 3 — Grant a developer access to one namespace

```bash
bash rbac/admin/scripts/grant-namespace-access.sh alice team-a-dev
```

This applies a `RoleBinding` (rendered from
`rbac/admin/manifests/04-rolebinding-template.yaml`) that says:

> *Inside namespace `team-a-dev`, user `alice` has every verb listed in
> ClusterRole `mirrord-developer`.*

That binding is the **only** thing tying alice's identity to mirrord
powers. It's scoped to a single namespace. Granting her a second
namespace is a second binding.

Verify the binding via impersonation (admin doesn't need alice's
kubeconfig):

```bash
kubectl auth can-i list pods       --as alice -n team-a-dev   # yes
kubectl auth can-i create jobs     --as alice -n team-a-dev   # yes
kubectl auth can-i list pods       --as alice -n team-b-dev   # no
```

## Step 4 — Hand off the kubeconfig

Send `rbac/.credentials/alice.kubeconfig` to alice. It contains her
private key, so use whatever secure-share channel your org already uses
(1Password, a vault, encrypted email, etc.). Do **not** commit it.

Tell alice:

- The kubeconfig file path she should set `KUBECONFIG=` to.
- The namespaces she's been granted (here: `team-a-dev`).
- The path to [`developer-runbook.md`](developer-runbook.md).

## Step 5 — Revoke when no longer needed

```bash
bash rbac/admin/scripts/revoke-namespace-access.sh alice team-a-dev
```

This deletes the `RoleBinding`. Alice's certificate is **still valid for
authentication** — she can still call `kubectl auth whoami` — but every
RBAC check returns `forbidden`. That's the right shape: identity and
authorization are decoupled.

If alice leaves the org entirely and you want to invalidate the cert,
the cleanest path is to rotate the cluster CA (rarely done) or simply
delete all bindings tied to her identity. With a real OIDC IDP you'd
disable the user there.

## Operational notes

- **Default-deny.** A fresh kubeconfig has zero powers. Authorization is
  *only* the union of `RoleBinding`s pointing at the user. Audit by
  `kubectl get rolebindings -A -o yaml | yq '.items[] |
  select(.subjects[].name=="alice")'`.
- **No `ClusterRoleBinding`.** The ClusterRole is referenced by
  `RoleBinding`s, which scope it. Granting cluster-wide mirrord access
  is intentionally a separate, deliberate act.
- **PodSecurity on kind.** Kind enables the PodSecurity admission
  plugin. mirrord-agent uses elevated capabilities, so the namespaces
  in this demo are labelled `pod-security.kubernetes.io/enforce=privileged`.
  In production you'd typically scope this to a small set of dev
  namespaces, or run agents as ephemeral containers (which avoids
  spawning a fresh privileged pod).
- **Audit logs.** Every mirrord operation goes through the API server
  as the user. Turning on K8s audit logging gives you a per-developer
  trail of "alice listed pods in team-a-dev at 14:03".

## End-to-end regression check

To confirm the whole pipeline is still healthy after changes:

```bash
bash rbac/validate-rbac.sh
```

It runs the full sequence and asserts both the allow path (`team-a-dev`)
and the deny path (`team-b-dev`).
