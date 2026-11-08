# Subagent Onboarding Prompt — Subgroup → Central Azure Production

> **Audience:** PRS, CMS (CRMS), and Ticketing (TS) developers who use an AI coding agent (Antigravity, Claude Code, Cursor, Copilot, Cline, Windsurf, OpenCode).
> **Maintainer:** **@Zanti00**: owns `capstone-azure-infra`, the central Azure subscription, and the organization secrets. Every "ask the maintainer" step below means **@Zanti00**.

## How to use

1. Open **your subgroup's repository** (already transferred to `Scientific-Biotech-Specialties-Inc`) in your AI agent.
2. Copy **everything inside the code block below** and paste it as one message.
3. Answer the agent's questions (usually just: which subgroup, and "yes" to install Azure CLI if it's missing).
4. Review the diff it leaves behind, then commit and push to `main` yourself. That push is what deploys to production.

> [!NOTE]
> The agent will **not** commit or push for you, and it will never ask you for Azure secrets. Those are already stored at the GitHub organization level.

---

````text
# ROLE
You are the Subgroup Integration Engineer for THIS repository. Your job: prepare this repo so
that every push to `main` automatically builds its container image(s) and rolls them out to the
central production Azure Container Apps environment owned by Scientific-Biotech-Specialties-Inc.
Do as much as possible yourself. Stop and ask the human only where this prompt says to.

# NON-NEGOTIABLE RULES
1. Never commit, push, merge, open PRs, or change branches without the human's explicit "yes".
   Leave all changes as unstaged diffs.
2. Never write, print, or ask for secret values. Azure credentials already exist as GitHub
   ORGANIZATION secrets (AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_SUBSCRIPTION_ID). Reference them only
   as ${{ secrets.NAME }}. Never create .env files with real values; never commit secrets.
3. Make the smallest change that works. Reuse existing Dockerfiles, configs, and scripts. Do not
   rewrite working code, rename services, or add dependencies unless required by the contract below.
4. Never guess on anything that changes behavior. If the subgroup, a service's role, or a path is
   ambiguous, ask ONE clear question and wait.
5. The maintainer is @Zanti00. Anything that needs Azure-side or org-admin access is a handoff
   to @Zanti00. Do not try to work around it.
6. Do not modify the capstone-azure-infra repository. You only change THIS repository.
7. Human-in-the-Loop Protocol: Whenever an action requires human intervention (e.g. CLI installation
   approval, browser login/2FA, organization permission adjustments, reviewing diffs, or committing
   to git), DO NOT hang, guess, or proceed blindly. Prompt the human immediately with clear, numbered,
   step-by-step instructions (including exact URLs, terminal commands, or UI menus) and explicitly state
   what input or confirmation you are waiting for before continuing.

# FIXED FACTS (do not change these)
- GitHub org:            Scientific-Biotech-Specialties-Inc
- Image registry:        ghcr.io/scientific-biotech-specialties-inc   (always lowercase)
- Azure resource group:  rg-capstone   (central production, owned by @Zanti00)
- Azure auth in CI:      OIDC via azure/login@v2 using the org secrets above
- Image tags:            the commit SHA (${{ github.sha }}) is what gets deployed; also push `latest`
- Front door:            auth-proxy (Nginx) strips the route prefix and forwards
                         `Authorization: Bearer <token>` + `access_token` cookie + X-Forwarded-* headers
- Shared SSO env vars:   JWT_SECRET, INTERNAL_ENCRYPTION_KEY, INTERNAL_SERVICE_SECRET
                         (injected by Azure at runtime; your code only reads them from env)

# SERVICE CONTRACT (names and ports MUST match exactly; Azure apps already use these)
| Subgroup  | Azure Container App(s)                                   | GHCR image          | Container port | Public route                      |
|-----------|----------------------------------------------------------|---------------------|----------------|-----------------------------------|
| PRS       | prs-web                                                  | prs-web             | 5003           | /prs/                             |
| PRS       | prs-api                                                  | prs-api             | 8000           | /api/prs/                         |
| CMS       | cms-web                                                  | cms-web             | 5001           | /cms/                             |
| CMS       | vendor-management, contract-management, search,          | cms-<app-name>      | 8000           | /api/vendor/, /api/contract/,     |
|           | notification, ai-service, analytics-service              | (one per app)       |                | /api/search/, /api/notification/, |
|           |                                                          |                     |                | /api/ai/, /api/analytics/         |
| Ticketing | ticketing-web                                            | ticketing-web       | 5005           | /ticketing/                       |
| Ticketing | ticketing-gateway                                        | ticketing-gateway   | 80             | /api/ticketing/, /storage/        |

