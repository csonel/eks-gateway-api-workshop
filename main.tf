################################################################################
# VPC
################################################################################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.19"

  name = "${var.eks_cluster_name}-vpc"
  cidr = "10.0.0.0/22"

  azs                     = var.availability_zones
  public_subnets          = var.public_subnets
  map_public_ip_on_launch = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${var.eks_cluster_name}" : "owned"
    "kubernetes.io/role/elb" = "1"
  }

  vpc_tags = {
    Name = "${var.eks_cluster_name}-vpc"
  }
}

################################################################################
# Kubernetes Cluster
################################################################################
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = var.eks_cluster_name
  cluster_version = var.eks_cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  cluster_endpoint_private_access = true
  cluster_endpoint_public_access  = true

  # Disable CloudWatch logging
  cluster_enabled_log_types = []

  # Grants cluster-admin access to whoever runs `terraform apply`.
  # Recreated if a different IAM user runs it (safe but noisy).
  # TODO: Add instructor access entries before the workshop.
  enable_cluster_creator_admin_permissions = true

  # Cluster addons
  cluster_addons = {
    vpc-cni    = {}
    kube-proxy = {}
    coredns = {
      configuration_values = jsonencode({
        replicaCount = 1
        resources = {
          requests = {
            cpu    = "50m"
            memory = "25Mi"
          }
          limits = {
            cpu    = "50m"
            memory = "25Mi"
          }
        }
      })
    }
    metrics-server = {
      configuration_values = "{\"replicas\": 1}"
    }
  }

  # EKS Managed Node group(s)
  eks_managed_node_group_defaults = {
    ami_type                        = "BOTTLEROCKET_x86_64"
    instance_types                  = ["t3.small", "t3.medium"]
    use_custom_launch_template      = false
    use_name_prefix                 = false
    iam_role_use_name_prefix        = false
    launch_template_use_name_prefix = false

    schedules = {
      "scale-up" = {
        recurrence   = "0 10 * * *"
        time_zone    = "Europe/Bucharest"
        min_size     = 1
        max_size     = 9
        desired_size = 3
      }
      "scale-down" = {
        recurrence   = "0 23 * * *"
        time_zone    = "Europe/Bucharest"
        min_size     = 0
        max_size     = 9
        desired_size = 0
      }
    }

    labels = {
      "ManagedBy" = "eks"
    }

    tags = {
      Project     = "AWS Community Day 2026"
      Environment = "Dev"
      Service     = "EKS"
    }
  }

  eks_managed_node_groups = {
    # Node group for x86_64 architecture
    awscdro_eks_default = {
      min_size     = 1
      max_size     = 9
      desired_size = 3
    }
  }

  cluster_tags = {
    Name = var.eks_cluster_name
  }
}

################################################################################
# VPC Lattice - Node Security Group Rules
# Allow VPC Lattice to reach pods on port 9898 (podinfo) via the managed
# prefix lists. Both IPv4 and IPv6 prefix lists must be allowed.
################################################################################

data "aws_ec2_managed_prefix_list" "vpc_lattice_ipv4" {
  name = "com.amazonaws.${var.region}.vpc-lattice"
}

data "aws_ec2_managed_prefix_list" "vpc_lattice_ipv6" {
  name = "com.amazonaws.${var.region}.ipv6.vpc-lattice"
}

resource "aws_security_group_rule" "nodes_vpc_lattice_ipv4" {
  description       = "Allow VPC Lattice (IPv4) to reach pods on port 9898"
  type              = "ingress"
  from_port         = 9898
  to_port           = 9898
  protocol          = "tcp"
  prefix_list_ids   = [data.aws_ec2_managed_prefix_list.vpc_lattice_ipv4.id]
  security_group_id = module.eks.cluster_primary_security_group_id
}

resource "aws_security_group_rule" "nodes_vpc_lattice_ipv6" {
  description       = "Allow VPC Lattice (IPv6) to reach pods on port 9898"
  type              = "ingress"
  from_port         = 9898
  to_port           = 9898
  protocol          = "tcp"
  prefix_list_ids   = [data.aws_ec2_managed_prefix_list.vpc_lattice_ipv6.id]
  security_group_id = module.eks.cluster_primary_security_group_id
}

resource "null_resource" "generate_kubeconfig" {
  provisioner "local-exec" {
    command = "aws eks --region ${var.region} update-kubeconfig --name ${module.eks.cluster_name} --profile ${var.profile}"
  }

  depends_on = [module.eks]
}
