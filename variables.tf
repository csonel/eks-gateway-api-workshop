variable "region" {
  type        = string
  description = "AWS region to deploy resources in"
  default     = "eu-central-1"
}

variable "profile" {
  type        = string
  description = "AWS profile. DO NOT FORGET to adjust also s3 backend in providers.tf"
}

variable "availability_zones" {
  type        = list(string)
  description = "List of availability zones to use for the VPC"
}

variable "public_subnets" {
  type        = list(string)
  description = "List of public subnets to create in the VPC"
}

variable "eks_cluster_name" {
  type        = string
  description = "Name of the EKS cluster"
}

variable "eks_cluster_version" {
  type        = string
  description = "Version of the EKS cluster"
  default     = "1.33"
}