# Subgroup Developer & Subagent Integration Guide

> **Audience:** Developers and AI subagents working on **PRS**, **CMS (CRMS)**, **Ticketing (TS)**, and **SERMS** in the `Scientific-Biotech-Specialties-Inc` GitHub Organization.  
> **Purpose:** Step-by-step procedures to containerize, deploy to Azure using a **$100 Azure for Students** subscription, and federate into the central front-door gateway (`auth-proxy`).

---

## 1. Subgroup Port & Routing Contract

All external client traffic passes through the central reverse proxy (`auth-proxy`). Your microservices must expose standard internal container ports matching the gateway configuration:

| Subgroup | Service | Container Port | Protocol | Public Gateway Route | Purpose |
|:---|:---|:---:|:---:|:---|:---|
| **Central Auth** | `auth-web` | `5000` | HTTP | `/` | Vue 3 SSO Login & Administration UI |
| | `auth-api` | `8000` | HTTP | `/api/` | Laravel 13 OAuth2 / Passport API |
| **SERMS** | `serms-web` | `80` | HTTP | `/serms/` | Static Vue 3 SPA |
| | `serms-api` | `8000` | HTTP | `/api/serms/` | Laravel 11 REST API |
| **PRS** | `prs-web` | `5003` | HTTP | `/prs/` | Vue 3 Productivity SPA |
| | `prs-api` | `8000` | HTTP | `/api/prs/` | Laravel API (Metrics, Reports) |
| **CMS (CRMS)** | `cms-web` | `5001` | HTTP | `/cms/` | Vue 3 Contract Management SPA |
| | `vendor-management` | `8000` | HTTP | `/api/vendor/` | Vendor microservice |
| | `contract-management`| `8000` | HTTP | `/api/contract/` | Contract microservice |
| | `search` | `8000` | HTTP | `/api/search/` | Search microservice |
| | `notification` | `8000` | HTTP | `/api/notification/` | Notification microservice |
| | `ai-service` | `8000` | HTTP | `/api/ai/` | AI analytics microservice |
| | `analytics-service` | `8000` | HTTP | `/api/analytics/` | Reporting microservice |
| **Ticketing (TS)**| `ticketing-web` | `5005` | HTTP | `/ticketing/` | Support ticket UI |
| | `ticketing-gateway` | `80` | HTTP | `/api/ticketing/`, `/storage/` | Ticketing API gateway & storage |

---

## 2. Shared Secrets & Single Sign-On (SSO) Contract

Because all subsystems rely on the central `auth-service` for OAuth2 authentication, every subgroup's backend service MUST share the exact same cryptographic keys:

1. **`JWT_SECRET`**: Used by downstream APIs to verify session JWT tokens issued by `auth-service`.
2. **`INTERNAL_ENCRYPTION_KEY`**: 32-character AES-256 key used for decrypting sensitive inter-service communication and encrypted form requests.
3. **`INTERNAL_SERVICE_SECRET`**: Shared header secret (`X-Internal-Secret`) for trusted service-to-service calls.

> [!IMPORTANT]
> Obtain these shared secrets from the lead maintainer via `secrets.prod.json`. Never change or commit them to Git.

---

## 3. How to Deploy Your Subgroup (Mode 1 Self-Service)

Each subgroup can use **their own team member's $100 Azure for Students credit** and **their own regional quota**.

### Step 1: Clone the Infrastructure Repository
```powershell
git clone https://github.com/Scientific-Biotech-Specialties-Inc/capstone-azure-infra.git
cd capstone-azure-infra
```

### Step 2: Configure Secrets
Copy `secrets.example.json` to `secrets.prod.json` and paste the shared keys:
```powershell
copy secrets.example.json secrets.prod.json
```

### Step 3: Log in to Your Azure Student Account
```powershell
az login
```
*(If deploying from a machine without a web browser, run `az login --use-device-code` and approve on your phone).*

### Step 4: Run the Deployment Script for Your Module
Run the deployment command corresponding to your subgroup:

- **For PRS:**
  ```powershell
  .\scripts\deploy.ps1 -Module prs -ScaleMode Serverless
  ```
- **For CMS:**
  ```powershell
  .\scripts\deploy.ps1 -Module cms -ScaleMode Serverless
  ```
- **For Ticketing:**
  ```powershell
  .\scripts\deploy.ps1 -Module ticketing -ScaleMode Serverless
  ```

