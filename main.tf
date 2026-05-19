
# ============================================================
# GCP Terraform - 실시간 고객 상담 챗봇 AI 서비스
# CSP: GCP | Region: asia-northeast3 (Seoul)
# Model: GPT-1/2 (Transformer) | Monthly Users: 100,000
# Tags: project=ai-infra, environment=production
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
  region  = var.region
}

# ============================================================
# Variables
# ============================================================

variable "project_id" {
  description = "GCP Project ID"
  type        = string
}

variable "region" {
  description = "GCP Region"
  type        = string
  default     = "asia-northeast3"
}

variable "zone" {
  description = "GCP Zone"
  type        = string
  default     = "asia-northeast3-a"
}

variable "gke_cluster_name" {
  description = "GKE Cluster Name"
  type        = string
  default     = "chatbot-ai-cluster"
}

variable "environment" {
  description = "Environment"
  type        = string
  default     = "production"
}

# ============================================================
# VPC & Networking
# ============================================================

resource "google_compute_network" "chatbot_vpc" {
  name                    = "chatbot-ai-vpc"
  auto_create_subnetworks = false

  description = "VPC for chatbot AI service"
}

resource "google_compute_subnetwork" "chatbot_subnet" {
  name          = "chatbot-ai-subnet"
  ip_cidr_range = "10.10.0.0/16"
  region        = var.region
  network       = google_compute_network.chatbot_vpc.id

  secondary_ip_range {
    range_name    = "gke-pods"
    ip_cidr_range = "10.20.0.0/16"
  }

  secondary_ip_range {
    range_name    = "gke-services"
    ip_cidr_range = "10.30.0.0/16"
  }
}

resource "google_compute_subnetwork" "chatbot_private_subnet" {
  name                     = "chatbot-ai-private-subnet"
  ip_cidr_range            = "10.40.0.0/16"
  region                   = var.region
  network                  = google_compute_network.chatbot_vpc.id
  private_ip_google_access = true
}

# Cloud Router & NAT (Spot VM 인터넷 접근용)
resource "google_compute_router" "chatbot_router" {
  name    = "chatbot-ai-router"
  region  = var.region
  network = google_compute_network.chatbot_vpc.id
}

resource "google_compute_router_nat" "chatbot_nat" {
  name                               = "chatbot-ai-nat"
  router                             = google_compute_router.chatbot_router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# ============================================================
# Firewall Rules
# ============================================================

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
  allow {
    protocol = "icmp"
  }

  source_ranges = ["10.0.0.0/8"]

  target_tags = ["chatbot-internal"]
}

resource "google_compute_firewall" "allow_health_check" {
  name    = "chatbot-allow-health-check"
  network = google_compute_network.chatbot_vpc.name

  allow {
    protocol = "tcp"
    ports    = ["8080", "8443"]
  }

  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["chatbot-gke-node"]
}

# ============================================================
# GKE Cluster (GPU 추론 서버)
# ============================================================

resource "google_container_cluster" "chatbot_cluster" {
  name     = var.gke_cluster_name
  location = var.region

  network    = google_compute_network.chatbot_vpc.name
  subnetwork = google_compute_subnetwork.chatbot_subnet.name

  # Default node pool 제거 후 별도 관리
  remove_default_node_pool = true
  initial_node_count       = 1

  ip_allocation_policy {
    cluster_secondary_range_name  = "gke-pods"
    services_secondary_range_name = "gke-services"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
  }

  master_authorized_networks_config {
    cidr_blocks {
      cidr_block   = "0.0.0.0/0"
      display_name = "all"
    }
  }

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

# ============================================================
# GKE Node Pool - GPU (L4 24GB) for GPT Inference
# Spot VM으로 비용 최적화 (최대 60~70% 절감)
# ============================================================

resource "google_container_node_pool" "gpu_spot_pool" {
  name       = "gpu-spot-node-pool"
  location   = var.region
  cluster    = google_container_cluster.chatbot_cluster.name

  # Auto Scaling: 최소 1 ~ 최대 5 노드
  autoscaling {
    min_node_count = 1
    max_node_count = 5
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type = "g2-standard-4"   # L4 GPU (24GB VRAM), 4 vCPU, 16GB RAM

    # Spot VM 활성화 (비용 최대 70% 절감)
    spot = true

    guest_accelerator {
      type  = "nvidia-l4"
      count = 1
      gpu_driver_installation_config {
        gpu_driver_version = "LATEST"
      }
    }

    disk_size_gb = 100
    disk_type    = "pd-ssd"

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    tags = ["chatbot-gke-node", "chatbot-internal"]

    labels = {
      project     = "ai-infra"
      environment = "production"
      node-type   = "gpu-inference"
    }

    taint {
      key    = "nvidia.com/gpu"
      value  = "present"
      effect = "NO_SCHEDULE"
    }
  }
}

# GKE Node Pool - CPU (API 서버, 일반 워크로드)
resource "google_container_node_pool" "cpu_pool" {
  name       = "cpu-node-pool"
  location   = var.region
  cluster    = google_container_cluster.chatbot_cluster.name

  autoscaling {
    min_node_count = 1
    max_node_count = 5
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type = "e2-standard-4"   # 4 vCPU, 16GB RAM (비용 효율 최고)
    spot         = true

    disk_size_gb = 50
    disk_type    = "pd-standard"

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]

    tags = ["chatbot-gke-node", "chatbot-internal"]

    labels = {
      project     = "ai-infra"
      environment = "production"
      node-type   = "cpu-api"
    }
  }
}

