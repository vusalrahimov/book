###############################################################################
# Enterprise Kubernetes Infrastructure on AWS
# Terraform 1.7+ | AWS Provider ~5.40
###############################################################################

terraform {
  required_version = ">= 1.7.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.40"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.27"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  backend "s3" {
    bucket         = "company-terraform-state"
    key            = "production/eks/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
    # Enable S3 versioning on the bucket for state history
  }
}

###############################################################################
# Variables
###############################################################################

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name (production, staging, dev)"
  type        = string
  default     = "production"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "main"
}

variable "cluster_version" {
  description = "Kubernetes version"
  type        = string
  default     = "1.29"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

###############################################################################
# Locals
###############################################################################

locals {
  cluster_full_name = "${var.environment}-${var.cluster_name}"

  common_tags = {
    Environment = var.environment
    Project     = "platform"
    ManagedBy   = "terraform"
    Team        = "platform-engineering"
  }

  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 48)]
  intra_subnets   = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 52)] # For EKS control plane
}

###############################################################################
# Data Sources
###############################################################################

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = local.common_tags
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

###############################################################################
# VPC
###############################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.7"

  name = "${local.cluster_full_name}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets
  intra_subnets   = local.intra_subnets

  # NAT Gateway for private subnet internet access
  enable_nat_gateway = true
  single_nat_gateway = var.environment != "production" # Multiple NAT GWs in prod
  one_nat_gateway_per_az = var.environment == "production"

  # DNS settings required for EKS
  enable_dns_hostnames = true
  enable_dns_support   = true

  # VPC Flow Logs for security and compliance
  enable_flow_log                      = true
  create_flow_log_cloudwatch_log_group = true
  create_flow_log_cloudwatch_iam_role  = true
  flow_log_max_aggregation_interval    = 60

  # Required subnet tags for EKS load balancer controller
  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
    "kubernetes.io/cluster/${local.cluster_full_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    "kubernetes.io/cluster/${local.cluster_full_name}" = "shared"
  }

  tags = local.common_tags
}

###############################################################################
# EKS Cluster
###############################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.8"

  cluster_name    = local.cluster_full_name
  cluster_version = var.cluster_version

  # API server endpoint access
  cluster_endpoint_public_access  = false  # Internal only
  cluster_endpoint_private_access = true
  cluster_endpoint_public_access_cidrs = []

  # Networking
  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  # Enable IRSA (IAM Roles for Service Accounts)
  enable_irsa = true

  # Secrets encryption with KMS
  cluster_encryption_config = {
    resources        = ["secrets"]
    provider_key_arn = aws_kms_key.eks.arn
  }

  # Cluster logging
  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # Managed node groups
  eks_managed_node_groups = {
    # General workload node group
    general = {
      name           = "${local.cluster_full_name}-general"
      instance_types = ["m5.xlarge", "m5a.xlarge"]  # Multiple types for Spot diversity
      capacity_type  = var.environment == "production" ? "ON_DEMAND" : "SPOT"

      min_size     = 3
      max_size     = 20
      desired_size = 5

      # Use SSM for node management (no SSH needed)
      enable_monitoring = true

      disk_size = 50

      labels = {
        "node-type" = "general"
        "workload"  = "application"
      }

      tags = merge(local.common_tags, {
        "k8s.io/cluster-autoscaler/enabled" = "true"
        "k8s.io/cluster-autoscaler/${local.cluster_full_name}" = "owned"
      })
    }

    # High-memory nodes for Redis/caching workloads
    high-memory = {
      name           = "${local.cluster_full_name}-high-memory"
      instance_types = ["r5.2xlarge"]
      capacity_type  = "ON_DEMAND"

      min_size     = 2
      max_size     = 10
      desired_size = 3

      labels = {
        "node-type" = "high-memory"
        "workload"  = "caching"
      }

      taints = [{
        key    = "dedicated"
        value  = "high-memory"
        effect = "NO_SCHEDULE"
      }]
    }
  }

  # Add-ons managed by AWS
  cluster_addons = {
    coredns = {
      most_recent = true
      configuration_values = jsonencode({
        replicaCount = 2
        resources = {
          limits   = { cpu = "200m", memory = "170Mi" }
          requests = { cpu = "100m", memory = "70Mi" }
        }
      })
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent              = true
      service_account_role_arn = module.vpc_cni_irsa_role.iam_role_arn
      configuration_values = jsonencode({
        env = {
          ENABLE_POD_ENI = "true"  # Security groups for pods
          POD_SECURITY_GROUP_ENFORCING_MODE = "standard"
        }
      })
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = module.ebs_csi_irsa_role.iam_role_arn
    }
  }

  tags = local.common_tags
}

