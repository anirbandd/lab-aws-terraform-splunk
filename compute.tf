# ------------------------------------------------------------------------------
# 1. Data Source: Find the latest Amazon Linux 2 AMI
# ------------------------------------------------------------------------------
# We ask Terraform to find the latest "golden image" (AMI)
# for Amazon Linux 2. We'll use this as the base OS for all servers.
data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

# ------------------------------------------------------------------------------
# 2. Local Variables: Our Boot-up (user_data) Scripts
# ------------------------------------------------------------------------------
# We define our bash scripts here. This is much cleaner than
# putting them inside the launch template resources.

locals {
  # This is the common "base" script for all Splunk Enterprise instances
  # (SH, IDX, DS). It fetches the password, installs Splunk, and enables it.
  splunk_enterprise_install_script = <<-EOF
    #!/bin/bash
    # This magic line logs all user_data output to a file for easy debugging
    exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
    
    echo "--- Starting Splunk Enterprise Install ---"
    
    # Wait for network and metadata services to be ready
    yum update -y
    yum install -y aws-cli
    
    # 1. Fetch the admin password from Secrets Manager
    # We use the AWS CLI, which works because of our IAM Role.
    echo "Fetching secret: ${aws_secretsmanager_secret.splunk_admin_password.name}"
    ADMIN_PASSWORD=$(aws secretsmanager get-secret-value \
      --secret-id ${aws_secretsmanager_secret.splunk_admin_password.name} \
      --region ${var.aws_region} \
      --query SecretString --output text)
      
    if [ -z "$ADMIN_PASSWORD" ]; then
      echo "FATAL: Could not fetch admin password from Secrets Manager"
      exit 1
    fi
    
    # 2. Download and install Splunk
    cd /opt
    echo "Downloading Splunk from ${var.splunk_url}"
    wget -O splunk.tgz "${var.splunk_url}"
    tar -xzf splunk.tgz
    
    # 3. Start Splunk with the fetched password
    echo "Starting Splunk and seeding password"
    /opt/splunk/bin/splunk start --accept-license --answer-yes --no-prompt --seed-passwd "$ADMIN_PASSWORD"
    
    # 4. Enable Splunk to start on boot
    /opt/splunk/bin/splunk enable boot-start -user splunk
    echo "--- Base Splunk Enterprise Install Complete ---"
  EOF

  # This is the "config" script for the Indexer
  indexer_config_script = <<-EOF
    echo "--- Configuring Indexer ---"
    
    # Set the role and enable port 9997 for receiving data
    /opt/splunk/bin/splunk edit-server-conf -role splunk_indexer -pass4SymmKey "${var.splunk_pass4symmkey}"
    /opt/splunk/bin/splunk enable listen 9997 -auth "admin:$(cat /opt/splunk/etc/passwd)"
    
    # Configure SmartStore
    # We point it to the S3 bucket we created in storage.tf
    echo "Configuring SmartStore S3 bucket: ${aws_s3_bucket.smartstore_bucket.id}"
    
    /opt/splunk/bin/splunk edit-indexes-conf -name "volume:smartstore_s3_volume" \
      -path "s3://${aws_s3_bucket.smartstore_bucket.id}/splunk_data" \
      -remote_path_s3 "s3://${aws_s3_bucket.smartstore_bucket.id}/splunk_data"
      
    # Set all *new* indexes to use this SmartStore volume by default
    /opt/splunk/bin/splunk edit-server-conf \
      -default_index_datastore "volume:smartstore_s3_volume"
    
    /opt/splunk/bin/splunk restart
    echo "--- Indexer Configuration Complete ---"
  EOF

  # This is the "config" script for the Search Head
  search_head_config_script = <<-EOF
    echo "--- Configuring Search Head ---"
    /opt/splunk/bin/splunk edit-server-conf -role splunk_search_head -pass4SymmKey "${var.splunk_pass4symmkey}"
    /opt/splunk/bin/splunk restart
    echo "--- Search Head Configuration Complete ---"
  EOF

  # This is the "config" script for the Deployment Server
  deployment_server_config_script = <<-EOF
    echo "--- Configuring Deployment Server ---"
    /opt/splunk/bin/splunk edit-server-conf -role splunk_deployment_server -pass4SymmKey "${var.splunk_pass4symmkey}"
    /opt/splunk/bin/splunk restart
    echo "--- Deployment Server Configuration Complete ---"
  EOF

  # This is the *separate* install script for the Universal Forwarder
  uf_install_script = <<-EOF
    #!/bin/bash
    exec > >(tee /var/log/user-data.log|logger -t user-data -s 2>/dev/console) 2>&1
    
    echo "--- Starting Splunk UF Install ---"
    yum update -y
    yum install -y aws-cli
    
    # 1. Fetch password
    echo "Fetching secret: ${aws_secretsmanager_secret.splunk_admin_password.name}"
    ADMIN_PASSWORD=$(aws secretsmanager get-secret-value \
      --secret-id ${aws_secretsmanager_secret.splunk_admin_password.name} \
      --region ${var.aws_region} \
      --query SecretString --output text)
      
    # 2. Download and install UF
    cd /opt
    echo "Downloading Splunk UF from ${var.splunk_uf_url}"
    wget -O splunk-uf.tgz "${var.splunk_uf_url}"
    tar -xzf splunk-uf.tgz
    
    # 3. Start Splunk UF
    echo "Starting Splunk UF and seeding password"
    /opt/splunkforwarder/bin/splunk start --accept-license --answer-yes --no-prompt --seed-passwd "$ADMIN_PASSWORD"
    
    # 4. Enable boot-start
    /opt/splunkforwarder/bin/splunk enable boot-start -user splunk
    
    # 5. Point the UF to its servers using the DNS names we will create in dns.tf
    echo "Setting deploy-poll to ds.splunk.lab:8089"
    /opt/splunkforwarder/bin/splunk set-deploy-poll "ds.splunk.lab:8089" -auth "admin:$ADMIN_PASSWORD"
    
    echo "Setting forward-server to indexer.splunk.lab:9997"
    /opt/splunkforwarder/bin/splunk add forward-server "indexer.splunk.lab:9997" -auth "admin:$ADMIN_PASSWORD"
    
    /opt/splunkforwarder/bin/splunk restart
    echo "--- Splunk UF Install Complete ---"
  EOF
}

