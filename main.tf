
# ============================================================
# GCP Terraform - 실시간 고객 상담 챗봇 AI 서비스
# CSP: GCP | Region: asia-northeast3 (Seoul)
# Model: GPT-1/2 (Transformer) | Monthly Users: 100,000
# ============================================================

terraform {
  required_version = ">= 1.3.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = "asia-northeast3"
  zone    = "asia-northeast3-a"
}

# ============================================================
# Variables
# ============================================================

variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  default = "asia-northeast3"
}

variable "zone" {
  default = "asia-northeast3-a"
}

# ============================================================
# VPC & Networking
# ============================================================

resource "google_compute_network" "chatbot_vpc" {
  name                    = "chatbot-vpc"
  auto_create_subnetworks = false

  labels = {
    project     = "ai-infra"
    environment = "production"
  }
}

resource "google_compute_subnetwork" "chatbot_subnet_public" {
  name          = "chatbot-subnet-public"
  ip_cidr_range = "10.0.1.0/24"
  region        = var.region
  network       = google_compute_network.chatbot_vpc.id
}

resource "google_compute_subnetwork" "chatbot_subnet_private" {
  name                     = "chatbot-subnet-private"
  ip_cidr_range            = "10.0.2.0/24"
  region                   = var.region
  network                  = google_compute_network.chatbot_vpc.id
  private_ip_google_access = true
}

resource "google_compute_router" "chatbot_router" {
  name    = "chatbot-router"
  region  = var.region
  network = google_compute_network.chatbot_vpc.id
}

resource "google_compute_router_nat" "chatbot_nat" {
  name                               = "chatbot-nat"
  router                             = google_compute_router.chatbot_router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# ============================================================
# Firewall Rules
# ============================================================

resource "google_compute_firewall" "allow_http_https" {
  name    = "chatbot-allow-http-https"
  network = google_compute_network.chatbot_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "8080"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["chatbot-api"]
}

resource "google_compute_firewall" "allow_internal" {
  name    = "chatbot-allow-internal"
  network = google_compute_network.chatbot_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }

  source_ranges = ["10.0.0.0/16"]
}

# ============================================================
# GKE Cluster (GPU Node Pool 포함)
# ============================================================

resource "google_container_cluster" "chatbot_gke" {
  name     = "chatbot-gke-cluster"
  location = var.zone

  network    = google_compute_network.chatbot_vpc.name
  subnetwork = google_compute_subnetwork.chatbot_subnet_private.name

  remove_default_node_pool = true
  initial_node_count       = 1

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  addons_config {
    http_load_balancing {
      disabled = false
    }
    horizontal_pod_autoscaling {
      disabled = false
    }
  }

  resource_labels = {
    project     = "ai-infra"
    environment = "production"
  }
}

# CPU Node Pool (API 서버용)
resource "google_container_node_pool" "cpu_nodes" {
  name       = "cpu-node-pool"
  location   = var.zone
  cluster    = google_container_cluster.chatbot_gke.name
  node_count = 2

  autoscaling {
    min_node_count = 1
    max_node_count = 5
  }

  node_config {
    machine_type = "e2-standard-4"
    disk_size_gb = 50
    disk_type    = "pd-ssd"

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    labels = {
      project     = "ai-infra"
      environment = "production"
      node-type   = "cpu"
    }
  }
}

# GPU Node Pool (GPT 추론 서버용 - g2-standard-4, NVIDIA L4 24GB)
resource "google_container_node_pool" "gpu_nodes" {
  name     = "gpu-node-pool"
  location = var.zone
  cluster  = google_container_cluster.chatbot_gke.name

  autoscaling {
    min_node_count = 1
    max_node_count = 4
  }

  node_config {
    machine_type = "g2-standard-4"
    disk_size_gb = 100
    disk_type    = "pd-ssd"

    # NVIDIA L4 GPU (24GB VRAM) - GPT-2 추론 최적
    guest_accelerator {
      type  = "nvidia-l4"
      count = 1
      gpu_driver_installation_config {
        gpu_driver_version = "LATEST"
      }
    }

    # Spot VM 활용 (최대 90% 비용 절감)
    spot = true

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    labels = {
      project     = "ai-infra"
      environment = "production"
      node-type   = "gpu"
      workload    = "gpt-inference"
    }

    taint {
      key    = "nvidia.com/gpu"
      value  = "present"
      effect = "NO_SCHEDULE"
    }
  }
}

