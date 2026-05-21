Write-Host "Post-deployment configuration..." -ForegroundColor Yellow

# Outputs from azd
$outputs = azd env get-values --output json | ConvertFrom-Json

$subscriptionId = (az account show --query id -o tsv)
$resourceGroupName = $outputs.resourceGroupName
$connectorNamespaceName = $outputs.connectorNamespaceName
$connectorNamespaceConnectionName = $outputs.connectorNamespaceConnectionName
$functionAppName = $outputs.functionAppName
$office365FunctionName = $outputs.office365FunctionName
$entraAppClientId = $outputs.entraAppClientId

# --- Create Connector Namespace trigger config ---
Write-Host "Creating Connector Namespace trigger config..." -ForegroundColor Yellow

$triggerName = "$connectorNamespaceConnectionName-trigger"

# No function key needed; EasyAuth validates the AAD token sent by the namespace MI.
$callbackUrl = "https://$functionAppName.azurewebsites.net/runtime/webhooks/connector?functionName=$office365FunctionName"

$apiUrl = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Web/connectorGateways/$connectorNamespaceName/triggerconfigs/${triggerName}?api-version=2026-05-01-preview"

$body = @{
  properties = @{
    description = "Office 365 Outlook trigger config (secured with MI + EasyAuth)"
    connectionDetails = @{
      connectorName = "office365"
      connectionName = $connectorNamespaceConnectionName
    }
    operationName = "OnNewEmailV3"
    parameters = @(
      @{ name = "folderPath"; value = "Inbox" }
    )
    notificationDetails = @{
      callbackUrl = $callbackUrl
      authentication = @{
        type = "ManagedServiceIdentity"
        audience = $entraAppClientId
      }
    }
  }
} | ConvertTo-Json -Depth 10 -Compress

Write-Host "  API URL: $apiUrl" -ForegroundColor Cyan
Write-Host "  Callback URL: $callbackUrl" -ForegroundColor Cyan
Write-Host "  Token audience: $entraAppClientId" -ForegroundColor Cyan

az rest --method PUT --url $apiUrl --body $body | Out-Null

Write-Host "Connector Namespace trigger config created." -ForegroundColor Green

# --- Authorize the office365 connection via Azure CLI ---
Write-Host ""
Write-Host "Authorizing office365 connection..." -ForegroundColor Yellow

$ext = az extension show --name connector-namespace 2>$null
if (-not $ext) {
  Write-Host "Installing 'connector-namespace' Azure CLI extension..." -ForegroundColor Cyan
  az extension add `
    --source https://github.com/anthonychu/azure-cli-extensions/releases/download/connector-namespace-0.1.0/connector_namespace-0.1.0-py2.py3-none-any.whl `
    --yes
}

Write-Host "-> A browser tab will open. Sign in with the mailbox account whose Inbox you want to monitor." -ForegroundColor Cyan
az connector-namespace connection authorize `
  --resource-group $resourceGroupName `
  --namespace-name $connectorNamespaceName `
  --name $connectorNamespaceConnectionName

Write-Host ""
Write-Host "Done. New emails in the connected Inbox will fire the OnNewEmail function." -ForegroundColor Green
Write-Host "Tail logs: az functionapp log tail -g $resourceGroupName -n $functionAppName" -ForegroundColor Green
Write-Host ""
