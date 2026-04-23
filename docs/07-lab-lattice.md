# Lab 4: VPC Lattice

This lab uses Amazon VPC Lattice together with the AWS Gateway API Controller to route traffic.

In the ALB and NLB labs, the AWS Load Balancer Controller provisions load balancers inside your VPC. In this lab, the model is different. VPC Lattice is a managed application networking service, so the routing layer is provided by VPC Lattice rather than by a load balancer deployed in your VPC.

You still use the same Kubernetes Gateway API resources: `GatewayClass`, `Gateway`, and `HTTPRoute`. However, the controller that watches and reconciles these resources is different. Instead of the AWS Load Balancer Controller, this lab uses the AWS Gateway API Controller.

As a result, the AWS resources created are also different. Instead of provisioning an Application Load Balancer, the controller creates VPC Lattice resources such as a Service Network and a Service, based on your Gateway API configuration.

This means the Kubernetes experience remains consistent with the earlier labs, while the underlying AWS implementation changes.

```
 YOU CREATE (Kubernetes)                   AWS GATEWAY API CONTROLLER PROVISIONS (AWS)
 --------------------------                -------------------------------------------

 GatewayClass: amazon-vpc-lattice
   controllerName: application-networking.k8s.aws/gateway-api-controller
         |
         v
 +-------+-----------------+               +------------------------------------+
 | Gateway                 |  -----------> | VPC Lattice Service Network        |
 |  ns: workshop-lattice   |               | (managed outside your VPC)         |
 |  class: amazon-vpc-     |               +-------------------+----------------+
 |    lattice              |                                   |
 +-------------------------+                                   v
                                           +-------------------+----------------+
 +-------------------------+               | VPC Lattice Service                |
 | HTTPRoute               |  -----------> |   listener: HTTP :80               |
 |  rules:                 |               |   routing rules from HTTPRoute     |
 |   /         -> FE:9898  |               +--------+------------------+--------+
 |   /api/info -> BE:9898  |                        |                  |
 +-------------------------+                    path: /           path: /api/info
                                                    |                  |
                                                    v                  v
 +-------------------------+               +--------+-------+ +--------+--------+
 | ns: workshop-lattice    |               | Target Group   | | Target Group    |
 |  podinfo-frontend (x2)  | <------------ | frontend       | | backend         |
 |  podinfo-backend  (x2)  |               | pod IPs        | | pod IPs         |
 +-------------------------+               +----------------+  +----------------+

 Traffic flow:
 Client -> VPC Lattice DNS -> Service Network -> Service listener
        -> routing rule -> Target Group -> pod IP:9898
```

## Step 1: Install the AWS Gateway API Controller

The AWS Gateway API Controller is a separate controller from the AWS Load Balancer Controller. It watches `GatewayClass`, `Gateway`, and `HTTPRoute` resources that reference `amazon-vpc-lattice` and provisions VPC Lattice resources accordingly. You will install it on the `awscdro-eks` cluster in `eu-central-1`.

### 1a. Get the IAM role ARN

The Terraform configuration creates the IAM role for the controller. Retrieve its ARN using the known workshop cluster name:

```bash
LATTICE_ROLE_ARN=$(aws iam get-role --role-name "awscdro-eks-gateway-api-controller" --query 'Role.Arn' --output text)
echo "Lattice Role ARN: $LATTICE_ROLE_ARN"
```

PowerShell (Windows):

```powershell
$env:LATTICE_ROLE_ARN = aws iam get-role --role-name "awscdro-eks-gateway-api-controller" --query 'Role.Arn' --output text
Write-Host "Lattice Role ARN: $env:LATTICE_ROLE_ARN"
```

> **Note:** If your workshop uses a different cluster name, replace `awscdro-eks` in the commands above, or set the role ARN directly: `LATTICE_ROLE_ARN=arn:aws:iam::<account-id>:role/<cluster-name>-gateway-api-controller`.

### 1b. Install the controller

The chart is published as an OCI artifact on Amazon ECR Public. The Helm chart creates the service account and applies the IRSA annotation in one step. Store the ECR Public token in a variable first to avoid pipe timing issues, then log in and install:

