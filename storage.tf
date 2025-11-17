# ------------------------------------------------------------------------------
# 1. S3 Bucket for Splunk SmartStore
# ------------------------------------------------------------------------------
# This bucket will store our Splunk warm/cold data.
# We make it private and enable versioning as a best practice.

resource "aws_s3_bucket" "smartstore_bucket" {
  # Bucket names must be globally unique. Using a random suffix helps.
  bucket = "splunk-lab-smartstore-${random_id.bucket_suffix.hex}"

  # 'private' means no public access is allowed by default.
  # This is what we want; access will be via the IAM role only.
  acl = "private"

  # Enabling versioning is a good safety net against accidental deletions.
  versioning {
    enabled = true
  }

  # Server-side encryption adds a layer of data-at-rest protection.
  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }

  tags = {
    Name = "Splunk-Lab-SmartStore"
  }
}

# Helper resource to generate a random string for the bucket name
resource "random_id" "bucket_suffix" {
  byte_length = 8
}

# ------------------------------------------------------------------------------
# 2. Secrets Manager for Splunk Admin Password
# ------------------------------------------------------------------------------
# We store the Splunk admin password here instead of in our code (IaC).
# The EC2 instances will fetch this secret on boot using their IAM role.

resource "aws_secretsmanager_secret" "splunk_admin_password" {
  name        = "splunk-lab-admin-password"
  description = "Splunk admin password for the lab environment"

  # We generate a random password automatically.
  # You could also set 'recovery_window_in_days = 0' to force delete
  # but we'll keep the default (30) for safety in a lab.
}

# This resource *stores* the actual password value (the "secret string")
# inside the "secret" we created above.
resource "aws_secretsmanager_secret_version" "splunk_admin_password_version" {
  secret_id = aws_secretsmanager_secret.splunk_admin_password.id

  # Generates a strong, random password.
  # We exclude " ' / \ @ to avoid issues in our boot scripts.
  secret_string = random_password.password.result
}

# Helper resource to generate the random password string
resource "random_password" "password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?" # List of special chars to use
}
