@description('Name of the existing workload managed identity.')
param managedIdentityName string

@description('OIDC issuer URL exposed by AKS.')
param issuerUrl string

@description('Kubernetes namespace containing the service account.')
param namespace string

@description('Kubernetes service account federated with the managed identity.')
param serviceAccountName string

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: managedIdentityName
}

resource federatedIdentityCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: managedIdentity
  name: '${namespace}-${serviceAccountName}'
  properties: {
    issuer: issuerUrl
    subject: 'system:serviceaccount:${namespace}:${serviceAccountName}'
    audiences: [
      'api://AzureADTokenExchange'
    ]
  }
}
