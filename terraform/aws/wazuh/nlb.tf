# NLB (Internal)
resource "aws_lb" "aws-wazuh-nlb-01" {
  name               = "aws-wazuh-nlb-01"
  internal           = true
  load_balancer_type = "network"
  subnets = [
    data.aws_subnet.aws-app-sub-2a.id,
    data.aws_subnet.aws-app-sub-2b.id
  ]
  enable_cross_zone_load_balancing = true

  tags = {
    Name  = "aws-wazuh-nlb-01"
    Owner = "st2"
  }
}

# Target Group - 1514 (Agent 통신, wazuh-01 + wazuh-02)
resource "aws_lb_target_group" "aws-wazuh-tg-1514-01" {
  name        = "aws-wazuh-tg-1514-01"
  port        = 1514
  protocol    = "TCP"
  vpc_id      = data.aws_vpc.aws-vpc-01.id
  target_type = "instance"

  health_check {
    protocol            = "TCP"
    port                = 1514
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = { Name = "aws-wazuh-tg-1514-01", Owner = "st2" }
}

# Target Group - 1515 (Agent 등록, wazuh-01 Master만)
resource "aws_lb_target_group" "aws-wazuh-tg-1515-01" {
  name        = "aws-wazuh-tg-1515-01"
  port        = 1515
  protocol    = "TCP"
  vpc_id      = data.aws_vpc.aws-vpc-01.id
  target_type = "instance"

  health_check {
    protocol            = "TCP"
    port                = 1515
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = { Name = "aws-wazuh-tg-1515-01", Owner = "st2" }
}

# Target 등록 - 1514 wazuh-01
resource "aws_lb_target_group_attachment" "aws-wazuh-tga-1514-01" {
  target_group_arn = aws_lb_target_group.aws-wazuh-tg-1514-01.arn
  target_id        = aws_instance.aws-wazuh-01.id
  port             = 1514
}

# Target 등록 - 1514 wazuh-02
resource "aws_lb_target_group_attachment" "aws-wazuh-tga-1514-02" {
  target_group_arn = aws_lb_target_group.aws-wazuh-tg-1514-01.arn
  target_id        = data.terraform_remote_state.wazuh2.outputs.wazuh_instance_id
  port             = 1514
}

# Target 등록 - 1515 wazuh-01만
resource "aws_lb_target_group_attachment" "aws-wazuh-tga-1515-01" {
  target_group_arn = aws_lb_target_group.aws-wazuh-tg-1515-01.arn
  target_id        = aws_instance.aws-wazuh-01.id
  port             = 1515
}

# Listener - 1514
resource "aws_lb_listener" "aws-wazuh-listener-1514-01" {
  load_balancer_arn = aws_lb.aws-wazuh-nlb-01.arn
  port              = 1514
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.aws-wazuh-tg-1514-01.arn
  }

  tags = { Name = "aws-wazuh-listener-1514-01", Owner = "st2" }
}

# Listener - 1515
resource "aws_lb_listener" "aws-wazuh-listener-1515-01" {
  load_balancer_arn = aws_lb.aws-wazuh-nlb-01.arn
  port              = 1515
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.aws-wazuh-tg-1515-01.arn
  }

  tags = { Name = "aws-wazuh-listener-1515-01", Owner = "st2" }
}



resource "aws_lb_target_group" "aws-wazuh-tg-443-01" {
  name        = "aws-wazuh-tg-443-01"
  port        = 443
  protocol    = "TCP"
  vpc_id      = data.aws_vpc.aws-vpc-01.id
  target_type = "instance"

  health_check {
    protocol            = "TCP"
    port                = 443
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 10
  }

  tags = { Name = "aws-wazuh-tg-443-01", Owner = "st2" }
}

# Target 등록 - 443 wazuh-01
resource "aws_lb_target_group_attachment" "aws-wazuh-tga-443-01" {
  target_group_arn = aws_lb_target_group.aws-wazuh-tg-443-01.arn
  target_id        = aws_instance.aws-wazuh-01.id
  port             = 443
}

# Target 등록 - 443 wazuh-02
resource "aws_lb_target_group_attachment" "aws-wazuh-tga-443-02" {
  target_group_arn = aws_lb_target_group.aws-wazuh-tg-443-01.arn
  target_id        = data.terraform_remote_state.wazuh2.outputs.wazuh_instance_id
  port             = 443
}

# Listener - 443
resource "aws_lb_listener" "aws-wazuh-listener-443-01" {
  load_balancer_arn = aws_lb.aws-wazuh-nlb-01.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.aws-wazuh-tg-443-01.arn
  }

  tags = { Name = "aws-wazuh-listener-443-01", Owner = "st2" }
}

# NLB DNS 출력
output "wazuh_nlb_dns" {
  value = aws_lb.aws-wazuh-nlb-01.dns_name
}