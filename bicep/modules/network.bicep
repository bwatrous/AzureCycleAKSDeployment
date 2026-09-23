@description('Name of the existing virtual network.')
param virtualNetworkName string

@description('Name of the subnet used by AKS nodes.')
param systemNodeSubnetName string

@description('CIDR assigned to the AKS system-node subnet.')
param systemNodeSubnetAddressPrefix string

@description('Enable API server VNet integration.')
param apiServerVnetIntegrationEnabled bool

@description('Name of the delegated API-server subnet.')
param apiServerSubnetName string

@description('CIDR assigned to the delegated API-server subnet.')
param apiServerSubnetAddressPrefix string

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: virtualNetworkName
}

resource systemNodeSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: virtualNetwork
  name: systemNodeSubnetName
  properties: {
    addressPrefix: systemNodeSubnetAddressPrefix
  }
}

resource apiServerSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = if (apiServerVnetIntegrationEnabled) {
  parent: virtualNetwork
  name: apiServerSubnetName
  properties: {
    addressPrefix: apiServerSubnetAddressPrefix
    delegations: [
      {
        name: 'aks-api-server'
        properties: {
          serviceName: 'Microsoft.ContainerService/managedClusters'
        }
      }
    ]
  }
}

output systemNodeSubnetId string = systemNodeSubnet.id
output apiServerSubnetId string = apiServerVnetIntegrationEnabled ? apiServerSubnet.id : ''
