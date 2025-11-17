# ------------------------------------------------------------------------------
# 1. Data Source: Find our existing Hosted Zone
# ------------------------------------------------------------------------------
# We find our domain's "Hosted Zone" so Terraform can add records to it.
data "aws_route53_zone" "lab_domain" {
  name = var.hosted_zone_name # e.g., "splunk.lab"
}

# ------------------------------------------------------------------------------
# 2. DNS Records for UI (pointing to the ALB)
# ------------------------------------------------------------------------------
# We create "A" records for our Search Head and DS.
# These use the special "alias" block to point directly to the ALB.
# This is better than a CNAME because it's faster and more resilient.

resource "aws_route53_record" "search_head_dns" {
  zone_id = data.aws_route53_zone.lab_domain.zone_id
  name    = var.sh_dns_name # e.g., "sh.splunk.lab"
  type    = "A"

  alias {
    name                   = aws_lb.splunk_alb.dns_name
    zone_id                = aws_lb.splunk_alb.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "deployment_server_dns" {
  zone_id = data.aws_route53_zone.lab_domain.zone_id
  name    = var.ds_dns_name # e.g., "ds.splunk.lab"
  type    = "A"

  alias {
    name                   = aws_lb.splunk_alb.dns_name
    zone_id                = aws_lb.splunk_alb.zone_id
    evaluate_target_health = true
  }
}

# ------------------------------------------------------------------------------
# 3. DNS Records for Internal Services (pointing to IPs)
# ------------------------------------------------------------------------------
# Our UFs need to find the Indexer. We create an "A" record
# that points directly to the *private* IP of our indexer instance.
# This is a "private DNS" record.

resource "aws_route53_record" "indexer_dns" {
  zone_id = data.aws_route53_zone.lab_domain.zone_id
  name    = var.indexer_dns_name # e.g., "indexer.splunk.lab"
  type    = "A"
  ttl     = 300
  
  # This points directly to the private IP of the EC2 instance
  records = [aws_instance.indexer.private_ip]
}