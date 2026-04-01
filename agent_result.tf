provider "google" {
  project = "ai-chatbot-project"
  region  = "asia-northeast3" # 서울 리전
}

# VPC 네트워크
resource "google_compute_network" "chatbot_vpc" {
  name                    = "chatbot-vpc"
  auto_create_subnetworks = false
}

# 서브넷
resource "google_compute_subnetwork" "chatbot_subnet" {
  name          = "chatbot-subnet"
  ip_cidr_range = "10.0.0.0/24"
  region        = "asia-northeast3"
  network       = google_compute_network.chatbot_vpc.id
}

# 방화벽 규칙
resource "google_compute_firewall" "allow_http_https" {
  name    = "allow-http-https"
  network = google_compute_network.chatbot_vpc.id

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["chatbot-web"]
}

resource "google_compute_firewall" "allow_ssh" {
  name    = "allow-ssh"
  network = google_compute_network.chatbot_vpc.id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["chatbot-web", "chatbot-model"]
}

# 모델 서버 인스턴스 (GPU VM)
resource "google_compute_instance" "model_server" {
  name         = "chatbot-model-server"
  machine_type = "g2-standard-4" # NVIDIA L4 GPU 1개, vCPU 4개, 메모리 16GB
  zone         = "asia-northeast3-a"

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-11"
      size  = 50
    }
  }

  guest_accelerator {
    type  = "nvidia-l4"
    count = 1
  }

  scheduling {
    on_host_maintenance = "TERMINATE" # GPU VM은 라이브 마이그레이션을 지원하지 않음
  }

  network_interface {
    network    = google_compute_network.chatbot_vpc.id
    subnetwork = google_compute_subnetwork.chatbot_subnet.id
    access_config {
      // 외부 IP 할당
    }
  }

  metadata_startup_script = <<-EOF
    #!/bin/bash
    apt-get update
    apt-get install -y python3-pip git
    pip3 install torch torchvision torchaudio
    pip3 install transformers
  EOF

  tags = ["chatbot-model"]

  labels = {
    project     = "ai-infra"
    environment = "production"
  }

  service_account {
    scopes = ["cloud-platform"]
  }
}

# 웹 서버 인스턴스
resource "google_compute_instance" "web_server" {
  name         = "chatbot-web-server"
  machine_type = "e2-standard-2" # vCPU 2개, 메모리 8GB
  zone         = "asia-northeast3-a"

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-11"
      size  = 20
    }
  }

  network_interface {
    network    = google_compute_network.chatbot_vpc.id
    subnetwork = google_compute_subnetwork.chatbot_subnet.id
    access_config {
      // 외부 IP 할당
    }
  }

  metadata_startup_script = <<-EOF
    #!/bin/bash
    apt-get update
    apt-get install -y nginx python3-pip
    pip3 install flask gunicorn
  EOF

  tags = ["chatbot-web"]

  labels = {
    project     = "ai-infra"
    environment = "production"
  }
}

# 로드 밸런서 설정
resource "google_compute_instance_group" "web_servers" {
  name        = "chatbot-web-servers"
  zone        = "asia-northeast3-a"
  instances   = [google_compute_instance.web_server.id]
  named_port {
    name = "http"
    port = 80
  }
}

# 헬스 체크
resource "google_compute_health_check" "http_health_check" {
  name               = "http-health-check"
  check_interval_sec = 5
  timeout_sec        = 5
  http_health_check {
    port         = 80
    request_path = "/health"
  }
}

# 백엔드 서비스
resource "google_compute_backend_service" "web_backend" {
  name          = "chatbot-web-backend"
  health_checks = [google_compute_health_check.http_health_check.id]
  backend {
    group = google_compute_instance_group.web_servers.id
  }
}

# URL 맵
resource "google_compute_url_map" "web_url_map" {
  name            = "chatbot-url-map"
  default_service = google_compute_backend_service.web_backend.id
}

# HTTP 프록시
resource "google_compute_target_http_proxy" "http_proxy" {
  name    = "chatbot-http-proxy"
  url_map = google_compute_url_map.web_url_map.id
}

# 글로벌 포워딩 규칙
resource "google_compute_global_forwarding_rule" "http_forwarding_rule" {
  name       = "chatbot-http-rule"
  target     = google_compute_target_http_proxy.http_proxy.id
  port_range = "80"
}

# Cloud Storage 버킷 - 모델 아티팩트 저장
resource "google_storage_bucket" "model_artifacts" {
  name          = "chatbot-model-artifacts-bucket"
  location      = "ASIA-NORTHEAST3"
  storage_class = "STANDARD"
  
  uniform_bucket_level_access = true
  
  labels = {
    project     = "ai-infra"
    environment = "production"
  }
}

# Cloud Monitoring 알림 정책 - CPU 사용률
resource "google_monitoring_alert_policy" "cpu_usage_alert" {
  display_name = "High CPU Usage Alert"
  combiner     = "OR"
  conditions {
    display_name = "VM Instance CPU utilization"
    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND metric.type = \"compute.googleapis.com/instance/cpu/utilization\""
      duration        = "60s"
      comparison      = "COMPARISON_GT"
      threshold_value = 0.8
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }

  documentation {
    content   = "CPU 사용률이 80%를 초과했습니다. 리소스 확장이 필요할 수 있습니다."
    mime_type = "text/markdown"
  }

  notification_channels = []
}

# Cloud Logging 싱크 - 로그 저장
resource "google_logging_project_sink" "chatbot_logs" {
  name        = "chatbot-logs-sink"
  description = "Chatbot 서비스 로그 싱크"
  destination = "storage.googleapis.com/${google_storage_bucket.model_artifacts.name}/logs"
  filter      = "resource.type=gce_instance AND resource.labels.instance_id=${google_compute_instance.model_server.instance_id}"
}