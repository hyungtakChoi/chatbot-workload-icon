provider "aws" {
  region = "ap-northeast-2" # Seoul region
}

# VPC configuration
resource "aws_vpc" "chatbot_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  
  tags = {
    Name        = "chatbot-vpc"
    project     = "ai-infra"
    environment = "production"
  }
}

# Public subnet
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

# Private subnet
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

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.chatbot_vpc.id
  
  tags = {
    Name        = "chatbot-igw"
    project     = "ai-infra"
    environment = "production"
  }
}

# Route table for public subnet
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

# Route table association
resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

# Security group for EC2 instance
resource "aws_security_group" "chatbot_sg" {
  name        = "chatbot-security-group"
  description = "Security group for chatbot service"
  vpc_id      = aws_vpc.chatbot_vpc.id
  
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "SSH"
  }
  
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTP"
  }
  
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "HTTPS"
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

# IAM role for EC2 instance
resource "aws_iam_role" "chatbot_role" {
  name = "chatbot-role"
  
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
  
  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# IAM instance profile
resource "aws_iam_instance_profile" "chatbot_profile" {
  name = "chatbot-profile"
  role = aws_iam_role.chatbot_role.name
}

# Attaching AmazonS3ReadOnlyAccess policy to the role
resource "aws_iam_role_policy_attachment" "s3_read_attach" {
  role       = aws_iam_role.chatbot_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

# EC2 instance with GPU (g5.xlarge)
resource "aws_instance" "chatbot_server" {
  ami                    = "ami-0c9c942bd7bf36742" # Amazon Linux 2 with NVIDIA drivers, Deep Learning AMI
  instance_type          = "g5.xlarge"  # g5.xlarge with A10G GPU
  key_name               = "chatbot-key"
  subnet_id              = aws_subnet.public_subnet.id
  vpc_security_group_ids = [aws_security_group.chatbot_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.chatbot_profile.name
  
  root_block_device {
    volume_size = 100
    volume_type = "gp3"
  }
  
  tags = {
    Name        = "chatbot-server"
    project     = "ai-infra"
    environment = "production"
  }
}

# Elastic IP for the EC2 instance
resource "aws_eip" "chatbot_eip" {
  instance = aws_instance.chatbot_server.id
  domain   = "vpc"
  
  tags = {
    Name        = "chatbot-eip"
    project     = "ai-infra"
    environment = "production"
  }
}

# S3 bucket for model storage
resource "aws_s3_bucket" "model_bucket" {
  bucket = "chatbot-model-storage-2026"
  
  tags = {
    Name        = "chatbot-model-storage"
    project     = "ai-infra"
    environment = "production"
  }
}

# S3 bucket ACL
resource "aws_s3_bucket_ownership_controls" "model_bucket_ownership" {
  bucket = aws_s3_bucket.model_bucket.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "model_bucket_acl" {
  depends_on = [aws_s3_bucket_ownership_controls.model_bucket_ownership]
  bucket = aws_s3_bucket.model_bucket.id
  acl    = "private"
}

# CloudWatch Log Group for the chatbot application
resource "aws_cloudwatch_log_group" "chatbot_logs" {
  name              = "/aws/chatbot-service"
  retention_in_days = 14
  
  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# Application Load Balancer
resource "aws_lb" "chatbot_alb" {
  name               = "chatbot-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.chatbot_sg.id]
  subnets            = [aws_subnet.public_subnet.id]
  
  tags = {
    Name        = "chatbot-alb"
    project     = "ai-infra"
    environment = "production"
  }
}

# ALB Target Group
resource "aws_lb_target_group" "chatbot_tg" {
  name     = "chatbot-target-group"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.chatbot_vpc.id
  
  health_check {
    path                = "/health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }
  
  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

# ALB Target Group Attachment
resource "aws_lb_target_group_attachment" "chatbot_tg_attachment" {
  target_group_arn = aws_lb_target_group.chatbot_tg.arn
  target_id        = aws_instance.chatbot_server.id
  port             = 80
}

# ALB Listener
resource "aws_lb_listener" "chatbot_listener" {
  load_balancer_arn = aws_lb.chatbot_alb.arn
  port              = 80
  protocol          = "HTTP"
  
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.chatbot_tg.arn
  }
}

# Route 53 Record (Assuming a hosted zone exists)
resource "aws_route53_record" "chatbot_dns" {
  zone_id = "Z1234567890ABC" # Replace with your hosted zone ID
  name    = "chatbot.example.com" # Replace with your domain
  type    = "A"
  
  alias {
    name                   = aws_lb.chatbot_alb.dns_name
    zone_id                = aws_lb.chatbot_alb.zone_id
    evaluate_target_health = true
  }
}

# Auto Scaling Group
resource "aws_launch_template" "chatbot_lt" {
  name_prefix   = "chatbot-lt"
  image_id      = "ami-0c9c942bd7bf36742" # Amazon Linux 2 with NVIDIA drivers
  instance_type = "g5.xlarge"
  key_name      = "chatbot-key"
  
  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.chatbot_sg.id]
  }
  
  iam_instance_profile {
    name = aws_iam_instance_profile.chatbot_profile.name
  }
  
  tag_specifications {
    resource_type = "instance"
    
    tags = {
      Name        = "chatbot-asg-instance"
      project     = "ai-infra"
      environment = "production"
    }
  }
  
  user_data = base64encode(<<-EOF
    #!/bin/bash
    yum update -y
    yum install -y git docker
    systemctl start docker
    systemctl enable docker
    
    # Clone the repository
    git clone https://github.com/hyungtakChoi/chatbot-workload-icon.git /opt/chatbot
    
    # Download model files from S3
    aws s3 sync s3://chatbot-model-storage-2026/models /opt/chatbot/models
    
    # Start the application
    cd /opt/chatbot
    nohup python3 gpt_inference.py > /var/log/chatbot.log 2>&1 &
  EOF
  )
}

resource "aws_autoscaling_group" "chatbot_asg" {
  desired_capacity    = 1
  max_size            = 3
  min_size            = 1
  vpc_zone_identifier = [aws_subnet.public_subnet.id]
  
  launch_template {
    id      = aws_launch_template.chatbot_lt.id
    version = "$Latest"
  }
  
  target_group_arns = [aws_lb_target_group.chatbot_tg.arn]
  
  tag {
    key                 = "project"
    value               = "ai-infra"
    propagate_at_launch = true
  }
  
  tag {
    key                 = "environment"
    value               = "production"
    propagate_at_launch = true
  }
}

# CloudWatch Alarms for scaling policies
resource "aws_cloudwatch_metric_alarm" "high_cpu" {
  alarm_name          = "chatbot-high-cpu-alarm"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 80
  
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.chatbot_asg.name
  }
  
  alarm_description = "This alarm triggers when CPU usage is high"
  alarm_actions     = [aws_autoscaling_policy.scale_up.arn]
  
  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_autoscaling_policy" "scale_up" {
  name                   = "chatbot-scale-up"
  scaling_adjustment     = 1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.chatbot_asg.name
}

resource "aws_cloudwatch_metric_alarm" "low_cpu" {
  alarm_name          = "chatbot-low-cpu-alarm"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 120
  statistic           = "Average"
  threshold           = 20
  
  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.chatbot_asg.name
  }
  
  alarm_description = "This alarm triggers when CPU usage is low"
  alarm_actions     = [aws_autoscaling_policy.scale_down.arn]
  
  tags = {
    project     = "ai-infra"
    environment = "production"
  }
}

resource "aws_autoscaling_policy" "scale_down" {
  name                   = "chatbot-scale-down"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.chatbot_asg.name
}

# Output values
output "instance_ip" {
  value = aws_eip.chatbot_eip.public_ip
}

output "alb_dns_name" {
  value = aws_lb.chatbot_alb.dns_name
}

output "model_bucket_name" {
  value = aws_s3_bucket.model_bucket.bucket
}