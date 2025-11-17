# ------------------------------------------------------------------------------
# AWS & Network Variables
# ------------------------------------------------------------------------------
variable "aws_region" {
  description = "The AWS region to deploy resources in."
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "The CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "The CIDR block for the public subnet."
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  description = "The CIDR block for the private subnet."
  type        = string
  default     = "10.0.100.0/24"
}

variable "my_ip" {
  description = "Your public IP address for secure SSH access (e.g., 203.0.113.4)."
  type        = string
}

variable "key_name" {
  description = "The name of the existing AWS Key Pair for SSH access."
  type        = string
}

# ------------------------------------------------------------------------------
# Splunk Software & Security Variables
# ------------------------------------------------------------------------------
variable "splunk_url" {
  description = "URL to the Splunk Enterprise .tgz package for SH/IDX/DS."
  type        = string
  # NOTE: You must replace this with a valid, accessible Splunk download link.
  default     = "https://download.splunk.com/products/splunk/releases/9.0.0/linux/splunk-9.0.0-dd4a72739e10-Linux-x86_64.tgz"
}

variable "splunk_uf_url" {
  description = "URL to the Splunk Universal Forwarder .tgz package."
  type        = string
  # NOTE: Replace with a valid UF download link.
  default     = "https://download.splunk.com/products/universal_forwarder/releases/9.0.0/linux/splunkforwarder-9.0.0-dd4a72739e10-Linux-x86_64.tgz"
}

variable "splunk_pass4symmkey" {
  description = "The security key used for encrypting inter-Splunk communication."
  type        = string
  default     = "REPLACE-ME-WITH-A-STRONG-KEY"
}

# ------------------------------------------------------------------------------
# Instance Type Variables
# ------------------------------------------------------------------------------
variable "sh_instance_type" {
  description = "EC2 instance type for the Search Head."
  type        = string
  default     = "t3.large"
}

variable "indexer_instance_type" {
  description = "EC2 instance type for the Indexer (requires decent IO/CPU)."
  type        = string
  default     = "m5.large"
}

variable "mgmt_instance_type" {
  description = "EC2 instance type for Deployment Server and Universal Forwarders."
  type        = string
  default     = "t3.medium"
}

# ------------------------------------------------------------------------------
# DNS Variables
# ------------------------------------------------------------------------------
variable "hosted_zone_name" {
  description = "The name of the Route 53 Hosted Zone where records will be created (e.g., splunk.lab)."
  type        = string
}

variable "sh_dns_name" {
  description = "The full DNS name for the Search Head (e.g., sh.splunk.lab)."
  type        = string
  default     = "sh.splunk.lab"
}

variable "ds_dns_name" {
  description = "The full DNS name for the Deployment Server (e.g., ds.splunk.lab)."
  type        = string
  default     = "ds.splunk.lab"
}

variable "indexer_dns_name" {
  description = "The internal DNS name for the Indexer (e.g., indexer.splunk.lab)."
  type        = string
  default     = "indexer.splunk.lab"
}