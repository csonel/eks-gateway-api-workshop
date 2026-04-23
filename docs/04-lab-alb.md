# Lab 1: ALB Ingress

This lab deploys an Application Load Balancer using a Kubernetes Ingress resource. The ALB operates at Layer 7 (HTTP), routing requests based on URL path to different backends. The AWS Load Balancer Controller - already installed on the `awscdro-eks` cluster in `eu-central-1` - watches for Ingress resources and provisions ALBs in AWS automatically. You will deploy the shared `podinfo` application into the `workshop-alb` namespace, then apply an Ingress resource to provision the ALB.

```
 YOU CREATE (Kubernetes)                 AWS LBC AUTO-PROVISIONS (AWS)
 --------------------------              ---------------------------------

 +-------------------------+
 | Ingress: podinfo-alb    |             +-----------------------------+
 |   class: alb            | ----------> | ALB (Layer 7)               |
 |   annotations:          |             | scheme: internet-facing     |
 |     scheme, target-type |             | listener: HTTP :80          |
 |   rules:                |             +------+--------------+-------+
 |     /         -> FE:9898|                    |              |
 |     /api/info -> BE:9898|                    |              |
 +-------------------------+                  path: /    path: /api/info
                                                |              |
                                                v              v
 +-------------------------+             +------+------+ +------+------+
 | ns: workshop-alb        |             | Target Grp  | | Target Grp  |
 |                         |             | frontend    | | backend     |
 |  +--------+ +--------+  | <---------- | pod IPs     | | pod IPs     |
 |  | Pod    | | Pod    |  |             +-------------+ +-------------+
 |  | FE x2  | | BE x2  |  |
 |  +---+----+ +---+----+  |             Traffic flow:
 |      |          |       |             Internet -> ALB :80
 |      v          v       |             ALB inspects HTTP path:
 |  +---+----+ +---+----+  |               -> path match
 |  | Svc    | | Svc    |  |                 -> target group
 |  | FE:9898| | BE:9898|  |                   -> pod IP:9898
 |  +--------+ +--------+  |
 +-------------------------+
```

## Step 1: Deploy the Lab Application

Deploy the shared podinfo application into the `workshop-alb` namespace. The base manifests live in `manifests/app/` - the `-n` flag specifies the target namespace:

```bash
kubectl apply -f manifests/app/ -n workshop-alb
```

This creates two `podinfo` Deployments (frontend and backend) and their ClusterIP Services in the `workshop-alb` namespace.

Next, apply the ALB Ingress manifest:

```bash
kubectl apply -f manifests/labs/alb/
```

This creates the Ingress resource that tells the AWS Load Balancer Controller to provision an ALB with path-based routing rules.

Verify pods are running:

```bash
kubectl get pods -n workshop-alb
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
kubectl get events -n workshop-alb --sort-by=.lastTimestamp
```

## Step 2: Watch the ALB Provision

```bash
kubectl get ingress podinfo-alb -n workshop-alb --watch
```

The `ADDRESS` field starts empty. The AWS Load Balancer Controller detects the Ingress resource and begins provisioning an Application Load Balancer in the `awscdro-eks` VPC in `eu-central-1`. This takes 3-5 minutes. Once the `ADDRESS` field shows a hostname ending in `elb.amazonaws.com`, press `Ctrl+C` to stop watching.

> **While you wait:** The controller is creating several AWS resources behind the scenes: an Application Load Balancer in your public subnets, two target groups (one per path rule) with your pod IPs registered as targets, and an HTTP listener on port 80 with rules matching your Ingress path configuration. You can watch this happen in the AWS Console under EC2 > Load Balancers if you have console access.

```
NAME          CLASS   HOSTS   ADDRESS                                                                  PORTS   AGE
podinfo-alb   alb     *                                                                                80      10s
podinfo-alb   alb     *       k8s-workshop-podinfoa-a1b2c3d4e5-123456789.eu-central-1.elb.amazonaws.com   80      3m12s
```

