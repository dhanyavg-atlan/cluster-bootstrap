# cluster-bootstrap

Onboard a new tenant/plane cluster, run as **one Devtron Job with three tasks**:
**provision → register → deploy**. `PLANE` (the cluster/tenant name) is the single
runtime input — set it once at trigger, and the whole flow is repeatable for any plane.

Tested end-to-end on `poc3` (us-central1-a): all 6 Flux controllers + Flagger came up.

## Onboarding plan — 3 tasks

Each task is an *Execute custom task → Container Image*. Data flows between them via
Devtron **output → input variables**.

### Task 1 — `provision-infra` (Terraform)
Creates the cluster and its controllers.

| Field | Value |
|---|---|
| Image | `ghcr.io/opentofu/opentofu:1.12.1` |
| Mount custom code → at | **Yes** → `/run.sh` |
| Command / Args | `sh` / `/run.sh` |
| Mount code to container | **Yes** → `/work` (the git repo) |
| Input variables | `PLANE` |
| **Output variables** | `CLUSTER_ENDPOINT`, `CD_USER_TOKEN` |

```sh
#!/bin/sh
set -e
cd /work
tofu init -backend-config="prefix=clusters/$PLANE"
tofu apply -auto-approve -var="name=$PLANE"
export CLUSTER_ENDPOINT="$(tofu output -raw cluster_endpoint)"
export CD_USER_TOKEN="$(tofu output -raw cd_user_token)"
```
Creates: GKE cluster + `cd-user` SA (cluster-admin) + **Flux** + **Flagger**.

### Task 2 — `register-cluster` (Devtron API)
Tells Devtron about the new cluster (for access management + observability). No repo needed.

| Field | Value |
|---|---|
| Image | `alpine:3.20` |
| Mount custom code → at | **Yes** → `/run.sh` |
| Command / Args | `sh` / `/run.sh` |
| Mount code to container | **No** |
| Input variables | `CLUSTER_ENDPOINT` + `CD_USER_TOKEN` ← *from Task 1 output*; `DEVTRON_HOST`, `DEVTRON_API_TOKEN`, `PLANE` |

```sh
#!/bin/sh
set -e
apk add --no-cache curl
curl -sS -X POST "https://$DEVTRON_HOST/orchestrator/cluster" \
  -H "token: $DEVTRON_API_TOKEN" -H "Content-Type: application/json" \
  -d "{\"cluster_name\":\"$PLANE\",\"server_url\":\"$CLUSTER_ENDPOINT\",\"config\":{\"bearer_token\":\"$CD_USER_TOKEN\"},\"insecure-skip-tls-verify\":true}"
```

### Task 3 — `deploy-workloads`  *(expectation — not yet built)*

**Goal:** get *this plane's workloads running* on the freshly-onboarded cluster, with
**per-tenant value overrides**. After Task 1 (cluster + Flux exist) and Task 2 (Devtron
sees it), Task 3 is what actually puts the plane's services on the cluster.

**What it must do:**
1. **Override the deployment values** for this specific plane/tenant — i.e. the per-plane
   Helm values + the `enable` flags that select *which* charts this plane runs
   (management-plane charts vs identity-plane charts, etc.).
2. **Apply the resources to the cluster** so those workloads come up.

**Mechanism — open design decision (the thing we're working out):**
- **Preferred (keeps Devtron out of CD):** Task 3 seeds the *in-cluster Flux's* desired
  state — apply the plane's `GitRepository` / `Kustomization` / `HelmRelease` (or the
  enable-flags + per-plane override values), then Flux pulls that plane's charts from OCI
  and reconciles them. Delivery stays with Flux; Devtron only seeds config.
- **Alternative under evaluation:** call the **Devtron API** to create a deployment/workflow
  block that overrides the values and applies them to the registered cluster directly.

**Inputs it will need:** `PLANE`, the cluster endpoint/credentials (from Task 1 / the
registration), the chart name + version, and the per-plane override values.

**Status:** to be designed and validated next — this README will be updated once the
mechanism is chosen.

> Note: Tasks 1 & 2 are proven; the output→input variable handoff between them is wired.
> Task 3 is the remaining piece to make onboarding end at "workloads running."

## What's already resolved

| | Item | How |
|---|---|---|
| **A** | Remote state | `backend "gcs"` → bucket `dev-infra-test-497417-tofu-state` (versioned). Per-plane state via `-backend-config="prefix=clusters/$PLANE"` at init. |
| **B** | Runner image | Use public `ghcr.io/opentofu/opentofu:1.12.1` directly (script does `apk add curl`). The `Dockerfile` is optional — only if you want a pinned private image. |
| **C** | GCP auth | Workload Identity — see below. |
| **D** | Network | `authorized_cidrs` defaults to Devtron's egress `34.56.214.245/32` (poc-2 NAT). Confirm this is your management cluster's egress. |

## (C) Workload Identity — one-time, on the management cluster

The Job pod's KSA must map to a GCP SA allowed to create GKE + SAs:

```bash
GSA=tofu-bootstrap@dev-infra-test-497417.iam.gserviceaccount.com
# 1. create GSA + grant
gcloud iam service-accounts create tofu-bootstrap --project dev-infra-test-497417
gcloud projects add-iam-policy-binding dev-infra-test-497417 \
  --member="serviceAccount:$GSA" --role="roles/container.admin"
# state bucket access
gcloud storage buckets add-iam-policy-binding gs://dev-infra-test-497417-tofu-state \
  --member="serviceAccount:$GSA" --role="roles/storage.objectAdmin"
# 2. bind the Devtron Job's KSA (namespace/name depend on where the Job runs)
gcloud iam service-accounts add-iam-policy-binding $GSA \
  --role roles/iam.workloadIdentityUser \
  --member "serviceAccount:dev-infra-test-497417.svc.id.goog[<job-namespace>/<job-ksa>]"
# 3. annotate the KSA: iam.gke.io/gcp-service-account=$GSA
```

## Secrets / env on the Job

- `DEVTRON_HOST`, `DEVTRON_API_TOKEN` — used by Task 2 (register). Treat the token as a
  secret; rotate it regularly. (This Devtron build has no "sensitive" toggle on task
  variables, so the value is stored in plaintext on the task — rotate accordingly.)
- `PLANE` — the single runtime parameter (cluster/tenant name), e.g. `poc3`.
- `register.sh` is kept for **local** testing only; the Devtron flow inlines the curl in Task 2.

## Run locally (test)

```bash
tofu init -backend-config="prefix=clusters/poc3"
tofu apply -var='authorized_cidrs=["34.56.214.245/32","<your-ip>/32"]'
DEVTRON_HOST=... DEVTRON_API_TOKEN=... ./register.sh
tofu destroy   # cleanup
```

Note: `cd-user` is `cluster-admin` (POC default) — scope down for prod, and prefer
`config.cert_auth_data` (cluster CA) over `insecure-skip-tls-verify`.