# ============================================================
# Cloud Memorystore (Redis) - 추론 응답 캐싱
# 반복 질문 30~50% GPU 추론 생략 → 비용 절감
# ============================================================

resource "google_redis_instance" "chatbot_cache" {
  name           = "chatbot-ai-redis"
  tier           = "STANDARD_HA"       # HA 구성 (실시간 서비스 필수)
  memory_size_gb = 4
  region         = var.region

  authorized_network = google_compute_network.chatbot_vpc.id
  connect_mode       = "PRIVATE_SERVICE_ACCESS"

  redis_version = "REDIS_7_0"

  redis_configs = {
    maxmemory-policy = "allkeys-lru"   # LRU 캐시 정책
    maxmemory-gb     = "3.2"
  }

  labels = {
    project     = "ai-infra"
    environment = "production"
  }
}

# ============================================================
# Firestore - 대화 이력 저장
# ============================================================

resource "google_firestore_database" "chatbot_db" {
  project     = var.project_id
  name        = "chatbot-conversation-db"
  location_id = var.region
  type        = "FIRESTORE_NATIVE"

  deletion_policy = "DELETE"
}

# ============================================================
# Cloud Storage - 모델 파일 저장 (GPT-1/2 weights)
# ============================================================

resource "google_storage_bucket" "model_bucket" {
  name          = "${var.project_id}-chatbot-model-weights"
  location      = var.region
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

resource "google_storage_bucket" "log_bucket" {
  name          = "${var.project_id}-chatbot-logs"
  location      = var.region
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
# Cloud Load Balancing (HTTPS) + Cloud CDN + Cloud Armor
# ============================================================

# Static IP for Load Balancer
resource "google_compute_global_address" "chatbot_lb_ip" {
  name = "chatbot-ai-lb-ip"
}

# Backend Service (GKE 연동)
resource "google_compute_backend_service" "chatbot_backend" {
  name                  = "chatbot-ai-backend"
  protocol              = "HTTP"
  port_name             = "http"
  timeout_sec           = 30
  load_balancing_scheme = "EXTERNAL_MANAGED"

  # Cloud CDN 활성화 (정적 응답 캐싱)
  enable_cdn = true

  cdn_policy {
    cache_mode                   = "CACHE_ALL_STATIC"
    default_ttl                  = 3600
    max_ttl                      = 86400
    serve_while_stale            = 86400
    signed_url_cache_max_age_sec = 7200
  }

  # Cloud Armor 보안 정책 연결
  security_policy = google_compute_security_policy.chatbot_armor.id

  health_checks = [google_compute_health_check.chatbot_hc.id]

  log_config {
    enable      = true
    sample_rate = 1.0
  }
}

# Health Check
resource "google_compute_health_check" "chatbot_hc" {
  name               = "chatbot-ai-health-check"
  check_interval_sec = 10
  timeout_sec        = 5

  http_health_check {
    port         = 8080
    request_path = "/health"
  }
}

# URL Map
resource "google_compute_url_map" "chatbot_url_map" {
  name            = "chatbot-ai-url-map"
  default_service = google_compute_backend_service.chatbot_backend.id
}

# HTTPS Proxy
resource "google_compute_target_https_proxy" "chatbot_https_proxy" {
  name    = "chatbot-ai-https-proxy"
  url_map = google_compute_url_map.chatbot_url_map.id

  ssl_certificates = [google_compute_managed_ssl_certificate.chatbot_ssl.id]
}

# Managed SSL Certificate
resource "google_compute_managed_ssl_certificate" "chatbot_ssl" {
  name = "chatbot-ai-ssl-cert"

  managed {
    domains = ["chatbot.ai-infra.example.com"]
  }
}

# Global Forwarding Rule
resource "google_compute_global_forwarding_rule" "chatbot_forwarding_rule" {
  name                  = "chatbot-ai-forwarding-rule"
  ip_address            = google_compute_global_address.chatbot_lb_ip.address
  port_range            = "443"
  target                = google_compute_target_https_proxy.chatbot_https_proxy.id
  load_balancing_scheme = "EXTERNAL_MANAGED"

  labels = {
    project     = "ai-infra"
    environment = "production"
  }
}

# ============================================================
# Cloud Armor - DDoS 방어 및 WAF
# ============================================================

resource "google_compute_security_policy" "chatbot_armor" {
  name = "chatbot-ai-armor-policy"

  # DDoS 자동 방어
  adaptive_protection_config {
    layer_7_ddos_defense_config {
      enable          = true
      rule_visibility = "STANDARD"
    }
  }

  # Rate Limiting (IP당 분당 100 요청 제한)
  rule {
    action   = "throttle"
    priority = 1000

    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }

    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
      rate_limit_threshold {
        count        = 100
        interval_sec = 60
      }
    }

    description = "Rate limiting per IP"
  }

  # 기본 허용 규칙
  rule {
    action   = "allow"
    priority = 2147483647

    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }

    description = "Default allow rule"
  }
}

