# cluster-bootstrap

One parameterized flow, run as a **Devtron Job**: create a GKE cluster + `cd-user`
ServiceAccount + install **Flux + Flagger**, then register the cluster into Devtron.

Tested end-to-end on `poc3` (us-central1-a): all 6 Flux controllers + Flagger came up,
and the `cd_user_token` output feeds `register.sh`.

## The Job — ONE task (Execute custom task → Container Image)

A single container-image task does everything (create cluster → install Flux/Flagger
→ register into Devtron). Use the public OpenTofu image directly — no custom Dockerfile.

Devtron UI fields:

| Field | Value |
|---|---|
| Container image | `ghcr.io/opentofu/opentofu:1.12.1` |
| Mount custom code | **Yes** → "Mount above code at" `/run.sh` (script below) |
| Command | `sh` |
| Args | `/run.sh` |
| Mount code to container | **Yes** → `/work` (the git repo) |
| Input variables | `PLANE`, `DEVTRON_HOST`, `DEVTRON_API_TOKEN` (sensitive) |

Script (paste into "Mount custom code"):
```sh
#!/bin/sh
set -e
cd /work
apk add --no-cache curl
tofu init -backend-config="prefix=clusters/$PLANE"
tofu apply -auto-approve -var="name=$PLANE"
sh register.sh
```

Runtime parameter: `PLANE` (e.g. `poc3`). Triggered per plane via UI or API.

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

- `DEVTRON_HOST`, `DEVTRON_API_TOKEN` (secret) — for `register.sh`.
- `PLANE` — runtime parameter.

## Run locally (test)

```bash
tofu init -backend-config="prefix=clusters/poc3"
tofu apply -var='authorized_cidrs=["34.56.214.245/32","<your-ip>/32"]'
DEVTRON_HOST=... DEVTRON_API_TOKEN=... ./register.sh
tofu destroy   # cleanup
```

Note: `cd-user` is `cluster-admin` (POC default) — scope down for prod, and prefer
`config.cert_auth_data` (cluster CA) over `insecure-skip-tls-verify`.