```bash
ECR_TOKEN=$(aws ecr-public get-login-password --region us-east-1)
echo $ECR_TOKEN | helm registry login --username AWS --password-stdin public.ecr.aws

helm install gateway-api-controller \
  oci://public.ecr.aws/aws-application-networking-k8s/aws-gateway-controller-chart \
  --version v2.0.2 \
  --namespace aws-application-networking-system \
  --create-namespace \
  --set serviceAccount.create=true \
  --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$LATTICE_ROLE_ARN" \
  --set log.level=info \
  --set defaultServiceNetwork=workshop-lattice-gateway
```

PowerShell (Windows):

```powershell
helm registry login public.ecr.aws --username AWS --password (aws ecr-public get-login-password --region us-east-1)

helm install gateway-api-controller oci://public.ecr.aws/aws-application-networking-k8s/aws-gateway-controller-chart --version v2.0.2 --namespace aws-application-networking-system --create-namespace --set serviceAccount.create=true --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$env:LATTICE_ROLE_ARN" --set log.level=info --set defaultServiceNetwork=workshop-lattice-gateway
```

> **Note:** ECR Public authentication always requires `--region us-east-1` regardless of your cluster region. If you still get a 400 error, verify your AWS credentials are valid with `aws sts get-caller-identity` before retrying.
>
> **Note (v2.x):** The `--set defaultServiceNetwork=workshop-lattice-gateway` flag is required with controller v2.x. The value must match your `Gateway` resource name (`workshop-lattice-gateway`). Without it the controller cannot create the VPC Lattice Service Network and the Gateway will remain `PROGRAMMED: False` with the message *"VPC Lattice Service Network not found"*.

### 1c. Verify the controller is running

```bash
kubectl get pods -n aws-application-networking-system
```

Expected: two pods in `Running` state within 60 seconds.

```bash
kubectl logs -n aws-application-networking-system -l control-plane=gateway-api-controller --tail=20
```

Look for `Starting controller` log lines without errors.

## Step 2: Deploy the Lab Application

Deploy the shared podinfo application into the `workshop-lattice` namespace:

```bash
kubectl apply -f manifests/app/ -n workshop-lattice
```

This creates two `podinfo` Deployments (frontend and backend) and their ClusterIP Services in the `workshop-lattice` namespace.

Verify pods are running:

```bash
kubectl get pods -n workshop-lattice
```

Expected output: four pods (two frontend + two backend), all showing `STATUS: Running` and `READY: 1/1`. Pods should be ready within 30 seconds.

```
NAME                                READY   STATUS    RESTARTS   AGE
podinfo-backend-7d8f9c6b4-jkl12     1/1     Running   0          15s
podinfo-backend-7d8f9c6b4-mno34     1/1     Running   0          15s
podinfo-frontend-5b6c7d8e9-pqr56    1/1     Running   0          15s
podinfo-frontend-5b6c7d8e9-stu78    1/1     Running   0          15s
```

If pods are in `Pending` state, check node capacity:

```bash
kubectl get events -n workshop-lattice --sort-by=.lastTimestamp
```

## Step 3: Deploy the GatewayClass and Gateway

### Apply the GatewayClass

```bash
kubectl apply -f manifests/labs/lattice/gatewayclass.yaml
```

The `GatewayClass` uses `controllerName: application-networking.k8s.aws/gateway-api-controller` - this is the AWS Gateway API Controller, not the AWS Load Balancer Controller used in Lab 3. Any `Gateway` referencing `amazon-vpc-lattice` will be handled by this controller.

Verify it is accepted:

```bash
kubectl get gatewayclass amazon-vpc-lattice
```

Expected output:

```
NAME                   CONTROLLER                                             ACCEPTED   AGE
amazon-vpc-lattice     application-networking.k8s.aws/gateway-api-controller True       10s
```

If `ACCEPTED` is `False`, check the controller logs:

```bash
kubectl logs -n aws-application-networking-system -l control-plane=gateway-api-controller --tail=30
```

### Apply the Gateway

```bash
kubectl apply -f manifests/labs/lattice/gateway.yaml
```

