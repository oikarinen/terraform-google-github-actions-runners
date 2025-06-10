/**
 * Copyright 2020 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
locals {
  network_name    = var.create_network ? google_compute_network.gh-network[0].name : var.network_name
  subnet_name     = var.create_network ? google_compute_subnetwork.gh-subnetwork[0].name : var.subnet_name
  service_account = var.service_account == "" ? "create" : var.service_account

  gh_app_secrets_processed = var.enable_secret_manager && var.gh_app_secrets != null ? {
    app_id = {
      project_id  = coalesce(var.gh_app_secrets.app_id.project_id, var.project_id)
      secret_name = var.gh_app_secrets.app_id.secret_name
      version     = var.gh_app_secrets.app_id.version
    },
    installation_id = {
      project_id  = coalesce(var.gh_app_secrets.installation_id.project_id, var.project_id)
      secret_name = var.gh_app_secrets.installation_id.secret_name
      version     = var.gh_app_secrets.installation_id.version
    },
    private_key = {
      project_id  = coalesce(var.gh_app_secrets.private_key.project_id, var.project_id)
      secret_name = var.gh_app_secrets.private_key.secret_name
      version     = var.gh_app_secrets.private_key.version
    }
  } : {}

  gh_app_secrets_ids = { for k, v in local.gh_app_secrets_processed : k => "projects/${v.project_id}/secrets/${v.secret_name}/versions/${v.version}" }
}

/*****************************************
  Optional Network
 *****************************************/
resource "google_compute_network" "gh-network" {
  count                   = var.create_network ? 1 : 0
  name                    = var.network_name
  project                 = var.project_id
  auto_create_subnetworks = false
}
resource "google_compute_subnetwork" "gh-subnetwork" {
  count         = var.create_network ? 1 : 0
  project       = var.project_id
  name          = var.subnet_name
  ip_cidr_range = var.subnet_ip
  region        = var.region
  network       = google_compute_network.gh-network[0].name

  secondary_ip_range {
    range_name    = var.ip_range_pods_name
    ip_cidr_range = var.ip_range_pods_cidr
  }

  secondary_ip_range {
    range_name    = var.ip_range_services_name
    ip_cidr_range = var.ip_range_services_cider
  }
}
/*****************************************
  Runner GKE
 *****************************************/
module "runner-cluster" {
  source                   = "terraform-google-modules/kubernetes-engine/google//modules/beta-public-cluster/"
  version                  = "~> 35.0"
  project_id               = var.project_id
  name                     = "gh-runner-${var.cluster_suffix}"
  regional                 = false
  region                   = var.region
  zones                    = var.zones
  network                  = local.network_name
  network_project_id       = var.subnetwork_project != "" ? var.subnetwork_project : var.project_id
  subnetwork               = local.subnet_name
  ip_range_pods            = var.ip_range_pods_name
  ip_range_services        = var.ip_range_services_name
  logging_service          = "logging.googleapis.com/kubernetes"
  monitoring_service       = "monitoring.googleapis.com/kubernetes"
  remove_default_node_pool = true
  service_account          = local.service_account
  gce_pd_csi_driver        = true
  deletion_protection      = false
  node_pools = [
    {
      name                 = "runner-pool"
      min_count            = var.min_node_count
      max_count            = var.max_node_count
      auto_upgrade         = true
      machine_type         = var.machine_type
      enable_private_nodes = var.enable_private_nodes
    }
  ]
  enable_secret_manager_addon = var.enable_secret_manager
}

data "google_client_config" "default" {
}

resource "kubernetes_namespace" "arc_systems" {
  metadata {
    name = var.arc_systems_namespace
  }
}

resource "kubernetes_namespace" "arc_runners" {
  metadata {
    name = var.arc_runners_namespace
  }

  depends_on = [helm_release.arc]
}

/*****************************************
  K8S secrets for configuring k8s runners
 *****************************************/
resource "kubernetes_secret" "gh_app_pre_defined_secret" {
  count = var.enable_secret_manager ? 0 : 1
  metadata {
    name      = var.gh_app_pre_defined_secret_name
    namespace = kubernetes_namespace.arc_runners.metadata[0].name
  }
  data = {
    github_app_id              = var.gh_app_id
    github_app_installation_id = var.gh_app_installation_id
    github_app_private_key     = var.gh_app_private_key
  }

  lifecycle {
    precondition {
      condition     = !var.enable_secret_manager && var.gh_app_id != null && var.gh_app_installation_id != null && var.gh_app_private_key != null
      error_message = "gh_app_id, gh_app_installation_id, and gh_app_private_key must be provided when enable_secret_manager is false"
    }
  }
}

resource "google_service_account" "arc_runners_gsa" {
  count        = var.enable_secret_manager ? 1 : 0
  project      = var.project_id
  account_id   = "arc-runners-sa-${var.cluster_suffix}"
  display_name = "GH Actions Runners GSA"

  lifecycle {
    precondition {
      condition     = !var.enable_secret_manager || var.gh_app_secrets != null
      error_message = "gh_app_secrets must be provided when enable_secret_manager is true"
    }
  }
}

