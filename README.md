# Azure Functions + Microsoft 365 Email secured with Managed Identity + built-in authentication

> **Receive a new-email event from Microsoft 365 in an Azure Function — where the only thing allowed to invoke that function is the Connector Namespace's own managed identity (no shared keys, no client secrets, anywhere).**

## Deploy and test

**Prereqs:** `azd`, `az` CLI, .NET 10 SDK, `jq` (for the bash post-deploy script in Mac and Linux).

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

The post-deploy hook creates the trigger config (with the `ManagedServiceIdentity` authentication block) on the Connector Namespace, installs the `connector-namespace` Azure CLI extension if needed, and opens a browser to OAuth-authorize the `office365` connection.

**Confirm built-in auth is the live gate** — hit the function with no token, expect a 401:

```bash
curl -i "https://<your-func>.azurewebsites.net/runtime/webhooks/connector?functionName=OnNewEmail"
# → HTTP/1.1 401 Unauthorized
# → WWW-Authenticate: Bearer realm="<your-func>.azurewebsites.net"
```

**Confirm the end-to-end happy path** — send yourself an email, then check Application Insights `traces` for the `OnNewEmail invoked` line (and the rest of the payload log). You should see logs similar to the following;

```
5/21/2026, 3:10:58 PM Information OnNewEmail invoked (caller pre-validated by built-in authentication).
5/21/2026, 3:10:58 PM Information Email received from: <sender's email address>
5/21/2026, 3:10:58 PM Information Email subject: <email subject>
```

---

## Clean up

⚠️ **While this sample is deployed, `OnNewEmail` logs the `From` and `Subject` of every email that arrives in the monitored mailbox to Application Insights.** That's fine for a hands-on demo, but you almost certainly don't want it running indefinitely against your real mailbox. Tear the sample down when you're done:

```bash
azd down --purge
```

`--purge` also removes the soft-deleted Application Insights / Log Analytics workspace so old email metadata doesn't linger.

---

## How it works (end-to-end)

```
        ┌────────────────────────┐
        │  📧 New email arrives  │
        │  in monitored mailbox  │
        └───────────┬────────────┘
                    │   Graph change-notification → connector runtime
                    ▼
 ┌─────────────────────────────────────────────────────────────────┐
 │  Connector Namespace  (westcentralus)                           │
 │  ├─ office365 connection  (OAuth-authorized to your mailbox)    │
 │  └─ trigger config                                              │
 │       authentication: ManagedServiceIdentity                    │
 │         identity = trigger UAMI                                 │
 │         audience = Entra app clientId                           │
 │       callbackUrl = https://<func>/runtime/webhooks/connector?  │
 │                     functionName=OnNewEmail                     │
 └────────────────────────────┬────────────────────────────────────┘
                              │
                              │  POST callbackUrl
                              │  Authorization: Bearer <AAD token>
                              │     iss = your tenant
                              │     aud = Entra app clientId
                              │     oid = trigger UAMI principalId
                              ▼
 ┌─────────────────────────────────────────────────────────────────┐
 │  Function App  (anywhere)                                       │
 │                                                                 │
 │   ┌─────────────────────────────────────────────────────────┐   │
 │   │ Built-in authentication  (App Service edge)             │   │
 │   │   • signature, iss, aud, exp                            │   │
 │   │   • allowedPrincipals.identities = [trigger UAMI oid]   │   │
 │   │   → no token  → 401                                     │   │
 │   │   → wrong oid → 403                                     │   │
 │   └─────────────────────────┬───────────────────────────────┘   │
 │                             │ pass                              │
 │                             ▼                                   │
 │   ┌─────────────────────────────────────────────────────────┐   │
 │   │ /runtime/webhooks/connector                             │   │
 │   │   (webhookAuthorizationLevel = Anonymous → no &code=)   │   │
 │   └─────────────────────────┬───────────────────────────────┘   │
 │                             ▼                                   │
 │   ┌─────────────────────────────────────────────────────────┐   │
 │   │ OnNewEmail(payload)   — your code                       │   │
 │   └─────────────────────────────────────────────────────────┘   │
 └─────────────────────────────────────────────────────────────────┘
                              ▲
                              │ FIC (federated identity credential)
                              │   — function app's MI proves itself
                              │     to Entra; no client secret
              ┌───────────────┴────────────────┐
              │  Entra app registration         │
              │  (federated to function-app MI) │
              └─────────────────────────────────┘
```

---

## Security model

Two managed identities, one Entra app, one federated trust — and **zero secrets**.

| Component | Purpose |
|---|---|
| **Function-app UAMI** | Storage + App Insights access, and the identity that built-in auth uses (via FIC) to mint client assertions instead of a client secret. |
| **Trigger UAMI** | Attached to the Connector Namespace. The connector runtime uses this identity to mint the AAD bearer token attached to every callback. |
| **Entra app registration** | The `aud` of the bearer token. Has a federated identity credential trusting the function-app UAMI (so built-in auth can authenticate the app *as* the Entra app without storing a secret). |
| **App Service built-in authentication** (`authsettingsV2`) | Edge-level token validator. Configured with `clientId` = Entra app, `allowedAudiences` = its clientId/identifierUri, `allowedPrincipals.identities` = `[trigger UAMI principalId]`. |
| **Connector Namespace** | Hosts the `office365` connection (OAuth to your mailbox) and the trigger config. |

### What's enforced — and where

Built-in authentication runs **inside the App Service worker, before** the Functions host sees the request. On every inbound call it validates, in order:

1. **Token presence** — missing/expired ⇒ **401** (`requireAuthentication: true` + `unauthenticatedClientAction: Return401`).
2. **Signature** — against the issuer's JWKS for your tenant.
3. **`iss`** — must match `openIdIssuer` (`https://login.microsoftonline.com/<tenant>/v2.0`).
4. **`aud`** — must be in `allowedAudiences`.
5. **`defaultAuthorizationPolicy.allowedPrincipals.identities`** — the token's `oid` must equal the trigger UAMI's `principalId`. **Any other identity gets a 403**, even with an otherwise-valid token for your `aud`.

This means **no application code is needed for the access check** — the function never sees a request that didn't come from the trigger UAMI.

### One enforcement layer, not two

`/runtime/webhooks/connector` is normally also protected by a Functions system key (`connector_extension`) — the `&code=...` query string. We opt out of that check in [`src/host.json`](src/host.json):

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

The shared-key check is strictly weaker than the AAD token check (a key is a static secret; a token is signed, audience-scoped, identity-scoped, and short-lived), so removing it deletes a thing-to-leak without lowering the security bar. **Built-in authentication is the only gate.**

### Re-running `azd up` / `azd provision`

The Connector Namespace RP **rejects `identity` in update PUTs after the resource is created**, even when the body is identical to live state:

```
ManagedIdentityInvalid: The request to update resource 'cns-…' managed identities
is not valid. The user assigned identities can not be changed.
```

To avoid this on the 2nd+ provision, set `CREATE_CONNECTOR_NAMESPACE` to `false`. The bicep then references the namespace as `existing` instead of re-PUTing it; the `office365` connection, access policies, and everything else continue to deploy normally:

```bash
azd env set CREATE_CONNECTOR_NAMESPACE false
azd up   # or: azd provision
```

If you only changed function code (not infra), skip provision entirely:

```bash
azd deploy
```
