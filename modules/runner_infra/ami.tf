# -----------------------------------------------------------------------------
# ECS-Optimized AMI Auto-Discovery (EC2 launch type only)
#
# AWS publishes the latest recommended ECS-optimized Amazon Linux 2 AMI
# to a public SSM parameter in every region.
#
# This data source reads that parameter so we can automatically resolve
# a valid AMI ID when:
#   - launch_type == "EC2"
#   - AND var.instance_ami is null or empty
#
# Why this approach:
#   - Region-safe (AMI IDs differ per region)
#   - Always patched / latest ECS agent version
#   - Removes onboarding friction (no manual AMI lookup required)
#   - Still allows AMI pinning for enterprise users via `instance_ami`
#
# Note:
# This data source is harmless when using FARGATE launch type because
# no EC2 instances are created in that mode.
# -----------------------------------------------------------------------------
data "aws_ssm_parameter" "ecs_al2_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2/recommended/image_id"
}
