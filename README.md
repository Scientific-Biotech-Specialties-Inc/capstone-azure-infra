# capstone-azure-infra

Infrastructure as Code for deploying the **three capstone microservices** to
**Microsoft Azure Container Apps** — budget-oriented for Azure for Students
credits, a short-lived presentation, and ephemeral data.

Deploys **SERMS** (`smart-expense-management-system`), **capstone-auth-module**
(the reverse-proxy front door), and **ocr-pipeline** (OCR + local LLM).
**PRS / CMS / TS are not deployed** — their auth-proxy routes return 503.

```
README                             root
├── infra/
│   ├── main.bicep                 ACR + Managed Environment
│   ├── apps.bicep                 14 container apps + secret wiring
│   └── parameters.prod.json       non-secret config
├── containers/mysql/              pre-builds the shared MySQL (capstone_auth DB)
├── scripts/
│   ├── deploy.ps1                 one-command deploy
│   └── teardown.ps1               delete everything
├── secrets.example.json           → copy to secrets.prod.json (git-ignored)
└── .github/workflows/             optional CI deploy
```

## Architecture

All apps live in **one** ACA Managed Environment (Consumption tier).

| App | Runs | Port |
|-----|------|------|
| `auth-proxy` | nginx **front door** — routes `/`, `/serms`, `/api/serms`, `/api` | 5173 |
| `auth-web` | auth module Vue login/admin UI | 5000 |
| `auth-api` / `auth-worker` | capstone Laravel API + Redis queue | 8000 |
| `serms-web` | static Vue bundle served by nginx | 80 |
| `serms-api` / `serms-worker` | SERMS Laravel API + DB-backed queue | 8000 |
| `ocr-api` / `ocr-worker` | FastAPI + Celery/Tesseract | 8010 |
| `ocr-ollama` | qwen2.5:1.5b local LLM (demo highlight) | 11434 |
| `shared-mysql` / `shared-redis` / `shared-postgres` / `shared-mongo` | stores (ephemeral) | 3306/6379/5432/27017 |

Front door URL after deploy:

- SERMS app: `https://auth-proxy.<env>.<region>.azurecontainerapps.io/serms`
- Auth admin: `https://auth-proxy.<env>.<region>.azurecontainerapps.io`

## Cost posture

- No Front Door / App Gateway / managed DBs / Key Vault.
- ACA free-tier compute allowance; scale-to-zero via `-MinReplicas 0`.
- Data stores are **ephemeral** — a redeploy/scale-down loses data (accepted
  for a short presentation).
- Always **tear down** after presenting.

## One-command deploy (recommended)

1. Install Azure CLI → `az login`
2. Copy `secrets.example.json` → `secrets.prod.json` and fill in real values
   (JWT secret, 32-char `internalEncryptionKey`, APP_KEYs, DB passwords,
   Supabase keys, shared AI callback key). This file is git-ignored.
3. Ensure the sibling app repos already have their deploy artifacts:
   - `smart-expense-management-system/apps/web/Dockerfile.prod`
   - `capstone-auth-module/deploy/nginx.Dockerfile`
   - `ocr-pipeline/Dockerfile.ollama`
4. Run:
   ```powershell
   .\scripts\deploy.ps1
   ```

The script creates the RG, ACR + environment, builds & pushes all 8 images with
`az acr build` (no local Docker needed), deploys the 14 apps, and prints the
front-door URL.

## Validate Bicep (before pushing)
```powershell
az bicep build -f infra/apps.bicep
az bicep build -f infra/main.bicep
```

## Teardown (critical — spend control)
```powershell
.\scripts\teardown.ps1 -Resource rg-capstone
```

## Troubleshooting

- **Ollama slow first call / model pull** — the ~1 GB model downloads on first
  start. Keep `ocr-ollama` at `minReplicas 1` and run a warm-up OCR **before**
  presenting.
- **Stores share public ingress** (no private VNet on the free tier) — random
  names + immediate teardown mitigates risk. Post-demo hardening = managed DBs
  private VNet.
- **Migrations** — SERMS runs `migrate` at API boot; the worker is overridden to
  `queue:work` and does not migrate. If you see duplicate-migration errors,
  delete the RG and redeploy.