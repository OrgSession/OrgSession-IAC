# Execution Guide: OrgSession CI/CD POC

This guide walks through deploying the OrgSession System Status Dashboard from scratch. Follow the steps in order.

---

## Prerequisites

Install the following tools before starting:

| Tool | Version | Install Guide |
|------|---------|---------------|
| AWS CLI | v2 | https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html |
| Terraform | >= 1.7 | https://developer.hashicorp.com/terraform/install |
| Docker | Latest | https://docs.docker.com/get-docker/ |
| Node.js | >= 20 | https://nodejs.org/ |
| Python | >= 3.12 | https://www.python.org/downloads/ |
| jq | Latest | https://jqlang.github.io/jq/download/ |
| git | Latest | https://git-scm.com/downloads |

You also need:

- An AWS account with administrator access (for initial setup)
- A GitHub account with access to the three OrgSession repositories
- AWS CLI configured: `aws configure` with your access key, secret, and region `us-east-1`

---

## Architecture Summary

```
Browser (HTTPS)
      |
      v
CloudFront Distribution
      |
      +-- /status  ---------> ALB (HTTP) --> ECS Fargate (FastAPI)
      |
      +-- /* (default) -----> S3 Bucket (React static files)
```

The frontend and backend share the same CloudFront domain. The browser calls
`https://<cloudfront-domain>/status` which CloudFront proxies to the ALB.
This avoids mixed content errors (HTTPS page calling HTTP endpoint) and
eliminates the need for CORS since both calls originate from the same domain.

---

## Branch and Environment Mapping

All three repositories follow the same branching convention:

| Branch | Environment |
|--------|-------------|
| `development` | dev |
| `main` | prod |

| Event | What triggers |
|-------|--------------|
| PR to `development` | Validation workflow (plan / test / build check) for dev |
| PR to `main` | Validation workflow for prod |
| Merge to `development` | Deploy to dev (automatic) |
| Merge to `main` | Deploy to prod (requires manual approval via GitHub Environments) |

### Workflow files per repository

| Repository | `build.yml` | `deploy.yml` |
|------------|-------------|--------------|
| OrgSession-IAC | `terraform-plan.yml` (PR) | `terraform-apply.yml` (merge) |
| OrgSession-BE | Tests + Docker build check (PR) | Build, push ECR, register task def, deploy ECS (merge) |
| OrgSession-FE | npm ci + Vite build check (PR) | Read config from Secrets Manager, build, sync S3, invalidate CloudFront (merge) |

---

## Step 1: Bootstrap AWS Resources

These resources are created once, manually. They support Terraform state management for all environments.

### 1.1 Create the Terraform state S3 bucket

```bash
aws s3api create-bucket \
  --bucket github-session-my-org-terraform-state \
  --region us-east-1

aws s3api put-bucket-versioning \
  --bucket github-session-my-org-terraform-state \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket github-session-my-org-terraform-state \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      }
    }]
  }'

aws s3api put-public-access-block \
  --bucket github-session-my-org-terraform-state \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

### 1.2 Create the DynamoDB lock table

```bash
aws dynamodb create-table \
  --table-name github-session-my-org-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

### 1.3 Create the GitHub Actions IAM user

```bash
aws iam create-user --user-name github-actions-orgsession
```

Attach the required policies:

```bash
aws iam attach-user-policy \
  --user-name github-actions-orgsession \
  --policy-arn arn:aws:iam::aws:policy/AmazonECS_FullAccess

aws iam attach-user-policy \
  --user-name github-actions-orgsession \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess

aws iam attach-user-policy \
  --user-name github-actions-orgsession \
  --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess

aws iam attach-user-policy \
  --user-name github-actions-orgsession \
  --policy-arn arn:aws:iam::aws:policy/CloudFrontFullAccess

aws iam attach-user-policy \
  --user-name github-actions-orgsession \
  --policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite

aws iam attach-user-policy \
  --user-name github-actions-orgsession \
  --policy-arn arn:aws:iam::aws:policy/AmazonVPCFullAccess

aws iam attach-user-policy \
  --user-name github-actions-orgsession \
  --policy-arn arn:aws:iam::aws:policy/IAMFullAccess

aws iam attach-user-policy \
  --user-name github-actions-orgsession \
  --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess

aws iam attach-user-policy \
  --user-name github-actions-orgsession \
  --policy-arn arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess
```

