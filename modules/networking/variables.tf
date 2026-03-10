################################################################################
# Networking Module - Input Variables
################################################################################
#
# Used when this repo creates VPC, subnets, NAT Gateway, IGW, and egress routes.
# All values come from Terraform variables (no hardcoded IDs or CIDRs).
#
################################################################################

variable "vpc_cidr" {
  description = "CIDR block for the created VPC (e.g. 10.0.0.0/16). Use a private range that does not overlap with other networks you need to reach."
  type        = string
}

variable "vpc_additional_cidrs" {
  description = "Optional additional IPv4 CIDR blocks to associate to the VPC after creation (for example [\"10.41.0.0/16\"])."
  type        = list(string)
  default     = []
}

variable "networking_azs" {
  description = "List of availability zone names (e.g. [\"us-east-1a\", \"us-east-1d\"]) where private subnets will be created. Use at least two AZs for high availability."
  type        = list(string)
}

variable "name_prefix" {
  description = "Optional prefix for resource names (VPC, subnets, NAT gateway, route tables). Helps avoid collisions if multiple stacks exist."
  type        = string
  default     = "github-runner"
}
