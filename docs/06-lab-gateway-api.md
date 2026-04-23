# Lab 3: Gateway API

This lab routes traffic using the Kubernetes Gateway API with the AWS Load Balancer Controller `v3.2.1` already installed on the `awscdro-eks` cluster in `eu-central-1`. Unlike the Ingress approach you used in the ALB lab, the Gateway API splits concerns across three distinct resource types: `GatewayClass` identifies the controller, `Gateway` provisions the ALB, and `HTTPRoute` defines the routing rules. Configuration that previously lived in Ingress annotations (scheme, target type) now lives in typed CRDs (`LoadBalancerConfiguration`, `TargetGroupConfiguration`). You will deploy the shared `podinfo` application, provision a Gateway-backed ALB, configure path-based and weighted routing, and then explore the cross-namespace security model with the "fail first, then fix" pattern.

```
 PLATFORM TEAM creates         APP TEAM creates            AWS (auto-provisioned)
 -------------------------     ----------------------      -------------------------

 GatewayClass (cluster-scoped)
   controller: gateway.k8s.aws/alb
         |
         v
 +-------+--------------+                                  +--------------------------+
 | Gateway              | ---- provisions ---------------> | ALB (Layer 7)            |
 |   ns: workshop-gw    |                                  | scheme: internet-facing  |
 |   listener: HTTP :80 |                                  | listener: HTTP :80       |
 |   allowedRoutes:     |                                  +-----+-------------+------+
 |     from: Same|All   |                                        |             |
 +----------------------+                                     path: /    path: /api/info
                                                                 |             |
                                                                 v             v
 LoadBalancerConfig                                        +-----+------+ +----+-------+
   scheme: internet-facing                                 | Target Grp | | Target Grp |
                               +---------------------+     | frontend   | | backend    |
 TargetGroupConfig (x2)        | HTTPRoute           |     | pod IPs    | | pod IPs    |
   targetType: ip              |   ns: workshop-gw   |     +-----+------+ +----+-------+
                               |   parentRef:        |           |             |
                               |     -> Gateway      |           v             v
                               |   rules:            |     +-----+------+ +----+-------+
                               |    /      -> FE:9898| --> | FE Pods    | | BE Pods    |
                               |    /api/* -> BE:9898|     +------------+ +------------+
                               +---------------------+
```

## Step 1: Deploy the Lab Application

Deploy the shared `podinfo` application into the `workshop-gateway` namespace. The base manifests live in `manifests/app/` - the `-n` flag specifies the target namespace:

```bash
kubectl apply -f manifests/app/ -n workshop-gateway
```

This creates two `podinfo` Deployments (frontend and backend) and their ClusterIP Services in the `workshop-gateway` namespace.

Verify pods are running:

```bash
kubectl get pods -n workshop-gateway
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
kubectl get events -n workshop-gateway --sort-by=.lastTimestamp
```

## Step 2: Deploy GatewayClass and Gateway

The Gateway API requires several setup resources before any routing rules can be applied: a `GatewayClass`, a `LoadBalancerConfiguration`, `TargetGroupConfiguration` resources for each backend, and a `Gateway`. Apply them in order.

```
GatewayClass (cluster-scoped, identifies controller)
     |
     v
Gateway (provisions ALB, references LBConfig)
  |-- LoadBalancerConfiguration (scheme: internet-facing)
  |-- TargetGroupConfiguration (per Service, targetType: ip)
     |
     v
HTTPRoute (routing rules, attaches via parentRefs)
     |
     v
Services (podinfo-frontend, podinfo-backend)
```

**Apply the GatewayClass:**

```bash
kubectl apply -f manifests/labs/gateway/gatewayclass.yaml
```

The `GatewayClass` is cluster-scoped and identifies the AWS Load Balancer Controller as the implementation for any Gateway referencing this class (via `controllerName: gateway.k8s.aws/alb`). This is the Gateway API equivalent of the `IngressClass` used by the ALB Ingress lab.

Verify the GatewayClass is accepted by the controller:

```bash
kubectl get gatewayclass aws-alb
```

Expected output:

```
NAME      CONTROLLER            ACCEPTED   AGE
aws-alb   gateway.k8s.aws/alb   True       10s
```

If `ACCEPTED` is `False` or `Unknown`, the most common cause is that the Gateway API feature flags were not enabled in the LBC installation. Verify:

