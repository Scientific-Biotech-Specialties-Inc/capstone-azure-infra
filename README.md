# capstone-azure-infra

Infrastructure as Code for deploying the capstone microservices and subgroup systems to **Microsoft Azure Container Apps (ACA)** — optimized for **$100 Azure for Students** subscriptions with **serverless scale-to-zero**, **zero-edit account rotation**, and **per-subgroup self-service deployment (Mode 1)** across the `Scientific-Biotech-Specialties-Inc` GitHub Organization.

```text
README.md                             root
├── AGENTS.md                         AI agent rulebook, axioms, and subagent directives
├── docs/
│   ├── SUBGROUP_DEVELOPER_GUIDE.md   step-by-step developer guide for PRS, CMS, TS, SERMS
│   ├── SUBAGENT_ONBOARDING_PROMPT.md paste-ready AI agent prompt for subgroup push-to-prod onboarding
│   └── ACCOUNT_ROTATION_RUNBOOK.md   runbook for rotating $100 student accounts
├── config/
│   └── deploy.config.json            central non-secret deployment config & subgroup URLs
├── infra/
│   ├── main.bicep                    environment, storage account (Azure Files), optional ACR
│   ├── apps.bicep                    modular orchestrator for all apps
│   └── modules/
│       ├── stores.bicep              shared MySQL, Redis, Postgres, MongoDB with persistent backup mount
│       ├── auth.bicep                auth-proxy (front door), auth-web, auth-api, auth-worker
│       ├── serms.bicep               serms-web, serms-api, serms-worker
│       ├── ocr.bicep                 ocr-api, ocr-worker (KEDA Redis scaler), ocr-ollama
│       ├── prs.bicep                 prs-web, prs-api
│       ├── cms.bicep                 cms-web + 6 CMS backend microservices (0.25 vCPU each)
│       └── ticketing.bicep           ticketing-web, ticketing-gateway
├── scripts/
│   ├── deploy.ps1                    one-command modular deploy, account switch & gateway sync
│   ├── scale.ps1                     fast power switch (Serverless | WarmDemo | SleepAll)
│   └── teardown.ps1                  delete resource group
├── secrets.example.json              → copy to secrets.prod.json (git-ignored)
└── .github/workflows/
    ├── deploy-infra.yml              automated Bicep verification & modular Azure deployment
    ├── publish-ghcr.yml              reusable GHCR container build workflow
    ├── reusable-subgroup-deploy.yml  central reusable workflow for automated subgroup deployment
    └── templates/                    turnkey push-to-prod CI/CD templates (PRS, CMS, TS, Single App)
```

---

## 📖 Documentation Hub

- **For AI Subagents & Orchestrators**: Consult [`AGENTS.md`](./AGENTS.md) for non-negotiable axioms, deterministic naming protocols, Bicep validation gates, and subagent role delegation.
- **For Subgroup Developers (PRS, CMS, Ticketing, SERMS)**: Consult [`docs/SUBGROUP_DEVELOPER_GUIDE.md`](./docs/SUBGROUP_DEVELOPER_GUIDE.md) for container port contracts, shared SSO keys, Mode 1 deployment walkthrough, front-door synchronization (`-SyncProxy`), and **automated push-to-prod GitHub Actions CI/CD**.
- **For Subgroup AI Agents**: Paste [`docs/SUBAGENT_ONBOARDING_PROMPT.md`](./docs/SUBAGENT_ONBOARDING_PROMPT.md) into your agent session to automate push-to-prod onboarding. Maintainer: **@Zanti00**.
- **For Account Rotation ($100 Credit Exhaustion)**: Consult [`docs/ACCOUNT_ROTATION_RUNBOOK.md`](./docs/ACCOUNT_ROTATION_RUNBOOK.md) for zero-edit account rotation steps and device-code remote logins.

---

## Architecture & Subgroup Federation

The primary gateway (`auth-proxy` Nginx reverse proxy) presents a **single unified URL** to panelists and users, while allowing subgroups to deploy either in the **same** subscription or on **their own separate $100 student accounts**:

