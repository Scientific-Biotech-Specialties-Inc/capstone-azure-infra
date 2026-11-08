# Azure Student Account Rotation Runbook ($100 Credit Renewal)

> **Audience:** DevOps Engineers, Team Leads, and AI Subagents (`@account-rotator`)  
> **Frequency:** Executed whenever an active Azure for Students $100 credit limit is reached or expires.  
> **Automated Subagent Prompt:** For full autonomous execution via an AI agent, use [`docs/ACCOUNT_ROTATION_SUBAGENT_PROMPT.md`](ACCOUNT_ROTATION_SUBAGENT_PROMPT.md) or local subagent [`.agents/agents/account-rotator.md`](../.agents/agents/account-rotator.md).

---

## 1. Overview of Zero-Edit Account Rotation

Because all Azure resource names (`acrName`, `storageAccountName`) are deterministically generated using:
```bicep
uniqueString(subscription().subscriptionId, resourceGroup().id)
```
You **never need to invent new resource names or edit Bicep parameters** when switching to a fresh student subscription.

> [!IMPORTANT]
> **Human-in-the-Loop Protocol for AI Agents:**  
> When an AI subagent executes this runbook, all steps requiring real human action (activating academic benefits, browser device login, updating GitHub organization secrets, and confirming old resource destruction) MUST halt and provide the human with clear, numbered, step-by-step instructions before proceeding.

---

## 2. Pre-Rotation Checklist

Before switching accounts:
1. **Save Existing Database State (Optional):**
   If you have seeded custom test data in the current database, export a quick SQL dump:
   ```powershell
   az containerapp exec -n "shared-mysql" -g "rg-capstone" --command "mysqldump -u root -p<password> --all-databases" > ./backup.sql
   ```
2. **Obtain the Next Student's Account:**
   Ensure the teammate who is providing the next $100 Azure for Students subscription has activated their Azure Student benefit at [azure.microsoft.com/free/students](https://azure.microsoft.com/free/students/).

---

## 3. Account Rotation Execution

### Step 1: Switch Account Session in Azure CLI

Run the automated account switcher:
```powershell
.\scripts\deploy.ps1 -SwitchAccount
```

**Alternative (Device Code / Remote Login):**  
If the student who owns the account is not on your laptop, use device-code authentication so they can approve it from their own browser/phone without sharing their password:
```powershell
.\scripts\deploy.ps1 -SwitchAccount -UseDeviceCode
```
1. CLI outputs: `To sign in, use a web browser to open https://microsoft.com/devicelogin and enter the code XXXXXXXX`.
2. Send the code to your classmate.
3. Once they approve, the CLI logs in and caches their student subscription.

---

### Step 2: Deploy the Target Stack

Deploy the stack to the new subscription in one command:
```powershell
.\scripts\deploy.ps1 -Module core -ScaleMode Serverless
```
> **Tip (ACR Mode Fast Track):** If your images are already built and stored in your Azure Container Registry, append `-SkipBuild` to skip local Docker builds and push:
> ```powershell
> .\scripts\deploy.ps1 -Module core -RegistryMode acr -SkipBuild
> ```

### What Happens Automatically:
1. **Resource Provider Registration:** Checks and registers `Microsoft.App`, `Microsoft.ContainerRegistry`, `Microsoft.OperationalInsights`, and `Microsoft.Storage`.
2. **Environment & Storage Provisioning:** Deploys `main.bicep` with unique resource names derived from the new subscription ID.
3. **Image Ingestion:** Pulls container images from `ghcr.io/scientific-biotech-specialties-inc/` (taking ~2–3 minutes total with zero Docker build time).
4. **App Wiring & Scaling:** Launches the container apps with `minReplicas = 0` (serverless mode).
5. **URL Output:** Prints the new front-door URL (`https://auth-proxy.<env>.<region>.azurecontainerapps.io`).

---

### Step 3: Seed / Restore Data
Run database migrations and seed default credentials in the new subscription:
```powershell
az containerapp exec -n "auth-api" -g "rg-capstone" --command "php artisan migrate --seed"
az containerapp exec -n "serms-api" -g "rg-capstone" --command "php artisan migrate"
```

---

### Step 3b: Update GitHub Organization Secrets (CI/CD)
If the team deploys via GitHub Actions, the maintainer (**@Zanti00**) must update the organization secrets to point to the new subscription:
1. Navigate to: `https://github.com/organizations/Scientific-Biotech-Specialties-Inc/settings/secrets/actions`
2. Update `AZURE_SUBSCRIPTION_ID` to the new subscription ID.
3. Update `AZURE_TENANT_ID` (if switching student tenants).

---

## 4. Post-Rotation Teardown of the Old Subscription

> [!CAUTION]
> **Safety Gate:** Verify that the new deployment front-door is responding with HTTP 200 on all routes before deleting the previous subscription's resources.

Once the new deployment is verified, tear down the expired subscription to prevent any residual resource lock:
```powershell
# Set subscription context to the expired account
az account set --subscription <old-subscription-id>

# Run teardown
.\scripts\teardown.ps1 -Resource rg-capstone
```
