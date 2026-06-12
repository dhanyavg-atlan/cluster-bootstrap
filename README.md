# cluster-bootstrap

One parameterized flow, run as a **Devtron Job**: create a GKE cluster + `cd-user`
ServiceAccount + install **Flux + Flagger**, then register the cluster into Devtron.

Tested end-to-end on `poc3` (us-central1-a): all 6 Flux controllers + Flagger came up,
and the `cd_user_token` output feeds `register.sh`.

## The Job — 2 tasks

**Task 1 — Container Image Task** (image built from `Dockerfile`):
```bash
tofu init -backend-config="prefix=clusters/${PLANE}" \
  && tofu apply -auto-approve -var="name=${PLANE}"
```

**Task 2 — Shell Task:**
```bash
./register.sh
```

Runtime parameter: `PLANE` (e.g. `poc3`). Triggered per plane via UI or API.

## What's already resolved

| | Item | How |
|---|---|---|
| **A** | Remote state | `backend "gcs"` → bucket `dev-infra-test-497417-tofu-state` (versioned). Per-plane state via `-backend-config="prefix=clusters/$PLANE"` at init. |
| **B** | Runner image | `Dockerfile` = OpenTofu 1.12 + curl + bash. No gcloud/helm CLI needed. |
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
