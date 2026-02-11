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

### How to choose `SHARED_VPC_CIDR`

Choose a CIDR that is valid for your environment, not just a doc example.

Rules:

- Use a private RFC1918 range (`10.0.0.0/8`, `172.16.0.0/12`, or `192.168.0.0/16`).
- Do not overlap with existing VPC CIDRs in this account/region.
- Do not overlap with networks reachable through TGW, peering, VPN, or Direct Connect.
- Keep it consistent with your subnet sizing plan (this module derives subnets from the VPC CIDR).

Address space sizing:

- A `/16` has 65,536 total IPs.
- In AWS, each subnet reserves 5 IPs, but VPC-level CIDR capacity is still that size envelope.
- Two `/16`s (`10.40.0.0/16` + `10.41.0.0/16`) give you about 131,072 total addresses.
- Equivalent single block: `10.40.0.0/15` (also ~131,072 addresses).

Recommendation:

- If you want extra headroom, pick a non-overlapping `/15` for this runner VPC.

Why you might need that much:

- Future growth in runners, services, and subnet count.
- Room to expand without adding secondary CIDRs later.
- Cleaner long-term network planning in shared environments.

Benefits of starting with `/15`:

- More free address space from day one.
- Fewer future rework events (subnet pressure, CIDR expansion planning).
- Simpler operations versus adding a second CIDR block later.

Check in AWS Console:

1. Open **AWS Console** in the target account and region.
2. Go to **VPC** → **Your VPCs**.
3. Review the **CIDRs** column for existing VPC ranges.
4. If Transit Gateway is used, also check **VPC** → **Transit Gateway Attachments** (and any peering/VPN/direct connect routes your team uses) to avoid overlap with connected networks.

Check in CloudShell (same account/region):

```bash
# Set your region once
AWS_REGION="us-east-1"

# List VPC CIDRs in this region
aws ec2 describe-vpcs \
  --region "$AWS_REGION" \
  --query "Vpcs[*].[VpcId,CidrBlock,Tags[?Key=='Name']|[0].Value]" \
  --output table

# Optional: list TGW VPC attachments in this region (to understand connected VPCs)
aws ec2 describe-transit-gateway-vpc-attachments \
  --region "$AWS_REGION" \
  --query "TransitGatewayVpcAttachments[*].[TransitGatewayAttachmentId,TransitGatewayId,VpcId,State]" \
  --output table
```

Optional IPAM policy check:

```bash
aws ec2 describe-ipam-pools --region "$AWS_REGION" --output table
```

If this prints only the table header (for example `DescribeIpamPools` with no rows), it means no IPAM pools are visible in this account/region or your current role does not have permission to read them.

How to know which CIDR to pick:

Choose a block that is:

- In private RFC1918 space:
  - `10.0.0.0/8`
  - `172.16.0.0/12`
  - `192.168.0.0/16`
- Not present in your current VPC CIDR list.
- Not overlapping TGW-connected networks.
- Allowed by your org IP policy or IPAM (if used).

What is RFC1918?

RFC1918 means private, non-internet-routable IP ranges reserved for internal networks. In AWS VPCs, you should use these private ranges for CIDRs.

Did we already run a TGW check?

Yes. `describe-transit-gateway-vpc-attachments` is the TGW connectivity check. It tells you which VPCs are attached; then compare their CIDRs from `describe-vpcs` to ensure no overlap.

How to check org policy or IPAM in CloudShell:

```bash
aws ec2 describe-ipams --region "$AWS_REGION" --output table
aws ec2 describe-ipam-pools --region "$AWS_REGION" --output table
```

If these return nothing (or access denied), your org may not use IPAM in that account/region, or your role cannot read it. If `describe-ipam-pools` prints only the table header (for example `DescribeIpamPools` with no rows), treat that as no pools visible in this account/region for your current permissions. In that case, confirm allowed CIDR ranges with your network/platform team.

Good vs bad examples:

- Good: existing VPCs are `10.40.0.0/16` and `10.41.0.0/16`, choose a non-overlapping `/15` such as `10.42.0.0/15` (if your network policy allows it).
- Bad: choosing `10.40.0.0/16` again when a VPC already uses that CIDR, or choosing a `/15` that overlaps existing/connected networks.
- Policy check: confirm `/15` is allowed by your org network standards or IPAM pool constraints before deploy.

### Detailed CIDR selection walkthrough

#### How to pick `SHARED_VPC_CIDR`

#### What to do first

In CloudShell, set your target region:

```bash
AWS_REGION="us-east-1"
```

List existing VPC CIDRs in this account/region:

```bash
aws ec2 describe-vpcs \
  --region "$AWS_REGION" \
  --query "Vpcs[*].[VpcId,CidrBlock,Tags[?Key=='Name']|[0].Value]" \
  --output table
```

If using Transit Gateway, list attached VPCs (connected networks):

```bash
aws ec2 describe-transit-gateway-vpc-attachments \
  --region "$AWS_REGION" \
  --query "TransitGatewayVpcAttachments[*].[TransitGatewayAttachmentId,TransitGatewayId,VpcId,State]" \
  --output table
```

Optional quick CIDR-only view:

```bash
aws ec2 describe-vpcs \
  --region "$AWS_REGION" \
  --query "Vpcs[*].CidrBlock" \
  --output text
```

Pick a non-overlapping `/15` (for headroom), for example `10.60.0.0/15`, only if both halves (`10.60.0.0/16` and `10.61.0.0/16`) are not already used or connected.

#### How to know which CIDR to pick

Choose a block that is:

- In private RFC1918 space:
  - `10.0.0.0/8`
  - `172.16.0.0/12`
  - `192.168.0.0/16`
- Not present in your current VPC CIDR list.
- Not overlapping TGW-connected networks.
- Allowed by your org IP policy/IPAM (if used).

Why those ranges (they are not random):

- These are the globally reserved private IPv4 ranges defined by RFC1918.
- They are intended for internal networks and are not publicly routable on the internet.
- AWS VPC private addressing is built around these private ranges.

#### What is RFC1918?

RFC1918 means private, non-internet-routable IP ranges reserved for internal networks. In AWS VPCs, you should use these private ranges for CIDRs.

#### Did we already run a TGW check?

Yes. `describe-transit-gateway-vpc-attachments` is the TGW connectivity check. It tells you which VPCs are attached; then compare their CIDRs from `describe-vpcs` to ensure no overlap.

#### How to check org policy / IPAM in CloudShell

If your org uses AWS VPC IPAM, check pools/allocations:

```bash
aws ec2 describe-ipams --region "$AWS_REGION" --output table
aws ec2 describe-ipam-pools --region "$AWS_REGION" --output table
```

If these return nothing (or access denied), your org may not use IPAM in that account/region, or your role cannot read it. In that case, confirm allowed CIDR ranges with your network/platform team.

If `describe-ipam-pools` output only shows the header (for example `DescribeIpamPools`) with no rows, it means no pools are visible in this account/region or your role lacks read permission.

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
