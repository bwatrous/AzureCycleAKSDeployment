# Generalized AKS Bicep Deployment

This deployment creates an AKS cluster and a dedicated virtual network in a new resource group, optionally peers that network to an existing hub virtual network (hub-spoke), and reuses an existing Azure Container Registry. It contains no user-specific defaults.

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
- AKS virtual network with a system-node subnet and optional delegated API-server subnet
- Optional bidirectional peering to an existing hub virtual network
- Network Contributor assignments scoped to the AKS subnets
- AcrPull assignment scoped to the selected registry

Role assignments for the workload identity are created only when the federated credential is created, that is, when workload identity is enabled and both `workloadIdentityNamespace` and `workloadIdentityServiceAccountName` are set. The deployment grants Contributor to the workload identity only on the selected CycleCloud workload resource group. It grants Storage Blob Data Contributor to the same identity only on the selected storage account. It does not grant Virtual Machine Contributor.

## Prerequisites

- Azure CLI authenticated to the deployment subscription
- Owner or User Access Administrator plus resource deployment permissions on the relevant scopes, including the CycleCloud workload resource group
- An existing ACR and CycleCloud storage account
- Permission to deploy to the ACR, storage account, and (when peering) hub VNet subscriptions when they differ from the current subscription. Creating the hub-to-spoke peering requires Network Contributor (or `virtualNetworkPeerings/write` and `peer` permissions) on the hub VNet.

## Configure

Create a personal parameter file from the tracked template:

```bash
cp main.parameters.json "main.parameters.${USER}.json"
```

Edit the copy using the table below. Replace every placeholder and review the sample address ranges before deploying. Personal parameter files matching `main.parameters.*.json` are ignored by Git.

| Settings | What to enter |
|----------|---------------|
| `prefix`, `resourceGroupName`, `nodeResourceGroupName`, `location` | Your naming prefix, new AKS resource groups, and Azure region. `aksClusterName` defaults to `<prefix>-aks` unless explicitly supplied. |
| `virtualNetworkName`, `virtualNetworkAddressPrefixes` | Name and address space of the AKS virtual network created in the AKS resource group. Defaults to `<prefix>-vnet` and `10.10.0.0/16`. |
| `systemNodeSubnetName`, `systemNodeSubnetAddressPrefix` | Name and address range of the subnet for AKS node private IP addresses. Leave the prefix empty to use the first half of the first VNet prefix (for example, `10.10.0.0/17` for `10.10.0.0/16`). |
| `hubVirtualNetworkResourceId`, `createHubToSpokePeering`, `useHubGateway` | Optional hub-spoke peering. See [hub-spoke peering](#optional-hub-spoke-peering). Leave `hubVirtualNetworkResourceId` empty to skip peering. |
| `serviceCidr` | Virtual address range for Kubernetes `ClusterIP` services; not a VNet subnet. |
| `dnsServiceIP` | CoreDNS service address inside `serviceCidr`. |
| `networkPluginMode`, `podCidr` | For the default standard Azure CNI mode, leave both empty. For Azure CNI Overlay, use `overlay` and a non-overlapping pod address range. |
| `apiServerVnetIntegrationEnabled` | Leave `false` for this walkthrough. See [optional API-server VNet integration](#optional-api-server-vnet-integration) to enable it. |
| `workloadIdentityEnabled`, `workloadIdentityNamespace`, `workloadIdentityServiceAccountName` | Use `true`, `default`, and `cyclecloud-sa` for the current chart, which hardcodes the service-account name. Federation requires workload identity to be enabled and both names to be non-empty. |
| `apiServerAuthorizedIpRanges` | Optional public CIDR ranges allowed to reach the AKS API server. Empty allows all. Ignored for private clusters. |
| `entraIntegrationEnabled`, `azureRbacEnabled`, `entraAdminGroupObjectIds`, `disableLocalAccounts` | Optional Microsoft Entra authentication for the cluster. All default to off. `azureRbacEnabled` and `disableLocalAccounts` require `entraIntegrationEnabled`; with local accounts disabled, use `kubelogin` and an Entra identity to access the cluster. |
| `privateClusterEnabled` | Leave `false` for the default public, authenticated AKS API endpoint. Private clusters require network access and DNS connectivity to the AKS private DNS zone, configured outside this deployment. |
| `containerRegistrySubscriptionId`, `containerRegistryResourceGroupName`, `containerRegistryName` | The same ACR used to push the image in the root walkthrough. |
| `workloadResourceGroupSubscriptionId`, `workloadResourceGroupName` | Existing resource group where CycleCloud will manage compute resources. |
| `storageAccountSubscriptionId`, `storageAccountResourceGroupName`, `storageAccountName` | Existing CycleCloud storage account details. |

### Network Address Ranges

To fit alongside a peered hub, usually only `virtualNetworkAddressPrefixes` needs to change: when the subnet prefixes are empty, they are derived from the first VNet prefix, which must then be `/26` or larger. Explicit subnet prefixes must fit inside `virtualNetworkAddressPrefixes` and must not overlap each other. When peering, `virtualNetworkAddressPrefixes` must not overlap the hub VNet or any network reachable through it. Service and pod CIDRs must not overlap each other, the VNet, peered VNets, VPN address spaces, or connected on-premises networks.

### Optional Hub-Spoke Peering

Set `hubVirtualNetworkResourceId` to the full resource ID of an existing hub VNet, for example `/subscriptions/<sub-id>/resourceGroups/<hub-rg>/providers/Microsoft.Network/virtualNetworks/<hub-vnet>`. The deployment then creates both peerings with forwarded traffic allowed.

- `createHubToSpokePeering`: set to `false` if you lack permissions on the hub; the hub owner must then create the hub-to-spoke peering.
- `useHubGateway`: set to `true` to route spoke traffic through a VPN or ExpressRoute gateway in the hub. The hub must have a gateway, and the hub-side peering is created first with gateway transit enabled.

Custom DNS servers and route tables (for example, forcing egress through a hub firewall) are not configured by this deployment.

### Optional API-Server VNet Integration

To enable this option, set `apiServerVnetIntegrationEnabled` to `true`. The delegated API-server subnet is named by `apiServerSubnetName`. If `apiServerSubnetAddressPrefix` is empty, it uses the first `/28` in the second half of the first VNet prefix (for example, `10.10.128.0/28` for `10.10.0.0/16`). To choose the range explicitly, set it in your personal file; the prefix is a subnet range, not the API server IP address.

```json
"apiServerSubnetName": {
	"value": "APIServerSubnet"
},
"apiServerSubnetAddressPrefix": {
	"value": "10.10.128.0/28"
}
```

The template uses a GA AKS API version. Verify that API-server VNet integration is available in your region before enabling it.

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