### 1.4 Create access keys for the IAM user

```bash
aws iam create-access-key \
  --user-name github-actions-orgsession \
  --query 'AccessKey.[AccessKeyId,SecretAccessKey]' \
  --output text
```

The output is two values on one line: the access key ID and the secret access key. Save both.

---

## Step 2: Configure GitHub Repository Secrets

Add the following three secrets to **each** of the three repositories (OrgSession-IAC, OrgSession-BE, OrgSession-FE) individually. GitHub secrets are per-repository and do not carry over between repos.

| Secret Name | Value |
|-------------|-------|
| `AWS_ACCESS_KEY_ID` | Access key ID from Step 1.4 |
| `AWS_SECRET_ACCESS_KEY` | Secret access key from Step 1.4 |
| `AWS_ACCOUNT_ID` | Your 12-digit AWS account ID |

Using the GitHub CLI:

```bash
# Replace placeholders before running
for REPO in OrgSession-IAC OrgSession-BE OrgSession-FE; do
  gh secret set AWS_ACCESS_KEY_ID \
    --body "YOUR_ACCESS_KEY_ID" \
    --repo YOUR_GITHUB_ORG/$REPO

  gh secret set AWS_SECRET_ACCESS_KEY \
    --body "YOUR_SECRET_ACCESS_KEY" \
    --repo YOUR_GITHUB_ORG/$REPO

  gh secret set AWS_ACCOUNT_ID \
    --body "YOUR_ACCOUNT_ID" \
    --repo YOUR_GITHUB_ORG/$REPO
done
```

To verify secrets are set in a repo:

```bash
gh secret list --repo YOUR_GITHUB_ORG/OrgSession-FE
```

---

## Step 3: Configure GitHub Environments

GitHub Environments provide deployment gates. The `prod` environment requires manual approval before any pipeline deploys to production.

Create environments in **each of the three repositories** (OrgSession-IAC, OrgSession-BE, OrgSession-FE):

1. Go to repository Settings > Environments > New environment
2. Create `dev` with no protection rules
3. Create `prod` and add at least one required reviewer

The deploy workflows reference these environments via `environment: dev` or `environment: prod`. For `prod`, GitHub will pause the workflow and wait for a reviewer to approve before proceeding.

---

## Step 4: Deploy Infrastructure (OrgSession-IAC)

> The IAC pipeline must complete before the BE or FE pipelines run.
> Secrets Manager is populated by Terraform. If the secret does not exist,
> BE and FE deployments will fail with a clear error message.

### 4.1 Push to a feature branch

```bash
cd OrgSession-IAC
git checkout -b feature/initial-infrastructure
git add .
git commit -m "Initial Terraform infrastructure"
git push origin feature/initial-infrastructure
```

### 4.2 Open a PR to `development`

Open a PR from `feature/initial-infrastructure` to `development`. The `terraform-plan.yml` workflow runs automatically:

- Runs `terraform init`, `fmt -check`, `validate`, and `plan` for the dev environment
- Posts the plan output as a collapsible comment on the PR
- Uploads the plan file as a workflow artifact (retained 5 days)

Review the plan. Verify it shows resources to create: VPC, subnets, NAT Gateway, ECR, ALB, ECS cluster and service (with placeholder image), S3 bucket, CloudFront distribution with two origins (S3 and ALB), and Secrets Manager secret.

### 4.3 Merge to `development` (deploys dev)

Merge the PR. The `terraform-apply.yml` workflow runs automatically for the `dev` GitHub Environment and applies all infrastructure.

Provisioning takes 10-15 minutes. CloudFront distributions take the longest.

### 4.4 Promote to `main` (deploys prod)

