# ------------------------------------------------------------------------------
# 1. Application Load Balancer (ALB)
# ------------------------------------------------------------------------------
# This is the "front door" for all our web UIs. It lives in the
# public subnet so it's reachable from the internet, and it will
# forward traffic to our private instances.

resource "aws_lb" "splunk_alb" {
  name               = "splunk-lab-alb"
  internal           = false # false = internet-facing
  load_balancer_type = "application"
  security_groups    = [aws_security_group.lb_sg.id] # The SG we made for it
  subnets            = [aws_subnet.public_subnet.id] # Must be in public subnets

  # Enable access logging for our LB. This is always a good idea.
  access_logs {
    bucket  = aws_s3_bucket.smartstore_bucket.id
    prefix  = "alb-logs"
    enabled = true
  }

  tags = {
    Name = "Splunk-Lab-ALB"
  }
}

# ------------------------------------------------------------------------------
# 2. Target Groups (TGs)
# ------------------------------------------------------------------------------
# A Target Group tells the ALB *where* to send traffic. We need one
# for each service we want to expose (SH and DS).

resource "aws_lb_target_group" "sh_tg" {
  name        = "splunk-lab-sh-tg"
  port        = 8000 # The port on the instance (Splunk Web)
  protocol    = "HTTP"
  vpc_id      = aws_vpc.splunk_lab_vpc.id
  target_type = "instance" # We are routing to an EC2 instance

  # Health check: The LB will ping this path to make sure the
  # instance is healthy (i.e., Splunk Web is running).
  health_check {
    path                = "/en-US/account/login" # A standard Splunk page
    protocol            = "HTTP"
    matcher             = "200" # Expect an HTTP 200 OK
    interval            = 30
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }
}

resource "aws_lb_target_group" "ds_tg" {
  name        = "splunk-lab-ds-tg"
  port        = 8000 # Also Splunk Web port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.splunk_lab_vpc.id
  target_type = "instance"

  health_check {
    path                = "/en-US/account/login"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 3
    unhealthy_threshold = 3
  }
}

# ------------------------------------------------------------------------------
# 3. Target Group Attachments
# ------------------------------------------------------------------------------
# Now we link our EC2 instances to the Target Groups.

resource "aws_lb_target_group_attachment" "sh_attach" {
  target_group_arn = aws_lb_target_group.sh_tg.arn
  target_id        = aws_instance.search_head.id
  port             = 8000
}

resource "aws_lb_target_group_attachment" "ds_attach" {
  target_group_arn = aws_lb_target_group.ds_tg.arn
  target_id        = aws_instance.deployment_server.id
  port             = 8000
}

# ------------------------------------------------------------------------------
# 4. ALB Listeners
# ------------------------------------------------------------------------------
# A listener checks for incoming connections. We'll set up an HTTP
# listener for our lab. (In production, you'd use HTTPS on port 443).

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.splunk_alb.arn
  port              = 80
  protocol          = "HTTP"

  # This is the "default" action. If no rules match, it will
  # just send a fixed response. This is better than an error.
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "No service configured for this path."
      status_code  = "404"
    }
  }
}

# ------------------------------------------------------------------------------
# 5. Listener Rules
# ------------------------------------------------------------------------------
# This is the "smart" part of the ALB. We create rules to send
# traffic to the right Target Group based on the DNS name (host).

resource "aws_lb_listener_rule" "sh_rule" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.sh_tg.arn
  }

  # This condition says: "If the user tries to access 'sh.splunk.lab'..."
  condition {
    host_header {
      values = [var.sh_dns_name] # e.g., "sh.splunk.lab"
    }
  }
}

resource "aws_lb_listener_rule" "ds_rule" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 101

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ds_tg.arn
  }

  # This condition says: "If the user tries to access 'ds.splunk.lab'..."
  condition {
    host_header {
      values = [var.ds_dns_name] # e.g., "ds.splunk.lab"
    }
  }
}