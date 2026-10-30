@description('Name of the virtual network to create.')
param virtualNetworkName string

@description('Azure region for the virtual network.')
param location string = resourceGroup().location

@description('Address prefixes for the virtual network.')
param virtualNetworkAddressPrefixes array

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

@description('Tags applied to the virtual network.')
param tags object = {}

var systemNodeSubnet = {
  name: systemNodeSubnetName
  properties: {
    addressPrefix: systemNodeSubnetAddressPrefix
  }
}

var apiServerSubnet = {
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

// Subnets are declared inline so the VNet and its subnets are written in one operation.
resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: virtualNetworkName
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: virtualNetworkAddressPrefixes
    }
    subnets: apiServerVnetIntegrationEnabled ? [systemNodeSubnet, apiServerSubnet] : [systemNodeSubnet]
  }
}

output virtualNetworkId string = virtualNetwork.id
output virtualNetworkName string = virtualNetwork.name
output systemNodeSubnetId string = resourceId('Microsoft.Network/virtualNetworks/subnets', virtualNetworkName, systemNodeSubnetName)
output apiServerSubnetId string = apiServerVnetIntegrationEnabled ? resourceId('Microsoft.Network/virtualNetworks/subnets', virtualNetworkName, apiServerSubnetName) : ''
