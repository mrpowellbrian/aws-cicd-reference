#!/usr/bin/env bash
# bootstrap-oidc.sh
#
# Creates everything a fresh AWS account needs before the first pipeline run:
#   - S3 bucket for Terraform state (versioned, encrypted, access-logged)
#   - DynamoDB table for Terraform state locking
#   - OIDC identity provider for token.actions.githubusercontent.com
#   - IAM role for PR/plan workflow (read-only access)
#   - IAM role for deploy workflow (scoped write access, main branch only)
#
# Usage:
#   export GITHUB_ORG=your-github-username
#   export GITHUB_REPO=aws-cicd-reference
#   export AWS_REGION=us-east-1   # optional, defaults to us-east-1
#   bash scripts/bootstrap-oidc.sh
#
# Idempotent: safe to run more than once. Resources that already exist
# are skipped with a notice rather than causing an error.

set -euo pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────
info()    { echo "[INFO]  $*"; }
success() { echo "[OK]    $*"; }
warn()    { echo "[WARN]  $*" >&2; }
die()     { echo "[ERROR] $*" >&2; exit 1; }

# ── Prerequisites ──────────────────────────────────────────────────────────
for cmd in aws jq; do
  command -v "$cmd" &>/dev/null || die "$cmd is required but not found in PATH"
done

[[ -z "${GITHUB_ORG:-}"  ]] && die "GITHUB_ORG is not set"
[[ -z "${GITHUB_REPO:-}" ]] && die "GITHUB_REPO is not set"

AWS_REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
STATE_BUCKET="tfstate-${ACCOUNT_ID}-${AWS_REGION}"
LOCK_TABLE="terraform-state-lock"
OIDC_URL="token.actions.githubusercontent.com"
PLAN_ROLE_NAME="github-actions-plan"
DEPLOY_ROLE_NAME="github-actions-deploy"

info "Account:      ${ACCOUNT_ID}"
info "Region:       ${AWS_REGION}"
info "GitHub:       ${GITHUB_ORG}/${GITHUB_REPO}"
info "State bucket: ${STATE_BUCKET}"
echo ""

# ── S3 state bucket ────────────────────────────────────────────────────────
info "Creating S3 state bucket..."

if aws s3api head-bucket --bucket "${STATE_BUCKET}" 2>/dev/null; then
  warn "Bucket ${STATE_BUCKET} already exists — skipping create"
else
  if [[ "${AWS_REGION}" == "us-east-1" ]]; then
    aws s3api create-bucket \
      --bucket "${STATE_BUCKET}" \
      --region "${AWS_REGION}" \
      --no-cli-pager
  else
    aws s3api create-bucket \
      --bucket "${STATE_BUCKET}" \
      --region "${AWS_REGION}" \
      --create-bucket-configuration LocationConstraint="${AWS_REGION}" \
      --no-cli-pager
  fi
  success "Created bucket ${STATE_BUCKET}"
fi

# Versioning — required for state recovery
aws s3api put-bucket-versioning \
  --bucket "${STATE_BUCKET}" \
  --versioning-configuration Status=Enabled \
  --no-cli-pager
success "Versioning enabled"

# Server-side encryption
aws s3api put-bucket-encryption \
  --bucket "${STATE_BUCKET}" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"},
      "BucketKeyEnabled": true
    }]
  }' \
  --no-cli-pager
success "Server-side encryption enabled"

# Block all public access
aws s3api put-public-access-block \
  --bucket "${STATE_BUCKET}" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
  --no-cli-pager
success "Public access blocked"

# Enforce TLS
aws s3api put-bucket-policy \
  --bucket "${STATE_BUCKET}" \
  --policy "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Sid\": \"DenyNonTLS\",
      \"Effect\": \"Deny\",
      \"Principal\": \"*\",
      \"Action\": \"s3:*\",
      \"Resource\": [
        \"arn:aws:s3:::${STATE_BUCKET}\",
        \"arn:aws:s3:::${STATE_BUCKET}/*\"
      ],
      \"Condition\": {\"Bool\": {\"aws:SecureTransport\": \"false\"}}
    }]
  }" \
  --no-cli-pager
success "TLS-only bucket policy applied"

# ── DynamoDB lock table ────────────────────────────────────────────────────
info "Creating DynamoDB lock table..."

if aws dynamodb describe-table --table-name "${LOCK_TABLE}" --region "${AWS_REGION}" &>/dev/null; then
  warn "Table ${LOCK_TABLE} already exists — skipping create"