Open a PR from `development` to `main`. The plan workflow targets the prod environment. After review, merge. The apply workflow pauses at the `prod` GitHub Environment gate and requires your reviewer approval before running.

### 4.5 Verify infrastructure outputs

```bash
cd OrgSession-IAC/environments/dev
terraform init
terraform output
```

Key outputs:
- `cloudfront_domain_name` - the public URL for both frontend and API (`https://<domain>/status`)
- `alb_dns_name` - the internal ALB endpoint (for direct backend testing only)
- `ecr_repository_url` - where Docker images are pushed

### 4.6 What Terraform stores in Secrets Manager

After apply, the secret `orgsession/dev/config` contains:

```json
{
  "api_url":                    "https://<cloudfront-domain>",
  "s3_bucket":                  "orgsession-fe-dev-<account-id>",
  "cloudfront_distribution_id": "EXXXXXXXXXXXX",
  "cloudfront_domain_name":     "<id>.cloudfront.net",
  "ecr_repository_url":         "<account>.dkr.ecr.us-east-1.amazonaws.com/orgsession-be-dev",
  "ecr_repository_name":        "orgsession-be-dev",
  "ecs_cluster_name":           "orgsession-dev",
  "ecs_service_name":           "orgsession-be-dev"
}
```

The BE and FE pipelines read this secret at runtime. No resource names are hardcoded in the workflows.

---

## Step 5: Deploy the Backend (OrgSession-BE)

### 5.1 Push to a feature branch and open a PR

```bash
cd OrgSession-BE
git checkout -b feature/initial-backend
git add .
git commit -m "Initial FastAPI backend"
git push origin feature/initial-backend
```

Open a PR to `development`. The `build.yml` workflow runs:
- pytest test suite
- Docker image build (no push, validates the Dockerfile only)

### 5.2 Merge to `development`

Merge the PR. The `deploy.yml` workflow runs:

1. Verifies `orgsession/dev/config` secret exists in Secrets Manager
2. Reads `ecr_repository_name`, `ecs_cluster_name`, `ecs_service_name` from the secret
3. Builds and pushes the Docker image to ECR tagged with the commit SHA and `latest`
4. Downloads the current ECS task definition
5. Reconstructs the task definition with only the writable fields and replaces the container image
6. Registers the new task definition revision in ECS
7. Calls `aws ecs update-service` with the new task definition ARN
8. Waits for `services-stable` (ECS replaces old tasks with new ones running the FastAPI image)

### 5.3 Verify the backend directly via ALB

```bash
ALB_DNS=$(cd OrgSession-IAC/environments/dev && terraform output -raw alb_dns_name)
curl http://$ALB_DNS/status
```

Expected response:

```json
{
  "app_name": "OrgWide Session Demo",
  "version": "v1",
  "environment": "dev",
  "status": "All systems operational",
  "timestamp": "2026-04-05T10:00:00.123456+00:00"
}
```

Also verify via CloudFront (the path the browser uses):

```bash
CF_DOMAIN=$(cd OrgSession-IAC/environments/dev && terraform output -raw cloudfront_domain_name)
curl https://$CF_DOMAIN/status
```

---

## Step 6: Deploy the Frontend (OrgSession-FE)

### 6.1 Push to a feature branch and open a PR

```bash
cd OrgSession-FE
git checkout -b feature/initial-frontend
git add .
git commit -m "Initial React dashboard"
git push origin feature/initial-frontend
```

Open a PR to `development`. The `build.yml` workflow runs `npm ci` and `vite build` with `VITE_API_URL=http://localhost:8000` as a placeholder to verify the build succeeds without connecting to any real backend.

### 6.2 Merge to `development`

Merge the PR. The `deploy.yml` workflow runs:

1. Reads `api_url`, `s3_bucket`, and `cloudfront_distribution_id` from Secrets Manager
2. Runs `npm ci` for reproducible dependency installation
3. Builds the Vite bundle with `VITE_API_URL` set to `https://<cloudfront-domain>` (the HTTPS CloudFront URL, not the ALB directly)
4. Syncs `dist/` to the S3 bucket using `aws s3 sync --delete`
5. Creates a CloudFront cache invalidation on `/*` so all edge locations serve the new files immediately

