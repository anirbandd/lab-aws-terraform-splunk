# ------------------------------------------------------------------------------
# 1. VPC (The "House")
# ------------------------------------------------------------------------------
# This is the main network boundary. Everything else lives inside this.
resource "aws_vpc" "splunk_lab_vpc" {
  cidr_block = var.vpc_cidr # e.g., "10.0.0.0/16" from variables.tf

  # We enable DNS support so our instances can resolve public
  # and private DNS names (like our Route 53 records).
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "Splunk-Lab-VPC"
  }
}

# ------------------------------------------------------------------------------
# 2. Subnets (The "Rooms")
# ------------------------------------------------------------------------------
# We'll create one public subnet (for LBs, NAT) and one private subnet (for Splunk).
# In a real setup, you'd create one of each per Availability Zone for high availability.

resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.splunk_lab_vpc.id
  cidr_block              = var.public_subnet_cidr # e.g., "10.0.1.0/24"
  availability_zone       = "us-east-1a"           # We'll hardcode one AZ for the lab
  map_public_ip_on_launch = true                   # Auto-assign public IPs (for NAT)

  tags = {
    Name = "Splunk-Lab-Public-Subnet"
  }
}

resource "aws_subnet" "private_subnet" {
  vpc_id                  = aws_vpc.splunk_lab_vpc.id
  cidr_block              = var.private_subnet_cidr # e.g., "10.0.100.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = false # CRITICAL: Private instances should NOT get public IPs.

  tags = {
    Name = "Splunk-Lab-Private-Subnet"
  }
}

# ------------------------------------------------------------------------------
# 3. Gateways (The "Doors" to the Internet)
# ------------------------------------------------------------------------------

# The Internet Gateway (IGW) allows two-way traffic for the Public subnet.
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.splunk_lab_vpc.id

  tags = {
    Name = "Splunk-Lab-IGW"
  }
}

# The NAT Gateway allows one-way *outbound* traffic for the Private subnet.
# It needs a static public IP (Elastic IP) to live at.
resource "aws_eip" "nat_eip" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public_subnet.id # Must live in a PUBLIC subnet

  tags = {
    Name = "Splunk-Lab-NAT-GW"
  }

  # This ensures the IGW is created *before* the NAT Gateway.
  depends_on = [aws_internet_gateway.gw]
}

# ------------------------------------------------------------------------------
# 4. Route Tables (The "Traffic Cop")
# ------------------------------------------------------------------------------

# Public route table: Send all internet-bound traffic (0.0.0.0/0) to the IGW.
resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.splunk_lab_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "Splunk-Lab-Public-RT"
  }
}

# Private route table: Send all internet-bound traffic (0.0.0.0/0) to the NAT Gateway.
resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.splunk_lab_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }

  tags = {
    Name = "Splunk-Lab-Private-RT"
  }
}

# ------------------------------------------------------------------------------
# 5. Associations (Linking Rooms to Traffic Cops)
# ------------------------------------------------------------------------------
# Finally, we associate our route tables with their intended subnets.

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "private_assoc" {
  subnet_id      = aws_subnet.private_subnet.id
  route_table_id = aws_route_table.private_rt.id
}