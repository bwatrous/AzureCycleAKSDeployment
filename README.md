# AzureCycleAKSDeployment

Deploy Azure CycleCloud in a new [Azure Kubernetes](https://docs.microsoft.com/en-us/azure/aks/) cluster using the [AzureRM Terraform Provider](https://www.terraform.io/docs/providers/azurerm/r/kubernetes_cluster.html) and storing the container images in an [Azure Container Registry](https://docs.microsoft.com/en-us/azure/container-registry/).


For this  README, we'll use  the name 'cccontainerreguswest2' for the ACR registry and use the "West US 2" region in Azure.

## Pre-Requisites

* Install the Azure CLI
* Install Docker and Terraform
* Prepare a new [Azure Container Registry](https://docs.microsoft.com/en-us/azure/container-registry/) to store the CycleCloud container images.


## Build and push the Azure Cyclecloud Container Image

Log in to the Azure CLI
``` bash
az login
```

Create the Container Registry
``` bash
az group create --name cccontainerreg-rg --location westus2
az acr create --resource-group cccontainerreg-rg --name cccontainerreguswest2 --sku Premium
```

### CycleCloud 8.x
Next, build and deploy the CycleCloud 8 container to ACR as follows:
``` bash
cd docker/cyclecloud8
az acr login -n cccontainerreguswest2
docker build -t cccontainerreguswest2.azurecr.io/cyclecloud8:latest .
docker push cccontainerreguswest2.azurecr.io/cyclecloud8:latest
```


### CycleCloud 7.x
If you require CycleCloud 7.9.x, you can build and deploy a 7.9 container to ACR as follows:
``` bash
cd docker/cyclecloud7
az acr login -n cccontainerreguswest2
docker build -t cccontainerreguswest2.azurecr.io/cyclecloud7:latest .
docker push cccontainerreguswest2.azurecr.io/cyclecloud7:latest
```


## Deploy the AKS cluster

Next, deploy the AKS cluster using Terraform.  (Alternatively, you may create the AKS cluster manually via the Portal  or Azure CLI.)

Ensure that the cluster is deployed to the same  region as the ACR registry when prompted.

```bash
cd terraform
terraform apply

```

## Assign the Roles to the Cluster's Managed Identity

Once the AKS cluster is deployed, the System Assigned Managed Identity for the AKS cluster and the User Assigned Managed Identity for the CycleCloud Pod must be permissioned.

> [!IMPORTANT]
> These instructions are based on the [AAD Pod Identity](https://github.com/Azure/aad-pod-identity) readme and may be out of date.  Refer to source for the most up-to-date instructions.

First, permission the AKS Cluster's system-assigned identity following the instructions in [AAD Pod Identity Pre-requisites](https://github.com/Azure/aad-pod-identity/blob/master/docs/readmes/README.msi.md#pre-requisites---role-assignments) documentation.
```bash
SUBSCRIPTION_ID=$( az account show --query id -o tsv )
AGENT_POOL_CLIENT_ID=$( az aks show -g cc-aks-tf-rg -n cc-aks-tf-cluster --query identityProfile.kubeletidentity.clientId -o tsv )

az role assignment create --role "Virtual Machine Contributor" --assignee ${AGENT_POOL_CLIENT_ID} --scope /subscriptions/${SUBSCRIPTION_ID}/resourceGroups/cc-aks-tf-nodes-rg
az role assignment create --role "Managed Identity Operator" --assignee ${AGENT_POOL_CLIENT_ID}  --scope /subscriptions/${SUBSCRIPTION_ID}/resourceGroups/cc-aks-tf-nodes-rg
az role assignment create --role "Managed Identity Operator" --assignee ${AGENT_POOL_CLIENT_ID}  --scope /subscriptions/${SUBSCRIPTION_ID}/resourceGroups/cc-aks-tf-nodes-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/cc-aks-tf-cluster-agentpool
az role assignment create --role "Managed Identity Operator" --assignee ${AGENT_POOL_CLIENT_ID}  --scope /subscriptions/${SUBSCRIPTION_ID}/resourceGroups/cc-aks-tf-nodes-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/cc-aks-tf-ui

```


## Launch the CycleCloud AKS Pod

Get the AKS Credentials for the new cluster
```bash
az aks get-credentials --resource-group cc-aks-tf-rg  --name cc-aks-tf
```

After the terraform cluster is up, we still need to enable [AAD Pod Identity](https://github.com/Azure/aad-pod-identity):
```bash
kubectl apply -f https://raw.githubusercontent.com/Azure/aad-pod-identity/master/deploy/infra/deployment-rbac.yaml
```

Next, attach the ACR registry to the cluster to allow it to pull the container image:
```bash
az aks update --attach-acr cccontainerreguswest2 --resource-group cc-aks-tf-rg  --name cc-aks-tf
```

Now permission the CycleCloud User-Assigned Managed Identity:
```bash
SUBSCRIPTION_ID=$( az account show --query id -o tsv )
CLIENT_ID=$( az identity show --resource-group cc-aks-tf-nodes-rg --name cc-aks-tf-ui --query clientId -o tsv )

az role assignment create --assignee ${CLIENT_ID} --role=Contributor --scope=/subscriptions/${SUBSCRIPTION_ID}
```

Optionally, create a new Resource Group to hold the compute cluster resources (if you do not already have a target Resource Group).
This should generally be a different Resource Group from the AKS nodes Resource Group.
```bash
az group create -l westus2 -n cccomputerguswest2
```

Finally, we're ready to deploy the CycleCloud Pod.   By default, this deployment will have a public IP.  To disable, the public IP, uncomment the "annotations" in the Service definition in `cyclecloud.yaml`.

> [!IMPORTANT]
> Update the cyclecloud YAML File with the new Managed Identity ID Resource ID and Client ID, and other variables.  The Client ID will change for each terraform cluster deployment even if the rest of the variables are constant.

```bash
SUBSCRIPTION_ID=$( az account show --query id -o tsv )
CLIENT_ID=$( az identity show --resource-group cc-aks-tf-nodes-rg --name cc-aks-tf-ui --query clientId -o tsv )
CYCLECLOUD_USERNAME="your_username"
CYCLECLOUD_PASSWORD="your_password"
CYCLECLOUD_STORAGE="ccstorageuswest2"
CYCLECLOUD_USER_PUBKEY="your SSH pub key here"
# Use the cyclecloud7:latest tag for a CycleCloud 7.9.x container instead of CycleCloud 8
CYCLECLOUD_CONTAINER_IMAGE="cccontainerreguswest2.azurecr.io/cyclecloud8:latest"
CYCLECLOUD_RESOURCE_GROUP="cccomputerguswest2"

# Feel free to skip the sed commands and simply  edit the yaml file
sed -i.bak "s|%SUBSCRIPTION_ID%|${SUBSCRIPTION_ID}|g" ./cyclecloud.yaml
sed -i.bak "s|%CLIENT_ID%|${CLIENT_ID}|g" ./cyclecloud.yaml
sed -i.bak "s|%CYCLECLOUD_USERNAME%|${CYCLECLOUD_USERNAME}|g" ./cyclecloud.yaml
sed -i.bak "s|%CYCLECLOUD_PASSWORD%|${CYCLECLOUD_PASSWORD}|g" ./cyclecloud.yaml
sed -i.bak "s|%CYCLECLOUD_STORAGE%|${CYCLECLOUD_STORAGE}|g" ./cyclecloud.yaml
sed -i.bak "s|%CYCLECLOUD_USER_PUBKEY%|${CYCLECLOUD_USER_PUBKEY}|g" ./cyclecloud.yaml
sed -i.bak "s|%CYCLECLOUD_CONTAINER_IMAGE%|${CYCLECLOUD_CONTAINER_IMAGE}|g" ./cyclecloud.yaml
sed -i.bak "s|%CYCLECLOUD_RESOURCE_GROUP%|${CYCLECLOUD_RESOURCE_GROUP}|g" ./cyclecloud.yaml

kubectl apply -f cyclecloud.yaml
```

## Description of values.yaml parameters for helm chart

azureIdentity: This parameter is only required when using managed identity for cyclecloud orchestration. It basically stores the resource id of managed identity and client id which would be used in Deployment.yaml file in case of using pod identity.

Parameters under Values.cycle are cyclecloud related parameters.Most of them are self-explantory, details of few:

configureDefaultAccount: If you want to create an azure account by default then it will be created if set to true.

storage: Specifies the storage account to use in case of intial account creation.

useWorkloadIdentity: If you are using workload identity then this needs to be set to true and azureIdentity is not required in this case.

storage_managed_identity: When using managed identity for storage account you need to set this to true. Also you need to assign Storage Blob Reader role to this identity for storage account. 
Note: If you are using managed identity for storage you also need to assign Storage Blob Data Contributor role to the Cyclecloud identity (Workload Identity or Managed Identity)

generate_cs_config: By default the container script will generate cycle_server.properties file but if you want to use ConfigMap for cycle_server.properties then you can disable this option to skip generation of file. 



