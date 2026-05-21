# Developer runbook — using mirrord with a scoped kubeconfig

This is what you (the developer) do after the platform admin hands you a
kubeconfig file.

## Prerequisites

| Tool | Install |
|---|---|
| kubectl | `brew install kubectl` |
| mirrord | `brew install metalbear-co/mirrord/mirrord` |
| your app's normal runtime | (e.g. `java`, `node`, `python`) |

## Step 1 — Drop the kubeconfig somewhere safe

The admin sends you a file. Put it under `~/.kube/` (or anywhere — the
path doesn't matter, just don't commit it).

```bash
mkdir -p ~/.kube
mv ~/Downloads/alice.kubeconfig ~/.kube/mirrord-demo.kubeconfig
chmod 600 ~/.kube/mirrord-demo.kubeconfig
```

Then point your shell at it:

```bash
export KUBECONFIG=~/.kube/mirrord-demo.kubeconfig
```

> **Don't merge this into your default `~/.kube/config`** unless you
> know what you're doing — keeping it isolated makes "switch back to my
> personal cluster" a one-line `unset KUBECONFIG`.

## Step 2 — Confirm who you are and what you can do

```bash
bash rbac/developer/scripts/whoami.sh
```

You should see your identity (`alice`) and a table like:

```
namespace    | verb                      | allowed?
-------------+---------------------------+--------
team-a-dev   | list pods                 | yes
team-a-dev   | list deployments.apps     | yes
team-a-dev   | create jobs.batch         | yes
team-a-dev   | create pods               | yes
team-a-dev   | get pods/log              | yes
team-b-dev   | list pods                 | NO
team-b-dev   | list deployments.apps     | NO
team-b-dev   | create jobs.batch         | NO
team-b-dev   | create pods               | NO
team-b-dev   | get pods/log              | NO
```

If everything is `NO`, your admin didn't bind you to any namespace yet
— ping them with the `whoami.sh` output.

## Step 3 — Run mirrord against an allowed namespace

The example config at `rbac/developer/mirrord.json` targets
`deployment/echo` in `team-a-dev`. Edit the `target.namespace` and
`target.path` to match the workload you actually want to attach to.

Then:

```bash
bash rbac/developer/scripts/run-mirrord.sh
```

By default this just runs a `curl` from inside the mirrord context to
prove cluster DNS works. To attach mirrord to your own local process,
pass it after `--`:

```bash
# Java
bash rbac/developer/scripts/run-mirrord.sh -- java -jar target/myapp.jar

# Node
bash rbac/developer/scripts/run-mirrord.sh -- node server.js

# Anything else
bash rbac/developer/scripts/run-mirrord.sh -- <your local command>
```

While that command runs:

- Outbound calls from your local process to in-cluster services
  (`echo.team-a-dev.svc.cluster.local`, MySQL inside the cluster, etc.)
  resolve as if you were running inside the target pod.
- Inbound traffic to the target pod is **mirrored** to your local
  process by default. Edit `feature.network.incoming` in
  `mirrord.json` to `"steal"` if you want to take traffic away from the
  pod instead of just copying it.

## Step 4 — Try a denied namespace (should fail)

To convince yourself the RBAC scope is real:

```bash
mirrord ls -n team-b-dev
```

You'll get something like `Forbidden: User "alice" cannot list
resource "pods" in API group "" in the namespace "team-b-dev"`.
That's working as intended.

## Common problems

- **`mirrord ls` says forbidden in the namespace you expected to have
  access to.** Re-run `bash rbac/developer/scripts/whoami.sh`. If the
  table shows `NO`, the binding never got applied — go back to the
  admin.
- **mirrord-agent pod fails to start with `PodSecurity violation`.**
  The target namespace doesn't have the
  `pod-security.kubernetes.io/enforce=privileged` label. Either the
  admin needs to apply that label, or the namespace is intentionally
  baseline/restricted and mirrord won't work there.
- **`failed to upgrade to a WebSocket connection: failed to switch
  protocol: 403 Forbidden`.** The agent pod was created successfully
  but the tunnel handshake is being rejected. This means the per-user
  `ClusterRoleBinding/mirrord-impersonator-<you>` is missing — mirrord
  needs cluster-scoped `serviceaccounts: impersonate`, which a
  namespace `RoleBinding` cannot satisfy. Ask the admin to re-run
  `grant-namespace-access.sh <you> <namespace>`; the current version of
  the script applies both bindings. You can sanity-check with:
  ```bash
  kubectl auth can-i impersonate serviceaccounts   # → yes (cluster-scoped, no -n)
  ```
  If that returns `no`, the impersonator binding is missing.
- **`kubectl auth whoami` returns `system:anonymous`.** Your kubeconfig
  path is wrong, the cert in it is corrupt, or you're connecting to a
  different cluster. Confirm `KUBECONFIG` is set to the file the admin
  sent you.
- **Cert expired.** Your kubeconfig is valid for one year. Ask the
  admin to re-run `issue-developer-kubeconfig.sh <you>` and send the
  refreshed file.

## What you cannot do (intentionally)

- Use mirrord against any namespace you weren't granted.
- Use mirrord against the cluster from your **personal** kubeconfig.
  `mirrord ls` will refuse if your normal kubeconfig points at a
  context that doesn't have the right RBAC.
- Create or delete arbitrary resources. The `mirrord-developer`
  ClusterRole only grants what the agent needs — no `secrets` write,
  no `clusterroles`, no `nodes`. If you find you need something it
  doesn't have, that's a conversation to have with the admin team
  rather than something to work around.
