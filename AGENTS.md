# AGENTS.md

> **Repository:** `capstone-azure-infra`  
> **Organization:** `Scientific-Biotech-Specialties-Inc`  
> **Role:** Central Infrastructure as Code (IaC) & Cloud Orchestration  
> **Target Cloud:** Microsoft Azure Container Apps (ACA) — Consumption Tier ($100 Azure for Students)

---

## 🤖 AI Agent Context & Ecosystem Overview

This repository is the central cloud infrastructure authority for the entire capstone microservices ecosystem. It orchestrates deployments across multiple **$100 Azure for Students** subscriptions and connects **5 subsystem groups** into a unified front-door domain:

| Subsystem | Components | In-Cluster Port | Gateway Route | Default Owner / Subgroup |
|:---|:---|:---|:---|:---|
| **Auth Module** | `auth-proxy` (Nginx), `auth-web` (Vue 3), `auth-api` (Laravel 13), `auth-worker` | 5173 / 5000 / 8000 | `/`, `/api/` | Central Auth Team |
| **SERMS** | `serms-web` (Vue 3), `serms-api` (Laravel), `serms-worker` | 80 / 8000 | `/serms/`, `/api/serms/` | Expense Management Team |
| **OCR Pipeline** | `ocr-api` (FastAPI), `ocr-worker` (Celery), `ocr-ollama` (Qwen 2.5:1.5b) | 8010 / 11434 | Internal AI Callback | AI & OCR Team |
| **PRS** | `prs-web` (Vue), `prs-api` (Laravel) | 5003 / 8000 | `/prs/`, `/api/prs/` | Productivity Report Team |
| **CMS (CRMS)** | `cms-web` + 6 Microservices (vendor, contract, search, notification, ai, analytics) | 5001 / 8000 | `/cms/`, `/api/<service>/` | Contract Management Team |
| **TS (Ticketing)** | `ticketing-web`, `ticketing-gateway` | 5005 / 80 | `/ticketing/`, `/api/ticketing/` | Helpdesk / Ticketing Team |

---

## ⚠️ Non-Negotiable Directives for AI Agents

All primary agents, subagents, and AI models modifying or operating on this repository must strictly adhere to the following axioms:

### 1. Deterministic Naming (Axiom A-06 & Account Rotation)
- **NEVER hardcode globally unique Azure resource names** (such as Azure Container Registry or Storage Accounts) in `.bicep` or `.json` parameter files.
- All global resources MUST use the deterministic pattern:
  - `acrName = 'capacr${uniqueString(subscription().subscriptionId, resourceGroup().id)}'`
  - `storageAccountName = 'capst${uniqueString(subscription().subscriptionId, resourceGroup().id)}'`
- This guarantees zero-conflict, zero-configuration redeployment when switching between student subscriptions.

### 2. Zero Secret Exposure & Trust Boundaries (Axiom A-02)
- Secrets MUST NEVER be committed to Git. All secrets reside exclusively in `secrets.prod.json` (git-ignored) or CI/CD repository secrets.
- In Bicep files, all credentials MUST be decorated with `@secure()` and passed as environment variables or Container App secret references.
- All inter-container internal traffic is bound to ACA managed environment internal ingress (`external: false`) wherever possible.

### 3. Serverless Scaling & Resource Quotas
- Student subscriptions are subject to regional quotas (~4 to 10 vCPUs and ~15 to 30 apps per environment).
- Container Apps MUST adhere to the following resource sizing constraints:
  - Web & lightweight APIs: `cpu: json('0.25')`, `memory: '0.5Gi'`, `minReplicas: 0`, HTTP scale rules.
  - Laravel / FastAPI APIs: `cpu: json('0.5')`, `memory: '1.0Gi'`, `minReplicas: 0`.
  - Machine learning / Ollama: `cpu: json('1.0')`, `memory: '2.0Gi'`.
  - Background workers (`auth-worker`, `ocr-worker`): KEDA Redis scale rules watching active queue lists so they scale to 0 when idle.
  - Databases (`shared-mysql`, `shared-postgres`, `shared-mongo`): Keep `minReplicas: 1` during active sessions or mount `/backups` persistent Azure Files shares before hibernating.

### 4. Cross-Subscription Reverse Proxying (SNI Enforcement)
- When proxying traffic to external student subscriptions, Nginx MUST include:
  ```nginx
  proxy_ssl_server_name on;
  proxy_ssl_protocols TLSv1.2 TLSv1.3;
  ```
  Without `proxy_ssl_server_name on;`, Azure Container Apps will reject cross-account TLS connections with `502 Bad Gateway`.
- Always preserve `Authorization: Bearer $cookie_access_token` and `X-Forwarded-*` headers to ensure Single Sign-On (SSO) works across different subgroup subscriptions.

### 5. Mandatory Verification Gate
- Before proposing or merging any changes to Bicep templates, agents MUST run:
  ```powershell
  az bicep build -f infra/main.bicep
  az bicep build -f infra/apps.bicep
  az bicep build -f infra/modules/<modified-module>.bicep
  ```
  All templates must compile with **0 errors and 0 diagnostics**.

### 6. Explicit Consent for Git Operations (Axiom A-11)
- Never commit, push, create PRs, or modify Git branch states without explicit user authorization. Unstaged diffs belong to the developer.

---

## 🛠️ Subagent Delegation Protocol

When coordinating infrastructure tasks, route actions to specialized subagent roles:

- **`@cloud-architect`**: Bicep module topology, cross-account routing, managed environment configuration, and Azure Files storage attachments.
- **`@devops-engineer`**: PowerShell deployment workflows (`deploy.ps1`, `scale.ps1`), GitHub Actions CI/CD pipelines (`deploy-infra.yml`, `publish-ghcr.yml`), and container image registry coordination.
- **`@security-auditor`**: Secret audits, RBAC definitions, ingress exposure verification, and Nginx reverse proxy hardening (`php2shell` multipart request filtering).
- **`@reviewer`**: Reusability audits (Axiom A-09), Bicep compilation verification, and quota usage checks against Azure for Students limits.

---

## 📂 Key Architecture Files

- [`config/deploy.config.json`](file:///c:/Projects/capstone-azure-infra/config/deploy.config.json): Master non-secret configuration (registry mode, active modules, subgroup upstream URLs).
- [`infra/main.bicep`](file:///c:/Projects/capstone-azure-infra/infra/main.bicep): Core infrastructure (Log Analytics, Managed Environment, Storage Account, ACR).
- [`infra/apps.bicep`](file:///c:/Projects/capstone-azure-infra/infra/apps.bicep): Top-level modular orchestrator.
- [`infra/modules/`](file:///c:/Projects/capstone-azure-infra/infra/modules): Individual subsystem Bicep modules (`stores`, `auth`, `serms`, `ocr`, `prs`, `cms`, `ticketing`).
- [`scripts/deploy.ps1`](file:///c:/Projects/capstone-azure-infra/scripts/deploy.ps1): One-command deployment, account switcher, and gateway sync script.
- [`scripts/scale.ps1`](file:///c:/Projects/capstone-azure-infra/scripts/scale.ps1): Instant power state manager (`Serverless`, `WarmDemo`, `SleepAll`).
- [`docs/SUBGROUP_DEVELOPER_GUIDE.md`](file:///c:/Projects/capstone-azure-infra/docs/SUBGROUP_DEVELOPER_GUIDE.md): Developer guide for subgroup teams to deploy and integrate their microservices.
