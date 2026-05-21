# Azure Functions + Microsoft 365 Email — secured with Managed Identity + built-in authentication

A minimal "hello, OnNewEmail" Connector Namespace trigger sample where **the only thing that can call the function app is the Connector Namespace's own managed identity** — no shared function keys, no client secrets anywhere.

It's the same single-function payload as [`azure-functions-m365-email-hello`](https://github.com/nzthiago/azure-functions-m365-email-hello), repackaged into the standard `src/` + `infra/` + `azure.yaml` layout used by the full [end-to-end sample](https://github.com/Azure-Samples/functions-connectors-net-e2e-email-users-teams), with the **MI + App Service built-in authentication** security layer added on top.

> ⚠️ Preview. Uses the `Microsoft.Web/connectorGateways@2026-05-01-preview` resource type and the `Azure.Connectors.Sdk` preview NuGet packages. The Connector Namespace itself only works in `westcentralus` at the moment (the function app can live anywhere — the default is wherever `azd up` is provisioning).

## Security model

```
┌────────────────────────┐    AAD token (trigger UAMI)          ┌────────────────────────┐
│  Connector Namespace   │  ───────────────────────────────────►│  Function App          │
│  attached UAMI         │   audience = Entra app's clientId    │  Built-in auth         │
│  (trigger identity)    │                                       │  (authsettingsV2)      │
│                        │                                       │  validates aud + oid   │
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
   - One attached to the **function app** (storage, App Insights, built-in auth FIC).
   - A dedicated one attached to the **Connector Namespace** as the "trigger identity" — referenced in the trigger config and used to mint AAD tokens when calling the callback URL.
2. **Entra app registration** (`infra/app/entra.bicep`) with a **federated identity credential** trusting the function app's user-assigned MI. Built-in authentication uses this to mint client assertions, so no client secret is ever stored.
3. **App Service built-in authentication** ([authsettingsV2](https://learn.microsoft.com/azure/app-service/overview-authentication-authorization), aka "Easy Auth") on the function app:
   - `requireAuthentication: true`, `unauthenticatedClientAction: Return401`
   - `clientId` = the Entra app
   - `clientSecretSettingName: OVERRIDE_USE_MI_FIC_ASSERTION_CLIENTID` (magic value — tells built-in auth to use FIC against the named user-assigned MI, no secret needed)
   - `allowedAudiences` = the Entra app's `applicationId` and `identifierUri`
   - `defaultAuthorizationPolicy.allowedPrincipals.identities` = `[triggerUserAssignedIdentity.principalId]` — **only the Connector Namespace's trigger UAMI is allowed in**.
4. **Connector Namespace** with the trigger UAMI attached and an `office365` connection. Both the trigger UAMI (so the connector runtime can read the mailbox) and the function app's MI (for SDK calls back into the connection) get access policies on the connection.
5. **Trigger config** (created in `infra/scripts/postdeploy.sh|ps1`) — exact shape per Aparna Seth's guidance:
   ```json
   "notificationDetails": {
     "callbackUrl": "https://<func>.azurewebsites.net/runtime/webhooks/connector?functionName=OnNewEmail",
     "httpMethod": "Post",
     "authentication": {
       "type": "ManagedServiceIdentity",
       "audience": "<entra-app-clientId>",
       "identity": "<trigger-uami-resourceId>"
     }
   }
   ```
   The connector then attaches an AAD token (audience = our Entra app, signed by the trigger UAMI) on every callback. **No client secret. No shared key. No `code=` in the URL.**

### One enforcement layer: built-in authentication

`/runtime/webhooks/connector` is normally protected by a Functions system key (`connector_extension`) — that's the `&code=...` query string. We opt the route out of that check in `src/host.json`:

```json
{
  "version": "2.0",
  "telemetryMode": "OpenTelemetry",
  "extensions": {
    "connector": {
      "system": {
        "webhookAuthorizationLevel": "Anonymous"
      }
    }
  }
}
```

This drops the inner key check so we don't have to manage a shared secret in the callback URL. **Built-in authentication is the only gate** — and it's the strongest one, because it validates a real AAD token tied to a specific managed identity.

### How "only the trigger UAMI can call in" is enforced

Built-in authentication runs **inside the App Service worker, before** the Functions host sees the request. On every inbound request it automatically validates:

1. **Token presence** — missing/expired ⇒ **401** (because of `requireAuthentication: true` + `unauthenticatedClientAction: Return401`).
2. **Signature** — against the issuer's JWKS for our tenant.
3. **`iss` claim** — must match `openIdIssuer` (`https://login.microsoftonline.com/<tenant>/v2.0`).
4. **`aud` claim** — must be in `allowedAudiences` (our Entra app's `applicationId` or `identifierUri`).
5. **`defaultAuthorizationPolicy.allowedPrincipals.identities`** — the token's `oid` must equal the trigger UAMI's `principalId`. **Any other identity gets a 403**, even with an otherwise-valid token for our `aud`.

This means **no application code is needed for the access check** — the function app code never sees a request that didn't come from the trigger UAMI.

If you want to audit *which* identity called in, built-in authentication injects these headers on every authenticated request:

| Header | Contents |
|---|---|
| `X-MS-CLIENT-PRINCIPAL-ID` | The validated `oid` (should equal the trigger UAMI's principalId) |
| `X-MS-CLIENT-PRINCIPAL-NAME` | Usually the `appid` |
| `X-MS-CLIENT-PRINCIPAL` | Base64-encoded JSON of all validated claims |

`OnNewEmail.cs` logs `X-MS-CLIENT-PRINCIPAL-ID` so you can verify in App Insights that every invocation was authenticated as the trigger UAMI. (Locally the header is absent — built-in authentication runs only in Azure.)

#### Verifying after deploy

```bash
FUNC=https://<your-func>.azurewebsites.net

# 1. No token → 401 (built-in auth blocks before the runtime)
curl -i "$FUNC/runtime/webhooks/connector?functionName=OnNewEmail"

# 2. Valid token but wrong identity (you, via az cli) → 403
TOKEN=$(az account get-access-token --resource <entra-app-clientId> --query accessToken -o tsv)
curl -i -H "Authorization: Bearer $TOKEN" "$FUNC/runtime/webhooks/connector?functionName=OnNewEmail"
```

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

# Some tenants (Microsoft included) require every new Entra app registration to
# carry a Service Management Reference. If you hit
# "ServiceManagementReference field is required for Update" during provision,
# set this once on the azd env -- the value is your service tree GUID or any
# identifier your tenant policy accepts.
azd env set SERVICE_MANAGEMENT_REFERENCE <your-service-tree-guid>

azd up
```

The post-deploy hook will:
1. Create the trigger config (with the MSI authentication block) on the Connector Namespace.
2. Install the `connector-namespace` Azure CLI extension if needed.
3. Open a browser to OAuth-authorize the office365 connection.

### Subsequent `azd up` / `azd provision` runs — flip the namespace toggle

The Connector Namespace RP **rejects `identity` in update PUTs after the resource is created**, even when the body is identical to live state:

```
ManagedIdentityInvalid: The request to update resource 'cns-…' managed
identities is not valid. The user assigned identities can not be changed.
```

To avoid this on the 2nd+ provision, set `CREATE_CONNECTOR_NAMESPACE` to `false` on your azd env. The bicep then references the namespace as `existing` instead of re-PUTing it; children (the office365 connection + access policies) and everything else continue to deploy normally:

```bash
azd env set CREATE_CONNECTOR_NAMESPACE false
azd up   # or: azd provision
```

If you only changed function code (not infra), skip provision entirely:

```bash
azd deploy
```

Send yourself an email and watch the function fire:

```bash
az functionapp log tail -g <resourceGroupName> -n <functionAppName>
```

## Local dev

Local dev uses your `az login` user (the deployer principalId is passed in via `userPrincipalId` and granted access on the office365 connection), so you can run the function locally against the same Connector Namespace connection. Built-in authentication is an App Service edge concern and won't trip you up at `localhost`.

```bash
cd src
func start
```