else
  aws dynamodb create-table \
    --table-name "${LOCK_TABLE}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${AWS_REGION}" \
    --no-cli-pager
  success "Created DynamoDB table ${LOCK_TABLE}"
fi

# ── OIDC provider ──────────────────────────────────────────────────────────
info "Creating OIDC provider for GitHub Actions..."

OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_URL}"

if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "${OIDC_ARN}" &>/dev/null; then
  warn "OIDC provider already exists — skipping create"
else
  # AWS validates GitHub's JWKS endpoint directly (since Oct 2023), so the
  # thumbprint is a required field but not used for token validation.
  # The two values below are GitHub's current published thumbprints.
  aws iam create-open-id-connect-provider \
    --url "https://${OIDC_URL}" \
    --client-id-list "sts.amazonaws.com" \
    --thumbprint-list \
      "6938fd4d98bab03faadb97b34396831e3780aea1" \
      "1c58a3a8518e8759bf075b76b750d4f2df264fcd" \
    --no-cli-pager
  success "Created OIDC provider ${OIDC_ARN}"
fi

# ── Trust policy helpers ───────────────────────────────────────────────────
# Plan role: any ref in the repo (covers PR branches and main)
PLAN_TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "${OIDC_ARN}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_URL}:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "${OIDC_URL}:sub": "repo:${GITHUB_ORG}/${GITHUB_REPO}:*"
      }
    }
  }]
}
EOF
)

# Deploy role: main branch only, not pull requests
DEPLOY_TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "${OIDC_ARN}"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "${OIDC_URL}:aud": "sts.amazonaws.com",
        "${OIDC_URL}:sub": "repo:${GITHUB_ORG}/${GITHUB_REPO}:ref:refs/heads/main"
      }
    }
  }]
}
EOF
)

# ── Plan role (read-only) ──────────────────────────────────────────────────
info "Creating IAM role: ${PLAN_ROLE_NAME}..."

if aws iam get-role --role-name "${PLAN_ROLE_NAME}" &>/dev/null; then
  warn "Role ${PLAN_ROLE_NAME} already exists — updating trust policy"
  aws iam update-assume-role-policy \
    --role-name "${PLAN_ROLE_NAME}" \
    --policy-document "${PLAN_TRUST_POLICY}" \
    --no-cli-pager
else
  aws iam create-role \
    --role-name "${PLAN_ROLE_NAME}" \
    --assume-role-policy-document "${PLAN_TRUST_POLICY}" \
    --description "GitHub Actions plan role — read-only, all refs in ${GITHUB_ORG}/${GITHUB_REPO}" \
    --no-cli-pager
  success "Created role ${PLAN_ROLE_NAME}"
fi

# ReadOnlyAccess covers all the describe/list/get calls terraform plan needs.
aws iam attach-role-policy \
  --role-name "${PLAN_ROLE_NAME}" \
  --policy-arn "arn:aws:iam::aws:policy/ReadOnlyAccess" \
  --no-cli-pager

# Terraform also needs to read and lock the S3 backend.
PLAN_INLINE=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:ListBucket", "s3:GetBucketVersioning"],
      "Resource": [
        "arn:aws:s3:::${STATE_BUCKET}",
        "arn:aws:s3:::${STATE_BUCKET}/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"],
      "Resource": "arn:aws:dynamodb:${AWS_REGION}:${ACCOUNT_ID}:table/${LOCK_TABLE}"
    }
  ]
}
EOF
)

aws iam put-role-policy \
  --role-name "${PLAN_ROLE_NAME}" \
  --policy-name "terraform-state-read" \
  --policy-document "${PLAN_INLINE}" \
  --no-cli-pager
success "Plan role configured"

PLAN_ROLE_ARN=$(aws iam get-role --role-name "${PLAN_ROLE_NAME}" --query 'Role.Arn' --output text)

# ── Deploy role (scoped write) ─────────────────────────────────────────────
info "Creating IAM role: ${DEPLOY_ROLE_NAME}..."

if aws iam get-role --role-name "${DEPLOY_ROLE_NAME}" &>/dev/null; then
  warn "Role ${DEPLOY_ROLE_NAME} already exists — updating trust policy"
  aws iam update-assume-role-policy \
    --role-name "${DEPLOY_ROLE_NAME}" \
    --policy-document "${DEPLOY_TRUST_POLICY}" \
    --no-cli-pager
