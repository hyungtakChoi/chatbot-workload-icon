terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 4.0"
    }
  }
}

provider "google" {
  region = "asia-northeast3"  # 서울 리전
}

# 프로젝트 변수
variable "project_id" {
  description = "GCP 프로젝트 ID"
  type        = string
}

# VPC 네트워크
resource "google_compute_network" "chatbot_network" {
  name                    = "chatbot-network"
  auto_create_subnetworks = false
  project                 = var.project_id
}

# 서브넷 생성
resource "google_compute_subnetwork" "chatbot_subnet" {
  name          = "chatbot-subnet"
  ip_cidr_range = "10.0.0.0/24"
  network       = google_compute_network.chatbot_network.id
  region        = "asia-northeast3"
  project       = var.project_id
}

# 방화벽 규칙
resource "google_compute_firewall" "chatbot_firewall" {
  name    = "chatbot-firewall"
  network = google_compute_network.chatbot_network.id
  project = var.project_id

  allow {
    protocol = "tcp"
    ports    = ["22", "80", "443", "8080"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["chatbot-server"]
}

# GPU VM 인스턴스
resource "google_compute_instance" "chatbot_server" {
  name         = "chatbot-server"
  machine_type = "g2-standard-8"  # 8 vCPUs, 32GB 메모리, 1 NVIDIA L4 GPU
  zone         = "asia-northeast3-a"
  project      = var.project_id

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-11"
      size  = 100  # GB
      type  = "pd-balanced"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.chatbot_subnet.id
    access_config {
      # 외부 IP 할당
    }
  }

  guest_accelerator {
    type  = "nvidia-l4"
    count = 1
  }

  scheduling {
    on_host_maintenance = "TERMINATE"  # GPU VM의 경우 필수
    automatic_restart   = true
    preemptible        = false
  }

  # GPU 드라이버 설치 스크립트
  metadata_startup_script = <<-EOF
    #!/bin/bash
    apt-get update
    apt-get install -y build-essential python3-pip
    pip3 install torch numpy transformers
    # GPU 드라이버 설치
    curl https://raw.githubusercontent.com/GoogleCloudPlatform/compute-gpu-installation/main/linux/install_gpu_driver.py -o install_gpu_driver.py
    python3 install_gpu_driver.py
  EOF

  service_account {
    scopes = ["cloud-platform"]
  }

  tags = ["chatbot-server"]

  labels = {
    project     = "ai-infra"
    environment = "production"
  }
}

# Cloud SQL 인스턴스 (메타데이터 저장)
resource "google_sql_database_instance" "chatbot_db" {
  name             = "chatbot-db"
  database_version = "POSTGRES_14"
  region           = "asia-northeast3"
  project          = var.project_id

  settings {
    tier              = "db-custom-2-4096"  # 2 vCPU, 4GB RAM
    disk_size         = 20  # GB
    disk_type         = "PD_SSD"
    availability_type = "ZONAL"  # REGIONAL로 설정하면 고가용성 활성화

    backup_configuration {
      enabled            = true
      start_time         = "02:00"
      binary_log_enabled = false
    }

    maintenance_window {
      day          = 7  # Sunday
      hour         = 2  # 2 AM
      update_track = "stable"
    }

    ip_configuration {
      ipv4_enabled    = true
      private_network = google_compute_network.chatbot_network.id
    }

    database_flags {
      name  = "max_connections"
      value = "100"
    }
  }

  deletion_protection = false  # 실제 운영 환경에서는 true로 설정

  labels = {
    project     = "ai-infra"
    environment = "production"
  }
}

# 데이터베이스 생성
resource "google_sql_database" "chatbot_database" {
  name     = "chatbotdb"
  instance = google_sql_database_instance.chatbot_db.name
  project  = var.project_id
}

# 데이터베이스 사용자 생성
resource "google_sql_user" "chatbot_user" {
  name     = "chatbot_user"
  instance = google_sql_database_instance.chatbot_db.name
  password = "changeme"  # 실제 환경에서는 Secret Manager 사용 권장
  project  = var.project_id
}

# Load Balancer를 위한 인스턴스 그룹
resource "google_compute_instance_group" "chatbot_instance_group" {
  name        = "chatbot-instance-group"
  zone        = "asia-northeast3-a"
  instances   = [google_compute_instance.chatbot_server.id]
  project     = var.project_id

  named_port {
    name = "http"
    port = 8080
  }

  lifecycle {
    create_before_destroy = true
  }
}

# 상태 점검
resource "google_compute_health_check" "chatbot_health_check" {
  name                = "chatbot-health-check"
  check_interval_sec  = 5
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 2
  project             = var.project_id

  http_health_check {
    port         = 8080
    request_path = "/health"
  }
}

# 백엔드 서비스
resource "google_compute_backend_service" "chatbot_backend" {
  name                  = "chatbot-backend-service"
  project               = var.project_id
  port_name             = "http"
  protocol              = "HTTP"
  load_balancing_scheme = "EXTERNAL"
  timeout_sec           = 30
  health_checks         = [google_compute_health_check.chatbot_health_check.id]

  backend {
    group = google_compute_instance_group.chatbot_instance_group.id
  }
}

# URL 맵
resource "google_compute_url_map" "chatbot_url_map" {
  name            = "chatbot-url-map"
  default_service = google_compute_backend_service.chatbot_backend.id
  project         = var.project_id
}

# HTTPS 프록시
resource "google_compute_target_https_proxy" "chatbot_https_proxy" {
  name             = "chatbot-https-proxy"
  url_map          = google_compute_url_map.chatbot_url_map.id
  ssl_certificates = [google_compute_managed_ssl_certificate.chatbot_cert.id]
  project          = var.project_id
}

# SSL 인증서
resource "google_compute_managed_ssl_certificate" "chatbot_cert" {
  name     = "chatbot-cert"
  project  = var.project_id

  managed {
    domains = ["chatbot.example.com"]  # 실제 도메인으로 변경 필요
  }
}

# 전역 전달 규칙
resource "google_compute_global_forwarding_rule" "chatbot_forwarding_rule" {
  name                  = "chatbot-forwarding-rule"
  target                = google_compute_target_https_proxy.chatbot_https_proxy.id
  port_range            = "443"
  load_balancing_scheme = "EXTERNAL"
  project               = var.project_id
}

# Redis Cache (세션 및 캐싱)
resource "google_redis_instance" "chatbot_cache" {
  name           = "chatbot-cache"
  tier           = "BASIC"
  memory_size_gb = 1
  region         = "asia-northeast3"
  project        = var.project_id
  
  authorized_network = google_compute_network.chatbot_network.id
  redis_version      = "REDIS_6_X"
  
  maintenance_policy {
    day      = "SUNDAY"
    start_time {
      hours   = 2
      minutes = 0
    }
  }

  labels = {
    project     = "ai-infra"
    environment = "production"
  }
}

# Cloud Storage 버킷 (모델 및 데이터 저장)
resource "google_storage_bucket" "chatbot_model_storage" {
  name          = "chatbot-model-storage-${var.project_id}"
  location      = "ASIA-NORTHEAST3"
  storage_class = "STANDARD"
  project       = var.project_id
  
  uniform_bucket_level_access = true
  
  versioning {
    enabled = true
  }

  labels = {
    project     = "ai-infra"
    environment = "production"
  }
}

# Auto Scaling 설정을 위한 인스턴스 템플릿
resource "google_compute_instance_template" "chatbot_template" {
  name_prefix  = "chatbot-template-"
  machine_type = "g2-standard-8"
  project      = var.project_id

  disk {
    source_image = "debian-cloud/debian-11"
    auto_delete  = true
    boot         = true
    disk_type    = "pd-balanced"
    disk_size_gb = 100
  }

  network_interface {
    subnetwork = google_compute_subnetwork.chatbot_subnet.id
    access_config {
      # 외부 IP 할당
    }
  }

  scheduling {
    on_host_maintenance = "TERMINATE"  # GPU VM의 경우 필수
    automatic_restart   = true
  }

  guest_accelerator {
    type  = "nvidia-l4"
    count = 1
  }

  service_account {
    scopes = ["cloud-platform"]
  }

  metadata_startup_script = <<-EOF
    #!/bin/bash
    apt-get update
    apt-get install -y build-essential python3-pip
    pip3 install torch numpy transformers
    # GPU 드라이버 설치
    curl https://raw.githubusercontent.com/GoogleCloudPlatform/compute-gpu-installation/main/linux/install_gpu_driver.py -o install_gpu_driver.py
    python3 install_gpu_driver.py
  EOF

  tags = ["chatbot-server"]

  labels = {
    project     = "ai-infra"
    environment = "production"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# 관리형 인스턴스 그룹 (MIG)
resource "google_compute_region_instance_group_manager" "chatbot_mig" {
  name                      = "chatbot-mig"
  base_instance_name        = "chatbot"
  region                    = "asia-northeast3"
  distribution_policy_zones = ["asia-northeast3-a", "asia-northeast3-b"]
  project                   = var.project_id

  version {
    instance_template = google_compute_instance_template.chatbot_template.id
  }

  named_port {
    name = "http"
    port = 8080
  }

  auto_healing_policies {
    health_check      = google_compute_health_check.chatbot_health_check.id
    initial_delay_sec = 300
  }

  target_size = 1  # 초기 인스턴스 수
}

# 자동 확장 정책
resource "google_compute_region_autoscaler" "chatbot_autoscaler" {
  name   = "chatbot-autoscaler"
  region = "asia-northeast3"
  target = google_compute_region_instance_group_manager.chatbot_mig.id
  project = var.project_id

  autoscaling_policy {
    max_replicas    = 5
    min_replicas    = 1
    cooldown_period = 60

    cpu_utilization {
      target = 0.6  # 60% CPU 사용률을 초과하면 확장
    }
  }
}

# Cloud Monitoring 알림 정책
resource "google_monitoring_alert_policy" "high_cpu_usage" {
  display_name = "High CPU Usage Alert"
  project      = var.project_id
  combiner     = "OR"
  
  conditions {
    display_name = "VM Instance CPU utilization"
    
    condition_threshold {
      filter          = "metric.type=\"compute.googleapis.com/instance/cpu/utilization\" AND resource.type=\"gce_instance\" AND metadata.user_labels.project=\"ai-infra\""
      duration        = "60s"
      comparison      = "COMPARISON_GT"
      threshold_value = 0.8  # 80% CPU 사용률 초과 시 알림
      
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_MEAN"
        cross_series_reducer = "REDUCE_MEAN"
      }
    }
  }

  notification_channels = []  # 알림 채널 ID 추가 필요
  
  documentation {
    content   = "CPU usage is above 80% for more than 1 minute. Please check the instance."
    mime_type = "text/markdown"
  }

  alert_strategy {
    auto_close = "1800s"  # 30분 동안 조건이 해결되면 자동 종료
  }
}