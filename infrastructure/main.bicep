targetScope = 'resourceGroup'

@description('Choose only after subscription/region eligibility and the full cost estimate have been checked.')
param location string
@minLength(3)
@maxLength(7)
param namePrefix string
@description('Verified Azure Entra administrator object ID, never an Apple/GitHub identity.')
param sqlAdministratorObjectId string
param sqlAdministratorName string
param oidcIssuer string
param oidcAudience string
param oidcJwksUrl string
param oidcScope string

var suffix = uniqueString(resourceGroup().id)
var storageName = '${namePrefix}${suffix}'
var functionName = '${namePrefix}-api-${suffix}'
var sqlName = '${namePrefix}-sql-${suffix}'
var vaultName = '${namePrefix}-kv-${suffix}'
var blobOwner = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var queueContributor = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var tableContributor = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
var secretReader = '4633458b-17de-408a-b874-0445c86b69e6'

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
  }
}
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}
resource images 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'recipe-images'
  properties: { publicAccess: 'None' }
}
resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'function-package'
  properties: { publicAccess: 'None' }
}
resource queueService 'Microsoft.Storage/storageAccounts/queueServices@2023-05-01' = {
  parent: storage
  name: 'default'
}
resource importQueue 'Microsoft.Storage/storageAccounts/queueServices/queues@2023-05-01' = {
  parent: queueService
  name: 'imports'
}
resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: vaultName
  location: location
  properties: {
    tenantId: tenant().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: true
  }
}
resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${namePrefix}-api-identity'
  location: location
}
resource plan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: '${namePrefix}-consumption'
  location: location
  kind: 'functionapp'
  sku: { name: 'FC1', tier: 'FlexConsumption' }
  properties: { reserved: true }
}
resource api 'Microsoft.Web/sites@2024-04-01' = {
  name: functionName
  location: location
  kind: 'functionapp,linux'
  identity: { type: 'UserAssigned', userAssignedIdentities: { '${identity.id}': {} } }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    keyVaultReferenceIdentity: identity.id
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${deploymentContainer.name}'
          authentication: {
            type: 'UserAssignedIdentity'
            userAssignedIdentityResourceId: identity.id
          }
        }
      }
      scaleAndConcurrency: { maximumInstanceCount: 1, instanceMemoryMB: 512 }
      runtime: { name: 'node', version: '24' }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      appSettings: [
        { name: 'AZURE_CLIENT_ID', value: identity.properties.clientId }
        { name: 'AzureWebJobsStorage__accountName', value: storage.name }
        { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
        { name: 'AzureWebJobsStorage__clientId', value: identity.properties.clientId }
        { name: 'ImportQueue__queueServiceUri', value: storage.properties.primaryEndpoints.queue }
        { name: 'ImportQueue__credential', value: 'managedidentity' }
        { name: 'ImportQueue__clientId', value: identity.properties.clientId }
        { name: 'QUEUE_SERVICE_URL', value: storage.properties.primaryEndpoints.queue }
        { name: 'BLOB_SERVICE_URL', value: storage.properties.primaryEndpoints.blob }
        { name: 'SQL_SERVER', value: sqlBackend.outputs.sqlServerHostname }
        { name: 'SQL_DATABASE', value: 'RecipeBook' }
        { name: 'OIDC_ISSUER', value: oidcIssuer }
        { name: 'OIDC_AUDIENCE', value: oidcAudience }
        { name: 'OIDC_JWKS_URL', value: oidcJwksUrl }
        { name: 'OIDC_SCOPE', value: oidcScope }
        { name: 'APIFY_ENABLED', value: 'false' }
      ]
    }
  }
}
resource blobRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, identity.id, blobOwner)
  scope: storage
  properties: { roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobOwner), principalId: identity.properties.principalId, principalType: 'ServicePrincipal' }
}
resource queueRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, identity.id, queueContributor)
  scope: storage
  properties: { roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', queueContributor), principalId: identity.properties.principalId, principalType: 'ServicePrincipal' }
}
resource tableRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, identity.id, tableContributor)
  scope: storage
  properties: { roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', tableContributor), principalId: identity.properties.principalId, principalType: 'ServicePrincipal' }
}
resource vaultRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, identity.id, secretReader)
  scope: vault
  properties: { roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', secretReader), principalId: identity.properties.principalId, principalType: 'ServicePrincipal' }
}
module sqlBackend 'sql.bicep' = {
  name: 'recipe-book-sql-resources'
  params: {
    location: location
    serverName: sqlName
    administratorObjectId: sqlAdministratorObjectId
    administratorName: sqlAdministratorName
  }
}

// No "Allow Azure services" rule. Authorize verified app outbound addresses and
// operator IPs separately, or select private networking with approved costs.
output apiBaseUrl string = 'https://${api.properties.defaultHostName}/api/'
output functionPrincipalId string = identity.properties.principalId
output functionAppName string = api.name
output sqlServerName string = sqlBackend.outputs.sqlServerName
output keyVaultName string = vault.name
