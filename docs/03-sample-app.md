# Sample Application

This guide deploys the shared sample application used by all three labs. The application consists of two instances of [podinfo](https://github.com/stefanprodan/podinfo), a lightweight Go microservice, each configured with a different response message so you can visually confirm which backend is handling traffic.

## Application Architecture

| Component  | Service Name     | Response Message      | Namespace    |
|------------|------------------|-----------------------|--------------|
| Frontend   | podinfo-frontend | "Hello from frontend" | workshop-app |
| Backend    | podinfo-backend  | "Hello from backend"  | workshop-app |

Both services are exposed as ClusterIP (internal only). The labs will add external-facing resources (Ingress, Service LoadBalancer, Gateway, HTTPRoute) that route traffic to these services.

## Step 1: Deploy the Application

```bash
kubectl apply -f manifests/app/ -n workshop-app
```

This creates two Deployments (2 replicas each) and two ClusterIP Services in the `workshop-app` namespace. The `-n` flag specifies the target namespace.

## Step 2: Verify Pods Are Running

```bash
kubectl get pods -n workshop-app
```

Expected output: Four pods (2 frontend + 2 backend), all showing `STATUS: Running` and `READY: 1/1`. Pods should be ready within 30 seconds.

If pods are in `Pending` state, check node capacity:

```bash
kubectl get events -n workshop-app --sort-by=.lastTimestamp
```

## Step 3: Verify Services

```bash
kubectl get services -n workshop-app
```

Expected output:
- `podinfo-frontend` - ClusterIP, port 9898
- `podinfo-backend` - ClusterIP, port 9898

## Step 4: Test Application Responses

Use `kubectl port-forward` to verify each instance responds with its unique message:

In one terminal, start the frontend port-forward and keep it running:

```bash
kubectl port-forward -n workshop-app svc/podinfo-frontend 9898:9898
```

In a second terminal, send a request:

```bash
curl -s http://localhost:9898
```

PowerShell (Windows):

```powershell
curl.exe -s http://localhost:9898 | Select-String "message"
```

Confirm the response includes: `"message": "Hello from frontend"`, then stop the port-forward with `Ctrl+C`.

Repeat the same process for the backend service. In one terminal, start:

```bash
kubectl port-forward -n workshop-app svc/podinfo-backend 9899:9898
```

In a second terminal, send a request:

```bash
curl -s http://localhost:9899
```

PowerShell (Windows):

```powershell
curl.exe -s http://localhost:9899 | Select-String "message"
```

Confirm the response includes: `"message": "Hello from backend"`, then stop the port-forward with `Ctrl+C`.

## Available Endpoints

`podinfo` exposes several useful endpoints for testing:

| Endpoint           | Purpose                                                |
|--------------------|--------------------------------------------------------|
| `/`                | Returns JSON with version, message, and hostname       |
| `/healthz`         | Health check (used by liveness probe)                  |
| `/readyz`          | Ready check (used by readiness probe)                  |
| `/delay/{seconds}` | Responds after a delay (useful for timeout testing)    |
| `/env`             | Returns environment variables                          |
| `/headers`         | Returns request headers (useful for verifying routing) |

## Next Step

Proceed to [04-lab-alb.md](04-lab-alb.md) to begin the ALB Ingress lab.
