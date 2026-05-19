
# ============================================================
# Terraform Code - 실시간 고객 상담 챗봇 AI 서비스
# CSP     : AWS (ap-northeast-2, Seoul)
# Users   : 100,000 / month
# Tags    : project=ai-infra, environment=production
# ============================================================

terraform {
  required_version = ">= 1.3.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-2"
  default_tags {
    tags = {
      project     = "ai-infra"
      environment = "production"
      service     = "chatbot-ai"
    }
  }
}

# ============================================================
# 1. VPC & Networking
# ============================================================
resource "aws_vpc" "chatbot_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = { Name = "chatbot-vpc" }
}

resource "aws_subnet" "public_subnet_a" {
  vpc_id                  = aws_vpc.chatbot_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "ap-northeast-2a"
  map_public_ip_on_launch = true
  tags = { Name = "chatbot-public-subnet-a" }
}

resource "aws_subnet" "public_subnet_c" {
  vpc_id                  = aws_vpc.chatbot_vpc.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "ap-northeast-2c"
  map_public_ip_on_launch = true
  tags = { Name = "chatbot-public-subnet-c" }
}

resource "aws_subnet" "private_subnet_a" {
  vpc_id            = aws_vpc.chatbot_vpc.id
  cidr_block        = "10.0.11.0/24"
  availability_zone = "ap-northeast-2a"
  tags = { Name = "chatbot-private-subnet-a" }
}

resource "aws_subnet" "private_subnet_c" {
  vpc_id            = aws_vpc.chatbot_vpc.id
  cidr_block        = "10.0.12.0/24"
  availability_zone = "ap-northeast-2c"
  tags = { Name = "chatbot-private-subnet-c" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.chatbot_vpc.id
  tags   = { Name = "chatbot-igw" }
}

resource "aws_eip" "nat_eip" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat_gw" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public_subnet_a.id
  tags          = { Name = "chatbot-nat-gw" }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.chatbot_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "chatbot-public-rt" }
}

resource "aws_route_table_association" "public_rta_a" {
  subnet_id      = aws_subnet.public_subnet_a.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "public_rta_c" {
  subnet_id      = aws_subnet.public_subnet_c.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.chatbot_vpc.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_gw.id
  }
  tags = { Name = "chatbot-private-rt" }
}

resource "aws_route_table_association" "private_rta_a" {
  subnet_id      = aws_subnet.private_subnet_a.id
  route_table_id = aws_route_table.private_rt.id
}

resource "aws_route_table_association" "private_rta_c" {
  subnet_id      = aws_subnet.private_subnet_c.id
  route_table_id = aws_route_table.private_rt.id
}

# ============================================================
# 2. Security Groups
# ============================================================
resource "aws_security_group" "alb_sg" {
  name        = "chatbot-alb-sg"
  description = "ALB Security Group"
  vpc_id      = aws_vpc.chatbot_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "chatbot-alb-sg" }
}

resource "aws_security_group" "ecs_sg" {
  name        = "chatbot-ecs-sg"
  description = "ECS Fargate Security Group"
  vpc_id      = aws_vpc.chatbot_vpc.id

  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "chatbot-ecs-sg" }
}

resource "aws_security_group" "gpu_sg" {
  name        = "chatbot-gpu-sg"
  description = "GPU Inference Server Security Group"
  vpc_id      = aws_vpc.chatbot_vpc.id

  ingress {
    from_port       = 5000
    to_port         = 5000
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_sg.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "chatbot-gpu-sg" }
}

resource "aws_security_group" "redis_sg" {
  name        = "chatbot-redis-sg"
  description = "ElastiCache Redis Security Group"
  vpc_id      = aws_vpc.chatbot_vpc.id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_sg.id, aws_security_group.gpu_sg.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "chatbot-redis-sg" }
}

resource "aws_security_group" "rds_sg" {
  name        = "chatbot-rds-sg"
  description = "Aurora Serverless Security Group"
  vpc_id      = aws_vpc.chatbot_vpc.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_sg.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "chatbot-rds-sg" }
}

# ============================================================
# 3. ALB (Application Load Balancer)
# ============================================================
resource "aws_lb" "chatbot_alb" {
  name               = "chatbot-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.public_subnet_a.id, aws_subnet.public_subnet_c.id]
  tags               = { Name = "chatbot-alb" }
}

resource "aws_lb_target_group" "chatbot_tg" {
  name        = "chatbot-tg"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.chatbot_vpc.id
  target_type = "ip"

  health_check {
    path                = "/health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
  tags = { Name = "chatbot-tg" }
}

resource "aws_lb_listener" "chatbot_listener" {
  load_balancer_arn = aws_lb.chatbot_alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.chatbot_tg.arn
  }
}

# ============================================================
# 4. ECS Fargate (API 서빙 레이어)
# ============================================================
resource "aws_ecs_cluster" "chatbot_cluster" {
  name = "chatbot-cluster"
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
  tags = { Name = "chatbot-ecs-cluster" }
}

