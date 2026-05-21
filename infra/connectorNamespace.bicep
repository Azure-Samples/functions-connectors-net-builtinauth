param name string
param location string
param tags object = {}
param connectionName string
@description('Resource ID of the user-assigned managed identity to attach to the Connector Namespace. This is the identity the trigger uses to mint tokens when calling the function app callback URL.')
param triggerIdentityResourceId string
@description('Object (principal) ID of the same user-assigned managed identity, granted access to the office365 connection.')
param triggerIdentityPrincipalId string
@description('Object (principal) ID of the function app user-assigned MI. Granted access to the office365 connection so it can call the connector at runtime.')
param functionAppPrincipalId string
@description('Optional. AAD object ID of a user (typically the deployer) to also grant access to the connection, so the same code can be debugged locally with `az login` credentials.')
param userPrincipalId string = ''
param tenantId string = tenant().tenantId

resource connectorNamespace 'Microsoft.Web/connectorGateways@2026-05-01-preview' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${triggerIdentityResourceId}': {}
    }
  }
}

resource office365Connection 'Microsoft.Web/connectorGateways/connections@2026-05-01-preview' = {
  parent: connectorNamespace
  name: connectionName
  properties: {
    connectorName: 'office365'
  }
}

// Function App MI -> Office 365 connection (used by the trigger callback path).
resource office365ConnectionFunctionAppAccessPolicy 'Microsoft.Web/connectorGateways/connections/accessPolicies@2026-05-01-preview' = {
  parent: office365Connection
  name: 'functionapp-msi'
  properties: {
    principal: {
      type: 'ActiveDirectory'
      identity: {
        objectId: functionAppPrincipalId
        tenantId: tenantId
      }
    }
  }
}

// Trigger UAMI -> Office 365 connection. The connector namespace runtime impersonates
// this identity when reading from the mailbox on behalf of the trigger config.
resource office365ConnectionTriggerIdentityAccessPolicy 'Microsoft.Web/connectorGateways/connections/accessPolicies@2026-05-01-preview' = {
  parent: office365Connection
  name: 'trigger-msi'
  properties: {
    principal: {
      type: 'ActiveDirectory'
      identity: {
        objectId: triggerIdentityPrincipalId
        tenantId: tenantId
      }
    }
  }
}

// Deployer (dev) -> Office 365 connection (so local dev can use the same connection).
resource office365ConnectionUserAccessPolicy 'Microsoft.Web/connectorGateways/connections/accessPolicies@2026-05-01-preview' = if (!empty(userPrincipalId)) {
  parent: office365Connection
  name: 'dev-user'
  properties: {
    principal: {
      type: 'ActiveDirectory'
      identity: {
        objectId: userPrincipalId
        tenantId: tenantId
      }
    }
  }
}

@description('The resource ID of the Connector Namespace.')
output resourceId string = connectorNamespace.id

@description('The name of the Connector Namespace.')
output name string = connectorNamespace.name

@description('The name of the Office 365 connection on the namespace.')
output connectionName string = office365Connection.name

@description('Runtime URL for the Office 365 connection.')
output office365ConnectionRuntimeUrl string = office365Connection.properties.connectionRuntimeUrl