The `Gateway` resource triggers VPC Lattice Service Network creation. Unlike the ALB Gateway lab where the Gateway provisions an ALB inside the VPC, here the controller creates a VPC Lattice Service Network - a managed overlay that operates at the AWS networking layer, outside of the VPC's address space.

Watch the Gateway until the DNS name appears:

```bash
kubectl get gateway workshop-lattice-gateway -n workshop-lattice --watch
```

The `ADDRESS` field starts empty. VPC Lattice Service Network creation takes 2-3 minutes. Once an address appears and `PROGRAMMED` shows `True`, press `Ctrl+C` to stop watching.

```
NAME                       CLASS                ADDRESS                                                              PROGRAMMED   AGE
workshop-lattice-gateway   amazon-vpc-lattice                                                                        Unknown      10s
workshop-lattice-gateway   amazon-vpc-lattice   workshop-lattice-gateway-<id>.vpc-lattice-svcs.eu-central-1.on.aws   True         2m45s
```

> **While you wait:** In the AWS Console, navigate to **VPC → PrivateLink and Lattice → Service networks** to watch the Service Network being created. This is fundamentally different from the ALB labs - there is no EC2 load balancer being provisioned. VPC Lattice is a fully managed service built into the AWS network fabric.

If `ADDRESS` stays empty after 5 minutes, check the controller logs and Gateway events:

```bash
kubectl logs -n aws-application-networking-system -l control-plane=gateway-api-controller --tail=50
kubectl describe gateway workshop-lattice-gateway -n workshop-lattice
```

Common causes: IAM permissions missing, the controller not running, or `defaultServiceNetwork` not set to match the Gateway name during `helm install`.

## Step 4: Deploy the HTTPRoute

With the Gateway provisioned, apply path-based routing rules:

```bash
kubectl apply -f manifests/labs/lattice/httproute.yaml
```

The `HTTPRoute` looks identical to the one you used in the Gateway API lab - same `parentRefs`, same path rules. The difference is entirely in the controller that processes it: here it is the AWS Gateway API Controller creating VPC Lattice routing rules, not the AWS LBC creating ALB listener rules.

> **Note - Security Groups:** VPC Lattice uses its own IP address space to reach your pods. The node security group must explicitly allow inbound traffic from the VPC Lattice managed prefix lists on the application port. The Terraform configuration already adds these rules automatically. If you see `Service Unavailable` or targets remain `UNHEALTHY` in the VPC Lattice console, verify the node security group has ingress rules for `com.amazonaws.<region>.vpc-lattice` (IPv4) and `com.amazonaws.<region>.ipv6.vpc-lattice` (IPv6) on port 9898.

Check the HTTPRoute status:

```bash
kubectl get httproute -n workshop-lattice
```

Expected output:

```
NAME                    HOSTNAMES   AGE
podinfo-lattice-route               30s
```

Inspect the full status to confirm the route is `Accepted` and `ResolvedRefs` is resolved:

```bash
kubectl get httproute podinfo-lattice-route -n workshop-lattice -o yaml
```

Inspect the `status.parents[0].conditions` block to confirm the route is `Accepted` and `ResolvedRefs` is resolved.

Capture the Gateway DNS name:

```bash
LATTICE_DNS=$(kubectl get gateway workshop-lattice-gateway -n workshop-lattice -o jsonpath="{.status.addresses[0].value}")
echo $LATTICE_DNS
```

PowerShell (Windows):

```powershell
$env:LATTICE_DNS = kubectl get gateway workshop-lattice-gateway -n workshop-lattice -o jsonpath="{.status.addresses[0].value}"
Write-Host $env:LATTICE_DNS
```

> **Note:** VPC Lattice DNS names are only resolvable from **within the VPC**. Unlike the ALB lab where the load balancer was internet-facing, VPC Lattice is designed for service-to-service communication inside AWS. All `curl` tests must run from a pod inside the cluster.

Test the frontend (root path) from inside the cluster:

```bash
kubectl run curl-test --image=curlimages/curl -n workshop-lattice --restart=Never --rm -it -- \
  curl -s http://$LATTICE_DNS/ | grep message
```

