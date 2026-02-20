###############################################################################
# Runner Infra Module - ASG + Launch Template (EC2 host layer)
#
# This file defines the EC2 “ECS container instances” host layer for `launch_type = "EC2"`.
# It creates:
# - A Launch Template: the “recipe” for EC2 instances (AMI, networking/SGs, instance profile, disks, user-data).
# - An Auto Scaling Group (ASG): the fleet manager that launches/replaces/scales EC2 instances using the launch template.
###############################################################################

# Resource: EC2 Launch Template for the ECS container instances (the EC2 hosts running the ECS agent).
#
# What it is:
# - Launch Template: an EC2 instance “recipe” (AMI, instance type, networking, IAM instance profile, storage, user-data).
#
# What it attaches to:
# - Used by `aws_autoscaling_group.github_runner_asg.launch_template` below (so the ASG can launch instances from it).
# - Provides instance networking (ENI + security groups), IAM instance profile, and disks that the launched instances will have.
resource "aws_launch_template" "github_runner_lt" {
  count = local.is_ec2_launch_type ? 1 : 0 # Only create for EC2 launch type (hosts exist only for EC2)

  name_prefix = "${local.effective_prefix}-lt-" # Launch template name prefix; derived from `local.effective_prefix` (see `locals.tf`)
  image_id = local.instance_ami_effective       # AMI used to boot instances; `instance_ami` override if set, else latest ECS-optimized AMI via SSM
  instance_type = var.instance_type             # EC2 instance size; from `var.instance_type`
  key_name      = null                          # No SSH key pair by default (access is typically via SSM)

  # What it is: instance ENI (network interface) settings for instances launched from this template.
  # Definition: an ENI is the instance’s virtual network card with an IP in your VPC; security groups attach to the ENI.
  network_interfaces {
    associate_public_ip_address = var.assign_public_ip # Whether to assign a public IP to the instance ENI; from `var.assign_public_ip`
    security_groups = concat(
      [aws_security_group.ecs_instances.id],
      var.security_group_ids
    ) # SGs attached to the instance ENI: the module’s instance SG + any additional SGs from `var.security_group_ids`
  }

  # What it is: IAM instance profile setting for the launched instances.
  # Definition: an instance profile is how an EC2 instance receives an IAM role at boot.
  iam_instance_profile {
    name = aws_iam_instance_profile.runner_instance_profile[0].name # Instance profile name; from `iam.tf`
  }

  # What it is: EC2 Instance Metadata Service (IMDS) configuration.
  # Definition: IMDS provides instance metadata/credentials; IMDSv2 requires session tokens (more secure than v1).
  metadata_options {
    http_tokens = "required" # enforce IMDSv2 (disables v1)
  }

  # What it is: root volume block device mapping (OS disk).
  # Definition: block device mappings define which EBS volumes are attached to the instance at launch.
  block_device_mappings {
    device_name = "/dev/xvda" # Root disk device name
    ebs {
      volume_size           = 30    # Root volume size (GiB)
      volume_type           = "gp3" # EBS volume type (gp3 = SSD)
      delete_on_termination = true  # Delete the volume when the instance is terminated
      encrypted             = true  # Encrypt the volume at rest (uses default EBS encryption / KMS settings for the account)
    }
  }

  # What it is: additional data volume mapping for Docker storage.
  # Definition: a separate EBS volume can be mounted for `/var/lib/docker` to reduce “disk full” issues from image builds.
  block_device_mappings {
    device_name = "/dev/xvdf" # Secondary disk device name
    ebs {
      volume_size           = var.docker_volume_size # Docker data volume size (GiB); from `var.docker_volume_size`
      volume_type           = "gp3"                  # EBS volume type
      delete_on_termination = true                   # Delete the volume when the instance is terminated
      encrypted             = true                   # Encrypt the volume at rest
    }
  }

  # What it is: instance bootstrap script (cloud-init style user-data) passed to EC2.
  # Definition: user-data runs on first boot; here it configures the ECS agent/cluster and optional Docker cleanup.
  user_data = base64encode(templatefile("${path.module}/user_data.sh.tpl", {
    cluster_name = var.cluster_name # ECS cluster name the agent should join; from `var.cluster_name`
    aws_region   = var.aws_region   # AWS region used by the bootstrap script; from `var.aws_region`

    enable_docker_prune_cron = var.enable_docker_prune_cron # Whether to enable docker prune cron on hosts; from `var.enable_docker_prune_cron`
    docker_prune_cron_schedule = var.docker_prune_cron_schedule # Cron schedule string for docker prune job; from `var.docker_prune_cron_schedule` (set in `variables.tf`)
    docker_prune_until         = var.docker_prune_until         # Age filter for docker prune (e.g., "3h"); from `var.docker_prune_until` (set in `variables.tf`)
  }))

  # What it is: tags applied to instances launched from this template.
  # Definition: tag_specifications control which AWS resource types receive tags at launch.
  # Definition: a tag is a key/value label on AWS resources used for identification, filtering, cost allocation, and automation.
  tag_specifications {
    resource_type = "instance" # Apply these tags to the EC2 instance resource
    # What it is: the set of tags to apply to the instance resource.
    # Definition: these key/value pairs show up on the EC2 instance in the AWS console and APIs.
    tags = {
      Name        = local.effective_prefix # Instance Name tag; derived from `local.effective_prefix`
      Environment = var.cluster_name       # Environment tag; uses cluster name as an environment identifier
    }
  }
}

