################################################################################
# AWS Load Balancer Controller - IAM & IRSA
################################################################################

resource "aws_iam_policy" "aws_load_balancer_controller" {
  name   = "${var.eks_cluster_name}-aws-lb-controller"
  policy = file("${path.module}/iam/lbc-policy.json")
}

resource "aws_iam_role" "aws_load_balancer_controller" {
  name = "${var.eks_cluster_name}-aws-lb-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = module.eks.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
          "${module.eks.oidc_provider}:sub" = "system:serviceaccount:kube-system:aws-load-balancer-controller"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "aws_load_balancer_controller" {
  role       = aws_iam_role.aws_load_balancer_controller.name
  policy_arn = aws_iam_policy.aws_load_balancer_controller.arn
}

################################################################################
# AWS Gateway API Controller (VPC Lattice) - IAM & IRSA
################################################################################

resource "aws_iam_policy" "gateway_api_controller" {
  name   = "${var.eks_cluster_name}-gateway-api-controller"
  policy = file("${path.module}/iam/lattice-policy.json")
}

resource "aws_iam_role" "gateway_api_controller" {
  name = "${var.eks_cluster_name}-gateway-api-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = module.eks.oidc_provider_arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
          "${module.eks.oidc_provider}:sub" = "system:serviceaccount:aws-application-networking-system:gateway-api-controller"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "gateway_api_controller" {
  role       = aws_iam_role.gateway_api_controller.name
  policy_arn = aws_iam_policy.gateway_api_controller.arn
}
