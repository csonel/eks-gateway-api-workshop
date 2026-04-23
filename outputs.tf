################################################################################
# Network
################################################################################

output "vpc_id" {
  description = "VPC ID used by EKS"
  value       = module.vpc.vpc_id
}

################################################################################
# EKS Cluster
################################################################################

output "aws_region" {
  description = "Region of all resources"
  value       = var.region
}

output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

################################################################################
# Helpers
################################################################################

output "eks_kubeconfig_command" {
  description = "Run this to configure kubectl"
  value       = "aws eks --region ${var.region} update-kubeconfig --name ${module.eks.cluster_name} --profile ${var.profile}"
}

output "my_ip_address" {
  description = "Current public IP"
  value       = chomp(data.http.myip.response_body)
}

################################################################################
# Controllers
################################################################################

output "aws_lbc_role_arn" {
  description = "IAM role ARN for the AWS Load Balancer Controller"
  value       = aws_iam_role.aws_load_balancer_controller.arn
}

output "gateway_api_controller_role_arn" {
  description = "IAM role ARN for the AWS Gateway API Controller (VPC Lattice)"
  value       = aws_iam_role.gateway_api_controller.arn
}