```bash
kubectl get deployment -n kube-system aws-load-balancer-controller -o jsonpath='{.spec.template.spec.containers[0].args}'
```

The output must include `--feature-gates=ALBGatewayAPI=true,NLBGatewayAPI=true`. If it does not, the controller was installed without Gateway API support. Check the controller logs:

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=30
```

Look for lines containing `Starting EventSource` with `gateway.k8s.aws/alb` - if absent, the Gateway API feature gate was not enabled at install time.

**Apply the LoadBalancerConfiguration:**

```bash
kubectl apply -f manifests/labs/gateway/lbconfig.yaml
```

`LoadBalancerConfiguration` is an LBC-specific CRD that sets ALB properties such as the scheme. It replaces the `alb.ingress.kubernetes.io/scheme` annotation used in Ingress mode. Without this resource, the ALB defaults to `internal` scheme and will not be reachable from the internet.

**Apply the TargetGroupConfigurations:**

```bash
kubectl apply -f manifests/labs/gateway/tgconfig-frontend.yaml -f manifests/labs/gateway/tgconfig-backend.yaml
```

`TargetGroupConfiguration` is an LBC-specific CRD that sets the target type per Service. It replaces the `alb.ingress.kubernetes.io/target-type` annotation used in Ingress mode. These resources set `targetType: ip` so the ALB registers pod IPs directly - the same mode established in the ALB lab.

**Apply the Gateway:**

```bash
kubectl apply -f manifests/labs/gateway/gateway.yaml
```

The `Gateway` resource triggers ALB provisioning. It references the `GatewayClass` and the `LoadBalancerConfiguration` via `infrastructure.parametersRef`. When the LBC processes this resource, it provisions an ALB in the `awscdro-eks` VPC in `eu-central-1` - the same way applying an Ingress provisioned an ALB in the ALB lab. The key difference: in the ALB lab the Ingress resource itself triggered ALB creation; here the Gateway triggers it and HTTPRoutes attach later.

Watch the Gateway until the ALB address appears:

```bash
kubectl get gateway workshop-gateway -n workshop-gateway --watch
```

The `ADDRESS` field starts empty. ALB provisioning takes 3-5 minutes. Once the `ADDRESS` field shows a hostname ending in `eu-central-1.elb.amazonaws.com` and `PROGRAMMED` shows `True`, press `Ctrl+C` to stop watching.

```
NAME               CLASS     ADDRESS                                                              PROGRAMMED   AGE
workshop-gateway   aws-alb                                                                        Unknown      10s
workshop-gateway   aws-alb   k8s-workshopg-workshopg-a1b2c3d4e5-123456789.eu-central-1.elb.amazonaws.com   True   4m12s
```

If `ADDRESS` stays empty after 5 minutes, check the controller logs and Gateway events:

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50
kubectl describe gateway workshop-gateway -n workshop-gateway
```

Common causes: subnet tags not set (already handled by Terraform for `awscdro-eks`), IAM permissions missing, or the LBC feature gate `ALBGatewayAPI=true` not set (already configured in the workshop installation).

**Resource summary for this step:**

| Resource                    | Kind                      | Purpose                                                      |
|-----------------------------|---------------------------|--------------------------------------------------------------|
| `aws-alb`                   | GatewayClass              | Registers LBC as the ALB controller                          |
| `workshop-gateway-lbconfig` | LoadBalancerConfiguration | Sets `scheme: internet-facing` (replaces Ingress annotation) |
| `podinfo-frontend-tgconfig` | TargetGroupConfiguration  | Sets `targetType: ip` for frontend Service                   |
| `podinfo-backend-tgconfig`  | TargetGroupConfiguration  | Sets `targetType: ip` for backend Service                    |
| `workshop-gateway`          | Gateway                   | Provisions the ALB (replaces Ingress as the ALB trigger)     |

## Step 3: Deploy Simple Path-Based HTTPRoute

With the Gateway provisioned, attach routing rules by deploying an `HTTPRoute`. Unlike Ingress where routing rules and the ALB provisioning lived in a single resource, the Gateway API separates the ALB (Gateway) from the routing rules (HTTPRoute).

Apply the simple routing manifest:

```bash
kubectl apply -f manifests/labs/gateway/httproute-simple.yaml
```