# ============================================================
# Cloud Memorystore (Redis) - 추론 응답 캐싱
# ============================================================

resource "google_redis_instance" "chatbot_cache" {
  name           = "chatbot-redis-cache"
  tier           = "STANDARD_HA"
  memory_size_gb = 4
  region         = var.region

  authorized_network = google_compute_network.chatbot_vpc.id
  connect_mode       = "PRIVATE_SERVICE_ACCESS"

  redis_version = "REDIS_7_0"
  display_name  = "Chatbot Inference Cache"

  redis_configs = {
    maxmemory-policy = "allkeys-lru"
  }

  labels = {
    project     = "ai-infra"
    environment = "production"
  }
}

# ============================================================
# Cloud Firestore - 대화 이력 저장
# ============================================================

resource "google_firestore_database" "chatbot_db" {
  project     = var.project_id
  name        = "chatbot-conversation-db"
  location_id = "asia-northeast3"
  type        = "FIRESTORE_NATIVE"

  deletion_policy = "DELETE"
}

# ============================================================
# Cloud Storage - 모델 파일 저장
# ============================================================

resource "google_storage_bucket" "model_storage" {
  name          = "${var.project_id}-chatbot-model-storage"
  location      = "ASIA-NORTHEAST3"
  force_destroy = false

  storage_class = "STANDARD"

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      age = 90
    }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }

  labels = {
    project     = "ai-infra"
    environment = "production"
  }
}

resource "google_storage_bucket" "log_storage" {
  name          = "${var.project_id}-chatbot-log-storage"
  location      = "ASIA-NORTHEAST3"
  force_destroy = false

  storage_class = "STANDARD"

  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
  }

  labels = {
    project     = "ai-infra"
    environment = "production"
  }
}

# ============================================================
# Cloud Load Balancing + Cloud CDN
# ============================================================

resource "google_compute_global_address" "chatbot_ip" {
  name = "chatbot-global-ip"
}

resource "google_compute_managed_ssl_certificate" "chatbot_ssl" {
  name = "chatbot-ssl-cert"

  managed {
    domains = ["chatbot.${var.project_id}.example.com"]
  }
}

