# Lab 2: NLB Service

This lab deploys a Network Load Balancer using a Kubernetes Service of type LoadBalancer. The NLB operates at Layer 4 (TCP/UDP), forwarding connections without inspecting HTTP content. You will deploy the NLB in instance target mode, then switch to IP target mode to see how the two modes differ in routing.

```
 INSTANCE MODE (default)                  IP MODE (after patch)
 target-type: instance                    target-type: ip

 Internet                                 Internet
    |                                        |
    v TCP :80                                v TCP :80
 +-----------------------------+          +-----------------------------+
 | NLB (Layer 4)               |          | NLB (Layer 4)               |
 | target: node IP + NodePort  |          | target: pod IP + port       |
 +-------+--------------+------+          +------+--------------+-------+
         |              |                        |              |
         v :31234       v :31234                 v :9898        v :9898
 +-------+-----+ +------+------+         +-------+------+ +-----+-------+
 | Node 1      | | Node 2      |         | Pod 1        | | Pod 2       |
 | kube-proxy  | | kube-proxy  |         | podinfo      | | podinfo     |
 +-------+-----+ +------+------+         +--------------+ +-------------+
         |              |
         v              v                 Fewer hops, lower latency,
 +-------+-----+ +------+------+         client source IP preserved
 | Pod 1       | | Pod 2       |
 | podinfo     | | podinfo     |
 +-------------+ +-------------+

 Extra hop through kube-proxy,
 client source IP lost (SNAT)
```

## Step 1: Deploy the Lab Application

```bash
kubectl apply -f manifests/labs/nlb/
```

This creates a `podinfo` Deployment and a LoadBalancer Service in the `workshop-nlb` namespace. The AWS Load Balancer Controller detects the Service annotations and provisions an NLB in the `awscdro-eks` VPC in `eu-central-1`.

> **Note:** Unlike the ALB and Gateway API labs which use the shared frontend/backend application, the NLB lab uses a single podinfo instance because NLB operates at Layer 4 and does not perform path-based routing - there is no need for multiple backends.

Verify pods are running:

```bash
kubectl get pods -n workshop-nlb
```

Expected output: two pods, `STATUS: Running`, `READY: 1/1`. Pods should be ready within 30 seconds.

```
NAME                           READY   STATUS    RESTARTS   AGE
podinfo-nlb-6d7f8c9b4-abc12    1/1     Running   0          20s
podinfo-nlb-6d7f8c9b4-def34    1/1     Running   0          20s
```

## Step 2: Watch the NLB Provision

```bash
kubectl get service podinfo-nlb -n workshop-nlb --watch
```

The `EXTERNAL-IP` field starts as `<pending>`. The AWS Load Balancer Controller provisions an NLB. This takes 3-5 minutes. Once a hostname ending in `amazonaws.com` appears in the `EXTERNAL-IP` column, press `Ctrl+C` to stop watching.

```
NAME          TYPE           CLUSTER-IP      EXTERNAL-IP                                              PORT(S)        AGE
podinfo-nlb   LoadBalancer   172.20.45.123   <pending>                                                80:31234/TCP   10s
podinfo-nlb   LoadBalancer   172.20.45.123   k8s-workshop-podinfon-a1b2c3d4e5-123456789.elb.eu-central-1.amazonaws.com   80:31234/TCP   4m5s
```

