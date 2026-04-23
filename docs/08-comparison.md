# When to Use ALB, NLB, or Gateway API on EKS

All three load balancing approaches are production-ready on Amazon EKS and managed by the AWS Load Balancer Controller v3.2.1. The right choice depends on your protocol requirements, routing complexity, and how your teams divide platform and application ownership. Use this document as a decision guide you can refer back to after leaving the workshop.

## Decision Table

| Approach                | Layer  | Protocol Support  | Use Case                                                                   | Provisioning Method                                     | Routing Flexibility                                                       |
|-------------------------|--------|-------------------|----------------------------------------------------------------------------|---------------------------------------------------------|---------------------------------------------------------------------------|
| ALB (Ingress)           | L7     | HTTP, HTTPS, gRPC | Web apps, REST APIs, microservice routing                                  | Ingress resource + annotations                          | Path-based, host-based                                                    |
| NLB (Service)           | L4     | TCP, UDP, TLS     | Raw TCP workloads, databases, game servers, high throughput                | Service type: LoadBalancer + annotations                | None (L4 forwarding only)                                                 |
| Gateway API (HTTPRoute) | L7     | HTTP, HTTPS, gRPC | Web apps needing advanced routing, canary deployments, multi-team clusters | GatewayClass + Gateway + HTTPRoute CRDs                 | Path-based, host-based, header-based, weighted splitting, cross-namespace |
| VPC Lattice             | L7     | HTTP, HTTPS, gRPC | Service-to-service (east-west), cross-account, cross-VPC                   | GatewayClass + Gateway + HTTPRoute (Lattice controller) | Path-based, weighted splitting, cross-account service discovery           |

## ALB via Ingress

ALB via Ingress uses the familiar Kubernetes Ingress resource pattern - a single manifest with path and host routing rules provisioned automatically by the AWS Load Balancer Controller from annotations. It is well-suited for standard web traffic where teams are already comfortable with Ingress and do not need advanced routing features like weighted canary splits or cross-namespace backends. The `alb.ingress.kubernetes.io/` annotation prefix controls ALB-specific behavior such as scheme, target type, and certificate ARN.

See [04-lab-alb.md](04-lab-alb.md) for the complete hands-on walkthrough including annotation reference and expected output at each step.

## NLB via Service

NLB via Service is the right choice for Layer 4 workloads where HTTP inspection is unnecessary or undesirable - TCP databases, UDP game servers, financial systems requiring static IPs via Elastic IPs, or any workload needing direct connection passthrough. The AWS LBC supports two target modes: instance mode (traffic hits node port first) and IP mode (traffic goes directly to pod IP, skipping the extra hop). Both modes are covered in the NLB lab.

See [05-lab-nlb.md](05-lab-nlb.md) for the NLB deployment walkthrough including the instance-to-IP target mode switch exercise.

## Gateway API via HTTPRoute

Gateway API is the Kubernetes-native forward direction for traffic management, using typed CRDs instead of untyped string annotations. The role separation model is built in: platform teams own the `Gateway` resource (which provisions the ALB and controls which namespaces can attach), and application teams own `HTTPRoute` resources (which define routing rules within those namespaces). This pattern scales to multi-team clusters without giving application teams ALB provisioning permissions. Built-in weighted routing lets you run canary deployments without extra tooling.

See [06-lab-gateway-api.md](06-lab-gateway-api.md) for the Gateway API lab including path routing, weighted canary splitting, and the cross-namespace security model with `ReferenceGrant`.

## Quick Decision Guide

1. Do you need Layer 4 (raw TCP/UDP) forwarding?
   - **Yes** -> NLB via Service
   - **No** -> continue
2. Is this service-to-service (east-west) traffic, or cross-account / cross-VPC routing?
   - **Yes** -> VPC Lattice
   - **No** -> continue
3. Do you need weighted routing, cross-namespace routing, or header-based matching?
   - **Yes** -> Gateway API (HTTPRoute)
   - **No** -> continue
4. Are you starting a new project or migrating existing Ingress resources?
   - **New project** -> Gateway API (future-proof)
   - **Existing Ingress that works fine** -> Keep ALB via Ingress (no urgency to migrate)

## Key Takeaways

1. **ALB (Ingress)** is the established pattern - simple, well-documented, and sufficient for most HTTP workloads. It is not going away.
2. **NLB (Service)** is the only option for non-HTTP protocols. Use IP mode on EKS with VPC CNI for direct pod targeting.
3. **Gateway API** is the Kubernetes-native future - typed CRDs, built-in role separation, and features like weighted routing that Ingress will never get. Start here for new projects.
4. **VPC Lattice** is the right choice for service mesh-like east-west routing without running a service mesh. It handles cross-account and cross-VPC connectivity natively and uses the same Gateway API CRDs you already know.
5. **All four** coexist in the same cluster. You do not choose one exclusively.

## VPC Lattice

AWS VPC Lattice provides east-west (service-to-service) routing using the same Gateway API CRDs — `GatewayClass`, `Gateway`, and `HTTPRoute` — but implemented by the Amazon VPC Lattice controller rather than the AWS LBC. It complements the north-south patterns you used in the ALB and NLB labs by enabling cross-account and cross-VPC service discovery without VPC peering or custom DNS.

See [07-lab-lattice.md](07-lab-lattice.md) for the full hands-on VPC Lattice lab including path-based routing, weighted splitting, and a comparison of when to choose VPC Lattice over ALB.

## Next Step

Proceed to [09-cleanup.md](09-cleanup.md) to tear down the lab resources and verify all AWS load balancers have been deprovisioned.