### 6.3 Verify the frontend

```bash
CF_DOMAIN=$(cd OrgSession-IAC/environments/dev && terraform output -raw cloudfront_domain_name)
echo "Open in browser: https://$CF_DOMAIN"
```

The dashboard should show:
- App name: OrgWide Session Demo
- Version: v1 (highlighted in blue)
- Environment: dev badge
- Status: All systems operational (pulsing dot)
- Timestamp refreshing every 30 seconds

The browser fetches `https://<cloudfront-domain>/status`. CloudFront routes this request to the ALB (HTTP internally), which forwards it to the ECS Fargate task. The response travels back through CloudFront over HTTPS to the browser. No mixed content, no CORS.

---

## Step 7: Run Locally with Docker Compose

To test the full stack on your machine without any AWS dependencies:

```bash
# From the root OrgSession/ directory
docker compose up
```

| Service | URL |
|---------|-----|
| Backend (FastAPI) | http://localhost:8000/status |
| Frontend (Vite dev server) | http://localhost:5173 |

The frontend container runs the Vite development server with hot reload. The backend container builds from the same Dockerfile used in production. `CORS_ORIGINS` is set to `*` in the compose file so no CORS configuration is needed locally.

On first run, `npm install` runs inside the frontend container (takes 1-2 minutes). A named volume `fe_node_modules` persists `node_modules` so subsequent starts are fast.

Before running `npm run dev` directly on your host (without Docker), create a local environment file:

```bash
cd OrgSession-FE
echo "VITE_API_URL=http://localhost:8000" > .env.local
npm run dev
```

---

## Step 8: Demonstrate the CI/CD Pipeline

### 8.1 Update the backend version

In `OrgSession-BE/app/config.py`, change:

```python
VERSION = "v1"
```

to:

```python
VERSION = "v2"
```

### 8.2 Push the change

```bash
cd OrgSession-BE
git checkout development
git add app/config.py
git commit -m "Bump version to v2"
git push origin development
```

### 8.3 Watch and verify

1. Open the GitHub Actions tab for OrgSession-BE
2. Watch the `Deploy` workflow: build > push > register task definition > update service > wait for stability
3. After the workflow completes, wait 30 seconds for ECS to drain old tasks
4. Refresh `https://<cloudfront-domain>` in the browser
5. The version card shows `v2`

---

## Teardown

Destroy resources in reverse order to avoid dependency errors.

### Destroy dev environment

```bash
cd OrgSession-IAC/environments/dev
terraform init
terraform destroy -var="aws_account_id=YOUR_ACCOUNT_ID"
```

Type `yes` when prompted. Takes 10-15 minutes.

### Destroy prod environment

```bash
cd OrgSession-IAC/environments/prod
terraform init
terraform destroy -var="aws_account_id=YOUR_ACCOUNT_ID"
```

### Remove bootstrap resources

```bash
# Empty and delete the state bucket
aws s3 rm s3://github-session-my-org-terraform-state --recursive
aws s3api delete-bucket --bucket github-session-my-org-terraform-state

# Delete the DynamoDB lock table
aws dynamodb delete-table --table-name github-session-my-org-terraform-locks

# Delete access keys
KEY_IDS=$(aws iam list-access-keys \
  --user-name github-actions-orgsession \
  --query 'AccessKeyMetadata[].AccessKeyId' \
  --output text)
for KEY_ID in $KEY_IDS; do
  aws iam delete-access-key \
    --user-name github-actions-orgsession \
    --access-key-id "$KEY_ID"
done

# Detach policies and delete IAM user
for POLICY_ARN in \
  arn:aws:iam::aws:policy/AmazonECS_FullAccess \
  arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryFullAccess \
  arn:aws:iam::aws:policy/AmazonS3FullAccess \
  arn:aws:iam::aws:policy/CloudFrontFullAccess \
  arn:aws:iam::aws:policy/SecretsManagerReadWrite \
  arn:aws:iam::aws:policy/AmazonVPCFullAccess \
  arn:aws:iam::aws:policy/IAMFullAccess \
  arn:aws:iam::aws:policy/CloudWatchLogsFullAccess \
  arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess; do
  aws iam detach-user-policy \
    --user-name github-actions-orgsession \
    --policy-arn "$POLICY_ARN"
done
aws iam delete-user --user-name github-actions-orgsession
```