resource "aws_iam_role" "ecs_task_execution_role" {
  name = "chatbot-ecs-task-execution-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_cloudwatch_log_group" "ecs_log_group" {
  name              = "/ecs/chatbot-api"
  retention_in_days = 14
}

resource "aws_ecs_task_definition" "chatbot_task" {
  family                   = "chatbot-api-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "1024"
  memory                   = "2048"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([{
    name      = "chatbot-api"
    image     = "chatbot-api:latest"
    essential = true
    portMappings = [{
      containerPort = 8080
      hostPort      = 8080
      protocol      = "tcp"
    }]
    environment = [
      { name = "REDIS_HOST",      value = aws_elasticache_cluster.chatbot_redis.cache_nodes[0].address },
      { name = "GPU_ENDPOINT",    value = "http://${aws_spot_instance_request.gpu_inference.private_ip}:5000" },
      { name = "DB_HOST",         value = aws_rds_cluster.chatbot_aurora.endpoint }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = "/ecs/chatbot-api"
        "awslogs-region"        = "ap-northeast-2"
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
  tags = { Name = "chatbot-task-definition" }
}

resource "aws_ecs_service" "chatbot_service" {
  name            = "chatbot-api-service"
  cluster         = aws_ecs_cluster.chatbot_cluster.id
  task_definition = aws_ecs_task_definition.chatbot_task.arn
  desired_count   = 2
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.private_subnet_a.id, aws_subnet.private_subnet_c.id]
    security_groups  = [aws_security_group.ecs_sg.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.chatbot_tg.arn
    container_name   = "chatbot-api"
    container_port   = 8080
  }

  depends_on = [aws_lb_listener.chatbot_listener]
  tags       = { Name = "chatbot-ecs-service" }
}

# ============================================================
# 5. Auto Scaling (ECS Fargate)
# ============================================================
resource "aws_appautoscaling_target" "ecs_scaling_target" {
  max_capacity       = 10
  min_capacity       = 2
  resource_id        = "service/${aws_ecs_cluster.chatbot_cluster.name}/${aws_ecs_service.chatbot_service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "ecs_cpu_scaling" {
  name               = "chatbot-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_scaling_target.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_scaling_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_scaling_target.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 60.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}

# ============================================================
# 6. GPU Inference Server (EC2 g4dn.xlarge Spot Instance)
# ============================================================
data "aws_ami" "deep_learning_ami" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["Deep Learning AMI GPU PyTorch*"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_spot_instance_request" "gpu_inference" {
  ami                    = data.aws_ami.deep_learning_ami.id
  instance_type          = "g4dn.xlarge"
  spot_price             = "0.25"
  wait_for_fulfillment   = true
  subnet_id              = aws_subnet.private_subnet_a.id
  vpc_security_group_ids = [aws_security_group.gpu_sg.id]

  root_block_device {
    volume_size = 50
    volume_type = "gp3"
  }

  user_data = <<-EOF
    #!/bin/bash
    pip install fastapi uvicorn torch transformers redis
    cd /home/ubuntu
    git clone https://github.com/hyungtakChoi/chatbot-workload-icon.git
    cd chatbot-workload-icon
    uvicorn gpt_inference:app --host 0.0.0.0 --port 5000 &
  EOF

  tags = { Name = "chatbot-gpu-inference-spot" }
}

# ============================================================
# 7. ElastiCache Redis (캐시 레이어)
# ============================================================
resource "aws_elasticache_subnet_group" "redis_subnet_group" {
  name       = "chatbot-redis-subnet-group"
  subnet_ids = [aws_subnet.private_subnet_a.id, aws_subnet.private_subnet_c.id]
  tags       = { Name = "chatbot-redis-subnet-group" }
}

resource "aws_elasticache_cluster" "chatbot_redis" {
  cluster_id           = "chatbot-redis"
  engine               = "redis"
  node_type            = "cache.t3.micro"
  num_cache_nodes      = 1
  parameter_group_name = "default.redis7"
  engine_version       = "7.0"
  port                 = 6379
  subnet_group_name    = aws_elasticache_subnet_group.redis_subnet_group.name
  security_group_ids   = [aws_security_group.redis_sg.id]
  tags                 = { Name = "chatbot-redis" }
}

# ============================================================
# 8. Aurora Serverless v2 (대화 이력 DB)
# ============================================================
resource "aws_db_subnet_group" "aurora_subnet_group" {
  name       = "chatbot-aurora-subnet-group"
  subnet_ids = [aws_subnet.private_subnet_a.id, aws_subnet.private_subnet_c.id]
  tags       = { Name = "chatbot-aurora-subnet-group" }
}

resource "aws_rds_cluster" "chatbot_aurora" {
  cluster_identifier      = "chatbot-aurora-cluster"
  engine                  = "aurora-mysql"
  engine_mode             = "provisioned"
  engine_version          = "8.0.mysql_aurora.3.04.0"
  database_name           = "chatbot_db"
  master_username         = "admin"
  master_password         = "ChatbotDB2024!"
  db_subnet_group_name    = aws_db_subnet_group.aurora_subnet_group.name
  vpc_security_group_ids  = [aws_security_group.rds_sg.id]
  skip_final_snapshot     = true
  deletion_protection     = false

  serverlessv2_scaling_configuration {
    min_capacity = 0.5
    max_capacity = 4.0
  }
  tags = { Name = "chatbot-aurora-cluster" }
}

resource "aws_rds_cluster_instance" "chatbot_aurora_instance" {
  identifier         = "chatbot-aurora-instance-1"
  cluster_identifier = aws_rds_cluster.chatbot_aurora.id
  instance_class     = "db.serverless"
  engine             = aws_rds_cluster.chatbot_aurora.engine
  engine_version     = aws_rds_cluster.chatbot_aurora.engine_version
  tags               = { Name = "chatbot-aurora-instance" }
}

# ============================================================
# 9. API Gateway (REST API)
# ============================================================
resource "aws_api_gateway_rest_api" "chatbot_api" {
  name        = "chatbot-api-gateway"
  description = "실시간 고객 상담 챗봇 AI API Gateway"
  endpoint_configuration {
    types = ["REGIONAL"]
  }
  tags = { Name = "chatbot-api-gateway" }
}

resource "aws_api_gateway_resource" "chat_resource" {
  rest_api_id = aws_api_gateway_rest_api.chatbot_api.id
  parent_id   = aws_api_gateway_rest_api.chatbot_api.root_resource_id
  path_part   = "chat"
}

resource "aws_api_gateway_method" "chat_post" {
  rest_api_id   = aws_api_gateway_rest_api.chatbot_api.id
  resource_id   = aws_api_gateway_resource.chat_resource.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "chat_integration" {
  rest_api_id             = aws_api_gateway_rest_api.chatbot_api.id
  resource_id             = aws_api_gateway_resource.chat_resource.id
  http_method             = aws_api_gateway_method.chat_post.http_method
  integration_http_method = "POST"
  type                    = "HTTP_PROXY"
  uri                     = "http://${aws_lb.chatbot_alb.dns_name}/chat"
}

resource "aws_api_gateway_deployment" "chatbot_deployment" {
  rest_api_id = aws_api_gateway_rest_api.chatbot_api.id
  stage_name  = "prod"
  depends_on  = [aws_api_gateway_integration.chat_integration]
}

# ============================================================
# 10. CloudFront CDN
# ============================================================
resource "aws_cloudfront_distribution" "chatbot_cdn" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "Chatbot AI CDN"
  default_root_object = "index.html"

  origin {
    domain_name = aws_api_gateway_rest_api.chatbot_api.id != "" ? "${aws_api_gateway_rest_api.chatbot_api.id}.execute-api.ap-northeast-2.amazonaws.com" : aws_lb.chatbot_alb.dns_name
    origin_id   = "chatbot-api-origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    allowed_methods        = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods         = ["GET", "HEAD"]
    target_origin_id       = "chatbot-api-origin"
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = true
      cookies { forward = "none" }
    }

    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 86400
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = { Name = "chatbot-cloudfront" }
}

# ============================================================
# 11. CloudWatch Monitoring & Alarms
# ============================================================
resource "aws_cloudwatch_metric_alarm" "ecs_cpu_alarm" {
  alarm_name          = "chatbot-ecs-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "ECS CPU 사용률 80% 초과 알림"
  dimensions = {
    ClusterName = aws_ecs_cluster.chatbot_cluster.name
    ServiceName = aws_ecs_service.chatbot_service.name
  }
}

resource "aws_cloudwatch_metric_alarm" "redis_memory_alarm" {
  alarm_name          = "chatbot-redis-memory-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "DatabaseMemoryUsagePercentage"
  namespace           = "AWS/ElastiCache"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "Redis 메모리 사용률 80% 초과 알림"
  dimensions = {
    CacheClusterId = aws_elasticache_cluster.chatbot_redis.id
  }
}

# ============================================================
# 12. Outputs
# ============================================================
output "cloudfront_domain" {
  description = "CloudFront 배포 도메인"
  value       = aws_cloudfront_distribution.chatbot_cdn.domain_name
}

output "alb_dns_name" {
  description = "ALB DNS 이름"
  value       = aws_lb.chatbot_alb.dns_name
}

output "api_gateway_url" {
  description = "API Gateway 엔드포인트"
  value       = "https://${aws_api_gateway_rest_api.chatbot_api.id}.execute-api.ap-northeast-2.amazonaws.com/prod/chat"
}

output "redis_endpoint" {
  description = "ElastiCache Redis 엔드포인트"
  value       = aws_elasticache_cluster.chatbot_redis.cache_nodes[0].address
}

output "aurora_endpoint" {
  description = "Aurora Serverless v2 엔드포인트"
  value       = aws_rds_cluster.chatbot_aurora.endpoint
}

output "gpu_instance_private_ip" {
  description = "GPU 추론 서버 Private IP"
  value       = aws_spot_instance_request.gpu_inference.private_ip
}
