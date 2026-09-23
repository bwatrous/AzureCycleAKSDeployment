@description('Name of the AKS cluster.')
param name string

@description('Azure region for the AKS cluster.')
param location string = resourceGroup().location

@description('DNS prefix for the AKS API server.')
param dnsPrefix string

@description('Name of the AKS node resource group.')
param nodeResourceGroupName string

@description('Optional Kubernetes version. Empty uses the Azure default.')
param kubernetesVersion string

@description('Administrator username for AKS Linux nodes.')
param adminUsername string

@description('SSH public key for AKS Linux nodes.')
param sshPublicKey string

@description('Resource ID of the AKS control-plane identity.')
param controlPlaneIdentityResourceId string

@description('VM size for the system node pool.')
param systemNodeVmSize string

@description('Initial system node count.')
param systemNodeCount int

@description('Enable cluster autoscaling for the system node pool.')
param systemNodeAutoscalingEnabled bool

@description('Minimum system node count when autoscaling is enabled.')
param systemNodeMinCount int

@description('Maximum system node count when autoscaling is enabled.')
param systemNodeMaxCount int

@description('Resource ID of the system-node subnet.')
param systemNodeSubnetId string

@description('Enable API server VNet integration.')
param apiServerVnetIntegrationEnabled bool

@description('Resource ID of the delegated API-server subnet.')
param apiServerSubnetId string

@description('Kubernetes networking implementation.')
param networkPlugin string

@description('Optional network plugin mode.')
param networkPluginMode string

@description('Kubernetes service CIDR.')
param serviceCidr string

@description('Kubernetes DNS service IP.')
param dnsServiceIP string

@description('Optional pod CIDR.')
param podCidr string

@description('Create the AKS cluster as a private cluster.')
param privateClusterEnabled bool

@description('Private DNS zone mode or resource ID.')
param privateDNSZone string

@description('Enable OIDC issuer and workload identity.')
param workloadIdentityEnabled bool

@description('Tags applied to the AKS cluster.')
param tags object = {}

resource aksCluster 'Microsoft.ContainerService/managedClusters@2025-04-02-preview' = {
  name: name
  location: location
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${controlPlaneIdentityResourceId}': {}
    }
  }
  properties: {
    kubernetesVersion: empty(kubernetesVersion) ? null : kubernetesVersion
    dnsPrefix: dnsPrefix
    nodeResourceGroup: nodeResourceGroupName
    oidcIssuerProfile: {
      enabled: workloadIdentityEnabled
    }
    securityProfile: {
      workloadIdentity: {
        enabled: workloadIdentityEnabled
      }
    }
    networkProfile: {
      networkPlugin: networkPlugin
      networkPluginMode: empty(networkPluginMode) ? null : networkPluginMode
      serviceCidr: serviceCidr
      dnsServiceIP: dnsServiceIP
      podCidr: empty(podCidr) ? null : podCidr
      loadBalancerSku: 'standard'
    }
    apiServerAccessProfile: {
      enablePrivateCluster: privateClusterEnabled
      privateDNSZone: privateClusterEnabled ? privateDNSZone : null
      enableVnetIntegration: apiServerVnetIntegrationEnabled
      subnetId: apiServerVnetIntegrationEnabled ? apiServerSubnetId : null
    }
    agentPoolProfiles: [
      {
        name: 'system'
        vmSize: systemNodeVmSize
        count: systemNodeCount
        enableAutoScaling: systemNodeAutoscalingEnabled
        minCount: systemNodeAutoscalingEnabled ? systemNodeMinCount : null
        maxCount: systemNodeAutoscalingEnabled ? systemNodeMaxCount : null
        osType: 'Linux'
        osSKU: 'AzureLinux'
        vnetSubnetID: systemNodeSubnetId
        mode: 'System'
      }
    ]
    linuxProfile: {
      adminUsername: adminUsername
      ssh: {
        publicKeys: [
          {
            keyData: sshPublicKey
          }
        ]
      }
    }
  }
}

output resourceId string = aksCluster.id
output name string = aksCluster.name
output oidcIssuerUrl string = workloadIdentityEnabled ? aksCluster.properties.oidcIssuerProfile.issuerURL : ''
output kubeletIdentityObjectId string = any(aksCluster.properties.identityProfile.kubeletidentity).objectId
