#!/usr/bin/env python3
"""
One-time setup: create IAM OIDC provider and IAM roles for GitHub Actions to assume
when running the deployment workflow. All configuration is read from environment
variables; there are no hardcoded account IDs, bucket names, GitHub org/repo, or role names.
"""

from __future__ import annotations

import hashlib
import json
import os
import socket
import ssl
import sys
import time

import boto3
from botocore.exceptions import ClientError

OIDC_URL = "https://token.actions.githubusercontent.com"
OIDC_AUDIENCE = "sts.amazonaws.com"
GITHUB_ACTIONS_ROLE_MAX_SESSION_DURATION = 7200


def get_oidc_thumbprint(url: str) -> str:
    """Compute the thumbprint of the OIDC provider's TLS certificate (SHA-1 of DER)."""
    host = url.replace("https://", "").split("/")[0]
    port = 443
    context = ssl.create_default_context()
    with context.wrap_socket(
        socket.socket(),
        server_hostname=host,
    ) as sock:
        sock.connect((host, port))
        cert_der = sock.getpeercert(binary_form=True)
    return hashlib.sha1(cert_der).hexdigest()


def require_env(*names: str) -> dict[str, str]:
    """Require that all given environment variables are set. Return a dict of name -> value."""
    out = {}
    missing = []
    for name in names:
        value = os.environ.get(name)
        if not (value and value.strip()):
            missing.append(name)
        else:
            out[name] = value.strip()
    if missing:
        print("ERROR: The following required environment variables are missing or empty:", file=sys.stderr)
        for m in missing:
            print(f"  - {m}", file=sys.stderr)
        sys.exit(1)
    return out


def ensure_oidc_provider(iam, thumbprint: str, account_id: str) -> None:
    """Create the GitHub OIDC identity provider if it does not exist."""
    provider_arn = f"arn:aws:iam::{account_id}:oidc-provider/{OIDC_URL.replace('https://', '')}"
    try:
        iam.get_open_id_connect_provider(OpenIDConnectProviderArn=provider_arn)
        print("OIDC provider already exists.")
        return
    except ClientError as e:
        if e.response["Error"]["Code"] != "NoSuchEntity":
            raise
    created_arn = iam.create_open_id_connect_provider(
        Url=OIDC_URL,
        ClientIDList=[OIDC_AUDIENCE],
        ThumbprintList=[thumbprint],
    )["OpenIDConnectProviderArn"]
    print(f"Created OIDC provider: {created_arn}")


def create_github_actions_role(iam, env: dict[str, str]) -> None:
    """Create the IAM role that GitHub Actions assumes via OIDC.
    Grants AdministratorAccess and an inline policy to assume state-role and terraform-exec.
    """
    role_name = env["GITHUB_ACTIONS_ROLE"]
    account_id = env["AWS_ACCOUNT_ID"]
    org = env["GITHUB_ORG"]
    repo = env["GITHUB_REPO"]
    state_role = env["STATE_ROLE_NAME"]
    terraform_exec_role = env["TERRAFORM_EXEC_ROLE"]
    trust_policy = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Principal": {
                    "Federated": f"arn:aws:iam::{account_id}:oidc-provider/token.actions.githubusercontent.com",
                },
                "Action": "sts:AssumeRoleWithWebIdentity",
                "Condition": {
                    "StringEquals": {"token.actions.githubusercontent.com:aud": OIDC_AUDIENCE},
                    "StringLike": {"token.actions.githubusercontent.com:sub": f"repo:{org}/{repo}:*"},
                },
            },
        ],
    }
    assume_state_and_exec = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "AssumeStateAndExec",
                "Effect": "Allow",
                "Action": ["sts:AssumeRole", "sts:TagSession"],
                "Resource": [
                    f"arn:aws:iam::{account_id}:role/{state_role}",
                    f"arn:aws:iam::{account_id}:role/{terraform_exec_role}",
                ],
            },
        ],
    }
    try:
        iam.get_role(RoleName=role_name)
        print(
            f"Role '{role_name}' already exists; updating assume-role policy, inline policy, and max session duration.",
        )
        iam.update_role(
            RoleName=role_name,
            MaxSessionDuration=GITHUB_ACTIONS_ROLE_MAX_SESSION_DURATION,
        )
        iam.update_assume_role_policy(RoleName=role_name, PolicyDocument=json.dumps(trust_policy))
        iam.put_role_policy(
            RoleName=role_name,
            PolicyName="AssumeStateAndExec",
            PolicyDocument=json.dumps(assume_state_and_exec),
        )
        return
    except ClientError as e:
        if e.response["Error"]["Code"] != "NoSuchEntity":
            raise
    iam.create_role(
        RoleName=role_name,
        AssumeRolePolicyDocument=json.dumps(trust_policy),
        Description="Role for GitHub Actions to assume via OIDC (no long-lived credentials).",
        MaxSessionDuration=GITHUB_ACTIONS_ROLE_MAX_SESSION_DURATION,
    )
    iam.put_role_policy(
        RoleName=role_name,
        PolicyName="AssumeStateAndExec",
        PolicyDocument=json.dumps(assume_state_and_exec),
    )
    iam.attach_role_policy(RoleName=role_name, PolicyArn="arn:aws:iam::aws:policy/AdministratorAccess")
    print(
        f"Created role '{role_name}' with AssumeStateAndExec, AdministratorAccess, and MaxSessionDuration="
        f"{GITHUB_ACTIONS_ROLE_MAX_SESSION_DURATION}.",
    )


