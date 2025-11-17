# ------------------------------------------------------------------------------
# 1. IAM Roles & Policies (The "Keys")
# ------------------------------------------------------------------------------

# --- Role 1: Splunk Indexer (for SmartStore S3 Access) ---

# First, we define the "Assume Role Policy". This is a trust document
# that says "We trust the AWS EC2 service to use this role."
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# The policy that grants S3 permissions.
# We use a data source to build the policy, which is cleaner than JSON in a string.
# We reference the S3 bucket ARN (Amazon Resource Name) which we will create in storage.tf.
data "aws_iam_policy_document" "splunk_s3_policy" {
  statement {
    actions = [
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.smartstore_bucket.arn # Reference to the bucket
    ]
  }
  statement {
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject"
    ]
    resources = [
      "${aws_s3_bucket.smartstore_bucket.arn}/*" # Note the /* for objects
    ]
  }
}

# Now, we create the actual policy resource from the document above.
resource "aws_iam_policy" "splunk_s3_policy" {
  name   = "splunk-lab-s3-smartstore-policy"
  policy = data.aws_iam_policy_document.splunk_s3_policy.json
}

# The IAM Role for the Indexer
resource "aws_iam_role" "splunk_indexer_role" {
  name               = "splunk-lab-indexer-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

# We attach the S3 policy to the Indexer role.
resource "aws_iam_role_policy_attachment" "indexer_s3_attach" {
  role       = aws_iam_role.splunk_indexer_role.name
  policy_arn = aws_iam_policy.splunk_s3_policy.arn
}

# Finally, the Instance Profile "wraps" the role so EC2 can wear it.
resource "aws_iam_instance_profile" "splunk_indexer_profile" {
  name = "splunk-lab-indexer-profile"
  role = aws_iam_role.splunk_indexer_role.name
}


# --- Role 2: Common Splunk Role (for Secrets Manager) ---

# Policy to allow fetching our one specific secret
data "aws_iam_policy_document" "splunk_secrets_policy" {
  statement {
    actions = [
      "secretsmanager:GetSecretValue",
    ]
    resources = [
      aws_secretsmanager_secret.splunk_admin_password.arn # Ref to secret
    ]
  }
}

resource "aws_iam_policy" "splunk_secrets_policy" {
  name   = "splunk-lab-secrets-policy"
  policy = data.aws_iam_policy_document.splunk_secrets_policy.json
}

# The common IAM Role
resource "aws_iam_role" "splunk_common_role" {
  name               = "splunk-lab-common-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

# Attach the secrets policy to this role
resource "aws_iam_role_policy_attachment" "common_secrets_attach" {
  role       = aws_iam_role.splunk_common_role.name
  policy_arn = aws_iam_policy.splunk_secrets_policy.arn
}

# The Instance Profile for all other instances (SH, DS, UFs)
resource "aws_iam_instance_profile" "splunk_common_profile" {
  name = "splunk-lab-common-profile"
  role = aws_iam_role.splunk_common_role.name
}

# ------------------------------------------------------------------------------
# 2. Security Groups (The "Locks")
# ------------------------------------------------------------------------------
# SGs act as a stateful firewall at the instance level.

# --- SG 1: Load Balancer ---
# This faces the internet and allows web traffic in.
resource "aws_security_group" "lb_sg" {
  name        = "splunk-lab-lb-sg"
  description = "Allow HTTP/S traffic from the internet"
  vpc_id      = aws_vpc.splunk_lab_vpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Allow HTTP from anywhere
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Allow HTTPS from anywhere
  }

  # Egress (outbound) is allowed by default, which is fine.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- SG 2: Splunk Web UI (for SH & DS) ---
# Allows Splunk Web (8000) and SSH (22)
resource "aws_security_group" "splunk_web_sg" {
  name        = "splunk-lab-web-sg"
  description = "For Splunk Search Head and Deployment Server"
  vpc_id      = aws_vpc.splunk_lab_vpc.id

  # Ingress rule 1: Allow Splunk Web traffic ONLY from our Load Balancer
  ingress {
    from_port       = 8000 # Splunk Web Port
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.lb_sg.id] # Source is the LB SG!
  }

  # Ingress rule 2: Allow SSH ONLY from our trusted IP
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${var.my_ip}/32"] # e.g., "80.1.2.3/32"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- SG 3: Splunk Indexer ---
resource "aws_security_group" "splunk_indexer_sg" {
  name        = "splunk-lab-indexer-sg"
  description = "For Splunk Indexer"
  vpc_id      = aws_vpc.splunk_lab_vpc.id

  # Ingress rule 1: Allow S2S forwarding (9997) ONLY from UFs
  ingress {
    from_port       = 9997
    to_port         = 9997
    protocol        = "tcp"
    security_groups = [aws_security_group.splunk_uf_sg.id] # See below
  }

  # Ingress rule 2: Allow management (8089) from SH and DS
  ingress {
    from_port       = 8089
    to_port         = 8089
    protocol        = "tcp"
    security_groups = [aws_security_group.splunk_web_sg.id] # SH/DS live here
  }

  # Ingress rule 3: Allow SSH ONLY from our trusted IP
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${var.my_ip}/32"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- SG 4: Splunk Universal Forwarders ---
resource "aws_security_group" "splunk_uf_sg" {
  name        = "splunk-lab-uf-sg"
  description = "For Splunk Universal Forwarders"
  vpc_id      = aws_vpc.splunk_lab_vpc.id

  # Ingress rule 1: Allow SSH ONLY from our trusted IP
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${var.my_ip}/32"]
  }

  # Note: No other ingress is needed. UFs only make outbound connections.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}