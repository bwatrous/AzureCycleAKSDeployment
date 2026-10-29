# Generalized AKS Bicep Deployment

This deployment creates an AKS cluster in a new resource group while reusing an existing virtual network and Azure Container Registry. It contains no user-specific defaults.

This guide owns the infrastructure configuration and deployment steps. Start with the [root walkthrough](../README.md) to build and push the image, complete this guide when directed, then follow the link at the end to continue installing CycleCloud.

From the repository root:

```bash
cd bicep
```

## Resources

- AKS resource group and cluster
- Dedicated AKS control-plane managed identity
- Optional workload managed identity and federated credential
- Contributor assignment for the workload identity, scoped to the selected CycleCloud workload resource group
- Storage Blob Data Contributor assignment for the workload identity, scoped to the selected storage account
- System-node subnet and optional delegated API-server subnet in an existing VNet
- Network Contributor assignments scoped to the AKS subnets
- AcrPull assignment scoped to the selected registry

The deployment grants Contributor to the workload identity only on the selected CycleCloud workload resource group. It grants Storage Blob Data Contributor to the same identity only on the selected storage account. It does not grant Virtual Machine Contributor.

## Prerequisites

- Azure CLI authenticated to the deployment subscription
- Owner or User Access Administrator plus resource deployment permissions on the relevant scopes, including the CycleCloud workload resource group
- An existing VNet, ACR, and CycleCloud storage account
- Permission to deploy to the VNet, ACR, and storage account subscriptions when they differ from the current subscription

## Configure

Create a personal parameter file from the tracked template:

```bash
cp main.parameters.json "main.parameters.${USER}.json"
```

Edit the copy using the table below. Replace every placeholder and review the sample address ranges before deploying. Personal parameter files matching `main.parameters.*.json` are ignored by Git.

| Settings | What to enter |
|----------|---------------|
| `prefix`, `resourceGroupName`, `nodeResourceGroupName`, `location` | Your naming prefix, new AKS resource groups, and Azure region. `aksClusterName` defaults to `<prefix>-aks` unless explicitly supplied. |
| `virtualNetworkSubscriptionId`, `virtualNetworkResourceGroupName`, `virtualNetworkName` | Existing VNet details. |
| `systemNodeSubnetName`, `systemNodeSubnetAddressPrefix` | Name and address range of the subnet to provision in the existing VNet for AKS node private IP addresses. |
| `serviceCidr` | Virtual address range for Kubernetes `ClusterIP` services; not a VNet subnet. |
| `dnsServiceIP` | CoreDNS service address inside `serviceCidr`. |
| `networkPluginMode`, `podCidr` | For the default standard Azure CNI mode, leave both empty. For Azure CNI Overlay, use `overlay` and a non-overlapping pod address range. |
| `apiServerVnetIntegrationEnabled` | Leave `false` for this walkthrough. See [optional API-server VNet integration](#optional-api-server-vnet-integration) to enable it. |
| `workloadIdentityEnabled`, `workloadIdentityNamespace`, `workloadIdentityServiceAccountName` | Use `true`, `default`, and `cyclecloud-sa` for the current chart, which hardcodes the service-account name. Federation requires workload identity to be enabled and both names to be non-empty. |
| `privateClusterEnabled` | Leave `false` for the default public, authenticated AKS API endpoint. Private clusters require network access and DNS connectivity to the AKS private DNS zone, configured outside this deployment. |
| `containerRegistrySubscriptionId`, `containerRegistryResourceGroupName`, `containerRegistryName` | The same ACR used to push the image in the root walkthrough. |
| `workloadResourceGroupSubscriptionId`, `workloadResourceGroupName` | Existing resource group where CycleCloud will manage compute resources. |
| `storageAccountSubscriptionId`, `storageAccountResourceGroupName`, `storageAccountName` | Existing CycleCloud storage account details. |

### Network Address Ranges

The node and optional API-server subnets must fit inside the existing VNet address space and must not overlap other subnets. Service and pod CIDRs must not overlap each other, the VNet, peered VNets, VPN address spaces, or connected on-premises networks.

### Optional API-Server VNet Integration

To enable this option, set `apiServerVnetIntegrationEnabled` to `true` and add the following parameters to your personal file. They name and allocate a dedicated delegated API-server subnet; the prefix is a subnet range, not the API server IP address. Replace the sample range to fit your network.

```json
"apiServerSubnetName": {
	"value": "APIServerSubnet"
},
"apiServerSubnetAddressPrefix": {
	"value": "10.10.1.0/28"
}
```

API-server VNet integration currently uses a preview AKS API; verify the required AKS provider feature is available in your subscription before enabling it.

## Validate And Deploy

Confirm the subscription in which the AKS resource group will be created is set properly:

```bash
az account show --query "{Name:name,Id:id}" -o table
```

### Run The Deployment

Deploy using your personal parameter file and the default SSH public key at `~/.ssh/id_rsa.pub`:

```bash
bash ./deploy.sh "./main.parameters.${USER}.json"
```

To use another public key file, run this command instead.

```bash
AKS_SSH_PUBLIC_KEY_FILE="$HOME/.ssh/id_ed25519.pub" bash ./deploy.sh "./main.parameters.${USER}.json"
```

Wait for a successful deployment before continuing.

The script validates the subscription deployment before creating it and generates the deployment name automatically. Its subscription deployment metadata location defaults to `westus2`; the resource region is set by the `location` parameter. It does not register preview features or modify local DNS and hosts files.

## Deployment Outputs And Application Installation

Record these values from the successful deployment output for the application steps:

| Output | Purpose |
|--------|---------|
| `aksClusterName` | Cluster name for credential retrieval. |
| `aksResourceGroupName` | Resource group for credential retrieval. |
| `workloadIdentityClientId` | Client ID for the CycleCloud service-account annotation when workload identity is enabled. |

All three values must be present for the chart walkthrough.

Bicep does not deploy Kubernetes resources or configure Helm values. Return to the repository root:

```bash
cd ..
```

Continue with [step 5 of the root walkthrough](../README.md#5-install-client-tools-and-connect-to-aks) for Kubernetes access, then apply the service account and install CycleCloud.