### What the Script Does Automatically:
1. Registers Azure resource providers (`Microsoft.App`, `Microsoft.Storage`, etc.) if this is a fresh student account.
2. Creates your resource group (`rg-capstone`) and ACA Managed Environment.
3. Provisions all containers for your subgroup with **Serverless scaling** (`minReplicas = 0`, scaling to zero when idle).
4. Auto-detects your live `.azurecontainerapps.io` URLs and writes them into [`config/deploy.config.json`](file:///c:/Projects/capstone-azure-infra/config/deploy.config.json).

---

## 4. Connecting Your Deployment to the Front Door

Once your deployment completes, the script prints your live URLs and updates `config/deploy.config.json`:

```json
"prs": {
  "mode": "external",
  "webUrl": "https://prs-web.capstone-env.eastus.azurecontainerapps.io",
  "apiUrl": "https://prs-api.capstone-env.eastus.azurecontainerapps.io"
}
```

### Step 1: Share Your Endpoints
Commit and push your updated `config/deploy.config.json` to the repo (or send your URLs to the central DevOps maintainer).

### Step 2: Sync the Front Door
The central maintainer (or anyone with access to the core account) runs:
```powershell
.\scripts\deploy.ps1 -SyncProxy
```
Within **~15 seconds**, the central `auth-proxy` begins routing `/prs/`, `/cms/`, or `/ticketing/` traffic directly to your subgroup's containers!

---

## 5. Dockerfile & Frontend Packaging Guardrails

When building Docker images for your subgroup, follow these guidelines to prevent deployment failures:

### Frontend SPAs (Vue / React / Vite):
1. **Never Hardcode Domain Names at Build Time**:
   - Because your app lives at `/prs/`, `/cms/`, or `/ticketing/`, set `base: '/<subgroup>/'` in your `vite.config.ts`.
   - Use relative API paths (e.g., `/api/prs` or `/api/vendor`) instead of hardcoding `https://*.azurecontainerapps.io` so requests naturally route through the front door.
2. **Nginx Ingress**:
   - Serve static frontend bundles using `nginx:1.27-alpine` on port `80` (or `5000+`).
   - Include a fallback rule for SPA history mode: `try_files $uri $uri/ /index.html;`.

### Backend APIs (Laravel / FastAPI / Node):
1. **Migrations on Startup**:
   - Ensure your entrypoint script runs database migrations on boot (e.g., `php artisan migrate --force`).
2. **Health Check Endpoint**:
   - Provide a fast `/up` or `/healthz` HTTP endpoint responding with HTTP 200 so Azure Container Apps detects readiness quickly.
3. **Cookie / Token Authentication**:
   - Read the incoming `Authorization: Bearer <token>` header or `access_token` cookie forwarded by `auth-proxy`.

---

## 6. Power & Cost Management for Subgroups

To ensure you don't burn through your $100 student allowance:

- **Idle / Development (Recommended):**
  ```powershell
  .\scripts\scale.ps1 -Mode Serverless
  ```
  Scales your apps to 0 replicas when there is no incoming traffic.
- **Before Presentations & Testing:**
  ```powershell
  .\scripts\scale.ps1 -Mode WarmDemo
  ```
  Pre-warms your apps to 1 replica so panelists experience zero cold-start delay.
- **Overnight Hibernation ($0.00/hr burn):**
  ```powershell
  .\scripts\scale.ps1 -Mode SleepAll
  ```
  Scales every container to 0.

---

## 7. Troubleshooting Common Issues

### Issue 1: "Subgroup service is currently unavailable or offline" (503 Error)
- **Cause:** Your container app has scaled to 0 and is waking up, or your URL in `config/deploy.config.json` is incorrect.
- **Resolution:** Wait 5 seconds for ACA cold start. Check that your container app is running with `az containerapp list -g rg-capstone -o table`.

### Issue 2: Cross-Account TLS / SSL Handshake Error (502 Bad Gateway)
- **Cause:** Azure Container Apps ingress requires Server Name Indication (SNI).
- **Resolution:** Verified fixed in `deploy/nginx.conf.tpl` via `proxy_ssl_server_name on;`. Ensure your external URL begins with `https://`.

### Issue 3: Missing Database Tables after Restart
- **Cause:** Database containers run with ephemeral storage unless backed up.
- **Resolution:** Ensure migrations run in your API entrypoint, or use the Azure Files storage share mounted at `/backups` to persist data.
