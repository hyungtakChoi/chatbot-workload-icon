provider "aws" {
  region = "ap-northeast-2"  # 서울 리전
}

# VPC 생성
resource "aws_vpc" "chatbot_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "chatbot-vpc"
    project     = "ai-infra"
    environment = "production"
  }
}

# 퍼블릭 서브넷 생성
resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.chatbot_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-northeast-2a"
  map_public_ip_on_launch = true

  tags = {
    Name        = "chatbot-public-subnet"
    project     = "ai-infra"
    environment = "production"
  }
}

# 프라이빗 서브넷 생성
resource "aws_subnet" "private_subnet" {
  vpc_id            = aws_vpc.chatbot_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "ap-northeast-2a"

  tags = {
    Name        = "chatbot-private-subnet"
    project     = "ai-infra"
    environment = "production"
  }
}

# 인터넷 게이트웨이 생성
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.chatbot_vpc.id

  tags = {
    Name        = "chatbot-igw"
    project     = "ai-infra"
    environment = "production"
  }
}

# 퍼블릭 라우팅 테이블 생성
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.chatbot_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name        = "chatbot-public-rt"
    project     = "ai-infra"
    environment = "production"
  }
}

# 퍼블릭 서브넷에 라우팅 테이블 연결
resource "aws_route_table_association" "public_rta" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

# 보안 그룹 생성
resource "aws_security_group" "chatbot_sg" {
  name        = "chatbot-security-group"
  description = "Allow inbound traffic for chatbot"
  vpc_id      = aws_vpc.chatbot_vpc.id

  # HTTPS 트래픽 허용
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP 트래픽 허용 (필요시)
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SSH 접근 허용
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "chatbot-sg"
    project     = "ai-infra"
    environment = "production"
  }
}

# IAM 역할 생성
resource "aws_iam_role" "ec2_role" {
  name = "chatbot-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      },
    ]
  })

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# EC2에 S3 접근 권한 부여
resource "aws_iam_policy_attachment" "s3_access" {
  name       = "s3-access-attachment"
  roles      = [aws_iam_role.ec2_role.name]
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

# IAM 인스턴스 프로파일 생성
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "chatbot-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# EC2 인스턴스 (GPU 인스턴스) 생성
resource "aws_instance" "chatbot_server" {
  ami                  = "ami-09eb4311cbaecf89d" # Amazon Linux 2 GPU AMI (ap-northeast-2)
  instance_type        = "g5.xlarge"             # GPU 인스턴스
  key_name             = "chatbot-key"           # SSH 키 페어 이름 (사전에 생성 필요)
  subnet_id            = aws_subnet.public_subnet.id
  security_groups      = [aws_security_group.chatbot_sg.id]
  iam_instance_profile = aws_iam_instance_profile.ec2_profile.name

  root_block_device {
    volume_size = 100 # GB
    volume_type = "gp3"
  }

  user_data = <<-EOF
              #!/bin/bash
              yum update -y
              yum install -y docker
              systemctl start docker
              systemctl enable docker
              usermod -aG docker ec2-user
              # NVIDIA 드라이버 및 CUDA 설치
              distribution=$(. /etc/os-release;echo $ID$VERSION_ID)
              curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | sudo apt-key add -
              curl -s -L https://nvidia.github.io/nvidia-docker/$distribution/nvidia-docker.list | sudo tee /etc/apt/sources.list.d/nvidia-docker.list
              apt-get update && apt-get install -y nvidia-container-toolkit
              systemctl restart docker
              EOF

  tags = {
    Name        = "chatbot-server"
    project     = "ai-infra"
    environment = "production"
  }
}

# 탄력적 IP 생성
resource "aws_eip" "chatbot_eip" {
  instance = aws_instance.chatbot_server.id
  vpc      = true

  tags = {
    Name        = "chatbot-eip"
    project     = "ai-infra"
    environment = "production"
  }
}

# S3 버킷 생성 (모델 저장소)
resource "aws_s3_bucket" "model_bucket" {
  bucket = "chatbot-model-storage-2026"

  tags = {
    Name        = "chatbot-model-storage"
    project     = "ai-infra"
    environment = "production"
  }
}

# S3 버킷 암호화 설정
resource "aws_s3_bucket_server_side_encryption_configuration" "model_bucket_encryption" {
  bucket = aws_s3_bucket.model_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# CloudWatch 대시보드 생성
resource "aws_cloudwatch_dashboard" "chatbot_dashboard" {
  dashboard_name = "chatbot-monitoring-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.chatbot_server.id]
          ]
          period = 300
          stat   = "Average"
          region = "ap-northeast-2"
          title  = "CPU 사용률"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          metrics = [
            ["AWS/EC2", "NetworkIn", "InstanceId", aws_instance.chatbot_server.id],
            ["AWS/EC2", "NetworkOut", "InstanceId", aws_instance.chatbot_server.id]
          ]
          period = 300
          stat   = "Average"
          region = "ap-northeast-2"
          title  = "네트워크 트래픽"
        }
      }
    ]
  })
}

# CloudWatch 알람 생성
resource "aws_cloudwatch_metric_alarm" "high_cpu_alarm" {
  alarm_name          = "chatbot-high-cpu-usage"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "CPU 사용률이 80% 이상인 경우 알림"
  alarm_actions       = []  # SNS ARN을 추가하여 알림 설정 가능

  dimensions = {
    InstanceId = aws_instance.chatbot_server.id
  }

  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# 출력 값
output "chatbot_public_ip" {
  description = "Chatbot 서버의 Public IP"
  value       = aws_eip.chatbot_eip.public_ip
}

output "model_bucket_name" {
  description = "모델 저장 S3 버킷 이름"
  value       = aws_s3_bucket.model_bucket.bucket
}