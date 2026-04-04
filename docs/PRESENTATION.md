# Presentation Walkthrough: OrgSession CI/CD POC

## Audience

Senior engineers, architects, and technical leads evaluating CI/CD patterns for AWS-based workloads.

---

## 1. Architecture Overview

### System Diagram

```
Developer Workstation
        |
        | git push / pull request
        v
GitHub (3 Repositories)
  |               |                |
  v               v                v
OrgSession-IAC  OrgSession-BE   OrgSession-FE
(Terraform)     (FastAPI)       (React/Vite)
  |               |                |
  v               v                v
GitHub Actions  GitHub Actions  GitHub Actions
  |               |                |
  v               v                v
AWS Infrastructure  ECR -> ECS    S3 + CloudFront
  |                 Fargate         |
  |                   |             |
  +-----> ALB <-------+    <--------+
           |
           v
    /status endpoint
```

### Component Responsibilities

**OrgSession-IAC** defines all AWS infrastructure as Terraform code. It is the source of truth for every cloud resource. Changes to infrastructure go through the same PR review and pipeline as application code.

**OrgSession-BE** contains a minimal FastAPI service with a single `/status` endpoint. It is containerized with Docker and deployed to ECS Fargate behind an Application Load Balancer.

**OrgSession-FE** contains a React/Vite single-page application. It calls the backend API and renders the response in a dashboard. It is deployed as a static site to S3, served globally through CloudFront.

**AWS Secrets Manager** holds the backend ALB URL. The frontend CI/CD pipeline reads it at build time so the API URL is compiled into the static bundle without being hardcoded in source control.

---

## 2. CI/CD Workflow Explanation

### Branch and Environment Convention

All three repositories share the same convention: the `development` branch deploys to the dev environment, and the `main` branch deploys to prod. This makes the relationship between code state and deployed state immediately readable from the branch name.

PRs to `development` trigger validation against dev. PRs to `main` trigger validation against prod. The promotion path for any change is: feature branch -> PR to `development` -> merge -> PR to `main` -> merge with required reviewer approval.

### Infrastructure Pipeline (OrgSession-IAC)

**Pull Request trigger:**

When a developer opens a PR, GitHub Actions inspects the target branch (`github.base_ref`) to determine which environment to plan. A PR to `development` plans the dev environment; a PR to `main` plans prod. The plan output is posted as a comment on the PR, making infrastructure changes visible to reviewers before any resource is modified.

**Merge trigger:**

On merge to `development`, `terraform apply` runs for dev automatically using the `dev` GitHub Environment. On merge to `main`, it runs for prod using the `prod` GitHub Environment -- which has a required reviewer configured, requiring a human to approve before Terraform touches production resources.

### Backend Pipeline (OrgSession-BE)

**Pull Request trigger:**

A PR to `development` or `main` triggers the `PR Checks` workflow, which runs the pytest suite and verifies the Docker image builds successfully. No deployment occurs on a PR.

**Merge trigger:**

On merge, the `Deploy Backend` workflow reads the target environment from the branch name. It then fetches the ECR repository name, ECS cluster, and ECS service from Secrets Manager (`orgsession/dev/config` or `orgsession/prod/config`). This means the workflow contains no hardcoded resource names -- all deployment targets are resolved at runtime from the infrastructure's own configuration store.

The pipeline runs tests first, then builds a Docker image, pushes it to ECR with two tags (the git commit SHA and `latest`), and triggers an ECS service update.

The SHA tag creates an audit trail: you can look at any running ECS task and trace it to a specific git commit. The `latest` tag is used for convenience when forcing a redeployment with `--force-new-deployment`.

After triggering the deployment, the workflow runs `aws ecs wait services-stable`, which polls the ECS service until all tasks have started successfully or the timeout is reached. This makes the pipeline fail fast if the new container crashes on startup.

### Frontend Pipeline (OrgSession-FE)

**Pull Request trigger:**

A PR to `development` or `main` triggers the `PR Checks` workflow, which runs `npm ci` and `npm run build` with a placeholder API URL. This verifies the build toolchain and all imports resolve correctly without connecting to any real backend.

**Merge trigger:**

On merge, the `Deploy Frontend` workflow reads three values from Secrets Manager: the API URL, the S3 bucket name, and the CloudFront distribution ID. These were written there by Terraform during infrastructure provisioning. The pipeline reads the backend API URL from Secrets Manager, runs `npm ci` (reproducible installs), builds the Vite bundle with the API URL baked in as an environment variable, syncs the output to S3, and invalidates the CloudFront distribution cache.

The CloudFront invalidation is critical. Without it, users on edge nodes that have cached the old `index.html` would continue to see the previous version until the TTL expires. The `/*` invalidation forces all edge locations to fetch fresh content on the next request.

---

## 3. Key Technical Decisions and Trade-offs

### Terraform Wrapper Pattern vs Workspaces

**Decision:** Directory-based environment separation (`environments/dev`, `environments/prod`) rather than Terraform workspaces.

**Reasoning:**

Terraform workspaces share a single configuration and vary behavior through workspace-specific variable files. The wrapper pattern uses separate directory trees that each call shared modules with environment-specific values.

