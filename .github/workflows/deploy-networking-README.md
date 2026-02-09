# Deploy Networking workflow

This document describes the **Deploy networking only** GitHub Actions workflow (`deploy-networking.yml`). Use it to create or update only the networking resources (VPC, subnets, Transit Gateway, attachment, and routes) using a **separate Terraform state file**, without touching the main runner deployment state.

## What it does

- **Trigger:** Manual only (`workflow_dispatch`). No push or PR triggers.
- **Actions:** You choose **plan** or **deploy** when you run the workflow.
- **Scope:** Runs Terraform with `-target=module.networking` so only the networking module is planned or applied.
- **State:** Uses its own S3 state key (from the `TF_NETWORKING_STATE_KEY` variable), so the main deployment state (used by `deployment.yml`) is not modified.

Use this workflow to:

- Test or create networking (VPC, subnets, TGW) in isolation before running a full deployment.
- Create networking once, then run the main deployment workflow with `create_networking` and the same CIDR/AZs so the main state can reference the same resources, or to inspect what the networking module would create.

## What gets created

When you run **deploy**, the workflow applies only `module.networking`, which creates:

| Resource | Description |
|----------|-------------|
| **Transit Gateway** | Regional TGW for routing. |
| **VPC** | One VPC with the CIDR you set in `SHARED_VPC_CIDR`. |
| **Private subnets** | One subnet per AZ in `SHARED_NETWORKING_AZS`, with CIDRs derived from the VPC CIDR. |
| **TGW VPC attachment** | Attaches the VPC to the Transit Gateway using those subnets. |
| **Route table** | One route table with a default route `0.0.0.0/0` → Transit Gateway. |
| **Route table associations** | Associates that route table with each created subnet. |

Egress from the runner VPC is sent to the TGW. For traffic to reach the internet or other networks, the TGW must have additional attachments and routing configured elsewhere (e.g. egress VPC with NAT or firewall).

## How to run it

1. In your repo, go to **Actions**.
2. Select **Deploy networking only** in the workflow list.
3. Click **Run workflow**.
4. Choose **plan** (only generate a plan) or **deploy** (plan and then apply).
5. Click **Run workflow**.

The job will checkout the repo, assume AWS via OIDC, run `terraform init` with the networking state key, validate, then plan (and optionally apply) with `-target=module.networking`.

## Required configuration

All configuration comes from **GitHub Settings → Secrets and variables → Actions**. Nothing is hardcoded in the workflow file.

### Variables (Settings → Actions → Variables)

| Variable | Example | Description |
|----------|---------|-------------|
| `SHARED_VPC_CIDR` | `10.0.0.0/16` | CIDR block for the VPC. Use a private range that does not overlap with other networks. |
| `SHARED_NETWORKING_AZS` | `["us-east-1a","us-east-1d"]` | JSON array of availability zone names. Use at least two AZs for high availability. Must be valid JSON (e.g. `["us-east-1a","us-east-1d"]`). |
| `TF_NETWORKING_STATE_KEY` | `github-runner-networking/terraform.tfstate` | S3 object key for the Terraform state file used by this workflow. Must be different from the main deployment state key. |
| `SHARED_AWS_REGION` | `us-east-1` | AWS region where resources are created. |
| `SHARED_CLUSTER_NAME` | `nexus-repo` | Optional. Used for resource naming; defaults to `nexus-repo` if not set. |

### Secrets (Settings → Actions → Secrets)

| Secret | Description |
|--------|-------------|
| `SHARED_AWS_ACCOUNT_ID` | Your 12-digit AWS account ID. Used for OIDC and Terraform. |
| `SHARED_AWS_ROLE_NAME` | IAM role name for GitHub OIDC. The workflow assumes this role to run Terraform. |
| `TF_BACKEND_BUCKET` | S3 bucket name for Terraform state. Can be the same bucket as the main workflow; the state key (above) separates networking state. |

## Relationship to the main deployment

- **Separate state:** This workflow uses `TF_NETWORKING_STATE_KEY`; the main deployment workflow uses `TF_STATE_KEY`. They do not share state.
- **No runner secrets:** This workflow uses placeholder `runner_services` so it can run without GitHub org or runner token secrets. Only the networking module is targeted.
- **Full deployment:** To deploy runners into the networking created here, run the main **Multi-Org github runner Deployment** workflow with `create_networking` and the same `SHARED_VPC_CIDR` and `SHARED_NETWORKING_AZS` (and the same backend bucket if you want Terraform to manage the same networking resources from the main state). Alternatively, you can use this workflow only to create networking once with its own state, then use the main workflow with **bring your own** VPC/subnets (using the created VPC and subnet IDs from this workflow’s outputs or from AWS).

## Troubleshooting

- **Plan/apply fails on variables:** Ensure `SHARED_VPC_CIDR`, `SHARED_NETWORKING_AZS`, `TF_NETWORKING_STATE_KEY`, and `SHARED_AWS_REGION` are set. `SHARED_NETWORKING_AZS` must be a JSON array string, e.g. `["us-east-1a","us-east-1d"]`.
- **AWS permission errors:** The role specified in `SHARED_AWS_ROLE_NAME` needs permissions to create and manage EC2 VPCs, subnets, and Transit Gateway resources (e.g. `ec2:CreateVpc`, `ec2:CreateSubnet`, `ec2:CreateTransitGateway`, and related APIs).
- **Backend errors:** Confirm `TF_BACKEND_BUCKET` exists, is in the same region as `SHARED_AWS_REGION`, and the OIDC role has `s3:GetObject`, `s3:PutObject`, and (if using locking) `dynamodb:*` on the state bucket/key and optional DynamoDB table.