###############################################################################
# IRSA Roles (IAM Roles for Service Accounts)
###############################################################################

module "vpc_cni_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.37"

  role_name             = "${local.cluster_full_name}-vpc-cni"
  attach_vpc_cni_policy = true
  vpc_cni_enable_ipv4   = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-node"]
    }
  }
}

module "ebs_csi_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.37"

  role_name             = "${local.cluster_full_name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

###############################################################################
# KMS Key for EKS Secret Encryption
###############################################################################

resource "aws_kms_key" "eks" {
  description             = "EKS Secret Encryption Key - ${local.cluster_full_name}"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = merge(local.common_tags, { Name = "${local.cluster_full_name}-eks-secrets" })
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${local.cluster_full_name}-eks-secrets"
  target_key_id = aws_kms_key.eks.key_id
}

###############################################################################
# RDS PostgreSQL (Multi-AZ for Production)
###############################################################################

module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.5"

  identifier = "${local.cluster_full_name}-orders"

  engine               = "postgres"
  engine_version       = "16.1"
  family               = "postgres16"
  major_engine_version = "16"
  instance_class       = var.environment == "production" ? "db.r6g.xlarge" : "db.t3.medium"

  allocated_storage     = 100
  max_allocated_storage = 1000  # Auto-scaling storage up to 1TB
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.rds.arn

  db_name  = "orders"
  username = "orders_admin"
  port     = 5432

  # Multi-AZ for production
  multi_az = var.environment == "production"

  # Networking
  db_subnet_group_name   = module.vpc.database_subnet_group
  vpc_security_group_ids = [aws_security_group.rds.id]

  # Performance Insights
  performance_insights_enabled          = true
  performance_insights_retention_period = 7  # days
  performance_insights_kms_key_id       = aws_kms_key.rds.arn

  # Enhanced monitoring (every 60 seconds)
  monitoring_interval    = 60
  monitoring_role_name   = "${local.cluster_full_name}-rds-monitoring"
  create_monitoring_role = true

  # Backups
  backup_retention_period = var.environment == "production" ? 30 : 7
  backup_window           = "03:00-06:00"
  maintenance_window      = "Mon:00:00-Mon:03:00"
  copy_tags_to_snapshot   = true

  # Parameters
  parameters = [
    { name = "shared_preload_libraries", value = "pg_stat_statements" },
    { name = "log_min_duration_statement", value = "1000" },  # Log queries > 1s
    { name = "log_connections", value = "1" },
    { name = "log_disconnections", value = "1" },
    { name = "log_lock_waits", value = "1" },
    { name = "auto_explain.log_min_duration", value = "1000" },
  ]

  # Protection
  deletion_protection = var.environment == "production"

  tags = merge(local.common_tags, { Name = "${local.cluster_full_name}-orders-rds" })
}

###############################################################################
# Outputs
###############################################################################

output "cluster_name" {
  description = "EKS Cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS Cluster endpoint"
  value       = module.eks.cluster_endpoint
  sensitive   = true
}

output "cluster_certificate_authority_data" {
  description = "EKS CA certificate"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "rds_endpoint" {
  description = "RDS endpoint"
  value       = module.rds.db_instance_endpoint
  sensitive   = true
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}
