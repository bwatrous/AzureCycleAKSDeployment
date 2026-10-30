@description('Name of the existing local virtual network that owns the peering.')
param localVirtualNetworkName string

@description('Resource ID of the remote virtual network.')
param remoteVirtualNetworkId string

@description('Allow the remote virtual network to use this network\'s gateway.')
param allowGatewayTransit bool = false

@description('Use the remote virtual network\'s gateway.')
param useRemoteGateways bool = false

resource localVirtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' existing = {
  name: localVirtualNetworkName
}

resource peering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-05-01' = {
  parent: localVirtualNetwork
  name: 'to-${last(split(remoteVirtualNetworkId, '/'))}'
  properties: {
    remoteVirtualNetwork: {
      id: remoteVirtualNetworkId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic: true
    allowGatewayTransit: allowGatewayTransit
    useRemoteGateways: useRemoteGateways
  }
}
