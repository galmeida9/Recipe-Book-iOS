targetScope = 'resourceGroup'

param location string = 'swedencentral'
param accountName string
param workloadPrincipalId string

resource modelAccount 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: accountName
  location: location
  kind: 'OpenAI'
  sku: { name: 'S0' }
  properties: {
    customSubDomainName: accountName
    disableLocalAuth: true
    publicNetworkAccess: 'Enabled'
    networkAcls: { defaultAction: 'Allow' }
  }
}

resource extractor 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: modelAccount
  name: 'recipe-extractor'
  sku: { name: 'GlobalStandard', capacity: 10 }
  properties: {
    model: { format: 'OpenAI', name: 'gpt-4.1-mini', version: '2025-04-14' }
    versionUpgradeOption: 'NoAutoUpgrade'
  }
}

resource workloadModelUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(modelAccount.id, workloadPrincipalId, 'openai-user')
  scope: modelAccount
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
    principalId: workloadPrincipalId
    principalType: 'ServicePrincipal'
  }
}

output endpoint string = modelAccount.properties.endpoint
output deployment string = extractor.name