Workspaces are convenient for small differences between environments (a replica count, an instance size). They become fragile when environments diverge structurally, when you need to run operations on one environment without touching another, or when you want to review the exact plan for a specific environment without switching context.

The wrapper pattern makes the state isolation explicit (each directory has its own backend config, its own state key), makes environment-specific customization explicit in the module call arguments, and makes it impossible to accidentally apply to the wrong environment.

**Trade-off:** More file duplication. The `prod` directory is almost identical to `dev`. This is acceptable because the duplication is in configuration (values), not in logic (which lives in modules).

### AWS Authentication: IAM User Access Keys

**Decision:** GitHub Actions authenticates to AWS using a dedicated IAM user with static access keys stored as GitHub repository secrets.

**Reasoning:**

This is the most straightforward approach for a POC and is universally supported across all GitHub plans and AWS account types. A dedicated IAM user (`github-actions-orgsession`) is created with only the policies required for the deployment workflows. The access key ID and secret are stored as GitHub secrets, which are encrypted at rest and masked in workflow logs.

**Trade-off:** Access keys are long-lived credentials that must be rotated periodically and revoked if a repository is compromised. The production hardening path is to replace this with OIDC, which eliminates the static secret entirely by issuing short-lived credentials per workflow run. For this POC, access keys are the right balance of simplicity and control.

**Rotation procedure:** To rotate the key, create a new access key for the IAM user, update the GitHub secrets in all three repos, then delete the old key. This can be scripted and automated on a schedule.

### ECS Fargate vs EC2 vs Lambda

**Decision:** ECS Fargate for the backend service.

**Reasoning:**

EC2 requires managing the underlying instances (patching, capacity planning, AMI selection). For a container workload, this is unnecessary operational overhead.

Lambda is a strong choice for stateless HTTP functions, but FastAPI with uvicorn is a persistent HTTP server. While Lambda does support containerized workloads, the cold start behavior and execution model differences make it a poor fit for a service that needs consistent sub-100ms response times.

Fargate runs the container without managing servers. You define CPU and memory, Fargate handles the rest. The ECS service handles health checking, rolling deployments, and task replacement.

**Trade-off:** Higher baseline cost than Lambda for low-traffic workloads. A Fargate task with 256 CPU / 512 MiB running continuously costs approximately $9/month. A Lambda that only runs when called costs fractions of a cent for low traffic.

### S3 + CloudFront vs Amplify vs App Runner

**Decision:** S3 with CloudFront for the frontend.

**Reasoning:**

AWS Amplify hosting automates much of this, but it is a higher-level abstraction that obscures the underlying components. For a POC demonstrating how CI/CD and infrastructure work, showing the explicit components (S3 bucket, OAC policy, CloudFront distribution) is more educational and more representative of how production frontend infrastructure is actually built.

App Runner is designed for containerized applications, not static sites.

S3 + CloudFront is the industry standard for serving static sites at scale. It is globally distributed, highly available, and requires no server management.

**Trade-off:** More Terraform and more workflow steps compared to Amplify. The operational model is explicit but verbose.

### Container Image Tagging Strategy

**Decision:** Tag images with both the git commit SHA and `latest`.

**Reasoning:**

The SHA tag is immutable and traceable. If you look at a running ECS task, you can read the image tag and find the exact commit that produced it. This is essential for debugging production issues.

The `latest` tag enables `--force-new-deployment` to work. ECS uses `latest` when you want to re-pull the current image without creating a new task definition revision.

For a more robust production pipeline, you would: register a new task definition revision with the SHA-tagged image explicitly, update the service to use that revision, and retain previous revisions for rollback. This POC uses `force-new-deployment` for simplicity.

---

## 4. Demo Flow and Narrative

### Setup context

"We have three repositories. One for infrastructure, one for the backend service, and one for the frontend. Each deploys independently through its own pipeline. Changes to infrastructure go through a review process identical to code review."

### Show the running system

"The frontend is running at this CloudFront URL. It calls our FastAPI backend through an Application Load Balancer. All of this was provisioned by Terraform and deployed by GitHub Actions."

Point to: app name, version badge (v1), environment badge (dev), status indicator, timestamp updating.

### Show the pipeline trigger

Open `OrgSession-BE/app/config.py`. Change `VERSION = "v1"` to `VERSION = "v2"`.

"I am going to make a single-line change to the backend: bump the version to v2. I will commit and push directly to main."

```bash
git add app/config.py
git commit -m "Bump version to v2"
git push origin main
```

### Walk through the pipeline stages

In GitHub Actions, show the running workflow:

1. "Tests run first. No deployment happens if tests fail."
2. "Docker builds the image, tags it with the commit SHA and latest, and pushes to ECR."
3. "ECS receives the force-new-deployment signal. It pulls the new image and starts replacement tasks."
4. "The pipeline waits for ECS to stabilize before declaring success."

### Show the result

After the workflow completes (~3-4 minutes), refresh the frontend dashboard.

