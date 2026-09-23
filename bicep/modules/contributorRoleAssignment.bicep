@description('Principal ID of the workload managed identity.')
param principalId string

resource contributorRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  scope: subscription()
  name: 'b24988ac-6180-42a0-ab88-20f7382dd24c'
}

resource contributorRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, principalId, contributorRole.id)
  properties: {
    roleDefinitionId: contributorRole.id
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
