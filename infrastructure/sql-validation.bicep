targetScope = 'resourceGroup'
param administratorObjectId string
param administratorName string
module sqlBackend 'sql.bicep' = {
  name: 'recipe-book-sql-resources'
  params: {
    location: 'swedencentral'
    serverName: 'recipe-sql-${uniqueString(resourceGroup().id)}'
    administratorObjectId: administratorObjectId
    administratorName: administratorName
  }
}
output sqlServerName string = sqlBackend.outputs.sqlServerName
output sqlServerHostname string = sqlBackend.outputs.sqlServerHostname