"The version card now shows v2. The entire change from commit to live went through an automated pipeline. No manual steps on any server. No SSH. No manual Docker commands. The infrastructure is unchanged. Only the application layer updated."

### Show the infrastructure gate

"If I had made a change to Terraform instead, the pipeline would have run plan, posted the plan to the PR as a comment, and waited for code review before applying. Production would have required an additional human approval step."

---

## 5. Common Questions and Responses

**Q: How do you handle secrets in the application?**

A: There are two layers. GitHub Actions uses static IAM access keys stored as GitHub secrets -- these are encrypted, masked in logs, and scoped to a dedicated IAM user. Application configuration (API URL, S3 bucket name, ECS service name) is stored in AWS Secrets Manager by Terraform after provisioning. Workflows read these values at runtime so no resource names are hardcoded in workflow files. The backend reads its configuration through environment variables injected by ECS at container startup. No secrets appear in source code.

**Q: How do you roll back a bad deployment?**

A: For the backend, ECS keeps the previous task definition revision. You can roll back by running `aws ecs update-service` pointing to the previous revision, or by reverting the commit and letting the pipeline redeploy. For the frontend, S3 bucket versioning is enabled, so you can restore previous objects. CloudFront can be pointed at a different S3 path or object version.

**Q: How would you make this production-ready?**

A: Several hardening steps beyond this POC: add HTTPS with ACM certificates on the ALB and a custom domain on CloudFront; add WAF rules on CloudFront and the ALB; implement ECS auto-scaling based on ALB request count; add a blue/green deployment strategy using CodeDeploy with ECS to enable zero-downtime deploys with automated rollback on health check failure; add structured logging and metrics to CloudWatch; set up alerting on ECS task failure and ALB 5xx rate; move the GitHub Actions role to least-privilege with a scoped policy instead of managed admin policies.

**Q: Why not use AWS CodePipeline instead of GitHub Actions?**

A: GitHub Actions colocates the pipeline definition with the code in the same repository. Developers see the workflow file when they review code, which makes it easy to understand what happens when a change merges. CodePipeline is a strong choice when you need deep AWS service integrations or are operating in an environment where keeping everything inside AWS is a compliance requirement. For a cross-org CI/CD standard, GitHub Actions tends to be more portable and familiar to engineers coming from different cloud backgrounds.

**Q: How do dev and prod share the same ECR repository?**

A: They do not. Each environment has its own ECR repository: `orgsession-be-dev` and `orgsession-be-prod`. The backend CI/CD workflow targets `orgsession-be-dev` when deploying to the dev ECS cluster. A separate workflow job or a parameterized workflow would target `orgsession-be-prod` for the production deployment. This isolation ensures a dev image push cannot accidentally affect the production service.

**Q: What does the Terraform wrapper pattern protect against?**

A: It prevents the most common Terraform production incident: running `terraform apply` in the wrong environment. With workspaces, switching environments is a `terraform workspace select` command, which is easy to forget or mistype. With directory-based separation, you must physically change to the correct directory. The state keys are different, the variable files are different, and the backend configuration is separate. There is no single command that can accidentally apply a dev change to prod.

---

## 6. Cost Estimate (dev environment, us-east-1, 30 days)

| Resource | Approximate Monthly Cost |
|----------|--------------------------|
| NAT Gateway (1) | $32 |
| Application Load Balancer | $16 |
| ECS Fargate (256 CPU / 512 MiB, always on) | $9 |
| ECR (storage, minimal) | $1 |
| CloudFront (free tier, low traffic) | $0 |
| S3 (static site, minimal) | $1 |
| Secrets Manager (1 secret) | $0.40 |
| CloudWatch Logs | $1 |
| **Total** | **~$60/month** |

The NAT Gateway is the largest cost item. For a short-lived POC, you can eliminate it by placing ECS tasks in public subnets with `assign_public_ip = true`. This trades a minor security boundary for $32/month in savings. For any real workload, keep ECS in private subnets.

---

## 7. Production Hardening Roadmap

The following items are out of scope for this POC but represent the path to production readiness:

1. **HTTPS everywhere**: ACM certificate on ALB, custom domain on CloudFront with ACM certificate
2. **Custom domains**: Route 53 hosted zone, ALB alias record, CloudFront CNAME
3. **WAF**: AWS WAF on CloudFront and ALB with managed rule groups for OWASP Top 10
4. **Blue/green deployments**: CodeDeploy + ECS for zero-downtime deploys with automatic rollback
5. **Auto-scaling**: ECS service auto-scaling based on ALB RequestCountPerTarget
6. **Multi-AZ redundancy**: Increase ECS desired count to at least 2, spread across AZs
7. **Centralized logging**: Structured JSON logs from FastAPI, aggregated in CloudWatch
8. **Alerting**: CloudWatch Alarms on ALB 5xx rate, ECS task failure count, and target response time
9. **Container image scanning**: Enable ECR scan-on-push and fail CI if critical vulnerabilities are found
10. **Least-privilege IAM**: Replace managed policies on the GitHub Actions role with a scoped custom policy
11. **Multi-region**: Route 53 latency-based routing with ECS clusters in two regions
