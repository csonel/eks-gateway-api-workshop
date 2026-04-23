# Cleanup

ALBs, NLBs, and VPC Lattice services incur charges even without traffic, so clean up lab resources before leaving. Delete Kubernetes resources that created AWS resources first, while the controllers are still running and can deprovision them, then run `terraform destroy`. Removing namespaces or uninstalling controllers is optional, as they are deleted with the cluster. Do not skip the AWS cleanup in Steps 1-4, or resources may be orphaned and continue to incur charges.

## Step 1: Delete VPC Lattice Lab Resources

Delete resources in dependency order: routes first, then the Gateway, and finally the GatewayClass. The AWS Gateway API Controller observes these deletions and automatically deprovisions the associated VPC Lattice services and target groups. The default Service Network and its VPC association are not managed by Gateway resources and must be cleaned up manually as shown below.

```bash
kubectl delete --ignore-not-found -f manifests/labs/lattice/httproute-weighted.yaml -n workshop-lattice
kubectl delete --ignore-not-found -f manifests/labs/lattice/httproute.yaml -n workshop-lattice
kubectl delete --ignore-not-found -f manifests/labs/lattice/gateway.yaml -n workshop-lattice
kubectl delete --ignore-not-found -f manifests/labs/lattice/gatewayclass.yaml
```

> **Note:** Some of these resources may have been deleted during the lab exercises. The `--ignore-not-found` flag suppresses "not found" errors so you can run the full cleanup safely.

### Delete the default Service Network manually

The `workshop-lattice-gateway` Service Network is created by the controller at startup via the `defaultServiceNetwork` Helm setting. It is not managed by Gateway resources, so deleting a Gateway does not remove it. You must delete the Service Network and its VPC association manually, otherwise they will block `terraform destroy`.

```bash
SERVICE_NETWORK_NAME=workshop-lattice-gateway
SERVICE_NETWORK_ID=$(aws vpc-lattice list-service-networks \
  --query "items[?name=='${SERVICE_NETWORK_NAME}'].id | [0]" \
  --output text 2>/dev/null)

if [ -z "$SERVICE_NETWORK_ID" ] || [ "$SERVICE_NETWORK_ID" = "None" ]; then
  echo "Service Network not found; continuing."
else
  for ASSOC in $(aws vpc-lattice list-service-network-vpc-associations \
      --service-network-identifier "$SERVICE_NETWORK_ID" \
      --query 'items[*].id' --output text); do
    aws vpc-lattice delete-service-network-vpc-association \
      --service-network-vpc-association-identifier "$ASSOC"
  done

  echo "Waiting for VPC associations to delete..."
  while aws vpc-lattice list-service-network-vpc-associations \
    --service-network-identifier "$SERVICE_NETWORK_ID" \
    --query 'items[*].id' --output text 2>/dev/null | grep -q .; do
    sleep 10
    echo "Still waiting..."
  done

  aws vpc-lattice delete-service-network --service-network-identifier "$SERVICE_NETWORK_ID"
  echo "Service Network deleted."
fi
```

PowerShell (Windows):

```powershell
$serviceNetworkName = "workshop-lattice-gateway"
$serviceNetworkId = aws vpc-lattice list-service-networks --query "items[?name=='$serviceNetworkName'].id | [0]" --output text 2>$null

if ([string]::IsNullOrWhiteSpace($serviceNetworkId) -or $serviceNetworkId -eq "None") {
  Write-Host "Service Network not found; continuing."
} else {
  $associationIds = aws vpc-lattice list-service-network-vpc-associations `
    --service-network-identifier $serviceNetworkId `
    --query 'items[*].id' --output text 2>$null

  if (-not [string]::IsNullOrWhiteSpace($associationIds)) {
    foreach ($associationId in ($associationIds -split '\s+')) {
      if (-not [string]::IsNullOrWhiteSpace($associationId)) {
        aws vpc-lattice delete-service-network-vpc-association `
          --service-network-vpc-association-identifier $associationId
      }
    }
  }

  Write-Host "Waiting for VPC associations to delete..."
  while ($true) {
    $remaining = aws vpc-lattice list-service-network-vpc-associations `
      --service-network-identifier $serviceNetworkId `
      --query 'items[*].id' --output text 2>$null
    if ([string]::IsNullOrWhiteSpace($remaining)) { break }
    Start-Sleep -Seconds 10
    Write-Host "Still waiting..."
  }

  aws vpc-lattice delete-service-network --service-network-identifier $serviceNetworkId
  Write-Host "Service Network deleted."
}
```

Then delete the `podinfo` instances deployed in the `workshop-lattice` namespace:

```bash
kubectl delete --ignore-not-found -f manifests/app/ -n workshop-lattice
```

## Step 2: Delete Gateway API Lab Resources

Delete resources in the correct order to avoid cleanup issues:

1. Routes
2. Gateway
3. Configuration CRDs (`LoadBalancerConfiguration`, `TargetGroupConfigurations`)
4. `GatewayClass`

The Gateway references the `LoadBalancerConfiguration` through `spec.infrastructure.parametersRef`. If you delete the configuration first, the controller cannot remove its finalizer and cleanup will hang with the error: *"loadbalancer configuration is still in use"*.

```bash
kubectl delete --ignore-not-found -f manifests/labs/gateway/httproute-crossns.yaml -n workshop-app
kubectl delete --ignore-not-found -f manifests/labs/gateway/referencegrant.yaml -n workshop-gateway
kubectl delete --ignore-not-found -f manifests/labs/gateway/httproute-weighted.yaml -n workshop-gateway
kubectl delete --ignore-not-found -f manifests/labs/gateway/httproute-simple.yaml -n workshop-gateway
kubectl delete --ignore-not-found -f manifests/labs/gateway/gateway.yaml -n workshop-gateway
kubectl delete --ignore-not-found -f manifests/labs/gateway/lbconfig.yaml -n workshop-gateway
kubectl delete --ignore-not-found -f manifests/labs/gateway/tgconfig-frontend.yaml -n workshop-gateway
kubectl delete --ignore-not-found -f manifests/labs/gateway/tgconfig-backend.yaml -n workshop-gateway
kubectl delete --ignore-not-found -f manifests/labs/gateway/gatewayclass.yaml
```

> **Note:** Some of these resources may have been deleted during the lab exercises. The `--ignore-not-found` flag suppresses "not found" errors so you can run the full cleanup safely.

Deleting the Gateway resource triggers the AWS LBC to begin deprovisioning the ALB. Wait for the ALB to be fully removed before proceeding - if you delete namespaces too early, they can get stuck in `Terminating` state while finalizers wait for AWS resources to be cleaned up.

```bash
echo "Waiting for Gateway ALB deprovisioning..."
while kubectl get gateway -A 2>/dev/null | grep -q workshop; do
  sleep 10
  echo "Still waiting..."