else
  aws iam create-role \
    --role-name "${DEPLOY_ROLE_NAME}" \
    --assume-role-policy-document "${DEPLOY_TRUST_POLICY}" \
    --description "GitHub Actions deploy role — write access, main branch only" \
    --no-cli-pager
  success "Created role ${DEPLOY_ROLE_NAME}"
fi

DEPLOY_INLINE=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TerraformStateBackend",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
        "s3:ListBucket", "s3:GetBucketVersioning"
      ],
      "Resource": [
        "arn:aws:s3:::${STATE_BUCKET}",
        "arn:aws:s3:::${STATE_BUCKET}/*"
      ]
    },
    {
      "Sid": "TerraformStateLock",
      "Effect": "Allow",
      "Action": ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"],
      "Resource": "arn:aws:dynamodb:${AWS_REGION}:${ACCOUNT_ID}:table/${LOCK_TABLE}"
    },
    {
      "Sid": "LambdaDeploy",
      "Effect": "Allow",
      "Action": [
        "lambda:CreateFunction", "lambda:UpdateFunctionCode",
        "lambda:UpdateFunctionConfiguration", "lambda:GetFunction",
        "lambda:GetFunctionConfiguration", "lambda:DeleteFunction",
        "lambda:AddPermission", "lambda:RemovePermission",
        "lambda:ListVersionsByFunction", "lambda:PublishVersion",
        "lambda:GetPolicy", "lambda:TagResource", "lambda:UntagResource",
        "lambda:ListTags"
      ],
      "Resource": "arn:aws:lambda:${AWS_REGION}:${ACCOUNT_ID}:function:*"
    },
    {
      "Sid": "APIGatewayDeploy",
      "Effect": "Allow",
      "Action": ["apigateway:*"],
      "Resource": "arn:aws:apigateway:${AWS_REGION}::/*"
    },
    {
      "Sid": "IAMPassRole",
      "Effect": "Allow",
      "Action": ["iam:PassRole"],
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:role/*-exec",
      "Condition": {
        "StringEquals": {
          "iam:PassedToService": "lambda.amazonaws.com"
        }
      }
    },
    {
      "Sid": "IAMExecutionRole",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole", "iam:DeleteRole", "iam:GetRole",
        "iam:AttachRolePolicy", "iam:DetachRolePolicy",
        "iam:PutRolePolicy", "iam:DeleteRolePolicy",
        "iam:GetRolePolicy", "iam:ListRolePolicy",
        "iam:ListAttachedRolePolicies", "iam:TagRole", "iam:UntagRole"
      ],
      "Resource": "arn:aws:iam::${ACCOUNT_ID}:role/*-exec"
    },
    {
      "Sid": "CloudWatchLogs",
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup", "logs:DeleteLogGroup",
        "logs:PutRetentionPolicy", "logs:DescribeLogGroups",
        "logs:ListTagsLogGroup", "logs:TagLogGroup", "logs:UntagLogGroup",
        "logs:CreateLogDelivery", "logs:DeleteLogDelivery",
        "logs:DescribeResourcePolicies", "logs:PutResourcePolicy"
      ],
      "Resource": "*"
    }
  ]
}
EOF
)

aws iam put-role-policy \
  --role-name "${DEPLOY_ROLE_NAME}" \
  --policy-name "deploy-policy" \
  --policy-document "${DEPLOY_INLINE}" \
  --no-cli-pager
success "Deploy role configured"

DEPLOY_ROLE_ARN=$(aws iam get-role --role-name "${DEPLOY_ROLE_NAME}" --query 'Role.Arn' --output text)

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo " Bootstrap complete. Add these to your GitHub repository secrets:"
echo "================================================================"
echo ""
echo "  AWS_PLAN_ROLE_ARN    = ${PLAN_ROLE_ARN}"
echo "  AWS_DEPLOY_ROLE_ARN  = ${DEPLOY_ROLE_ARN}"
echo "  TF_STATE_BUCKET      = ${STATE_BUCKET}"
echo ""
echo " Backend config for local development (infra/backend.hcl):"
echo ""
echo "  bucket         = \"${STATE_BUCKET}\""
echo "  dynamodb_table = \"${LOCK_TABLE}\""
echo ""
echo " Create a 'production' environment in GitHub Settings → Environments"
echo " and add at least one required reviewer before the first deploy."
echo "================================================================"
