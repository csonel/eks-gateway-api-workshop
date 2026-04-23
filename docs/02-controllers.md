# Controller Installation

This guide installs the two components that power the ALB, NLB, and Gateway API labs. The order matters: Gateway API CRDs must be installed before the controller.

## Step 1: Install Gateway API CRDs

Gateway API Custom Resource Definitions (CRDs) define the GatewayClass, Gateway, HTTPRoute, and related resources used by the AWS Load Balancer Controller. Install them first using server-side apply (required because the CRDs are too large for client-side apply).

> **Note:** The AWS Load Balancer Controller Helm chart does not install Gateway API CRDs. You must install them separately before deploying the controller. See [kubernetes-sigs/aws-load-balancer-controller#4651](https://github.com/kubernetes-sigs/aws-load-balancer-controller/issues/4651).

> **Version compatibility:** Gateway API CRDs `v1.5.x` are supported starting with AWS Load Balancer Controller `v3.2.0`. Older controller versions require CRDs `v1.3.x`. This workshop uses `v3.2.1` to remain within the supported minor version while including the latest patch fixes.

> **Channel:** This workshop installs the experimental bundle.
>
> | Bundle | What it adds | Required for |
> |--------|--------------|--------------|
> | Standard (`standard-install.yaml`) | Layer 7 routes: HTTPRoute, GRPCRoute | ALB Gateway controller |
> | Experimental (`experimental-install.yaml`) | Standard bundle plus Layer 4 routes: TCPRoute, UDPRoute, TLSRoute | NLB Gateway controller and full Gateway API support |
>
> If only the standard bundle is installed, ALB exercises still work, but the controller logs warnings about missing Layer 4 CRDs. The experimental bundle removes these warnings and enables the full Gateway API feature set.

```bash
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.5.1/experimental-install.yaml
```

Expected output:

```
customresourcedefinition.apiextensions.k8s.io/backendtlspolicies.gateway.networking.k8s.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/gatewayclasses.gateway.networking.k8s.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/gateways.gateway.networking.k8s.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/grpcroutes.gateway.networking.k8s.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/httproutes.gateway.networking.k8s.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/listenersets.gateway.networking.k8s.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/referencegrants.gateway.networking.k8s.io serverside-applied
customresourcedefinition.apiextensions.k8s.io/tlsroutes.gateway.networking.k8s.io serverside-applied
validatingadmissionpolicy.admissionregistration.k8s.io/safe-upgrades.gateway.networking.k8s.io serverside-applied
validatingadmissionpolicybinding.admissionregistration.k8s.io/safe-upgrades.gateway.networking.k8s.io serverside-applied
```

Verify the CRDs are installed:

```bash
kubectl get crds | grep gateway
```

PowerShell (Windows):

```powershell
kubectl get crds | Select-String "gateway"
```

Expected output (you should see at least):
- `gatewayclasses.gateway.networking.k8s.io`
- `gateways.gateway.networking.k8s.io`
- `httproutes.gateway.networking.k8s.io`
- `referencegrants.gateway.networking.k8s.io`

## Step 2: Install AWS Load Balancer Controller

The AWS Load Balancer Controller provisions ALBs (from Ingress resources) and NLBs (from Service type LoadBalancer). With Gateway API feature flags enabled (`ALBGatewayAPI=true,NLBGatewayAPI=true`), it also handles Gateway/HTTPRoute resources.

> **Important:** The Gateway API feature flags are set in `helm/lbc-values.yaml` under `controllerConfig.featureGates` (map format required by v3.x). They must be present at first install; they cannot be enabled retroactively without a Helm upgrade.

### 2a. Add the Helm repository

```bash
helm repo add eks https://aws.github.io/eks-charts
helm repo update eks
```

### 2b. Get the VPC ID and IAM Role ARN

The controller needs the VPC ID explicitly because Bottlerocket nodes use IMDSv2 with a hop limit that blocks auto-detection. It also needs an IAM role ARN for the service account to authenticate with AWS.

> **Subnet discovery:** Once the controller knows the VPC ID, it discovers which subnets to use for ALBs and NLBs by selecting subnets with the required tags. The workshop’s Terraform configuration applies these tags automatically. See [Subnet Auto Discovery](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/deploy/subnet_discovery/).

```bash
# Get VPC ID from the EKS cluster
export VPC_ID=$(aws eks describe-cluster --name awscdro-eks --region eu-central-1 \
  --query 'cluster.resourcesVpcConfig.vpcId' --output text)
echo "VPC ID: $VPC_ID"

# Get the IAM role ARN for the LBC service account
export LBC_ROLE_ARN=$(aws iam get-role --role-name awscdro-eks-aws-lb-controller \
  --query 'Role.Arn' --output text)
echo "LBC Role ARN: $LBC_ROLE_ARN"
```

PowerShell (Windows):

```powershell
# Get VPC ID from the EKS cluster
$env:VPC_ID = aws eks describe-cluster --name awscdro-eks --region eu-central-1 --query 'cluster.resourcesVpcConfig.vpcId' --output text
Write-Host "VPC ID: $env:VPC_ID"

# Get the IAM role ARN for the LBC service account
$env:LBC_ROLE_ARN = aws iam get-role --role-name awscdro-eks-aws-lb-controller --query 'Role.Arn' --output text
Write-Host "LBC Role ARN: $env:LBC_ROLE_ARN"
```

### 2c. Install via Helm

```bash
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  -f helm/lbc-values.yaml \
  --set vpcId=$VPC_ID \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$LBC_ROLE_ARN \
  --version 3.2.1
```

PowerShell (Windows):

```powershell
helm install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system -f helm/lbc-values.yaml --set vpcId=$env:VPC_ID --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$env:LBC_ROLE_ARN --version 3.2.1
```

### 2d. Verify LBC is running

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
```

Expected: Pod in `Running` state. Wait up to 60 seconds for it to start.

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=20
```

Look for: `Starting controller` log lines without errors. If you see IAM permission errors, verify the IRSA configuration created by Terraform: the IAM role exists, the service account annotation is set, and the role trust policy matches `system:serviceaccount:kube-system:aws-load-balancer-controller`.

## Verification Checklist

Run these commands to confirm both components are ready:

```bash
# Gateway API CRDs
kubectl get crd gatewayclasses.gateway.networking.k8s.io gateways.gateway.networking.k8s.io httproutes.gateway.networking.k8s.io referencegrants.gateway.networking.k8s.io
# Should return the 4 CRDs above

# LBC
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller -o jsonpath='{.items[0].status.phase}'
# Should return: Running
```

## Next Step

Proceed to [03-sample-app.md](03-sample-app.md) to deploy the shared sample application.
