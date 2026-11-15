targetScope = 'resourceGroup'

@description('Choose only after subscription/region eligibility and the full cost estimate have been checked.')
param location string
@minLength(3)
@maxLength(7)
param namePrefix string
@description('Verified Azure Entra administrator object ID, never an Apple/GitHub identity.')
param sqlAdministratorObjectId string = ''
param sqlAdministratorName string = ''
@description('Verified owned existing SQL server. When set, no SQL server/database/admin resources are modified.')
param existingSqlServerName string = ''
@description('Public Google web-application OAuth client ID used as the exact API ID-token audience.')
param googleServerClientId string = ''
@allowed(['Disabled', 'Enabled'])
@description('Keep Disabled until real Google clients, workload tests and no-overage controls are verified.')
param apiPublicNetworkAccess string = 'Disabled'
@description('Enable only after the fresh Flex subnet is integrated. Adds only its SQL service-endpoint rule, never a blanket firewall.')
param enableSqlServiceEndpoint bool = false

var suffix = uniqueString(resourceGroup().id)
var storageName = '${namePrefix}${suffix}'
var functionName = '${namePrefix}-api-${suffix}'
var sqlName = '${namePrefix}-sql-${suffix}'
var resolvedSqlServerName = empty(existingSqlServerName) ? sqlName : existingSqlServerName
var vaultName = '${namePrefix}-kv-${suffix}'
var blobOwner = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
var queueContributor = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var queueMessageSender = 'c6a89b2d-59bc-44d0-9896-0f6e12d7b80a'
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
resource poisonQueue 'Microsoft.Storage/storageAccounts/queueServices/queues@2023-05-01' = {
  parent: queueService
  name: 'imports-poison'
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
resource network 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: '${namePrefix}-api-network'
  location: location
  properties: {
    addressSpace: { addressPrefixes: ['10.42.0.0/16'] }
  }
}
resource subnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: network
  name: 'functions'
  properties: {
    addressPrefix: '10.42.0.0/27'
    delegations: [{ name: 'flex', properties: { serviceName: 'Microsoft.App/environments' } }]
    serviceEndpoints: enableSqlServiceEndpoint ? [{ service: 'Microsoft.Sql', locations: [location] }] : []
  }
}
resource sqlNetworkRule 'Microsoft.Sql/servers/virtualNetworkRules@2023-08-01' = if (enableSqlServiceEndpoint) {
  name: '${resolvedSqlServerName}/recipe-functions-subnet'
  dependsOn: [sqlBackend]
  properties: {
    virtualNetworkSubnetId: subnet.id
    ignoreMissingVnetServiceEndpoint: false
  }
}
resource api 'Microsoft.Web/sites@2024-04-01' = {
  name: functionName
  location: location
  kind: 'functionapp,linux'
  identity: { type: 'UserAssigned', userAssignedIdentities: { '${identity.id}': {} } }
  dependsOn: [blobRole, queueRole, importSendRole, poisonSendRole, tableRole]
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    publicNetworkAccess: apiPublicNetworkAccess
    virtualNetworkSubnetId: subnet.id
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
      scaleAndConcurrency: { maximumInstanceCount: 1, instanceMemoryMB: 512, alwaysReady: [] }
      runtime: { name: 'node', version: '24' }
    }
    siteConfig: {
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      appSettings: [
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'AzureWebJobsFeatureFlags', value: 'EnableWorkerIndexing' }
        { name: 'FUNCTIONS_NODE_BLOCK_ON_ENTRY_POINT_ERROR', value: 'true' }
        { name: 'AZURE_CLIENT_ID', value: identity.properties.clientId }
        { name: 'AzureWebJobsStorage__accountName', value: storage.name }
        { name: 'AzureWebJobsStorage__credential', value: 'managedidentity' }
        { name: 'AzureWebJobsStorage__clientId', value: identity.properties.clientId }
        { name: 'ImportQueue__queueServiceUri', value: storage.properties.primaryEndpoints.queue }
        { name: 'ImportQueue__credential', value: 'managedidentity' }
        { name: 'ImportQueue__clientId', value: identity.properties.clientId }
        { name: 'QUEUE_SERVICE_URL', value: storage.properties.primaryEndpoints.queue }
        { name: 'BLOB_SERVICE_URL', value: storage.properties.primaryEndpoints.blob }
        { name: 'SQL_SERVER', value: '${resolvedSqlServerName}.${environment().suffixes.sqlServerHostname}' }
        { name: 'SQL_DATABASE', value: 'RecipeBook' }
        { name: 'GOOGLE_SERVER_CLIENT_ID', value: googleServerClientId }
        { name: 'GOOGLE_OAUTH_CLIENT_SECRET', value: '@Microsoft.KeyVault(VaultName=${vaultName};SecretName=google-oauth-client-secret)' }
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
resource importSendRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(importQueue.id, identity.id, queueMessageSender)
  scope: importQueue
  properties: { roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', queueMessageSender), principalId: identity.properties.principalId, principalType: 'ServicePrincipal' }
}
resource poisonSendRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(poisonQueue.id, identity.id, queueMessageSender)
  scope: poisonQueue
  properties: { roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', queueMessageSender), principalId: identity.properties.principalId, principalType: 'ServicePrincipal' }
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
module sqlBackend 'sql.bicep' = if (empty(existingSqlServerName)) {
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
output sqlServerName string = resolvedSqlServerName
output functionIdentityClientId string = identity.properties.clientId
output functionIdentityName string = identity.name
output networkName string = network.name
output keyVaultName string = vault.name
