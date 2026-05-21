# Azure Functions + Microsoft 365 Email — secured with Managed Identity + EasyAuth

A minimal "hello, OnNewEmail" Connector Namespace trigger sample where **the only thing that can call the function app is the Connector Namespace's own managed identity** — no shared function keys, no client secrets anywhere.

It's the same single-function payload as [`azure-functions-m365-email-hello`](https://github.com/nzthiago/azure-functions-m365-email-hello), repackaged into the standard `src/` + `infra/` + `azure.yaml` layout used by the full [end-to-end sample](https://github.com/Azure-Samples/functions-connectors-net-e2e-email-users-teams), with the **MI + EasyAuth** security layer added on top.

> ⚠️ Preview. Uses the `Microsoft.Web/connectorGateways@2026-05-01-preview` resource type and the `Azure.Connectors.Sdk` preview NuGet packages. The Connector Namespace itself only works in `brazilsouth` at the moment (the function app can live anywhere — the default is wherever `azd up` is provisioning).

## Security model

```
┌────────────────────────┐    AAD token (trigger UAMI)          ┌────────────────────────┐
│  Connector Namespace   │  ───────────────────────────────────►│  Function App          │
│  attached UAMI         │   audience = Entra app's clientId    │  EasyAuth (authsetting │
│  (trigger identity)    │                                       │  V2) validates aud +   │
│                        │                                       │  caller oid            │
└────────────────────────┘                                       └────────────────────────┘
                                                                          │ FIC
                                                                          ▼
                                                          ┌────────────────────────────┐
                                                          │ Entra app registration     │
                                                          │ (federated to function MI) │
                                                          └────────────────────────────┘
```

What `infra/` sets up:

1. **Two user-assigned managed identities**:
   - One attached to the **function app** (storage, App Insights, EasyAuth FIC).
   - A dedicated one attached to the **Connector Namespace** as the "trigger identity" — referenced in the trigger config and used to mint AAD tokens when calling the callback URL.
2. **Entra app registration** (`infra/app/entra.bicep`) with a **federated identity credential** trusting the function app's user-assigned MI. EasyAuth uses this to mint client assertions, so no client secret is ever stored.
3. **App Service Authentication V2** on the function app (`authsettingsV2` config):
   - `requireAuthentication: true`, `unauthenticatedClientAction: Return401`
   - `clientId` = the Entra app
   - `clientSecretSettingName: OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID` (magic value — tells EasyAuth to use FIC against the named user-assigned MI, no secret needed)
   - `allowedAudiences` = the Entra app's `applicationId` and `identifierUri`
   - `defaultAuthorizationPolicy.allowedPrincipals.identities` = `[triggerUserAssignedIdentity.principalId]` — **only the Connector Namespace's trigger UAMI is allowed in**.
4. **Connector Namespace** with the trigger UAMI attached and an `office365` connection. Both the trigger UAMI (so the connector runtime can read the mailbox) and the function app's MI (for SDK calls back into the connection) get access policies on the connection.
5. **Trigger config** (created in `infra/scripts/postdeploy.sh|ps1`) — exact shape per Aparna Seth's guidance:
   ```json
   "notificationDetails": {
     "callbackUrl": "https://<func>.azurewebsites.net/runtime/webhooks/connector?functionName=OnNewEmail&code=<connector_extension key>",
     "httpMethod": "Post",
     "authentication": {
       "type": "ManagedServiceIdentity",
       "audience": "<entra-app-clientId>",
       "identity": "<trigger-uami-resourceId>"
     }
   }
   ```
   The connector then attaches an AAD token (audience = our Entra app, signed by the trigger UAMI) on every callback. **No client secret. No shared key in app config.**

### Two layers, on purpose

EasyAuth + the `code=` system key are **independent checks**:

| Layer | Where | What it gates on |
|---|---|---|
| EasyAuth (outer) | App Service "front door" — before the function host sees the request | AAD token: audience matches our Entra app, caller `oid` is the trigger UAMI |
| `connector_extension` system key (inner) | Functions runtime, on `/runtime/webhooks/connector` | The `code=` query string matches the function app's `systemKeys.connector_extension` |

The Functions runtime always requires a webhook system key for built-in webhook handlers like `/runtime/webhooks/connector` — there is no app setting that disables it. So we keep `code=` in the callback URL and treat EasyAuth as **defense in depth** on top: even if the system key leaks, a caller that isn't the trigger UAMI still gets a 401 at the App Service edge.

The function code itself is unchanged from the hello sample — it just logs the inbound email payload.

## Layout

```
azure.yaml
src/                                # function app (azd service "function-app")
  m365-email-secured.csproj
  OnNewEmail.cs
  Program.cs
  host.json
  local.settings.json.sample
  test.http
infra/
  main.bicep                        # subscription-scoped, creates RG + everything
  main.parameters.json
  connectorNamespace.bicep          # Connector Namespace + office365 connection
  abbreviations.json
  bicepconfig.json                  # enables microsoftGraphV1 extension
  app/
    entra.bicep                     # Entra app reg + FIC for the function MI
  scripts/
    postdeploy.sh / postdeploy.ps1  # trigger config + connection authorize
```

## Deploy

Prereqs: `azd`, `az` CLI, .NET 10 preview SDK, `jq` (for the bash post-deploy script).

```bash
azd auth login
az login
azd up
```

The post-deploy hook will:
1. Create the trigger config (with the MSI authentication block) on the Connector Namespace.
2. Install the `connector-namespace` Azure CLI extension if needed.
3. Open a browser to OAuth-authorize the office365 connection.

Send yourself an email and watch the function fire:

```bash
az functionapp log tail -g <resourceGroupName> -n <functionAppName>
```

## Local dev

Local dev uses your `az login` user (the deployer principalId is passed in via `userPrincipalId` and granted access on the office365 connection), so you can run the function locally against the same Connector Namespace connection. EasyAuth is a function-app concern and won't trip you up at `localhost`.

```bash
cd src
func start
```
