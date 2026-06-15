# Plane bootstrap — create a private GKE cluster + cd-user SA + install Flux/Flagger, in one apply.
# Designed to run as a Devtron Job (Task 1). State lives in GCS (per-plane prefix).
# Tested end-to-end on poc3 (us-central1-a).
#
# PRIVATE cluster: nodes have internal IPs only (egress via Cloud NAT) and the control-plane
# endpoint is private — reachable only from inside the VPC. Devtron (same project/VPC) reaches
# the API over the private endpoint; the Terraform kubernetes/helm providers do too, since the
# Job pod runs in that VPC. There is NO public endpoint, so the API allowlist is an INTERNAL CIDR.

terraform {
  required_providers {
    google     = { source = "hashicorp/google", version = "~> 5.0" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.27" }
    helm       = { source = "hashicorp/helm", version = "~> 2.12" }
  }

  # (A) Remote state — bucket is fixed; pass the per-plane prefix at init:
  #     tofu init -backend-config="prefix=clusters/$PLANE"
  backend "gcs" {
    bucket = "dev-infra-test-497417-tofu-state"
  }
}

variable "project" { default = "dev-infra-test-497417" }
variable "zone" { default = "us-central1-a" }
variable "name" { default = "poc3" } # pass -var="name=$PLANE" per plane

# (D) INTERNAL CIDRs allowed to reach the PRIVATE control-plane endpoint. The endpoint has no
# public IP, so these must be in-VPC ranges (Devtron's node/pod CIDR on poc-2). Default covers
# the shared internal range; scope this down to Devtron's exact source CIDR for prod.
variable "authorized_cidrs" {
  type    = list(string)
  default = ["10.0.0.0/8"]
}

# /28 peering range for the control plane. Must not overlap the VPC or any peer; 172.16.0.0/28
# is safe against the default network's 10.x ranges. Change if a peer already uses 172.16.x.
variable "master_ipv4_cidr_block" {
  type    = string
  default = "172.16.0.0/28"
}

provider "google" {
  project = var.project
  zone    = var.zone
}

# ---------- 1. the cluster ----------
resource "google_container_cluster" "this" {
  name     = var.name
  location = var.zone
  network  = "default"

  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = false # POC — lets you `tofu destroy` cleanly

  # VPC-native (alias IPs) — required for private clusters. Empty block lets GKE
  # auto-allocate the pod/service secondary ranges on the default network.
  ip_allocation_policy {}

  # Private cluster: private nodes (no public IPs) + private endpoint (no public API).
  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = true
    master_ipv4_cidr_block  = var.master_ipv4_cidr_block

    # Allow reaching the private endpoint from other regions in the VPC (in case
    # Devtron/poc-2 sits in a different region than this plane).
    master_global_access_config {
      enabled = true
    }
  }

  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = var.authorized_cidrs
      content {
        cidr_block = cidr_blocks.value
      }
    }
  }
}

resource "google_container_node_pool" "default" {
  name       = "default-pool"
  cluster    = google_container_cluster.this.id
  node_count = 1
  node_config {
    machine_type = "e2-standard-2" # 2 vCPU — fits Flux's controllers + Flagger
    disk_size_gb = 30
    disk_type    = "pd-balanced"
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }
}

# Node egress (pulling images / Flux charts) is already provided by the existing
# region-wide Cloud NAT (teleport-poc-nat, ALL_SUBNETWORKS_ALL_IP_RANGES on us-central1/default),
# which covers poc3's subnet too. A second NAT here would conflict, so none is created.

# ---------- providers pointed at the new cluster ----------
data "google_client_config" "current" {}

provider "kubernetes" {
  host                   = "https://${google_container_cluster.this.endpoint}"
  token                  = data.google_client_config.current.access_token
  cluster_ca_certificate = base64decode(google_container_cluster.this.master_auth[0].cluster_ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = "https://${google_container_cluster.this.endpoint}"
    token                  = data.google_client_config.current.access_token
    cluster_ca_certificate = base64decode(google_container_cluster.this.master_auth[0].cluster_ca_certificate)
  }
}

# ---------- 2. cd-user service account (the token Devtron will use) ----------
resource "kubernetes_service_account" "cd_user" {
  metadata {
    name      = "cd-user"
    namespace = "kube-system"
  }
}

resource "kubernetes_cluster_role_binding" "cd_user" {
  metadata { name = "cd-user-admin" }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin" # POC default; scope down for prod
  }
  subject {
    kind      = "ServiceAccount"
    name      = "cd-user"
    namespace = "kube-system"
  }
}

resource "kubernetes_secret" "cd_user_token" {
  metadata {
    name        = "cd-user-token"
    namespace   = "kube-system"
    annotations = { "kubernetes.io/service-account.name" = "cd-user" }
  }
  type                           = "kubernetes.io/service-account-token"
  wait_for_service_account_token = true
  depends_on                     = [kubernetes_service_account.cd_user]
}

# ---------- 3. install Flux + Flagger (+ add more here) ----------
resource "helm_release" "flux" {
  name             = "flux2"
  repository       = "https://fluxcd-community.github.io/helm-charts"
  chart            = "flux2"
  namespace        = "flux-system"
  create_namespace = true
  timeout          = 600
  depends_on       = [google_container_node_pool.default]
}

resource "helm_release" "flagger" {
  name             = "flagger"
  repository       = "https://flagger.app"
  chart            = "flagger"
  namespace        = "flagger-system"
  create_namespace = true
  set {
    name  = "meshProvider"
    value = "kubernetes" # simplest; switch to gatewayapi when the Gateway is in
  }
  depends_on = [helm_release.flux]
}

# ---------- outputs the register step consumes ----------
output "cluster_endpoint" {
  value = "https://${google_container_cluster.this.endpoint}"
}

# Base64 cluster CA — passed to Devtron as cert_auth_data so it can verify the
# private master's TLS cert (the private endpoint has no public CA chain).
output "cluster_ca" {
  value = google_container_cluster.this.master_auth[0].cluster_ca_certificate
}

output "cd_user_token" {
  value     = kubernetes_secret.cd_user_token.data["token"]
  sensitive = true
}