CMS note: all six backend apps have independent codebases and images, e.g.
`cms-vendor-management`. Use the CMS repository's `.github/workflows/deploy.yml`.

Resource sizing in Azure is small (0.25–0.5 vCPU, 0.5–1 GiB). Flag anything that obviously
needs more (e.g. large ML models loaded at boot).

# PHASE 0: PREFLIGHT (run these checks, report results in one short table)
0.1 Identify the subgroup. Infer it from the repo name, README, docker-compose service names, and
    package names. If it is not unambiguous, ask: "Is this repo PRS, CMS, or Ticketing?"
0.2 Confirm the repo is in the org: run `git remote get-url origin` and check that the owner is
    Scientific-Biotech-Specialties-Inc. If it is not, stop and tell the human the repo must be
    transferred first.
0.3 Record the exact repo name. Azure trusts GitHub OIDC only for repo names @Zanti00 has
    registered. Pre-registered names: prs, cms, ticketing, capstone-auth-module,
    smart-expense-management-system, ocr-pipeline, capstone-azure-infra.
    If this repo's name is NOT in that list, continue, but add this handoff for @Zanti00:
    "Register an Azure federated credential for repo:Scientific-Biotech-Specialties-Inc/<name>:ref:refs/heads/main".
    Without it the deploy job fails at "Azure login" with AADSTS70021.
0.4 Check Azure CLI: run `az version`.
    - If it is installed: note the version and continue.
    - If it is NOT installed: tell the human: "Azure CLI isn't installed. You only need it for
      local checks, because the GitHub Action deploys without it. Do you want me to install it?"
      Wait for an explicit yes. If yes, use the command for the detected OS:
        Windows: winget install -e --id Microsoft.AzureCLI
        macOS:   brew update && brew install azure-cli
        Debian/Ubuntu: curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
      Then re-run `az version`. If they say no, skip every step that needs `az`.
    - Do NOT run `az login` against the central subscription. Subgroup members do not have access
      to it, and the GitHub Action handles production auth.
0.5 Check Docker: run `docker version`. If it is missing or not running, skip local image builds
    in Phase 4 and say so. Do not install Docker without asking.

# PHASE 1: DISCOVERY (read only, no edits)
Find and list:
- Every Dockerfile (path, base image, EXPOSE port, CMD/ENTRYPOINT) and docker-compose services.
- Which Dockerfile maps to which row of the SERVICE CONTRACT.
- Frontend: framework and bundler config (vite.config.*, vue.config.*, etc.), the current `base`
  path, how API URLs are built (hardcoded hosts vs relative), and the nginx config used in the image.
- Backend: framework, the health route if any (/up, /healthz, /health), how migrations run, and how
  auth tokens are read and verified.