done
echo "Gateway resources cleared."
```

PowerShell (Windows):

```powershell
Write-Host "Waiting for Gateway ALB deprovisioning..."
while (kubectl get gateway -A 2>$null | Select-String "workshop") {
  Start-Sleep -Seconds 10
  Write-Host "Still waiting..."
}
Write-Host "Gateway resources cleared."
```

Then remove the `podinfo` resources deployed in the `workshop-gateway` namespace:

```bash
kubectl delete -f manifests/app/ -n workshop-gateway
```

## Step 3: Delete NLB Lab Resources

```bash
kubectl delete --ignore-not-found -f manifests/labs/nlb/ -n workshop-nlb
```

Deleting the LoadBalancer Service triggers NLB deprovisioning. Wait approximately 30 seconds before proceeding.

## Step 4: Delete ALB Lab Resources

```bash
kubectl delete --ignore-not-found -f manifests/labs/alb/ -n workshop-alb
```

Wait approximately 30 seconds for the ALB to be deprovisioned. Then delete the podinfo instances in the ALB namespace:

```bash
kubectl delete -f manifests/app/ -n workshop-alb
```

## Step 5: Verify AWS Resources Are Gone

Check that no Ingress, LoadBalancer Service, or Gateway resources remain:

```bash
kubectl get ingress -A
kubectl get svc -A --field-selector spec.type=LoadBalancer
kubectl get gateway -A
```

Expected output: no Ingress resources, no LoadBalancer Services (any remaining services should be cluster-internal), no Gateway resources. If any remain, delete them individually before proceeding to namespace deletion.

Verify in AWS that all load balancers have been deprovisioned:

```bash
aws elbv2 describe-load-balancers --region eu-central-1 --query 'LoadBalancers[?contains(LoadBalancerName, `k8s`) == `true`].[LoadBalancerName,State.Code]' --output table
```

Also verify VPC Lattice Services and Service Networks are gone:

```bash
aws vpc-lattice list-services --query 'items[*].[name,status]' --output table
aws vpc-lattice list-service-networks --query 'items[*].[name,status]' --output table
aws vpc-lattice list-service-network-vpc-associations \
  --query 'items[*].[serviceNetworkName,status]' --output table 2>/dev/null || true
```

Expected output: empty tables for all commands. **If any Service Network VPC associations are still listed, `terraform destroy` will fail to delete the VPC.** Delete them manually before proceeding:

```bash
aws vpc-lattice delete-service-network-vpc-association \
  --service-network-vpc-association-identifier <association-id>
```

## Step 6: Delete Namespaces (Optional)

If the cluster is being torn down entirely, the namespaces will be removed with it. If you are keeping the cluster for future sessions, remove the workshop namespaces:

```bash
kubectl delete -f manifests/namespaces/workshop-namespaces.yaml
```

This deletes all five workshop namespaces: `workshop-app`, `workshop-alb`, `workshop-nlb`, `workshop-gateway`, and `workshop-lattice`.

## Step 7: Remove Controllers (Optional)

Only remove controllers if you are tearing down the workshop environment completely. The controllers must be removed after all lab resources - not before.

Remove the AWS Load Balancer Controller:

```bash
helm uninstall aws-load-balancer-controller -n kube-system
```

If you installed the AWS Gateway API Controller (VPC Lattice), remove it as well:

```bash
helm uninstall gateway-api-controller -n aws-application-networking-system
```

## Step 8: Destroy the Cluster

With Step 5 confirming that all AWS resources are cleaned up, destroy the EKS cluster and remaining infrastructure using Terraform:

```bash
terraform destroy
```

Confirm the prompt to proceed. This takes 10-15 minutes.

> **Note:** `terraform destroy` removes the EKS cluster and all supporting infrastructure. Ensure all Kubernetes-managed AWS resources are deleted first. If the cluster is removed while controller finalizers are still pending, AWS resources may be orphaned and continue to incur charges. Complete Steps 1–5 before proceeding.

Workshop cleanup is complete. All AWS load balancers, VPC Lattice resources, and cluster infrastructure have been removed.