The `HTTPRoute` attaches to the existing `workshop-gateway` via `parentRefs`. It defines two path rules: `/api/info` routes to the backend Service and `/` (the catch-all) routes to the frontend Service. The more-specific path is listed first - the same ordering principle as the ALB Ingress lab.

Check the HTTPRoute status:

```bash
kubectl get httproute -n workshop-gateway
```

Expected output:

```
NAME            HOSTNAMES   AGE
podinfo-route               30s
```

> **Why is `HOSTNAMES` empty?** The manifest omits `spec.hostnames`, so the route matches all Host headers and routes based only on the path. Adding a hostname would require a real DNS record or using `-H "Host: ..."` with every request, so this workshop skips it to allow direct access via the ALB DNS name.

Capture the Gateway address:

```bash
GW_ADDR=$(kubectl get gateway workshop-gateway -n workshop-gateway -o jsonpath='{.status.addresses[0].value}')
echo $GW_ADDR
```

PowerShell (Windows):

```powershell
$env:GW_ADDR = kubectl get gateway workshop-gateway -n workshop-gateway -o jsonpath='{.status.addresses[0].value}'
Write-Host $env:GW_ADDR
```

Expected output: the ALB hostname, for example:

```
k8s-workshopg-workshopg-a1b2c3d4e5-123456789.eu-central-1.elb.amazonaws.com
```

Test the frontend (root path):

```bash
curl -s http://$GW_ADDR/ | grep message
```

PowerShell (Windows):

```powershell
(curl.exe -s "http://$env:GW_ADDR/") | Select-String "message" | ForEach-Object { $_.Line }
```

Expected output:

```
"message": "Hello from frontend"
```

Test the backend path:

```bash
curl -s http://$GW_ADDR/api/info | grep message
```

PowerShell (Windows):

```powershell
(curl.exe -s "http://$env:GW_ADDR/api/info") | Select-String "message" | ForEach-Object { $_.Line }
```

Expected output:

```
"message": "Hello from backend"
```

If the root path returns "Hello from backend", the catch-all rule is matching before the more-specific `/api/info` rule. This is a path ordering problem and should not occur with the provided manifest. If either curl times out on the first attempt, wait 30 seconds and retry - the ALB may still be registering the pod IP targets.

If `curl` returns connection refused or a 503, check HTTPRoute attachment:

```bash
kubectl get httproute podinfo-route -n workshop-gateway -o yaml
```

Inspect the `status.parents[].conditions` block to confirm the route is attached to the Gateway and the backends resolved successfully.

## Step 4: Weighted Traffic Splitting

In this step you replace the path-based route with a weighted route that splits all incoming traffic between frontend and backend. This demonstrates the canary deployment pattern - incrementally shifting traffic to a new version.

First, remove the simple route:

```bash
kubectl delete httproute podinfo-route -n workshop-gateway
```

Apply the weighted routing manifest:

```bash
kubectl apply -f manifests/labs/gateway/httproute-weighted.yaml
```

The weighted HTTPRoute defines a single rule with two `backendRefs`, each with a `weight` value:

- `podinfo-frontend`: weight 90
- `podinfo-backend`: weight 10

Weight values are relative - they do not need to add up to 100. A 90:10 split means approximately 90% of requests go to frontend and 10% go to backend. In a canary deployment, you would start at 90:10 and gradually shift toward the new version (backend in this case).

Run 10 requests in a loop to observe the split:

```bash
for i in $(seq 1 10); do curl -s http://$GW_ADDR/ | grep message; done
```

PowerShell (Windows):

```powershell
1..10 | ForEach-Object {
    (curl.exe -s "http://$env:GW_ADDR/") |
    Select-String "message" |
    ForEach-Object { $_.Line }
}
```

Expected output: approximately 9 lines showing `"message": "Hello from frontend"` and approximately 1 line showing `"message": "Hello from backend"`. The exact distribution varies because the ALB implements weights via target group routing rules, not strict per-request randomization:

```
"message": "Hello from frontend"
"message": "Hello from frontend"
"message": "Hello from frontend"
"message": "Hello from backend"
"message": "Hello from frontend"
"message": "Hello from frontend"
"message": "Hello from frontend"
"message": "Hello from frontend"
"message": "Hello from frontend"
"message": "Hello from frontend"
```

> **Note:** Traffic splitting at this granularity (10 requests) may not show a perfect 9:1 split. Run 50-100 requests to observe a distribution closer to the configured 90:10 ratio.

