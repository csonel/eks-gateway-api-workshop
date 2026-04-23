profile = "aws-community-day"

# VPC
availability_zones = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]
public_subnets     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]

# EKS
eks_cluster_name    = "awscdro-eks"
eks_cluster_version = "1.35"
