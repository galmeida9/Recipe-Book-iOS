targetScope = 'resourceGroup'
param location string
param serverName string
param administratorObjectId string
param administratorName string

resource sqlServer 'Microsoft.Sql/servers@2023-08-01' = {
  name: serverName
  location: location
  properties: {
    version: '12.0'
    minimalTlsVersion: '1.2'
    publicNetworkAccess: 'Enabled'
    administrators: {
      administratorType: 'ActiveDirectory'
      principalType: 'User'
      login: administratorName
      sid: administratorObjectId
      tenantId: tenant().tenantId
      azureADOnlyAuthentication: true
    }
  }
}
resource database 'Microsoft.Sql/servers/databases@2023-08-01' = {
  parent: sqlServer
  name: 'RecipeBook'
  location: location
  // Basic never auto-pauses. Serverless free-offer resume made the first request after idle take 30-60 s.
  sku: { name: 'Basic', tier: 'Basic', capacity: 5 }
  properties: {
    maxSizeBytes: 2147483648
    requestedBackupStorageRedundancy: 'Local'
  }
}
output sqlServerName string = sqlServer.name
output sqlServerHostname string = sqlServer.properties.fullyQualifiedDomainName
