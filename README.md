# Deploy Azure CycleCloud on AKS

Build a CycleCloud 8 insiders image, push it to Azure Container Registry (ACR), deploy Azure Kubernetes Service (AKS) with Bicep, and install CycleCloud with Helm.

This walkthrough follows the tested WSL workflow. Run the commands in a **WSL Bash terminal**, with Docker available in WSL. Azure authentication and Docker authentication are separate steps so that Azure CLI does not try to invoke Windows Docker.

Follow this page in order: build and push the image, complete the linked Bicep guide in step 4, then return here to connect to AKS and install CycleCloud. Infrastructure configuration and deployment instructions live only in the Bicep guide. The service account must currently be applied separately.

## 1. Get the repository and check prerequisites

All subsequent commands run from the repository root unless a command explicitly changes directory.

You need:

- Azure CLI authenticated to the appropriate tenant and subscription.
- Docker accessible from WSL.
- An existing ACR, virtual network, CycleCloud workload resource group, and CycleCloud storage account.
- Permissions to deploy resources and assign Azure roles at the relevant scopes; see the [Bicep prerequisites](./bicep/README.md#prerequisites).
- An SSH public key for AKS nodes.
- Linux `kubectl` and Helm available in WSL before installing the application; installation guidance is in step 5.

```bash
az login
az version
docker version
az account set --subscription '<deployment-subscription-name-or-id>'
az account show --query "{Name:name,Id:id}" -o table
```

Confirm that the selected subscription is the one you intend to use before continuing.

## 2. Build the CycleCloud image in WSL

Set these values for the existing ACR where you will push the image. Use this same registry when configuring Bicep in step 4:

```bash
ACR_NAME='<container-registry-name>'
ACR_SUBSCRIPTION_ID='<acr-subscription-id>'
ACR_LOGIN_SERVER=$(az acr show --name "$ACR_NAME" --subscription "$ACR_SUBSCRIPTION_ID" --query loginServer --output tsv)
IMAGE_TAG='<your-alias>-symphony-test'
IMAGE="${ACR_LOGIN_SERVER}/cyclecloud:${IMAGE_TAG}"
```

The build context must be the [CycleCloud 8 Docker directory](./docker/cyclecloud8/). Use the [Ubuntu insiders Dockerfile](./docker/cyclecloud8/Dockerfile.ubuntu.insiders) explicitly:

```bash
cd docker/cyclecloud8
docker build -f Dockerfile.ubuntu.insiders -t "$IMAGE" .
cd ../..
```

This builds an insiders/testing image; it is not a pinned production-release recipe.

### Smoke-test the image before pushing

From the repository root, run the [container smoke test](./docker/cyclecloud8/tests/smoke.sh):

```bash
bash docker/cyclecloud8/tests/smoke.sh "$IMAGE"
```

The test requires Docker, Bash, and OpenSSL on the host and an already-built image.
It tests three disposable containers sequentially using the normal startup script:
one with image-provided directories, then one with empty host folders bind-mounted
at `/opt/cycle_server/{work,system,config,data}`, then a fresh container mounting
those same populated folders. Both volume cases use a read-only root filesystem
and writable temporary mounts for `/tmp`, `/opt/cycle_server/logs`, and
`/opt/cycle_server/.ssh`, matching the chart's writable paths.
Each case checks that the
default user and startup process run as `cycle_server` (UID/GID `1169`), waits for
local CLI configuration to be refreshed by that startup, checks CycleCloud's
service status, and requires HTTP 200
from HTTPS `/health_monitor`, the endpoint used by the chart's probes.
It exits nonzero on failure and prints the last 100 startup log lines.

The empty-volume case creates a unique `.cyclecloud-smoke.*` working directory
under the current directory. An isolated root helper container sets ownership of
the four empty folders to `1169:1169`, matching writable Kubernetes volumes; the
application itself still runs as the image's default non-root user. The test
verifies that startup populates all four folders, restores the expected system
version, and leaves the mounted directories writable.
Before replacing the container, the test writes a marker in each mounted directory
and stops CycleCloud cleanly. The existing-volume case repeats the startup and
health checks and verifies that all four markers survived. The host folders are
retained between these cases and removed only at the end.

The chart invokes the startup script through Bash without modifying image files
at runtime, so it also supports `securityContext.containerSecurityContext.readOnlyRootFilesystem: true`.
The default remains `false`.

The containers have no external network, published ports, or Azure
credentials. Only the disposable test folders are host-mounted.
The installer uses its local `--dryrun` mode and
`--noDefaultAccount`, with a disposable admin password. TLS certificate validation
is disabled only for this isolated container's self-signed certificate, matching
the chart's probes. Containers, anonymous volumes, and test folders are removed
on exit (a root helper removes files owned by the container user).
This is an integration smoke test, not an Azure identity, Kubernetes PVC,
package-vulnerability, or compute-provisioning test.

Startup defaults to a 900-second timeout per case; override it with a second argument:

```bash
bash docker/cyclecloud8/tests/smoke.sh "$IMAGE" 1200
```

## 3. Authenticate WSL Docker and push the image

Do not use plain `az acr login` for this workflow. In a mixed Windows/WSL setup it can try to run Windows Docker. Instead, obtain an ACR token and pass it to the Docker client running in WSL:

```bash
TOKEN=$(az acr login -n "$ACR_NAME" --expose-token --output tsv --query accessToken)

test -n "$TOKEN" && echo "TOKEN OK" || echo "TOKEN FAILED"
```

Continue only if the Azure command succeeded and you see `TOKEN OK`. Do not print or share the token.

```bash
echo "$TOKEN" | docker login "$ACR_LOGIN_SERVER" --username 00000000-0000-0000-0000-000000000000 --password-stdin
```

After Docker reports `Login Succeeded`, push the image:

```bash
docker push "$IMAGE"
```

Keep the exact image reference for the Helm configuration in step 6.

## 4. Configure and deploy AKS with Bicep

Follow the [Bicep deployment guide](./bicep/README.md) in the same WSL terminal.

At the end, the guide asks you to record the deployment outputs and return to the repository root. Then continue with step 5 below.

## 5. Install client tools and connect to AKS

Set the cluster details using the outputs recorded in the Bicep guide:

```bash
AKS_NAME='<aksClusterName-output>'
AKS_RESOURCE_GROUP='<aksResourceGroupName-output>'
```

Check for Linux tools in WSL:

```bash
kubectl version --client
helm version --short
```

If `kubectl` is missing, follow the [Linux installation instructions](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/). Choose a client version within one minor version of the AKS API server, rather than copying a fixed version from another deployment. You can check the cluster version with:

```bash
az aks show --name "$AKS_NAME" --resource-group "$AKS_RESOURCE_GROUP" --query kubernetesVersion --output tsv
```

For Helm, follow the [official installation instructions](https://helm.sh/docs/intro/install/). On WSL installations with Snap enabled, the tested installation command was:

```bash
sudo snap install helm --classic
helm version --short
```

### Choose the kubeconfig location before retrieving credentials

For a WSL-local kubeconfig:

```bash
export KUBECONFIG="$HOME/.kube/config"
```

Alternatively, to share the Windows kubeconfig as in the tested workflow, use this **instead**, replacing the Windows username:

```bash
export KUBECONFIG='/mnt/c/Users/<windows-username>/.kube/config'
```

Use one location consistently. Get credentials into that file and explicitly select the context:

```bash
az aks get-credentials --name "$AKS_NAME" --resource-group "$AKS_RESOURCE_GROUP" --file "$KUBECONFIG" --context "$AKS_NAME"

kubectl config use-context "$AKS_NAME"
kubectl config current-context
kubectl get nodes
kubectl get pods -A
```

The context must match your intended cluster; it was `cyclecloud-aks` in the tested deployment. Stop if the context is wrong or the API server is unreachable.

If you run Windows Azure CLI from WSL, it may require a Windows-form path for `--file`. Use the equivalent path, such as `C:/Users/<windows-username>/.kube/config`, for that Azure CLI argument while keeping `KUBECONFIG` set to the `/mnt/c/...` path for Linux `kubectl`.

## 6. Configure CycleCloud and apply its service account

This is still a manual configuration step. Bicep does not update the chart or the Kubernetes service-account manifest.

Edit the [service-account manifest](./charts/cyclecloud/cyclecloud-sa.yaml):

- Set `metadata.annotations.azure.workload.identity/client-id` to the literal `workloadIdentityClientId` output recorded in the Bicep guide.
- Keep `metadata.name: cyclecloud-sa` and `metadata.namespace: default`, matching the Bicep federation settings.
- Do not put shell variables or Helm expressions in this plain Kubernetes YAML.

Configure the [chart values](./charts/cyclecloud/values.yaml) for your environment:

| Value | Setting |
|-------|---------|
| `cycle.containerImage` | The exact image pushed in step 3, including registry and tag. Run `printf '%s\n' "$IMAGE"` to display it. |
| `cycle.useWorkloadIdentity` | `true`. |
| `cycle.configureDefaultAccount` | `true` to configure the initial Azure account. |
| `cycle.storage` | CycleCloud storage account name from the infrastructure inputs. |
| `cycle.resourceGroup` | CycleCloud workload resource group, not the AKS node resource group. |
| `cycle.username`, `cycle.password` | Your initial CycleCloud login credentials. |
| `cycle.userPubKey` | Your SSH public key for CycleCloud compute access. |
| `cycle.storage_managed_identity` | Resource ID of the identity used by compute nodes for storage access; do not assume it is the pod workload identity. |
| `resources`, `cycle.webServerMaxHeapSize` | Resource requests, limits, and JVM heap suitable for your nodes. |

The tested small configuration used a 1-CPU / 8-GiB request, a 2-CPU / 8-GiB limit, and a `4096M` heap on a 4-vCPU / 16-GiB node. This is test sizing, not a production recommendation.

> [!WARNING]
> The chart values file is tracked by Git. Do not stage or commit it with passwords or personal configuration. The current chart passes the password into the container environment; this walkthrough does not change that behavior.

The pod identity client ID belongs in the service-account annotation. Setting `azureIdentity.clientID` in chart values does not configure the current templates.

From the repository root, validate and apply the service account:

```bash
kubectl apply --dry-run=server -f ./charts/cyclecloud/cyclecloud-sa.yaml
kubectl apply -f ./charts/cyclecloud/cyclecloud-sa.yaml
kubectl get serviceaccount cyclecloud-sa -n default
```

Helm does not create this account because the manifest is outside the chart's templates directory. Reapply it before a Helm upgrade if its identity annotation changes.

## 7. Validate and install the Helm chart

The service defaults to a public `LoadBalancer`. Review network exposure before installing.

```bash
helm lint ./charts/cyclecloud
```

Render the chart and validate it against the cluster:

```bash
set -o pipefail
helm template cyclecloud ./charts/cyclecloud --namespace default | kubectl apply --dry-run=server --validate=strict -f -
```

Both rendering and server validation must succeed. These checks do not prove image availability or runtime Azure permissions.

Install or upgrade:

```bash
helm upgrade --install cyclecloud ./charts/cyclecloud --namespace default
```

## 8. Wait for CycleCloud to become ready

```bash
kubectl get pods,pvc,svc -n default
kubectl rollout status statefulset/cyclecloud -n default --timeout=15m
kubectl get pod cyclecloud-0 -n default
```

Initial startup can take several minutes. The tested deployment progressed from `ContainerCreating` to `0/1 Running`, then reached:

```text
NAME           READY   STATUS    RESTARTS   AGE
cyclecloud-0   1/1     Running   0          4m55s
```

The checkpoint is **`1/1 Running`**, not just `Running`. Also verify that the PVC is `Bound` and the service has an external address:

```bash
kubectl get pvc,svc -n default
```

Open `https://<cyclecloud-service-external-ip>` in your browser and verify that you can sign in with the configured CycleCloud credentials. A default self-signed certificate may trigger a browser warning; confirm the endpoint is yours before proceeding.

If readiness times out or the pod restarts, inspect:

```bash
kubectl describe pod cyclecloud-0 -n default
kubectl logs cyclecloud-0 -n default
kubectl get events -n default --sort-by=.metadata.creationTimestamp
```

Check image-pull errors, PVC provisioning, node capacity, application logs, and workload identity configuration before continuing to scheduler or autoscaling tests. A ready CycleCloud pod alone does not verify compute provisioning permissions or job completion.