| Service Path | Subsystem | Target Port | Deployment Option |
|--------------|-----------|-------------|-------------------|
| `/` | **Auth Web** (Vue admin UI / login) | 5000 | In-Cluster (`-Module auth` / `core`) |
| `/api/` | **Auth API** (Laravel REST API) | 8000 | In-Cluster (`-Module auth` / `core`) |
| `/serms/` | **SERMS Web** (Vue frontend) | 80 | In-Cluster (`-Module serms` / `core`) |
| `/api/serms/` | **SERMS API** (Laravel REST API) | 8000 | In-Cluster (`-Module serms` / `core`) |
| — | **OCR Pipeline** (FastAPI, Celery, Ollama) | 8010/11434 | In-Cluster (`-Module ocr` / `core`) |
| `/prs/` & `/api/prs/` | **PRS** (Productivity Report System) | 5003 / 8000 | In-Cluster or Separate Student Account (`-Module prs`) |
| `/cms/` & `/api/(vendor\|contract\|...)` | **CMS** (Contract Management) | 5001 / 8000 | In-Cluster or Separate Student Account (`-Module cms`) |
| `/ticketing/` & `/api/ticketing/` | **Ticketing System** (TS) | 5005 / 80 | In-Cluster or Separate Student Account (`-Module ticketing`) |

---

## 1. Quickstart: Core Deployment

### Prerequisites
1. Azure CLI (`az`) installed
2. Copy `secrets.example.json` → `secrets.prod.json` and populate secrets (shared JWT secret, encryption keys, passwords)

### Deploy Core Stack (Auth + SERMS + OCR + Stores)
```powershell
.\scripts\deploy.ps1 -Module core -ScaleMode Serverless
```
By default, this sets `minReplicas = 0` for all Web/APIs (scaling down when idle to preserve the $100 credit), while databases stay persistent.

---

## 2. Subgroup Self-Service Deployment (Mode 1)

When another subgroup (PRS, CMS, or Ticketing) wants to deploy on **their own $100 Azure for Students account**:

1. They clone `capstone-azure-infra` and place the shared `secrets.prod.json`.
2. They run:
   ```powershell
   az login
   .\scripts\deploy.ps1 -Module prs -ScaleMode Serverless
   # Or for CMS:
   .\scripts\deploy.ps1 -Module cms -ScaleMode Serverless
   # Or for Ticketing:
   .\scripts\deploy.ps1 -Module ticketing -ScaleMode Serverless
   ```
3. The script automatically updates their generated `.azurecontainerapps.io` URLs in `config/deploy.config.json`.
4. Commit/share the updated `config/deploy.config.json` with the maintainer, **@Zanti00**, who runs:
   ```powershell
   .\scripts\deploy.ps1 -SyncProxy
   ```
   In ~15 seconds, the primary front door immediately routes `/prs`, `/cms`, or `/ticketing` to their live containers!

---

## 3. Switching Azure Accounts ($100 Credit Exhaustion)

When an account runs out of the $100 student credit:
```powershell
.\scripts\deploy.ps1 -SwitchAccount
```
- Or if helping a classmate deploy from your machine without knowing their password:
  ```powershell
  .\scripts\deploy.ps1 -SwitchAccount -UseDeviceCode
  ```
Because Azure resource names (`acrName`, `storageAccountName`) are deterministically generated via `uniqueString()`, **you do not need to change any configuration names**. The script automatically registers required resource providers on the new subscription and deploys in minutes.

---

## 4. Power & Cost Management (`scale.ps1`)

Control your running costs instantly without deleting resources:

- **Serverless (Default / Low Burn):**
  ```powershell
  .\scripts\scale.ps1 -Mode Serverless
  ```
  Web & APIs scale to 0 when idle ($0 compute burn). DBs stay at 1.

- **Warm for Demo (10 mins before presentation):**
  ```powershell
  .\scripts\scale.ps1 -Mode WarmDemo
  ```
  Pre-warms all active apps and `ocr-ollama` to `minReplicas: 1` for zero latency and instant response.

- **Sleep All ($0.00/hr burn overnight):**
  ```powershell
  .\scripts\scale.ps1 -Mode SleepAll
  ```
  Scales **every container** (including DBs and Ollama) to 0.

---

## 5. Teardown

To completely wipe resources from an expired student account:
```powershell
.\scripts\teardown.ps1 -Resource rg-capstone
```