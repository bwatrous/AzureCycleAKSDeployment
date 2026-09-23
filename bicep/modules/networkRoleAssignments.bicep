@description('Name of the existing virtual network.')
param virtualNetworkName string

@description('Name of the subnet used by AKS nodes.')
param systemNodeSubnetName string

@description('Enable API server VNet integration.')
param apiServerVnetIntegrationEnabled bool

@description('Name of the delegated API-server subnet.')
param apiServerSubnetName string

@description('Principal ID of the AKS control-plane managed identity.')
param principalId string

resource networkContributorRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' existing = {
  scope: subscription()
  name: '4d97b98b-1d4f-4787-a291-c67834d212e7'
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: virtualNetworkName
}

resource systemNodeSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = {
  parent: virtualNetwork
  name: systemNodeSubnetName
}

resource apiServerSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' existing = if (apiServerVnetIntegrationEnabled) {
  parent: virtualNetwork
  name: apiServerSubnetName
}

resource systemNodeSubnetNetworkContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(systemNodeSubnet.id, principalId, networkContributorRole.id)
  scope: systemNodeSubnet
  properties: {
    roleDefinitionId: networkContributorRole.id
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}

resource apiServerSubnetNetworkContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (apiServerVnetIntegrationEnabled) {
  name: guid(apiServerSubnet.id, principalId, networkContributorRole.id)
  scope: apiServerSubnet
  properties: {
    roleDefinitionId: networkContributorRole.id
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