---

## Troubleshooting

### AWS credential errors (InvalidClientTokenId or AccessDenied)

Symptom: GitHub Actions fails with `InvalidClientTokenId`, `AccessDenied`, or `Credentials could not be loaded`

Check:
1. All three repos have `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` set: `gh secret list --repo YOUR_ORG/REPO`
2. The IAM user exists: `aws iam get-user --user-name github-actions-orgsession`
3. The access key is active: `aws iam list-access-keys --user-name github-actions-orgsession`
4. All required policies are attached: `aws iam list-attached-user-policies --user-name github-actions-orgsession`
5. Wait 30-60 seconds after creating a new key before using it (IAM propagation delay)

### Secret not found (ResourceNotFoundException)

Symptom: BE or FE deploy fails with `Secrets Manager can't find the specified secret`

The IAC pipeline must run `terraform apply` before BE or FE can deploy. The Secrets Manager secret is created by Terraform. Run the IAC pipeline first and confirm it completed successfully, then re-run the failing pipeline.

### ECS still running placeholder Apache image

Symptom: CloudWatch logs show Apache httpd instead of uvicorn

The placeholder image (`public.ecr.aws/docker/library/httpd:latest`) is set in the ECS task definition by Terraform on first provision. The BE deploy workflow replaces it by registering a new task definition revision. If the deploy workflow has not run yet, or if it failed before the task definition step, ECS will still use the placeholder. Re-run the BE deploy workflow after confirming it completes all steps including `Register new task definition and deploy to ECS`.

### ECS service stuck in deployment

Symptom: The `aws ecs wait services-stable` step times out

Check:
1. CloudWatch Logs group `/ecs/orgsession-be-dev` for container startup errors
2. ECS service events in the AWS console for failed task placement or health check failures
3. ALB target group health: the `/status` endpoint must return HTTP 200 within the configured timeout
4. Security group on ECS tasks: must allow inbound port 8000 from the ALB security group

### Mixed content error in browser

Symptom: Dashboard shows a fetch error, browser console shows `blocked:mixed-content`

This means `VITE_API_URL` was baked into the frontend bundle as an `http://` URL while the frontend is served over HTTPS. The Secrets Manager `api_url` field should be `https://<cloudfront-domain>` (not `http://alb-dns`). This is set correctly by Terraform in `environments/*/main.tf`. If you manually set the secret with an `http://` URL, update it:

```bash
aws secretsmanager put-secret-value \
  --secret-id orgsession/dev/config \
  --secret-string "$(aws secretsmanager get-secret-value \
    --secret-id orgsession/dev/config \
    --query SecretString --output text | \
    jq --arg URL "https://YOUR_CLOUDFRONT_DOMAIN" '.api_url = $URL')"
```

Then re-run the FE deploy pipeline to rebuild the bundle with the corrected URL.

### CloudFront serving stale content

Symptom: Frontend shows old version after a deploy

The deploy workflow creates a `/*` invalidation automatically after every S3 sync. If you need to invalidate manually:

```bash
CF_DIST_ID=$(cd OrgSession-IAC/environments/dev && terraform output -raw cloudfront_distribution_id)
aws cloudfront create-invalidation \
  --distribution-id "$CF_DIST_ID" \
  --paths "/*"
```

### Terraform state lock

Symptom: `Error acquiring the state lock`

```bash
aws dynamodb delete-item \
  --table-name github-session-my-org-terraform-locks \
  --key '{"LockID": {"S": "github-session-my-org-terraform-state/orgsession/dev/terraform.tfstate-md5"}}'
```

Replace the key value with the exact LockID shown in the error message.
