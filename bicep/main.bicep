targetScope = 'subscription'

@description('Short, globally meaningful prefix used for generated resource names.')
@minLength(2)
@maxLength(30)
param prefix string

@description('Azure region for the AKS resource group and regional resources.')
param location string

@description('Name of the resource group that will contain AKS and its managed identities.')
param resourceGroupName string = '${prefix}-aks-rg'

@description('Name of the AKS cluster.')
param aksClusterName string = '${prefix}-aks'

@description('Name of the AKS node resource group.')
param nodeResourceGroupName string = '${prefix}-aks-nodes-rg'

@description('Optional Kubernetes version. Leave empty to use the current Azure default.')
param kubernetesVersion string = ''

@description('Administrator username for AKS Linux nodes.')
param adminUsername string = 'azureuser'

@description('SSH public key for AKS Linux nodes.')
param sshPublicKey string

@description('VM size for the system node pool.')
param systemNodeVmSize string = 'Standard_D4ds_v5'

@description('Initial node count for the system node pool.')
@minValue(1)
param systemNodeCount int = 1

@description('Enable cluster autoscaling for the system node pool.')
param systemNodeAutoscalingEnabled bool = false

@description('Minimum system node count when autoscaling is enabled.')
@minValue(1)
param systemNodeMinCount int = 1

@description('Maximum system node count when autoscaling is enabled.')
@minValue(1)
param systemNodeMaxCount int = 3

@description('Name of the virtual network created for AKS.')
param virtualNetworkName string = '${prefix}-vnet'

@description('Address prefixes for the AKS virtual network. Must not overlap the hub or any peered network. The first prefix must be /26 or larger when subnet prefixes are left empty.')
param virtualNetworkAddressPrefixes array = [
  '10.10.0.0/16'
]

@description('Name of the subnet used by AKS nodes.')
param systemNodeSubnetName string = 'SystemSubnet'

@description('CIDR assigned to the AKS system-node subnet. Leave empty to use the first half of the first VNet address prefix.')
param systemNodeSubnetAddressPrefix string = ''

@description('Optional resource ID of an existing hub virtual network to peer with (hub-spoke). Leave empty to skip peering.')
param hubVirtualNetworkResourceId string = ''

@description('Create the hub-to-spoke peering. Disable if the deployer lacks rights on the hub and the hub team creates it.')
param createHubToSpokePeering bool = true

@description('Route spoke traffic through the hub virtual network gateway. Requires a gateway in the hub and createHubToSpokePeering.')
param useHubGateway bool = false

@description('Enable API server VNet integration.')
param apiServerVnetIntegrationEnabled bool = false

@description('Name of the delegated API-server subnet.')
param apiServerSubnetName string = 'APIServerSubnet'

@description('CIDR assigned to the delegated API-server subnet. Leave empty to use the first /28 in the second half of the first VNet address prefix.')
param apiServerSubnetAddressPrefix string = ''

@description('Kubernetes networking implementation.')
@allowed([
  'azure'
  'kubenet'
])
param networkPlugin string = 'azure'

@description('Optional network plugin mode. Use overlay for Azure CNI Overlay.')
@allowed([
  ''
  'overlay'
])
param networkPluginMode string = ''

@description('Kubernetes service CIDR. It must not overlap the VNet or pod CIDR.')
param serviceCidr string = '172.16.0.0/16'

@description('Kubernetes DNS service IP within the service CIDR.')
param dnsServiceIP string = '172.16.0.10'

@description('Pod CIDR for kubenet or Azure CNI Overlay. Leave empty for standard Azure CNI.')
param podCidr string = ''

@description('Public IP ranges (CIDR) allowed to reach the API server. Empty allows all. Ignored for private clusters.')
param apiServerAuthorizedIpRanges array = []

@description('Enable AKS-managed Microsoft Entra integration for cluster authentication.')
param entraIntegrationEnabled bool = false

@description('Use Azure RBAC for Kubernetes authorization. Requires entraIntegrationEnabled.')
param azureRbacEnabled bool = false

@description('Microsoft Entra group object IDs granted cluster-admin. Used when entraIntegrationEnabled is true.')
param entraAdminGroupObjectIds array = []

@description('Disable local (non-Entra) Kubernetes accounts. Requires entraIntegrationEnabled.')
param disableLocalAccounts bool = false

@description('Create the AKS cluster as a private cluster.')
param privateClusterEnabled bool = false

@description('Private DNS zone mode or resource ID. Common values are system and none.')
param privateDNSZone string = 'system'

@description('Enable AKS workload identity and OIDC issuer support.')
param workloadIdentityEnabled bool = true

