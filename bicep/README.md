# Generalized AKS Bicep Deployment

This deployment creates an AKS cluster in a new resource group while reusing an existing virtual network and Azure Container Registry. It contains no user-specific defaults.

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

Edit the new file, such as `main.parameters.nidhi.json`, and replace the placeholder workload resource group, VNet, ACR, and storage account values with resources from your Azure environment. The generated workload identity receives Contributor on `workloadResourceGroupName` and Storage Blob Data Contributor on the selected storage account. Change the sample address ranges if they overlap your network. Personal parameter files matching `main.parameters.*.json` are ignored by Git.

By default, `deploy.sh` reads the node SSH public key from `~/.ssh/id_rsa.pub`; no separate export is required. To use another key file:

```bash
AKS_SSH_PUBLIC_KEY_FILE="$HOME/.ssh/id_ed25519.pub" ./deploy.sh "./main.parameters.${USER}.json"
```

You can also provide the public key directly through `AKS_SSH_PUBLIC_KEY`.

For standard Azure CNI, set `networkPluginMode` and `podCidr` to empty strings. For Azure CNI Overlay, set `networkPluginMode` to `overlay` and provide a non-overlapping pod CIDR.

### Network Address Ranges

| Parameter | Purpose | Required by the default configuration |
|-----------|---------|---------------------------------------|
| `systemNodeSubnetAddressPrefix` | Subnet in the existing VNet where AKS nodes receive private IP addresses. | Yes |
| `serviceCidr` | Virtual address range used by Kubernetes `ClusterIP` services. It is not part of the VNet. | Yes |
| `dnsServiceIP` | Address assigned to CoreDNS. It must be inside `serviceCidr`. | Yes |
| `podCidr` | Address range assigned to pods when using Azure CNI Overlay or kubenet. | No for the default standard Azure CNI mode |
| `apiServerSubnetAddressPrefix` | Dedicated delegated subnet for API-server VNet integration. This is not the API server IP address. | No |

These ranges must not overlap each other, the existing VNet, peered VNets, VPN address spaces, or connected on-premises networks.

API-server VNet integration is disabled by default, so the default JSON file omits `apiServerSubnetName` and `apiServerSubnetAddressPrefix`. To enable it, set `apiServerVnetIntegrationEnabled` to `true` and add both parameters:

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

Select the subscription in which the AKS resource group will be created, then run:

```bash
az account set --subscription '<subscription-name-or-id>'
./deploy.sh
```

Deploy with your personal parameter file:

```bash
./deploy.sh "./main.parameters.${USER}.json"
```

The script validates the subscription deployment before creating it. It does not register preview features or modify local DNS and hosts files.

For a private cluster, configure DNS connectivity to the AKS private DNS zone through your network platform. Keep that network-specific DNS linking outside this reusable cluster deployment.

The default `privateClusterEnabled` value is `false`, so the AKS API endpoint is public but still requires Azure and Kubernetes authorization. After deployment, connect with:

```bash
az aks get-credentials \
    -n '<aks-cluster-name>' \
	-g '<aks-resource-group>'
	
kubectl get pods -A
```

## Apply The Service Account And Upgrade CycleCloud

The Bicep deployment creates the Azure workload identity and federated credential, but it does not deploy Kubernetes resources. Before installing or upgrading the Helm release, edit `../cyclecloud-sa.yaml` and set `azure.workload.identity/client-id` to the `workloadIdentityClientId` output from the Bicep deployment. Ensure its name and namespace match `workloadIdentityServiceAccountName` and `workloadIdentityNamespace` in the parameter file.

Apply the service account manually before running Helm:

```bash
kubectl apply -f ../cyclecloud-sa.yaml
kubectl get serviceaccount cyclecloud-sa -n default

helm upgrade --install cyclecloud ../charts/cyclecloud \
	--namespace default \
	-f ../values.yaml
```

Reapply the service account whenever its workload identity client ID, name, or namespace changes, before the next Helm upgrade.