provider "google" {
  project = "chatbot-ai-project"
  region  = "asia-northeast3"  # 서울 리전
}

# GCP 프로젝트 리소스
resource "google_project" "chatbot_project" {
  name       = "Chatbot AI Service"
  project_id = "chatbot-ai-project"
  billing_account = "BILLING_ACCOUNT_ID" # 실제 사용 시 청구 계정 ID로 교체 필요
}

# VPC 네트워크 생성
resource "google_compute_network" "vpc_network" {
  name                    = "chatbot-vpc-network"
  auto_create_subnetworks = false
  
  depends_on = [google_project.chatbot_project]
}

# 서브넷 생성
resource "google_compute_subnetwork" "subnet" {
  name          = "chatbot-subnet"
  ip_cidr_range = "10.0.0.0/24"
  region        = "asia-northeast3"
  network       = google_compute_network.vpc_network.id
  
  depends_on = [google_compute_network.vpc_network]
}

# 방화벽 규칙 생성 - SSH 및 웹 접속 허용
resource "google_compute_firewall" "allow_ssh_web" {
  name    = "allow-ssh-web"
  network = google_compute_network.vpc_network.name

  allow {
    protocol = "tcp"
    ports    = ["22", "80", "443"]
  }

  source_ranges = ["0.0.0.0/0"]
  
  depends_on = [google_compute_network.vpc_network]
}

# 서비스 계정 생성
resource "google_service_account" "chatbot_service_account" {
  account_id   = "chatbot-service"
  display_name = "Chatbot Service Account"
  
  depends_on = [google_project.chatbot_project]
}

# 서비스 계정에 권한 부여
resource "google_project_iam_binding" "project_binding" {
  project = google_project.chatbot_project.project_id
  role    = "roles/editor"

  members = [
    "serviceAccount:${google_service_account.chatbot_service_account.email}",
  ]
  
  depends_on = [google_service_account.chatbot_service_account]
}

# Compute Engine VM 인스턴스 생성 (GPU 활용)
resource "google_compute_instance" "chatbot_instance" {
  name         = "chatbot-gpu-instance"
  machine_type = "g2-standard-4"  # 4 vCPUs, 16GB RAM, 1 L4 GPU
  zone         = "asia-northeast3-a"

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-11"
      size  = 50  # 50GB boot disk
    }
  }

  network_interface {
    network    = google_compute_network.vpc_network.name
    subnetwork = google_compute_subnetwork.subnet.name
    access_config {
      // Ephemeral public IP
    }
  }

  scheduling {
    on_host_maintenance = "TERMINATE" # Required for GPU instances
    automatic_restart   = true
    preemptible         = false
  }

  guest_accelerator {
    type  = "nvidia-l4"
    count = 1
  }

  service_account {
    email  = google_service_account.chatbot_service_account.email
    scopes = ["cloud-platform"]
  }

  metadata_startup_script = <<-EOT
    #!/bin/bash
    apt-get update
    apt-get install -y python3-pip git
    pip3 install torch torchvision torchaudio transformers
    mkdir -p /opt/chatbot
    cd /opt/chatbot
    git clone https://github.com/hyungtakChoi/chatbot-workload-icon.git .
    # Install NVIDIA drivers and CUDA
    curl -O https://developer.download.nvidia.com/compute/cuda/repos/debian11/x86_64/cuda-keyring_1.0-1_all.deb
    dpkg -i cuda-keyring_1.0-1_all.deb
    apt-get update
    apt-get -y install cuda-drivers
  EOT

  depends_on = [
    google_compute_subnetwork.subnet,
    google_service_account.chatbot_service_account
  ]
  
  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# Cloud Storage 버킷 - 모델 저장용
resource "google_storage_bucket" "model_bucket" {
  name          = "chatbot-ai-models-bucket"
  location      = "ASIA-NORTHEAST3"
  storage_class = "STANDARD"
  force_destroy = false
  
  uniform_bucket_level_access = true
  
  depends_on = [google_project.chatbot_project]
  
  labels = {
    project     = "ai-infra"
    environment = "production"
  }
}

# Cloud Load Balancer 생성
resource "google_compute_global_address" "default" {
  name = "chatbot-lb-ip"
  
  depends_on = [google_project.chatbot_project]
}

resource "google_compute_health_check" "default" {
  name = "chatbot-healthcheck"
  
  timeout_sec         = 5
  check_interval_sec  = 10
  healthy_threshold   = 2
  unhealthy_threshold = 3
  
  http_health_check {
    port         = 80
    request_path = "/health"
  }
  
  depends_on = [google_project.chatbot_project]
}

resource "google_compute_backend_service" "default" {
  name          = "chatbot-backend"
  health_checks = [google_compute_health_check.default.id]
  
  backend {
    group = google_compute_instance_group.webservers.id
  }
  
  depends_on = [
    google_compute_instance_group.webservers,
    google_compute_health_check.default
  ]
}

resource "google_compute_instance_group" "webservers" {
  name        = "chatbot-instance-group"
  zone        = "asia-northeast3-a"
  
  instances = [
    google_compute_instance.chatbot_instance.id
  ]
  
  named_port {
    name = "http"
    port = 80
  }
  
  depends_on = [google_compute_instance.chatbot_instance]
}

resource "google_compute_url_map" "default" {
  name            = "chatbot-url-map"
  default_service = google_compute_backend_service.default.id
  
  depends_on = [google_compute_backend_service.default]
}

resource "google_compute_target_http_proxy" "default" {
  name    = "chatbot-http-proxy"
  url_map = google_compute_url_map.default.id
  
  depends_on = [google_compute_url_map.default]
}

resource "google_compute_global_forwarding_rule" "default" {
  name       = "chatbot-forwarding-rule"
  target     = google_compute_target_http_proxy.default.id
  port_range = "80"
  ip_address = google_compute_global_address.default.address
  
  depends_on = [
    google_compute_target_http_proxy.default,
    google_compute_global_address.default
  ]
}

# Cloud Monitoring 설정
resource "google_monitoring_alert_policy" "cpu_usage" {
  display_name = "High CPU Usage Alert"
  combiner     = "OR"
  
  conditions {
    display_name = "VM Instance - CPU utilization"
    condition_threshold {
      filter          = "resource.type = \"gce_instance\" AND resource.labels.instance_id = \"${google_compute_instance.chatbot_instance.instance_id}\" AND metric.type = \"compute.googleapis.com/instance/cpu/utilization\""
      duration        = "60s"
      comparison      = "COMPARISON_GT"
      threshold_value = 0.8
      
      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MEAN"
      }
    }
  }
  
  notification_channels = []  # 실제 사용 시 알림 채널 ID 설정
  
  depends_on = [google_compute_instance.chatbot_instance]
}