# AzureCycleAKSDeployment

Deploy Azure CycleCloud into an [Azure Kubernetes Service (AKS)](https://docs.microsoft.com/en-us/azure/aks/) cluster. The cluster is provisioned with the [AzureRM Terraform Provider](https://www.terraform.io/docs/providers/azurerm/r/kubernetes_cluster.html), the container image is stored in an [Azure Container Registry (ACR)](https://docs.microsoft.com/en-us/azure/container-registry/), and CycleCloud itself is installed with the Helm chart under [`charts/cyclecloud`](charts/cyclecloud).

Throughout this README we use the example ACR registry name `cccontainerreguswest2` and the `westus2` region. Replace these with your own values.

## Repository layout

| Path | Purpose |
|------|---------|
| [`docker/cyclecloud8`](docker/cyclecloud8) | Dockerfile and startup scripts for the CycleCloud 8 container image |
| [`terraform-aks-azure-cni`](terraform-aks-azure-cni) | Terraform to provision the AKS cluster (Azure CNI) and supporting identities |
| [`charts/cyclecloud`](charts/cyclecloud) | Helm chart used to deploy the CycleCloud pod |

## Pre-Requisites

* [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli)
* [Docker](https://docs.docker.com/get-docker/)
* [Terraform](https://developer.hashicorp.com/terraform/install)
* [kubectl](https://kubernetes.io/docs/tasks/tools/)
* [Helm](https://helm.sh/docs/intro/install/)
* An existing VNet/subnet and an [Azure Container Registry](https://docs.microsoft.com/en-us/azure/container-registry/) for the CycleCloud container image. The Terraform module attaches to an existing network and ACR (see [Deploy the AKS cluster](#deploy-the-aks-cluster)).

## Build and push the CycleCloud container image

Log in to the Azure CLI:

```bash
az login
```

Create the Container Registry (skip if you already have one):

```bash
az group create --name cccontainerreg-rg --location westus2
az acr create --resource-group cccontainerreg-rg --name cccontainerreguswest2 --sku Premium
```

Build and push the CycleCloud 8 image. The [`docker/cyclecloud8`](docker/cyclecloud8) directory contains multiple Dockerfile variants (a default and `Dockerfile.ubuntu*`); choose the one that matches your intended base OS. The example below builds the default Dockerfile:

```bash
cd docker/cyclecloud8
az acr login -n cccontainerreguswest2
docker build -t cccontainerreguswest2.azurecr.io/cyclecloud8:latest .
docker push cccontainerreguswest2.azurecr.io/cyclecloud8:latest
```

> [!NOTE]
> To build a specific variant, pass `-f`, e.g. `docker build -f Dockerfile.ubuntu -t cccontainerreguswest2.azurecr.io/cyclecloud8:latest .`

## Deploy the AKS cluster

Provision the AKS cluster with Terraform. The module in [`terraform-aks-azure-cni`](terraform-aks-azure-cni) expects an **existing** VNet, subnet, and ACR, and creates the cluster in a new resource group named `<prefix>-rg` (default prefix `cc-aks-tf`).

Set the required variables (via a `terraform.tfvars` file, `-var` flags, or `TF_VAR_*` environment variables). The key inputs from [`variables.tf`](terraform-aks-azure-cni/variables.tf) are:

| Variable | Description |
|----------|-------------|
| `prefix` | Prefix for all created resources (default `cc-aks-tf`) |
| `location` | Azure region (use the same region as the ACR) |
| `network_rg` | Resource group of the existing VNet |
| `vnet_name` | Existing VNet name |
| `subnet_name` | Existing subnet name |
| `acr_id` | Resource ID of the existing ACR |
| `ssh_key` | SSH public key for the AKS nodes |
| `kubernetes_version` | Kubernetes version for the cluster (verify it is still supported in your region) |
| `machine_type` | VM size for the default node pool (default `Standard_D4s_v3`) |

Then apply:

```bash
cd terraform-aks-azure-cni
terraform init
terraform apply
```

> [!NOTE]
> The Terraform module runs several `local-exec` provisioners on `terraform apply` that automate cluster setup: it fetches kubeconfig credentials (`az aks get-credentials`), assigns the kubelet identity the **Virtual Machine Contributor** and **Managed Identity Operator** roles, attaches the ACR (`az aks update --attach-acr`), and creates a user-assigned identity (`<prefix>-ui`) with **Contributor** on the subscription. As a result, most of the manual role-assignment and credential steps from older versions of this guide are no longer required. Review [`main.tf`](terraform-aks-azure-cni/main.tf) to confirm the behavior for your environment.

If you prefer to create the cluster manually (Portal or Azure CLI), ensure it is deployed to the same region as the ACR and that the cluster and node identities are permissioned equivalently.

## Deploy CycleCloud with Helm

CycleCloud is deployed via the Helm chart in [`charts/cyclecloud`](charts/cyclecloud). Configure the deployment by editing [`values.yaml`](charts/cyclecloud/values.yaml) or by passing `--set`/`-f` overrides.

Get the AKS credentials (the Terraform provisioner does this automatically, but you can refresh them):

```bash
az aks get-credentials --resource-group cc-aks-tf-rg --name cc-aks-tf-cluster
```

Install or upgrade the release:

```bash
cd charts
helm upgrade --install cyclecloud ./cyclecloud \
  --namespace cyclecloud --create-namespace \
  -f cyclecloud/values.yaml
```

### Key `values.yaml` parameters

The most commonly edited values under `cycle:` and related keys:

| Parameter | Description |
|-----------|-------------|
| `cycle.username` / `cycle.password` | Initial CycleCloud admin credentials |
| `cycle.containerImage` | Full image reference, e.g. `cccontainerreguswest2.azurecr.io/cyclecloud8:latest` |
| `cycle.resourceGroup` | Resource group where CycleCloud provisions compute resources |
| `cycle.storage` | Storage account used for the initial account when `configureDefaultAccount` is true |
| `cycle.configureDefaultAccount` | Create a default Azure account on first boot |
| `cycle.userPubKey` | SSH public key registered with the CycleCloud user |
| `cycle.dataDiskSize` / `cycle.backupsDiskSize` | Persistent volume sizes |
| `cycle.webServerMaxHeapSize` | JVM heap for the CycleCloud web server |
| `cycle.generate_cs_config` | When `true`, the container generates `cycle_server.properties`; set `false` to supply it via ConfigMap |
| `azureIdentity.resourceID` / `azureIdentity.clientID` | User-assigned managed identity used for orchestration (the `<prefix>-ui` identity created by Terraform) |
| `cycle.useWorkloadIdentity` | Use [Azure AD Workload Identity](https://azure.github.io/azure-workload-identity/) instead of `azureIdentity`. When `true`, `azureIdentity` is not required |
| `cycle.storage_managed_identity` | Resource ID of the managed identity used for storage. Requires **Storage Blob Data Reader** on the storage account |
| `service.type` / `service.port` | Kubernetes Service type and port (defaults to a `LoadBalancer` on `443`) |

> [!IMPORTANT]
> If you use a managed identity for storage, the CycleCloud identity (Workload Identity or managed identity) also needs the **Storage Blob Data Contributor** role on the storage account.

### Identity options

This chart supports two identity models for CycleCloud's Azure orchestration:

* **User-assigned managed identity** — set `azureIdentity.resourceID` and `azureIdentity.clientID` to the `<prefix>-ui` identity created by Terraform.
* **Workload Identity (recommended)** — set `cycle.useWorkloadIdentity: true` and configure the associated federated credential / service account. With Workload Identity enabled, `azureIdentity` is not required.

> [!NOTE]
> Earlier versions of this guide used the now-archived [AAD Pod Identity](https://github.com/Azure/aad-pod-identity) project. New deployments should prefer Workload Identity. Note that the Terraform module still applies AAD Pod Identity RBAC manifests; remove or update those provisioners if you standardize on Workload Identity.

### Microsoft Entra ID authentication (optional)

The chart can configure CycleCloud to authenticate against Microsoft Entra ID. Set `cycle.entraEnabled: true` and provide the related values:

| Parameter | Description |
|-----------|-------------|
| `cycle.entraTenantId` | Entra tenant ID |
| `cycle.entraClientId` | Application (client) ID |
| `cycle.entraObjectId` | Object ID of the service principal or managed identity |
| `cycle.entraAuthEndpoint` | Entra authentication endpoint |
| `cycle.entraUsername` | Entra username to map |
| `cycle.entraUID` | UID assigned to the Entra user (default `19000`) |

## Uninstall

```bash
helm uninstall cyclecloud --namespace cyclecloud
cd terraform-aks-azure-cni && terraform destroy
```