@description('Kubernetes namespace of the CycleCloud release. Required for the federated credential and the workload role assignments.')
param workloadIdentityNamespace string = ''

@description('Kubernetes service account used by the optional federated identity credential.')
param workloadIdentityServiceAccountName string = 'cyclecloud-sa'

@description('Subscription containing the resource group managed by the CycleCloud workload identity.')
param workloadResourceGroupSubscriptionId string = subscription().subscriptionId

@description('Resource group on which the CycleCloud workload identity receives Contributor.')
param workloadResourceGroupName string

@description('Subscription containing the existing CycleCloud storage account.')
param storageAccountSubscriptionId string = subscription().subscriptionId

@description('Resource group containing the existing CycleCloud storage account.')
param storageAccountResourceGroupName string

@description('Name of the existing CycleCloud storage account.')
param storageAccountName string

@description('Subscription containing the existing Azure Container Registry.')
param containerRegistrySubscriptionId string = subscription().subscriptionId

@description('Resource group containing the existing Azure Container Registry.')
param containerRegistryResourceGroupName string

@description('Name of the existing Azure Container Registry.')
param containerRegistryName string

@description('Tags applied to resources that support tags.')
param tags object = {}

// Default subnets are carved from the first VNet prefix so changing only the VNet
// range (for example, to avoid overlapping a peered hub) keeps them inside it.
var virtualNetworkPrimaryCidr = parseCidr(virtualNetworkAddressPrefixes[0]).cidr
var effectiveSystemNodeSubnetAddressPrefix = empty(systemNodeSubnetAddressPrefix) ? cidrSubnet(virtualNetworkAddressPrefixes[0], virtualNetworkPrimaryCidr + 1, 0) : systemNodeSubnetAddressPrefix
var effectiveApiServerSubnetAddressPrefix = empty(apiServerSubnetAddressPrefix) ? cidrSubnet(cidrSubnet(virtualNetworkAddressPrefixes[0], virtualNetworkPrimaryCidr + 1, 1), 28, 0) : apiServerSubnetAddressPrefix
var hubVirtualNetworkPeeringEnabled = !empty(hubVirtualNetworkResourceId)
var hubVirtualNetworkIdSegments = split(hubVirtualNetworkResourceId, '/')
var hubVirtualNetworkSubscriptionId = hubVirtualNetworkPeeringEnabled ? hubVirtualNetworkIdSegments[2] : subscription().subscriptionId
var hubVirtualNetworkResourceGroupName = hubVirtualNetworkPeeringEnabled ? hubVirtualNetworkIdSegments[4] : resourceGroupName
var federatedIdentityEnabled = workloadIdentityEnabled && !empty(workloadIdentityNamespace) && !empty(workloadIdentityServiceAccountName)

resource aksResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module network 'modules/network.bicep' = {
  scope: resourceGroup(resourceGroupName)
  params: {
    virtualNetworkName: virtualNetworkName
    location: location
    virtualNetworkAddressPrefixes: virtualNetworkAddressPrefixes
    tags: tags
    systemNodeSubnetName: systemNodeSubnetName
    systemNodeSubnetAddressPrefix: effectiveSystemNodeSubnetAddressPrefix
    apiServerVnetIntegrationEnabled: apiServerVnetIntegrationEnabled
    apiServerSubnetName: apiServerSubnetName
    apiServerSubnetAddressPrefix: effectiveApiServerSubnetAddressPrefix
  }
  dependsOn: [
    aksResourceGroup
  ]
}

// The hub side is created first so the spoke can set useRemoteGateways.
module hubToSpokePeering 'modules/virtualNetworkPeering.bicep' = if (hubVirtualNetworkPeeringEnabled && createHubToSpokePeering) {
  scope: resourceGroup(hubVirtualNetworkSubscriptionId, hubVirtualNetworkResourceGroupName)
  params: {
    localVirtualNetworkName: last(hubVirtualNetworkIdSegments)
    remoteVirtualNetworkId: network.outputs.virtualNetworkId
    allowGatewayTransit: useHubGateway
  }
}

module spokeToHubPeering 'modules/virtualNetworkPeering.bicep' = if (hubVirtualNetworkPeeringEnabled) {
  scope: resourceGroup(resourceGroupName)
  params: {
    localVirtualNetworkName: network.outputs.virtualNetworkName
    remoteVirtualNetworkId: hubVirtualNetworkResourceId
    useRemoteGateways: useHubGateway
  }
  dependsOn: [
    hubToSpokePeering
  ]
}

module controlPlaneIdentity 'modules/managedIdentity.bicep' = {
  scope: resourceGroup(resourceGroupName)
  params: {
    name: '${prefix}-aks-control-plane'
    location: location
    tags: tags
  }
  dependsOn: [
    aksResourceGroup
  ]
}

