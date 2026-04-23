# Cluster Setup

Configure `kubectl` to connect to the workshop EKS cluster and create all lab namespaces.

## Step 1: Provision the Cluster

The Terraform configuration uses **local state** by default - `terraform.tfstate` is stored in the repository root on your machine. No additional setup is required.

> **(Optional) S3 backend:** To store state remotely, open `providers.tf` and uncomment the `backend "s3"` block, filling in your bucket name and adjusting the profile if needed. Then run `terraform init` as normal.

Run Terraform to provision the EKS cluster and VPC infrastructure:

```bash
terraform init
terraform apply
```

Confirm the prompt to proceed. This takes 10-15 minutes.

`terraform apply` automatically updates your kubeconfig at the end using a `local-exec` provisioner, so you do not need to run `aws eks update-kubeconfig` manually.

> **Note:** If you are using **Option B** (environment variables, `profile=""`), the local-exec provisioner runs `aws eks update-kubeconfig --profile ""` which will fail. In that case, run the kubeconfig update manually after `terraform apply` completes:
>
> ```bash
> aws eks --region eu-central-1 update-kubeconfig --name awscdro-eks
> ```

## Step 2: Verify Cluster Access

Check that all nodes are healthy and the cluster is reachable:

```bash
kubectl get nodes -o wide
```

Expected output: all nodes in `Ready` status, running Bottlerocket (you will see `bottlerocket` in the OS image description).

```bash
kubectl cluster-info
```

Expected output: the Kubernetes control plane URL and the CoreDNS address.

## Step 3: Create Workshop Namespaces

Apply the namespace manifest to create all five lab namespaces at once:

```bash
kubectl apply -f manifests/namespaces/workshop-namespaces.yaml
```

Expected output:

```
namespace/workshop-app created
namespace/workshop-alb created
namespace/workshop-nlb created
namespace/workshop-gateway created
namespace/workshop-lattice created
```

## Step 4: Verify Namespaces

Confirm all five workshop namespaces are present and labeled correctly:

```bash
kubectl get namespaces -l workshop=aws-community-day-2026
```

Expected output:

```
NAME               STATUS   AGE
workshop-alb       Active   <age>
workshop-app       Active   <age>
workshop-gateway   Active   <age>
workshop-lattice   Active   <age>
workshop-nlb       Active   <age>
```

Each lab uses its own namespace so resources do not conflict. The `workshop-app` namespace holds the shared application, and each lab namespace holds that lab's load balancer resources. This separation also lets us demonstrate cross-namespace routing in the Gateway API lab.

| Namespace          | Purpose                                   |
|--------------------|-------------------------------------------|
| `workshop-app`     | Sample application shared across all labs |
| `workshop-alb`     | ALB via Ingress lab                       |
| `workshop-nlb`     | NLB via Service type LoadBalancer lab     |
| `workshop-gateway` | Gateway API lab                           |
| `workshop-lattice` | VPC Lattice lab                           |

## Next Step

Continue to [02-controllers.md](02-controllers.md) to install the Gateway API CRDs and the AWS Load Balancer Controller.