If `EXTERNAL-IP` stays `<pending>` after 5 minutes, check the controller logs and Service events:

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=30
kubectl describe service podinfo-nlb -n workshop-nlb
```

Common causes: subnet tags not set (already handled by Terraform for `awscdro-eks`), IAM permissions missing, or the LBC pod not running. The controller logs will show the specific error.

## Step 3: Test NLB Connectivity

Capture the NLB hostname:

```bash
NLB_HOSTNAME=$(kubectl get service podinfo-nlb -n workshop-nlb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
echo $NLB_HOSTNAME
```

PowerShell (Windows):

```powershell
$env:NLB_HOSTNAME = kubectl get service podinfo-nlb -n workshop-nlb -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
Write-Host $env:NLB_HOSTNAME
```

Send a request to the NLB:

```bash
curl -s http://$NLB_HOSTNAME/ | grep message
```

PowerShell (Windows):

```powershell
curl.exe -s http://$env:NLB_HOSTNAME/ | Select-String "message"
```

Expected output:

```
"message": "Hello from podinfo"
```

If the curl times out on the first attempt, wait 30 seconds and retry. NLBs take a moment after the hostname resolves for targets to become healthy.

## Step 4: Understand Instance Target Mode

The Service manifest includes the annotation `service.beta.kubernetes.io/aws-load-balancer-type: external` - this tells the AWS Load Balancer Controller (not the legacy in-tree cloud provider) to manage this Service.

In instance target mode, the NLB registers EC2 node IPs and NodePorts as targets. Traffic flows as follows:

1. Client sends a TCP connection to the NLB hostname
2. NLB forwards the connection to a node IP on the NodePort
3. kube-proxy on that node forwards the packet to a pod (which may be on a different node)
4. The pod responds and the reply travels back the same path

This is the simpler mode - it works with any CNI plugin and does not require pods to have VPC-routable IP addresses. The trade-off is the extra network hop through kube-proxy before traffic reaches the pod.

Verify the current target type:

```bash
kubectl get service podinfo-nlb -n workshop-nlb -o jsonpath='{.metadata.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-nlb-target-type}'
```

Expected output:

```
instance
```

## Step 5: Switch to IP Target Mode

Patch the annotation in place to switch to IP target mode:

```bash
kubectl annotate service podinfo-nlb -n workshop-nlb service.beta.kubernetes.io/aws-load-balancer-nlb-target-type=ip --overwrite
```

> **Note:** In production, AWS recommends deleting and recreating the Service rather than patching core NLB annotations. Editing annotations after creation can cause target group configuration issues. This patch-in-place approach is a workshop shortcut that works because the AWS LBC reconciles the change by replacing the target group.

Wait for the target group re-registration. The NLB needs to deregister the old node targets and register the new pod IP targets, which takes about 90 seconds. After 90 seconds, retry the request below. If it still fails, wait another 30 seconds and retry.

Verify connectivity is restored:

```bash
curl -s http://$NLB_HOSTNAME/ | grep message
```

PowerShell (Windows):

```powershell
curl.exe -s http://$env:NLB_HOSTNAME/ | Select-String "message"
```

Expected output:

```
"message": "Hello from podinfo"
```

If the curl fails, this is normal during target group replacement. Wait another 30 seconds and retry:

```bash
sleep 30
curl -s http://$NLB_HOSTNAME/ | grep message
```

PowerShell (Windows):

```powershell
Start-Sleep -Seconds 30
curl.exe -s http://$env:NLB_HOSTNAME/ | Select-String "message"
```

## Step 6: Understand IP Target Mode

In IP target mode, the NLB registers pod IPs directly as targets. Traffic flows as follows:

1. Client sends a TCP connection to the NLB hostname
2. NLB looks up the target group and forwards the connection directly to a pod IP
3. The pod receives the connection and responds directly

This eliminates the kube-proxy hop - traffic goes straight to the pod without stopping at a node's NodePort. It requires the VPC CNI plugin (installed on the `awscdro-eks` cluster) so that pods have VPC-routable IP addresses. IP mode is generally preferred on EKS because it reduces latency and preserves the client source IP address at the pod.

Verify the updated annotation:

```bash
kubectl get service podinfo-nlb -n workshop-nlb -o jsonpath='{.metadata.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-nlb-target-type}'
```

Expected output:

```
ip
```

## Step 7: Key Takeaways

|                      | Instance Mode                  | IP Mode                         |
|----------------------|--------------------------------|---------------------------------|
| **Target**           | Node IP + NodePort             | Pod IP directly                 |
| **Extra hop**        | Yes (kube-proxy)               | No                              |
| **CNI requirement**  | Any                            | VPC CNI (pods need VPC IPs)     |
| **Client source IP** | Lost (SNAT by kube-proxy)      | Preserved                       |
| **When to use**      | Simple setup, any CNI          | EKS with VPC CNI (recommended)  |

## Next Step

Proceed to [06-lab-gateway-api.md](06-lab-gateway-api.md) to deploy traffic routing using the Kubernetes Gateway API.