# Resource: Auto Scaling Group (ASG) for the ECS container instances.
#
# What it is:
# - Auto Scaling Group: manages a fleet of EC2 instances (launches, replaces unhealthy instances, scales up/down).
#
# What it attaches to:
# - Uses the Launch Template above (so the instances it creates have the right networking, IAM, disks, and user-data).
# - Launches instances into the subnets in `var.subnets` (i.e., attaches their ENIs into those VPC subnets).
resource "aws_autoscaling_group" "github_runner_asg" {
  count = local.is_ec2_launch_type ? 1 : 0 # Only create for EC2 launch type

  name                = "${local.effective_prefix}-asg" # ASG name; derived from `local.effective_prefix`
  vpc_zone_identifier = var.subnets                     # Subnets where instances are launched; from `var.subnets`

  min_size         = var.asg_min_size         # Minimum number of instances; from `var.asg_min_size`
  max_size         = var.asg_max_size         # Maximum number of instances; from `var.asg_max_size`
  desired_capacity = var.asg_desired_capacity # Desired/initial number of instances; from `var.asg_desired_capacity`

  protect_from_scale_in = true # aka "new instances protected from scale-in"
  default_cooldown      = 300  # Default cooldown between scaling activities (seconds)
  health_check_type     = "EC2" # ASG health check source ("EC2" uses instance status checks)
  force_delete          = true  # Allow delete even if instances are still running (useful for teardown)

  # What it is: reference to the launch template used for instances in this ASG.
  # Definition: the ASG uses this to know which AMI/networking/IAM/disks/user-data each instance should have.
  launch_template {
    id      = aws_launch_template.github_runner_lt[0].id            # Launch template ID; from `aws_launch_template.github_runner_lt`
    version = aws_launch_template.github_runner_lt[0].latest_version # Use latest version so updates roll out on new instances
  }

  # What it is: explicit dependency list for Terraform's resource graph.
  # Definition: `depends_on` forces Terraform to create/refresh the referenced resources before this one.
  depends_on = [
    aws_launch_template.github_runner_lt # Explicit dependency on the launch template resource (ensures it exists/updates before the ASG is planned/applied)
  ]

  # What it is: special ASG tag consumed by ECS when managing container instances.
  # Definition: `AmazonECSManaged` is used by ECS/ASG integration to mark instances as ECS-managed.
  # What it is: ASG tag used by ECS/ASG integration.
  # Definition: ASG tags can be copied onto each launched instance when `propagate_at_launch=true`.
  tag {
    key                 = "AmazonECSManaged" # Tag key recognized by ECS for managed container instances
    value               = ""                 # Tag value (ECS expects empty string for this marker tag)
    propagate_at_launch = true               # Copy this tag onto instances launched by the ASG
  }

  # What it is: environment tag applied to launched instances.
  # Definition: ASG tags with `propagate_at_launch=true` are copied onto each instance the ASG launches.
  # What it is: environment tag applied to launched instances.
  # Definition: a simple key/value label used for grouping, filtering, and cost allocation.
  tag {
    key                 = "Environment"     # Tag key
    value               = var.cluster_name  # Tag value; from `var.cluster_name` (used as an environment identifier in this repo)
    propagate_at_launch = true              # Copy this tag onto instances launched by the ASG
  }

  # What it is: Terraform lifecycle tuning for this ASG resource.
  # Definition: used to control how Terraform performs updates and what changes it should ignore.
  lifecycle {
    create_before_destroy = true # Replace by creating the new ASG before destroying the old one (helps avoid capacity gaps during updates)
    ignore_changes        = [desired_capacity, min_size, max_size] # Don't force Terraform diffs if these drift (often tuned operationally / by scaling mechanisms)
  }
}