resource "google_compute_backend_service" "chatbot_backend" {
  name                  = "chatbot-backend-service"
  protocol              = "HTTP"
  port_name             = "http"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  timeout_sec           = 30

  enable_cdn = true

  cdn_policy {
    cache_mode                   = "CACHE_ALL_STATIC"
    default_ttl                  = 3600
    max_ttl                      = 86400
    serve_while_stale            = 86400
    signed_url_cache_max_age_sec = 7200
  }

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

resource "google_compute_url_map" "chatbot_url_map" {
  name            = "chatbot-url-map"
  default_service = google_compute_backend_service.chatbot_backend.id
}

resource "google_compute_target_https_proxy" "chatbot_https_proxy" {
  name             = "chatbot-https-proxy"
  url_map          = google_compute_url_map.chatbot_url_map.id
  ssl_certificates = [google_compute_managed_ssl_certificate.chatbot_ssl.id]
}

resource "google_compute_global_forwarding_rule" "chatbot_forwarding_rule" {
  name                  = "chatbot-forwarding-rule"
  ip_protocol           = "TCP"
  load_balancing_scheme = "EXTERNAL_MANAGED"
  port_range            = "443"
  target                = google_compute_target_https_proxy.chatbot_https_proxy.id
  ip_address            = google_compute_global_address.chatbot_ip.id
}

# ============================================================
# Cloud API Gateway
# ============================================================

resource "google_api_gateway_api" "chatbot_api" {
  provider = google
  api_id   = "chatbot-api"
}

resource "google_api_gateway_api_config" "chatbot_api_config" {
  provider      = google
  api           = google_api_gateway_api.chatbot_api.api_id
  api_config_id = "chatbot-api-config-v1"

  openapi_documents {
    document {
      path = "spec.yaml"
      contents = base64encode(<<-EOF
        swagger: "2.0"
        info:
          title: Chatbot AI API
          description: 실시간 고객 상담 챗봇 AI API
          version: "1.0.0"
        host: chatbot-api.example.com
        schemes:
          - https
        paths:
          /chat:
            post:
              summary: 챗봇 메시지 전송
              operationId: sendMessage
              consumes:
                - application/json
              produces:
                - application/json
              parameters:
                - in: body
                  name: body
                  schema:
                    type: object
                    properties:
                      message:
                        type: string
                      session_id:
                        type: string
              responses:
                "200":
                  description: 챗봇 응답
          /health:
            get:
              summary: 헬스체크
              operationId: healthCheck
              responses:
                "200":
                  description: OK
      EOF
      )
    }
  }

  labels = {
    project     = "ai-infra"
    environment = "production"
  }
}

resource "google_api_gateway_gateway" "chatbot_gateway" {
  provider   = google
  api_config = google_api_gateway_api_config.chatbot_api_config.id
  gateway_id = "chatbot-gateway"
  region     = var.region

  labels = {
    project     = "ai-infra"
    environment = "production"
  }
}

# ============================================================
# Cloud Monitoring & Alerting
# ============================================================

resource "google_monitoring_notification_channel" "email_alert" {
  display_name = "Chatbot Alert Email"
  type         = "email"

  labels = {
    email_address = "gwonsoo.che@mz.co.kr"
  }
}

resource "google_monitoring_alert_policy" "gpu_utilization_alert" {
  display_name = "GPU Utilization High Alert"
  combiner     = "OR"

  conditions {
    display_name = "GPU Utilization > 85%"
    condition_threshold {
      filter          = "metric.type=\"kubernetes.io/node/accelerator/duty_cycle\" resource.type=\"k8s_node\""
      duration        = "300s"
      comparison      = "COMPARISON_GT"
      threshold_value = 85

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email_alert.name]

  alert_strategy {
    auto_close = "1800s"
  }
}

resource "google_monitoring_alert_policy" "latency_alert" {
  display_name = "API Latency High Alert"
  combiner     = "OR"

  conditions {
    display_name = "API Latency > 3s"
    condition_threshold {
      filter          = "metric.type=\"loadbalancing.googleapis.com/https/total_latencies\" resource.type=\"https_lb_rule\""
      duration        = "120s"
      comparison      = "COMPARISON_GT"
      threshold_value = 3000

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_PERCENTILE_99"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email_alert.name]
}

# ============================================================
# IAM - Service Account
# ============================================================

resource "google_service_account" "chatbot_sa" {
  account_id   = "chatbot-inference-sa"
  display_name = "Chatbot Inference Service Account"
  description  = "GPT 추론 서버용 서비스 계정"
}

resource "google_project_iam_member" "chatbot_sa_storage" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${google_service_account.chatbot_sa.email}"
}

resource "google_project_iam_member" "chatbot_sa_firestore" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.chatbot_sa.email}"
}

resource "google_project_iam_member" "chatbot_sa_monitoring" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.chatbot_sa.email}"
}

# ============================================================
# Outputs
# ============================================================

output "gke_cluster_name" {
  value       = google_container_cluster.chatbot_gke.name
  description = "GKE 클러스터 이름"
}

output "gke_cluster_endpoint" {
  value       = google_container_cluster.chatbot_gke.endpoint
  description = "GKE 클러스터 엔드포인트"
  sensitive   = true
}

output "redis_host" {
  value       = google_redis_instance.chatbot_cache.host
  description = "Redis 캐시 호스트"
  sensitive   = true
}

output "load_balancer_ip" {
  value       = google_compute_global_address.chatbot_ip.address
  description = "로드밸런서 글로벌 IP"
}

output "api_gateway_url" {
  value       = google_api_gateway_gateway.chatbot_gateway.default_hostname
  description = "API Gateway URL"
}

output "model_storage_bucket" {
  value       = google_storage_bucket.model_storage.name
  description = "모델 파일 저장 버킷"
}

output "monthly_cost_estimate" {
  value       = "예상 월 비용: ~$370 (Spot VM + CUD 1년 약정 기준)"
  description = "월 예상 비용"
}