# ------------------------------------------------------------------------------
# 3. Launch Templates (The "Blueprints")
# ------------------------------------------------------------------------------
# Now we define the blueprints. Each one combines an AMI, instance type,
# security groups, IAM role, and its specific user_data script.

resource "aws_launch_template" "splunk_indexer" {
  name_prefix   = "splunk-lab-idx-"
  image_id      = data.aws_ami.amazon_linux_2.id
  instance_type = var.indexer_instance_type
  key_name      = var.key_name

  vpc_security_group_ids = [aws_security_group.splunk_indexer_sg.id]

  iam_instance_profile {
    arn = aws_iam_instance_profile.splunk_indexer_profile.arn
  }

  # We combine the base install script + the indexer config script
  user_data = base64encode(join("\n", [
    local.splunk_enterprise_install_script,
    local.indexer_config_script
  ]))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "Splunk-Lab-IDX"
      Role = "Indexer"
    }
  }
}

resource "aws_launch_template" "splunk_search_head" {
  name_prefix   = "splunk-lab-sh-"
  image_id      = data.aws_ami.amazon_linux_2.id
  instance_type = var.sh_instance_type
  key_name      = var.key_name

  vpc_security_group_ids = [aws_security_group.splunk_web_sg.id]

  iam_instance_profile {
    arn = aws_iam_instance_profile.splunk_common_profile.arn
  }

  user_data = base64encode(join("\n", [
    local.splunk_enterprise_install_script,
    local.search_head_config_script
  ]))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "Splunk-Lab-SH"
      Role = "Search-Head"
    }
  }
}

resource "aws_launch_template" "splunk_ds" {
  name_prefix   = "splunk-lab-ds-"
  image_id      = data.aws_ami.amazon_linux_2.id
  instance_type = var.mgmt_instance_type
  key_name      = var.key_name

  vpc_security_group_ids = [aws_security_group.splunk_web_sg.id]

  iam_instance_profile {
    arn = aws_iam_instance_profile.splunk_common_profile.arn
  }

  user_data = base64encode(join("\n", [
    local.splunk_enterprise_install_script,
    local.deployment_server_config_script
  ]))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "Splunk-Lab-DS"
      Role = "Deployment-Server"
    }
  }
}

resource "aws_launch_template" "splunk_uf" {
  name_prefix   = "splunk-lab-uf-"
  image_id      = data.aws_ami.amazon_linux_2.id
  instance_type = var.mgmt_instance_type # UFs are small, t3.micro is fine
  key_name      = var.key_name

  vpc_security_group_ids = [aws_security_group.splunk_uf_sg.id]

  iam_instance_profile {
    arn = aws_iam_instance_profile.splunk_common_profile.arn
  }

  # This one uses its own unique script
  user_data = base64encode(local.uf_install_script)

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "Splunk-Lab-UF"
      Role = "Forwarder"
    }
  }
}

# ------------------------------------------------------------------------------
# 4. EC2 Instances (The "Servers")
# ------------------------------------------------------------------------------
# Finally, we stamp out our instances from the blueprints.
# They will all be launched into the secure *private* subnet.

resource "aws_instance" "search_head" {
  launch_template {
    id = aws_launch_template.splunk_search_head.id
  }
  subnet_id = aws_subnet.private_subnet.id

  tags = {
    Name = "Splunk-Lab-SH-Instance"
  }
}

resource "aws_instance" "indexer" {
  launch_template {
    id = aws_launch_template.splunk_indexer.id
  }
  subnet_id = aws_subnet.private_subnet.id

  tags = {
    Name = "Splunk-Lab-IDX-Instance"
  }
}

resource "aws_instance" "deployment_server" {
  launch_template {
    id = aws_launch_template.splunk_ds.id
  }
  subnet_id = aws_subnet.private_subnet.id

  tags = {
    Name = "Splunk-Lab-DS-Instance"
  }
}

resource "aws_instance" "forwarder" {
  # This "count" meta-argument is how we create 2 identical instances
  count = 2

  launch_template {
    id = aws_launch_template.splunk_uf.id
  }
  subnet_id = aws_subnet.private_subnet.id

  # We use count.index to give them unique names
  tags = {
    Name = "Splunk-Lab-UF-${count.index + 1}-Instance"
  }
}