resource "google_secret_manager_secret_iam_member" "gh_app" {
  for_each  = var.enable_secret_manager ? local.gh_app_secrets_processed : {}
  secret_id = each.value.secret_name
  project   = each.value.project_id
  role      = "roles/secretmanager.secretAccessor"
  member    = google_service_account.arc_runners_gsa[0].member
}

resource "kubernetes_service_account" "arc_runners_ksa" {
  count = var.enable_secret_manager ? 1 : 0
  metadata {
    name      = "arc-runners-sa"
    namespace = kubernetes_namespace.arc_runners.metadata[0].name
    annotations = {
      "iam.gke.io/gcp-service-account" = google_service_account.arc_runners_gsa[0].email
    }
  }

  automount_service_account_token = true
}

resource "google_project_iam_member" "arc_runners_gsa_wi_user" {
  count   = var.enable_secret_manager ? 1 : 0
  project = var.project_id
  role    = "roles/iam.workloadIdentityUser"
  member  = "serviceAccount:${var.project_id}.svc.id.goog[${kubernetes_namespace.arc_runners.metadata[0].name}/${kubernetes_service_account.arc_runners_ksa[0].metadata[0].name}]"
}

resource "kubernetes_manifest" "arc_runners_spc" {
  count = var.enable_secret_manager ? 1 : 0

  manifest = {
    "apiVersion" = "secrets-store.csi.x-k8s.io/v1"
    "kind"       = "SecretProviderClass"
    "metadata" = {
      "name"      = "arc-runners-gh-creds"
      "namespace" = kubernetes_namespace.arc_runners.metadata[0].name
    }
    "spec" = {
      "provider" = "gke"
      "parameters" = {
        "secrets" = yamlencode([
          {
            "resourceName" = local.gh_app_secrets_ids.app_id
            "path"         = "github_app_id"
            "mode"         = 0444
          },
          {
            "resourceName" = local.gh_app_secrets_ids.installation_id
            "path"         = "github_app_installation_id"
            "mode"         = 0444
          },
          {
            "resourceName" = local.gh_app_secrets_ids.private_key
            "path"         = "github_app_private_key"
            "mode"         = 0400
          }
        ])
      }
      "secretObjects" = [
        {
          "secretName" = "arc-runners-gh-creds"
          "type"       = "Opaque"
          "data" = [
            {
              "objectName" = "github_app_id"
              "key"        = "github_app_id"
            },
            {
              "objectName" = "github_app_installation_id"
              "key"        = "github_app_installation_id"
            },
            {
              "objectName" = "github_app_private_key"
              "key"        = "github_app_private_key"
            }
          ]
        }
      ]
    }
  }
}

resource "helm_release" "arc" {
  name      = "arc"
  namespace = kubernetes_namespace.arc_systems.metadata[0].name
  chart     = "oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller"
  version   = var.arc_controller_version
  wait      = true
  values    = var.arc_controller_values
}

resource "helm_release" "arc_runners_set" {
  name      = "arc-runners"
  namespace = kubernetes_namespace.arc_runners.metadata[0].name
  chart     = "oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set"
  version   = var.arc_runners_version

  dynamic "set" {
    for_each = var.enable_secret_manager ? [] : [1]
    content {
      name  = "githubConfigSecret"
      value = kubernetes_secret.gh_app_pre_defined_secret[0].metadata[0].name
    }
  }

  set {
    name  = "githubConfigUrl"
    value = var.gh_config_url
  }

  dynamic "set" {
    for_each = var.arc_container_mode == "" ? [] : [1]
    content {
      name  = "containerMode.type"
      value = var.arc_container_mode
    }
  }

  values = concat(var.arc_runners_values, var.enable_secret_manager && var.gh_app_secrets != null ? [yamlencode({
    template = {
      spec = {
        serviceAccountName = "arc-runners-sa"
        nodeSelector = {
          "iam.gke.io/gke-metadata-server-enabled" = "true"
        }
        volumes = [
          {
            name = "arc-secrets-vol"
            csi = {
              driver   = "secrets-store-gke.csi.k8s.io"
              readOnly = true
              volumeAttributes = {
                secretProviderClass = "arc-runners-gh-creds"
              }
            }
          }
        ]
        containers = [
          {
            name = "runner"
            volumeMounts = [
              {
                name      = "arc-secrets-vol"
                mountPath = "/mnt/arc-secrets"
                readOnly  = true
              }
            ]
            env = [
              {
                name  = "GITHUB_APP_ID_FILE"
                value = "/mnt/arc-secrets/github_app_id"
              },
              {
                name  = "GITHUB_APP_INSTALLATION_ID_FILE"
                value = "/mnt/arc-secrets/github_app_installation_id"
              },
              {
                name  = "GITHUB_APP_PRIVATE_KEY_FILE"
                value = "/mnt/arc-secrets/github_app_private_key"
              }
            ]
          }
        ]
      }
    }
  })] : [])

  depends_on = [
    kubernetes_manifest.arc_runners_spc,
    kubernetes_service_account.arc_runners_ksa
  ]
}