To compare against a fixed path rule (no split):

```bash
curl -s http://$GW_ADDR/api/info | grep message
```

PowerShell (Windows):

```powershell
(curl.exe -s "http://$env:GW_ADDR/api/info") | Select-String "message" | ForEach-Object { $_.Line }
```

The weighted route has no path filter - all paths go through the weighted split. `/api/info` will also distribute across both backends based on weight.

## Step 5: Cross-Namespace Routing (Fail First)

In production environments, a platform team typically owns the `Gateway` (infrastructure) and application teams own their `HTTPRoute` resources (routing). Placing them in separate namespaces enforces this separation. This step demonstrates the two security mechanisms Gateway API uses to control cross-namespace access.

First, clean up the weighted route (if you already deleted it, skip this command):

```bash
kubectl delete --ignore-not-found httproute podinfo-weighted-route -n workshop-gateway
```

### First Failure: NotAllowedByListeners

The cross-namespace `HTTPRoute` lives in the `workshop-app` namespace and references the `workshop-gateway` Gateway in the `workshop-gateway` namespace. Apply it:

```bash
kubectl apply -f manifests/labs/gateway/httproute-crossns.yaml
```

Check whether the route attached to the Gateway:

```bash
kubectl get httproute podinfo-crossns-route -n workshop-app -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].reason}'
```

PowerShell (Windows):

```powershell
kubectl get httproute podinfo-crossns-route -n workshop-app -o jsonpath='{.status.parents[0].conditions[?(@.type==\"Accepted\")].reason}'
```

Expected output:

```
NotAllowedByListeners
```

The Gateway's HTTP listener has `allowedRoutes: namespaces: from: Same`, which rejects routes from any namespace other than `workshop-gateway`. The HTTPRoute in `workshop-app` is rejected at the Gateway level before any routing occurs.

**Fix:** Patch the Gateway listener to allow routes from all namespaces:

```bash
kubectl patch gateway workshop-gateway -n workshop-gateway --type=merge -p '{"spec":{"listeners":[{"name":"http","protocol":"HTTP","port":80,"allowedRoutes":{"namespaces":{"from":"All"}}}]}}'
```

PowerShell (Windows):

```powershell
kubectl patch gateway workshop-gateway -n workshop-gateway --type=merge -p '{\"spec\":{\"listeners\":[{\"name\":\"http\",\"protocol\":\"HTTP\",\"port\":80,\"allowedRoutes\":{\"namespaces\":{\"from\":\"All\"}}}]}}'
```

Wait a few seconds for the LBC to reconcile, then check again:

```bash
kubectl get httproute podinfo-crossns-route -n workshop-app -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].reason}'
```

PowerShell (Windows):

```powershell
kubectl get httproute podinfo-crossns-route -n workshop-app -o jsonpath='{.status.parents[0].conditions[?(@.type==\"Accepted\")].reason}'
```

Expected output:

```
Accepted
```

The route is now accepted by the Gateway listener. But traffic does not flow yet.

### Second Failure: RefNotPermitted

Check whether the route's backend references resolved:

```bash
kubectl get httproute podinfo-crossns-route -n workshop-app -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].reason}'
```

PowerShell (Windows):

```powershell
kubectl get httproute podinfo-crossns-route -n workshop-app -o jsonpath='{.status.parents[0].conditions[?(@.type==\"ResolvedRefs\")].reason}'
```

Expected output:

```
RefNotPermitted
```

The `HTTPRoute` in `workshop-app` references `podinfo-frontend` Service in `workshop-gateway` as a backend. The Gateway API security model requires an explicit opt-in from the target namespace for this kind of cross-namespace backend reference. Without a `ReferenceGrant` in `workshop-gateway`, the reference is denied.

**Fix:** Apply the ReferenceGrant:

```bash
kubectl apply -f manifests/labs/gateway/referencegrant.yaml
```

The `ReferenceGrant` lives in `workshop-gateway` (the namespace where the Service is) and explicitly permits HTTPRoutes in `workshop-app` to reference Services in `workshop-gateway`. Without this resource in the target namespace, no amount of configuration in the `workshop-app` namespace can override the restriction.

Wait a few seconds, then re-check the `ResolvedRefs` reason:

```bash
kubectl get httproute podinfo-crossns-route -n workshop-app -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].reason}'
```