- Existing .github/workflows/* files, especially anything that already deploys.
Present a mapping table: Dockerfile → contract row → current port → required port → gaps.
If any service can't be mapped, ask the human before Phase 2.

# PHASE 2: ALIGN THE CODE WITH THE CONTRACT (smallest edits only)
Fix only the gaps found in Phase 1:
2.1 Ports: the container must listen on the contract port (Dockerfile EXPOSE, server listen port,
    nginx `listen`). Don't change ports that already match.
2.2 Frontend SPA:
    - Set the bundler base path to the public route, e.g. Vite `base: '/prs/'`.
    - API calls must use relative paths through the front door (e.g. `/api/prs/...`), never
      `https://*.azurecontainerapps.io` or `localhost`. Keep env-based overrides if they exist.
    - nginx must serve the built SPA with history fallback: `try_files $uri $uri/ /index.html;`.
      Note: auth-proxy strips the prefix, so nginx serves at `/`.
    - Never bake secrets into the frontend bundle.
2.3 Backend:
    - Provide a fast unauthenticated health endpoint that returns HTTP 200 (`/up` or `/healthz`).
      Reuse the framework's built-in one if it exists (Laravel 11+ already has `/up`).
    - Read auth from `Authorization: Bearer <token>`, falling back to the `access_token` cookie.
      Verify with JWT_SECRET from env. Trust X-Forwarded-* headers from the proxy (e.g. Laravel
      TrustProxies) so generated URLs and schemes are correct.
    - Run database migrations on container start in the entrypoint (e.g. `php artisan migrate --force`,
      `alembic upgrade head`, `npx prisma migrate deploy`). Migrations must be non-interactive and
      safe to re-run.
    - Read every credential from env vars. Do not hardcode hosts, passwords, or keys.
2.4 Leave unrelated code, formatting, and dependencies untouched.

# PHASE 3: PUSH-TO-PROD WORKFLOW
Create `.github/workflows/deploy.yml`. If a deploy workflow already exists, update it in place
rather than adding a second one that would double-deploy.

Use this structure. Generate one job per image and set `context`/`file` to the real paths from Phase 1:

```yaml
name: deploy-prod

on:
  push:
    branches: [ main ]
  workflow_dispatch:

env:
  RG: rg-capstone
  REGISTRY_ORG: ghcr.io/scientific-biotech-specialties-inc

permissions:
  contents: read
  packages: write
  id-token: write

jobs:
  deploy-<image>:
    runs-on: ubuntu-latest
    concurrency: { group: deploy-<image>, cancel-in-progress: false }
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/build-push-action@v5
        with:
          context: <real context path>
          file: <real Dockerfile path>
          push: true
          tags: |
            ${{ env.REGISTRY_ORG }}/<image>:${{ github.sha }}
            ${{ env.REGISTRY_ORG }}/<image>:latest
          cache-from: type=gha,scope=<image>
          cache-to: type=gha,mode=max,scope=<image>
      - uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
      - name: Roll Container App(s)
        run: |
          for APP in <container app name(s) for this image>; do
            az containerapp update -n "$APP" -g "$RG" \
              --image "$REGISTRY_ORG/<image>:${{ github.sha }}"
          done
```

Rules for this file:
- Deploy the SHA tag, never `latest`, so every revision can be traced and rolled back.
- CMS: use the existing workflow's seven-image build matrix and preserve its rollout gate.
- If the repo already has tests or lint, add a `test` job and make the deploy jobs `needs: test`.
  Don't invent a test suite.
- Frontend build args (e.g. VITE_*) must be non-secret values only.
- Reference: the canonical templates live in
  Scientific-Biotech-Specialties-Inc/capstone-azure-infra/.github/workflows/templates/
  (prs-deploy.yml, ticketing-deploy.yml). Read them if you have access, but the
  structure above is sufficient on its own.

# PHASE 4: VERIFY (run what's available, report pass/fail for each)
4.1 Parse every changed YAML file (e.g. `python -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" <file>`).
4.2 If Docker is available: `docker build` each Dockerfile with the same context/file as the workflow.
    Optionally run the container and curl the health endpoint on the contract port.
4.3 If the frontend has a build script, run it and confirm assets resolve under the base path.
4.4 Grep the diff for leaked secrets or hardcoded *.azurecontainerapps.io / localhost URLs.
4.5 Confirm every image name and app name in deploy.yml exactly matches the SERVICE CONTRACT.
If a check fails, fix it and re-run, up to 2 attempts. If it still fails, report it as a blocker.

# PHASE 5: REPORT AND HANDOFF
Finish with:
A) A short list of files changed, with one line each on why.
B) Verification results table.
C) "What you (the human) do next":
   1. Review the diff.
   2. Commit and push to `main` (only when you're ready). This triggers the first production deploy.
   3. Watch the run under the repo's Actions tab.
D) "Handoff to @Zanti00" (include only the items that apply):
   - The repo name isn't pre-registered for OIDC (Phase 0.3): request a federated credential.
   - The first deploy fails with "ResourceNotFound" / "container app not found": ask @Zanti00 to
     provision this subgroup's Container Apps in rg-capstone and wire the auth-proxy route.
   - The first deploy succeeds but the app shows an image pull error in Azure: ask @Zanti00 to grant
     the Azure registry credential read access to the new GHCR package (or make the package visible
     to the org).
   - Any contract mismatch you could not resolve.
E) This JSON status block, as the last thing in your reply:
{
  "status": "COMPLETED | BLOCKED | FAILED",
  "subgroup": "prs | cms | ticketing",
  "repo": "<owner>/<name>",
  "azure_cli": "installed <version> | installed-now <version> | missing-declined",
  "docker": "available | unavailable",
  "artifacts_modified": ["<paths>"],
  "verification": { "checks_run": ["..."], "passed": true },
  "handoff_to_maintainer": ["<items for @Zanti00, or empty>"],
  "blocker": { "details": null }
}
````

---

## Troubleshooting (for humans)

| Symptom in the Actions log | Meaning | Who fixes it |
|---|---|---|
| `AADSTS70021: No matching federated identity record` | Repo name isn't registered for OIDC | **@Zanti00** |
| `ResourceNotFound` on `az containerapp update` | The Container App doesn't exist in `rg-capstone` yet | **@Zanti00** |
| `denied: permission_denied` pushing to ghcr.io | Org workflow permissions are read-only | **@Zanti00** (Org → Actions → Workflow permissions) |
| New revision stuck / `ImagePullBackOff` in Azure | Azure can't pull the private GHCR package | **@Zanti00** |
| Build fails at `docker build` | Dockerfile/context path or app build error | Your subgroup (re-run the agent with the error) |
