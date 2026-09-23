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

@description('Subscription containing the existing virtual network.')
param virtualNetworkSubscriptionId string = subscription().subscriptionId

@description('Resource group containing the existing virtual network.')
param virtualNetworkResourceGroupName string

@description('Name of the existing virtual network.')
param virtualNetworkName string

@description('Name of the subnet used by AKS nodes.')
param systemNodeSubnetName string = 'SystemSubnet'

@description('CIDR assigned to the AKS system-node subnet.')
param systemNodeSubnetAddressPrefix string

@description('Enable API server VNet integration.')
param apiServerVnetIntegrationEnabled bool = false

@description('Name of the delegated API-server subnet.')
param apiServerSubnetName string = 'APIServerSubnet'

@description('CIDR assigned to the delegated API-server subnet.')
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

@description('Create the AKS cluster as a private cluster.')
param privateClusterEnabled bool = false

@description('Private DNS zone mode or resource ID. Common values are system and none.')
param privateDNSZone string = 'system'

@description('Enable AKS workload identity and OIDC issuer support.')
param workloadIdentityEnabled bool = true

@description('Kubernetes namespace used by the optional federated identity credential.')
param workloadIdentityNamespace string = ''

@description('Kubernetes service account used by the optional federated identity credential.')
param workloadIdentityServiceAccountName string = ''

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

resource aksResourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
  tags: tags
}

module network 'modules/network.bicep' = {
  scope: resourceGroup(virtualNetworkSubscriptionId, virtualNetworkResourceGroupName)
  params: {
    virtualNetworkName: virtualNetworkName
    systemNodeSubnetName: systemNodeSubnetName
    systemNodeSubnetAddressPrefix: systemNodeSubnetAddressPrefix
    apiServerVnetIntegrationEnabled: apiServerVnetIntegrationEnabled
    apiServerSubnetName: apiServerSubnetName
    apiServerSubnetAddressPrefix: apiServerSubnetAddressPrefix
  }
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
  scope: resourceGroup(virtualNetworkSubscriptionId, virtualNetworkResourceGroupName)
  params: {
    virtualNetworkName: virtualNetworkName
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

module federatedIdentity 'modules/federatedIdentity.bicep' = if (workloadIdentityEnabled && !empty(workloadIdentityNamespace) && !empty(workloadIdentityServiceAccountName)) {
  scope: resourceGroup(resourceGroupName)
  params: {
    managedIdentityName: workloadIdentity!.outputs.name
    issuerUrl: aksCluster.outputs.oidcIssuerUrl
    namespace: workloadIdentityNamespace
    serviceAccountName: workloadIdentityServiceAccountName
  }
}

module workloadContributorRoleAssignment 'modules/contributorRoleAssignment.bicep' = if (workloadIdentityEnabled) {
  scope: resourceGroup(workloadResourceGroupSubscriptionId, workloadResourceGroupName)
  params: {
    principalId: workloadIdentity!.outputs.principalId
  }
}

module storageBlobDataContributorRoleAssignment 'modules/storageBlobDataContributorRoleAssignment.bicep' = if (workloadIdentityEnabled) {
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
output oidcIssuerUrl string = aksCluster.outputs.oidcIssuerUrl