PowerShell (Windows):

```powershell
kubectl run curl-test --image=curlimages/curl -n workshop-lattice --restart=Never --rm -it -- curl -s http://$env:LATTICE_DNS/ | Select-String "message"
```

Expected output:

```
"message": "Hello from frontend"
```

Test the backend path:

```bash
kubectl run curl-test --image=curlimages/curl -n workshop-lattice --restart=Never --rm -it -- \
  curl -s http://$LATTICE_DNS/api/info | grep message
```

PowerShell (Windows):

```powershell
kubectl run curl-test --image=curlimages/curl -n workshop-lattice --restart=Never --rm -it -- curl -s http://$env:LATTICE_DNS/api/info | Select-String "message"
```

Expected output:

```
"message": "Hello from backend"
```

## Step 5: Weighted Traffic Splitting

Replace the path-based route with a weighted route that splits traffic 80/20 between frontend and backend:

First, remove the path-based route:

```bash
kubectl delete httproute podinfo-lattice-route -n workshop-lattice
```

Apply the weighted route:

```bash
kubectl apply -f manifests/labs/lattice/httproute-weighted.yaml
```

Send several requests from inside the cluster to observe the split:

```bash
kubectl run curl-test --image=curlimages/curl -n workshop-lattice --restart=Never --rm -it -- \
  sh -c "for i in \$(seq 1 10); do curl -s http://$LATTICE_DNS/ | grep message; done"
```

PowerShell (Windows):

```powershell
# Capture the DNS on the host, then pass it into a single container that loops
$dns = $env:LATTICE_DNS
kubectl run curl-test --image=curlimages/curl -n workshop-lattice --restart=Never --rm -it -- `
  sh -c "for i in 1 2 3 4 5 6 7 8 9 10; do curl -s http://$dns/ | grep message; done"
```

You should see approximately 8 responses with `"message": "Hello from frontend"` and approximately 2 with `"message": "Hello from backend"`.

## Step 6: What Just Happened - VPC Lattice vs ALB

Both this lab and Lab 3 used `Gateway` and `HTTPRoute` resources with identical YAML structure. The key difference is what the controller provisioned in AWS:

|                                 | Lab 3: Gateway API (ALB)          | Lab 4: VPC Lattice                                      |
|---------------------------------|-----------------------------------|---------------------------------------------------------|
| **Controller**                  | AWS Load Balancer Controller      | AWS Gateway API Controller                              |
| **GatewayClass controllerName** | `gateway.k8s.aws/alb`             | `application-networking.k8s.aws/gateway-api-controller` |
| **AWS resource provisioned**    | Application Load Balancer (EC2)   | VPC Lattice Service + Service Network                   |
| **DNS hostname**                | `*.elb.amazonaws.com`             | `*.vpc-lattice-svcs.*.on.aws`                           |
| **Reachable from**              | Internet (internet-facing scheme) | Inside VPC / cross-VPC / cross-account                  |
| **Primary use case**            | North-south (internet → service)  | East-west (service → service)                           |
| **Cross-account routing**       | Not supported                     | Native support                                          |
| **Extra AWS config needed**     | Subnet tags, security groups      | Node SG rules for VPC Lattice prefix lists              |

**When to use VPC Lattice instead of ALB:**
- Service-to-service communication where internet exposure is not needed
- Cross-account or cross-VPC service discovery without VPC peering or Transit Gateway
- Centralised policy enforcement (auth, observability) across services owned by different teams or accounts

**Can VPC Lattice be exposed publicly?**

No. VPC Lattice is a private-only service - its DNS names (`*.vpc-lattice-svcs.<region>.on.aws`) only resolve from within associated VPCs, and there is no internet-facing listener option. If you need to expose the same workload publicly, place an ALB in front of it (as in Labs 1-3) and use VPC Lattice exclusively for internal service-to-service traffic. Both can run simultaneously on the same pods.

## Next Step

Proceed to [08-comparison.md](08-comparison.md) to review when to use each approach - ALB, NLB, Gateway API, and VPC Lattice.