module workloadIdentity 'modules/managedIdentity.bicep' = if (workloadIdentityEnabled) {
  scope: resourceGroup(resourceGroupName)
  params: {
    name: '${prefix}-workload'
    location: location
    tags: tags
  }
  dependsOn: [
    aksResourceGroup
  ]
}

module networkRoleAssignments 'modules/networkRoleAssignments.bicep' = {
  scope: resourceGroup(resourceGroupName)
  params: {
    virtualNetworkName: network.outputs.virtualNetworkName
    systemNodeSubnetName: systemNodeSubnetName
    apiServerVnetIntegrationEnabled: apiServerVnetIntegrationEnabled
    apiServerSubnetName: apiServerSubnetName
    principalId: controlPlaneIdentity.outputs.principalId
  }
}

module aksCluster 'modules/aksCluster.bicep' = {
  scope: resourceGroup(resourceGroupName)
  params: {
    name: aksClusterName
    location: location
    dnsPrefix: '${prefix}-aks'
    nodeResourceGroupName: nodeResourceGroupName
    kubernetesVersion: kubernetesVersion
    adminUsername: adminUsername
    sshPublicKey: sshPublicKey
    controlPlaneIdentityResourceId: controlPlaneIdentity.outputs.resourceId
    systemNodeVmSize: systemNodeVmSize
    systemNodeCount: systemNodeCount
    systemNodeAutoscalingEnabled: systemNodeAutoscalingEnabled
    systemNodeMinCount: systemNodeMinCount
    systemNodeMaxCount: systemNodeMaxCount
    systemNodeSubnetId: network.outputs.systemNodeSubnetId
    apiServerVnetIntegrationEnabled: apiServerVnetIntegrationEnabled
    apiServerSubnetId: network.outputs.apiServerSubnetId
    networkPlugin: networkPlugin
    networkPluginMode: networkPluginMode
    serviceCidr: serviceCidr
    dnsServiceIP: dnsServiceIP
    podCidr: podCidr
    apiServerAuthorizedIpRanges: apiServerAuthorizedIpRanges
    entraIntegrationEnabled: entraIntegrationEnabled
    azureRbacEnabled: azureRbacEnabled
    entraAdminGroupObjectIds: entraAdminGroupObjectIds
    disableLocalAccounts: disableLocalAccounts
    privateClusterEnabled: privateClusterEnabled
    privateDNSZone: privateDNSZone
    workloadIdentityEnabled: workloadIdentityEnabled
    tags: tags
  }
  dependsOn: [
    aksResourceGroup
    networkRoleAssignments
  ]
}

module federatedIdentity 'modules/federatedIdentity.bicep' = if (federatedIdentityEnabled) {
  scope: resourceGroup(resourceGroupName)
  params: {
    managedIdentityName: workloadIdentity!.outputs.name
    issuerUrl: aksCluster.outputs.oidcIssuerUrl
    namespace: workloadIdentityNamespace
    serviceAccountName: workloadIdentityServiceAccountName
  }
}

// Roles are granted only when a workload can actually federate to the identity.
module workloadContributorRoleAssignment 'modules/contributorRoleAssignment.bicep' = if (federatedIdentityEnabled) {
  scope: resourceGroup(workloadResourceGroupSubscriptionId, workloadResourceGroupName)
  params: {
    principalId: workloadIdentity!.outputs.principalId
  }
}

module storageBlobDataContributorRoleAssignment 'modules/storageBlobDataContributorRoleAssignment.bicep' = if (federatedIdentityEnabled) {
  scope: resourceGroup(storageAccountSubscriptionId, storageAccountResourceGroupName)
  params: {
    storageAccountName: storageAccountName
    principalId: workloadIdentity!.outputs.principalId
  }
}

module acrPullRoleAssignment 'modules/acrPullRoleAssignment.bicep' = {
  scope: resourceGroup(containerRegistrySubscriptionId, containerRegistryResourceGroupName)
  params: {
    containerRegistryName: containerRegistryName
    principalId: aksCluster.outputs.kubeletIdentityObjectId
  }
}

output aksClusterResourceId string = aksCluster.outputs.resourceId
output aksClusterName string = aksCluster.outputs.name
output aksResourceGroupName string = resourceGroupName
output controlPlaneIdentityClientId string = controlPlaneIdentity.outputs.clientId
output workloadIdentityClientId string = workloadIdentityEnabled ? workloadIdentity!.outputs.clientId : ''
output virtualNetworkId string = network.outputs.virtualNetworkId
output oidcIssuerUrl string = aksCluster.outputs.oidcIssuerUrl