# ============================================================
# Cloud Monitoring & Alerting
# ============================================================

resource "google_monitoring_notification_channel" "email_channel" {
  display_name = "Chatbot AI Alert Email"
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

  notification_channels = [google_monitoring_notification_channel.email_channel.id]

  alert_strategy {
    auto_close = "1800s"
  }
}

resource "google_monitoring_alert_policy" "redis_memory_alert" {
  display_name = "Redis Memory Usage High Alert"
  combiner     = "OR"

  conditions {
    display_name = "Redis Memory > 80%"

    condition_threshold {
      filter          = "metric.type=\"redis.googleapis.com/stats/memory/usage_ratio\" resource.type=\"redis_instance\""
      duration        = "300s"
      comparison      = "COMPARISON_GT"
      threshold_value = 0.8

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email_channel.id]
}

# ============================================================
# IAM - Workload Identity (GKE → GCP 서비스 접근)
# ============================================================

resource "google_service_account" "chatbot_sa" {
  account_id   = "chatbot-ai-sa"
  display_name = "Chatbot AI Service Account"
  description  = "Service account for chatbot AI GKE workloads"
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

# Workload Identity Binding
resource "google_service_account_iam_member" "workload_identity_binding" {
  service_account_id = google_service_account.chatbot_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[chatbot/chatbot-ai-ksa]"
}

# ============================================================
# Outputs
# ============================================================

output "gke_cluster_name" {
  description = "GKE Cluster Name"
  value       = google_container_cluster.chatbot_cluster.name
}

output "gke_cluster_endpoint" {
  description = "GKE Cluster Endpoint"
  value       = google_container_cluster.chatbot_cluster.endpoint
  sensitive   = true
}

output "load_balancer_ip" {
  description = "Load Balancer External IP"
  value       = google_compute_global_address.chatbot_lb_ip.address
}

output "redis_host" {
  description = "Redis Instance Host"
  value       = google_redis_instance.chatbot_cache.host
  sensitive   = true
}

output "model_bucket_name" {
  description = "GCS Bucket for Model Weights"
  value       = google_storage_bucket.model_bucket.name
}

output "service_account_email" {
  description = "Chatbot Service Account Email"
  value       = google_service_account.chatbot_sa.email
}

output "monthly_cost_estimate" {
  description = "Estimated Monthly Cost (USD)"
  value       = "~$370 (Spot VM + Committed Use Discounts 적용 기준)"
}