If `ADDRESS` stays empty after 5 minutes, check the controller logs and Ingress events:

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=30
kubectl describe ingress podinfo-alb -n workshop-alb
```

Common causes: subnet tags not set (already handled by Terraform for `awscdro-eks`), IAM permissions missing, or LBC pod not running. The controller logs will show the specific error.

## Step 3: Test Path-Based Routing

Capture the ALB hostname:

```bash
ALB_HOSTNAME=$(kubectl get ingress podinfo-alb -n workshop-alb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo $ALB_HOSTNAME
```

PowerShell (Windows):

```powershell
$env:ALB_HOSTNAME = kubectl get ingress podinfo-alb -n workshop-alb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
Write-Host $env:ALB_HOSTNAME
```

Test the frontend (root path):

```bash
curl -s http://$ALB_HOSTNAME/ | grep message
```

PowerShell (Windows):

```powershell
curl.exe -s http://$env:ALB_HOSTNAME/ | Select-String "message"
```

Expected output:

```
"message": "Hello from frontend"
```

Test the backend path:

```bash
curl -s http://$ALB_HOSTNAME/api/info | grep message
```

PowerShell (Windows):

```powershell
curl.exe -s http://$env:ALB_HOSTNAME/api/info | Select-String "message"
```

Expected output:

```
"message": "Hello from backend"
```

If the root path returns "Hello from backend", path rule ordering is wrong. For this workshop that should not happen - the Ingress manifest lists `/api/info` before `/`, which ensures the more-specific prefix is evaluated first.

## Step 4: Examine the Ingress Resource

```bash
kubectl get ingress podinfo-alb -n workshop-alb -o yaml
```

Key fields to note:

- `spec.ingressClassName: alb` - tells the AWS Load Balancer Controller to handle this Ingress. The LBC Helm chart automatically creates an IngressClass named `alb`; no manual IngressClass manifest is required.
- `alb.ingress.kubernetes.io/scheme: internet-facing` - creates a public-facing ALB. Without this annotation the default is `internal`, which means the ALB is only reachable from within the VPC.
- `alb.ingress.kubernetes.io/target-type: ip` - routes traffic directly to pod IP addresses. The alternative `instance` mode routes to node IP + NodePort, requiring an extra kube-proxy hop. IP mode is preferred on EKS because the VPC CNI assigns real VPC IPs to pods.
- `spec.rules[].http.paths` - path-based routing rules: `/api/info` routes to `podinfo-backend:9898`, everything else (`/`) routes to `podinfo-frontend:9898`. The more-specific path is listed first.

## Step 5: What Just Happened

When you applied the Ingress manifest, the AWS Load Balancer Controller provisioned an Application Load Balancer in your VPC, created two target groups pointing to your pod IPs, and configured HTTP listener rules matching your path rules. The ALB operates at Layer 7 - it inspects each HTTP request, reads the URL path, and forwards to the matching target group. Target group health checks use the pod `/readyz` endpoint from the readiness probe. This is the traditional Kubernetes approach to exposing HTTP services on AWS EKS.

## Step 6: Looking Ahead - Ingress vs Gateway API

---

> **Reference only - do not apply.** The YAML below is a side-by-side comparison for reading. You will deploy Gateway API resources in [Lab 3](06-lab-gateway-api.md).

The Ingress resource you just deployed uses annotations for all AWS-specific configuration. This is the established Kubernetes pattern, but annotations are untyped strings with no schema validation. Kubernetes Gateway API takes a different approach: dedicated CRD resources (`GatewayClass`, `Gateway`, `HTTPRoute`) replace both the Ingress and its annotations with typed, structured objects.

Here is how the same path-based routing looks in each approach:

<table>
<tr>
<th>Ingress (annotation-based, what you just deployed)</th>
<th>Gateway API equivalent (CRD-based, covered in Lab 3)</th>
</tr>
<tr>
<td>

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: podinfo-alb
  namespace: workshop-alb
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
spec:
  ingressClassName: alb
  rules:
    - http:
        paths:
          - path: /api/info
            pathType: Prefix
            backend:
              service:
                name: podinfo-backend
                port:
                  number: 9898
          - path: /
            pathType: Prefix
            backend:
              service:
                name: podinfo-frontend
                port:
                  number: 9898
```

</td>
<td>

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: podinfo-route
  namespace: workshop-gateway
spec:
  parentRefs:
    - name: workshop-gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /api/info
      backendRefs:
        - name: podinfo-backend
          port: 9898
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: podinfo-frontend
          port: 9898
```

</td>
</tr>
</table>

Notice that the Gateway API HTTPRoute expresses routing rules as structured fields rather than string annotations. The `GatewayClass` and `Gateway` resources (not shown here) replace the `ingressClassName` and scheme annotation.

For a complete comparison of when to use Ingress vs Gateway API, see the comparison summary in the final workshop section.

---

## Next Step

Proceed to [05-lab-nlb.md](05-lab-nlb.md) to deploy a Network Load Balancer.
