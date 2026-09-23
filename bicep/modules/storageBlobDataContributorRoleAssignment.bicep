@description('Name of the existing storage account.')
param storageAccountName string

@description('Principal ID of the workload managed identity.')
param principalId string

resource storageBlobDataContributorRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  scope: subscription()
  name: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' existing = {
  name: storageAccountName
}

resource storageBlobDataContributorRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storageAccount.id, principalId, storageBlobDataContributorRole.id)
  scope: storageAccount
  properties: {
    roleDefinitionId: storageBlobDataContributorRole.id
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