PowerShell (Windows):

```powershell
kubectl get httproute podinfo-crossns-route -n workshop-app -o jsonpath='{.status.parents[0].conditions[?(@.type==\"ResolvedRefs\")].reason}'
```

Expected output:

```
ResolvedRefs
```

Before testing traffic, confirm the cross-namespace topology is in place:

```bash
kubectl get httproute -A
```

Expected output:

```
NAMESPACE      NAME                    HOSTNAMES   AGE
workshop-app   podinfo-crossns-route               2m
```

The route lives in `workshop-app`, but it attaches to the `workshop-gateway` Gateway in the `workshop-gateway` namespace - this is the cross-namespace link you just authorized with `allowedRoutes` and `ReferenceGrant`.

Now test that traffic flows end-to-end. This route targets only the `frontend` Service to keep the example focused on the security model rather than routing complexity:

```bash
curl -s http://$GW_ADDR/ | grep message
```

PowerShell (Windows):

```powershell
(curl.exe -s "http://$env:GW_ADDR/") | Select-String "message" | ForEach-Object { $_.Line }
```

Expected output:

```
"message": "Hello from frontend"
```

### What Just Happened

Two independent security mechanisms protected the cross-namespace boundary:

1. **`allowedRoutes` on the Gateway listener** - Controls which namespaces can attach routes to this Gateway. This is the platform team's control: they decide which application namespaces are allowed to use the Gateway. Set on the Gateway by the Gateway owner.

2. **`ReferenceGrant` in the target namespace** - Controls which namespaces can reference Services in this namespace as HTTPRoute backends. This is the Service owner's control: they decide who can route traffic to their Services. Set in the target namespace by the Service owner.

Both mechanisms must grant permission independently. Fixing one reveals the other. This two-step security model prevents any namespace from becoming a routing target without the explicit consent of the namespace owner.

## Step 6: Key Differences from Ingress

The table below compares the Ingress approach from the ALB lab with the Gateway API approach you deployed in this lab. Both ultimately provision an ALB - the difference is how configuration is expressed and where responsibility lies.

|                           | Ingress                                                    | Gateway API                                         |
|---------------------------|------------------------------------------------------------|-----------------------------------------------------|
| ALB provisioned by        | Ingress resource                                           | Gateway resource                                    |
| Scheme config             | `alb.ingress.kubernetes.io/scheme` annotation              | `LoadBalancerConfiguration` CRD                     |
| Target type config        | `alb.ingress.kubernetes.io/target-type` annotation         | `TargetGroupConfiguration` CRD                      |
| Routing rules             | `spec.rules` in Ingress                                    | `HTTPRoute` (separate resource)                     |
| Controller selection      | `spec.ingressClassName: alb`                               | `spec.gatewayClassName: aws-alb`                    |
| Cross-namespace routing   | Not supported by LBC                                       | `allowedRoutes` + `ReferenceGrant`                  |
| Traffic splitting         | Not native (requires custom headers or separate Ingresses) | `HTTPRoute` `weight` field on `backendRefs`         |
| Configuration type safety | Untyped string annotations (no schema validation)          | Typed CRD fields (validated by API server)          |
| Role separation           | Single Ingress resource owns ALB + routing                 | Platform team owns Gateway, app team owns HTTPRoute |

**Why Gateway API is the forward direction:** The Kubernetes Ingress resource is stable and will not be removed, but it receives no new features. New capabilities in Kubernetes traffic management (weighted routing, header-based routing, traffic mirroring, cross-namespace patterns) are developed in Gateway API. For new projects on EKS, Gateway API with the AWS Load Balancer Controller v3.2.1 is the recommended approach. The AWS LBC supports both Ingress and Gateway API in the same installation - you do not need to choose one exclusively.

See [04-lab-alb.md](04-lab-alb.md) for the complete Ingress approach reference, including the side-by-side YAML comparison of Ingress vs HTTPRoute routing rules.

## Next Step

You have completed the Gateway API lab. You deployed a Gateway-backed ALB, configured path-based routing, demonstrated weighted canary splitting, and explored the cross-namespace security model with the two-failure "fail first, then fix" pattern.

Proceed to [07-lab-lattice.md](07-lab-lattice.md) to route traffic using Amazon VPC Lattice and the AWS Gateway API Controller.
