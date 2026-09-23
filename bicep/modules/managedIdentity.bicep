@description('Name of the user-assigned managed identity.')
param name string

@description('Azure region for the managed identity.')
param location string = resourceGroup().location

@description('Tags applied to the managed identity.')
param tags object = {}

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: name
  location: location
  tags: tags
}

output resourceId string = managedIdentity.id
output name string = managedIdentity.name
output clientId string = managedIdentity.properties.clientId
output principalId string = managedIdentity.properties.principalId