def create_state_role(iam, env: dict[str, str]) -> None:
    """Create the IAM role for Terraform state bucket access.
    Trust: any principal in the same AWS Org whose role name is the GitHub Actions role.
    """
    role_name = env["STATE_ROLE_NAME"]
    org_id = env["AWS_ORGANIZATION_ID"]
    bucket = env["TF_BACKEND_BUCKET"]
    github_actions_role = env["GITHUB_ACTIONS_ROLE"]
    trust_policy = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "Statement1",
                "Effect": "Allow",
                "Principal": {"AWS": "*"},
                "Action": ["sts:AssumeRole", "sts:TagSession"],
                "Condition": {
                    "StringEquals": {"aws:PrincipalOrgID": org_id},
                    "ArnLike": {"aws:PrincipalArn": f"arn:aws:iam::*:role/{github_actions_role}"},
                },
            },
        ],
    }
    inline_policy = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "Statement1",
                "Effect": "Allow",
                "Action": [
                    "s3:ListBucket",
                    "s3:GetObject",
                    "s3:PutObject",
                    "s3:DeleteObject",
                    "s3:AbortMultipartUpload",
                ],
                "Resource": [f"arn:aws:s3:::{bucket}", f"arn:aws:s3:::{bucket}/*"],
            },
        ],
    }
    try:
        iam.get_role(RoleName=role_name)
        print(f"Role '{role_name}' already exists; updating assume-role policy and inline policy.")
        iam.update_assume_role_policy(RoleName=role_name, PolicyDocument=json.dumps(trust_policy))
        iam.put_role_policy(RoleName=role_name, PolicyName="StateBucketAccess", PolicyDocument=json.dumps(inline_policy))
        return
    except ClientError as e:
        if e.response["Error"]["Code"] != "NoSuchEntity":
            raise
    iam.create_role(
        RoleName=role_name,
        AssumeRolePolicyDocument=json.dumps(trust_policy),
        Description="Access to Terraform state S3 bucket; trust from GitHub Actions role in same Org.",
    )
    iam.put_role_policy(RoleName=role_name, PolicyName="StateBucketAccess", PolicyDocument=json.dumps(inline_policy))
    print(f"Created role '{role_name}' with state bucket access for '{bucket}'.")


def create_terraform_exec_role(iam, env: dict[str, str]) -> None:
    """Create the IAM role used to run Terraform plan/apply (trust: GitHub Actions role in this account)."""
    role_name = env["TERRAFORM_EXEC_ROLE"]
    account_id = env["AWS_ACCOUNT_ID"]
    github_actions_role = env["GITHUB_ACTIONS_ROLE"]
    trust_policy = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Sid": "Statement1",
                "Effect": "Allow",
                "Principal": {"AWS": f"arn:aws:iam::{account_id}:role/{github_actions_role}"},
                "Action": ["sts:AssumeRole", "sts:TagSession"],
            },
        ],
    }
    try:
        iam.get_role(RoleName=role_name)
        print(f"Role '{role_name}' already exists; updating assume-role policy.")
        iam.update_assume_role_policy(RoleName=role_name, PolicyDocument=json.dumps(trust_policy))
        return
    except ClientError as e:
        if e.response["Error"]["Code"] != "NoSuchEntity":
            raise
    max_attempts = 3
    for attempt in range(1, max_attempts + 1):
        try:
            iam.create_role(
                RoleName=role_name,
                AssumeRolePolicyDocument=json.dumps(trust_policy),
                Description="Role used to run Terraform (plan/apply); trust from GitHub Actions role.",
            )
            break
        except ClientError as e:
            if e.response["Error"]["Code"] == "MalformedPolicyDocumentException" and attempt < max_attempts:
                print(f"Waiting for IAM propagation (attempt {attempt}/{max_attempts})...")
                time.sleep(10)
            else:
                raise
    iam.attach_role_policy(RoleName=role_name, PolicyArn="arn:aws:iam::aws:policy/AdministratorAccess")
    print(f"Created role '{role_name}' and attached AdministratorAccess.")


def main() -> None:
    required = (
        "TF_BACKEND_BUCKET",
        "GITHUB_ORG",
        "GITHUB_REPO",
        "AWS_ORGANIZATION_ID",
        "AWS_ACCOUNT_ID",
        "GITHUB_ACTIONS_ROLE",
        "STATE_ROLE_NAME",
        "TERRAFORM_EXEC_ROLE",
    )
    env = require_env(*required)
    iam = boto3.client("iam")

    thumbprint = get_oidc_thumbprint(OIDC_URL)
    ensure_oidc_provider(iam, thumbprint, env["AWS_ACCOUNT_ID"])
    create_github_actions_role(iam, env)
    create_state_role(iam, env)
    # Brief delay so IAM can propagate the GitHub Actions role before it is used as a principal.
    time.sleep(10)
    create_terraform_exec_role(iam, env)

    print("\n--- Values to set in GitHub (Settings → Secrets and variables → Actions) ---")
    print(f"SHARED_AWS_ACCOUNT_ID = {env['AWS_ACCOUNT_ID']}")
    print(f"SHARED_AWS_ROLE_NAME   = {env['GITHUB_ACTIONS_ROLE']}")
    print(f"TF_BACKEND_BUCKET      = {env['TF_BACKEND_BUCKET']}")
    print("---")


if __name__ == "__main__":
    main()
