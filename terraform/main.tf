locals {
  name               = "my-app-cluster"
  kubernetes_version = "1.32"
  region             = "ap-south-1"

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  # Namespaces Jenkins is allowed to deploy into via Helm (CD stage).
  # Add/remove as your app namespaces are created.
  jenkins_deploy_namespaces = ["default", "apps"]

  # Git repo holding jenkins.yaml (JCasC) + plugins.txt — cloned by user_data at boot.
  jenkins_config_repo = "https://github.com/arupsscet1-buff/google-online-boutique.git"

  tags = {
    Test       = local.name
    GithubRepo = "aws-eks"
    GithubOrg  = "aws-modules"
  }
}

data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

################################################################################
# VPC Module
################################################################################
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 48)]

  enable_nat_gateway = true
  single_nat_gateway = true

  enable_dns_support   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = local.tags
}

################################################################################
# EKS Module
################################################################################
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name                    = local.name
  kubernetes_version      = local.kubernetes_version
  endpoint_public_access  = true
  endpoint_private_access = true

  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Cluster Addons
  addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
    # CHANGE: required for aws_eks_pod_identity_association (Jenkins agent
    # ECR access) to actually function inside the cluster.
    eks-pod-identity-agent = {
      most_recent = true
    }
  }

  # EKS Managed Node Group(s)
  eks_managed_node_groups = {
    system-ng = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3.large"]
      subnet_ids     = module.vpc.private_subnets

      labels = {
        role = "system-node"
      }

      iam_role_additional_policies = {
        AmazonEKSWorkerNodePolicy          = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
        AmazonEKS_CNI_Policy               = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
        AmazonEC2ContainerRegistryReadOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
        AmazonSSMManagedInstanceCore       = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      min_size     = 2
      max_size     = 2
      desired_size = 2

      tags = merge(
        local.tags,
        {
          "k8s.io/cluster-autoscaler/${local.name}" = "owned"
        }
      )
    }

    build-ng = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3.large"]
      subnet_ids     = module.vpc.private_subnets

      labels = {
        role = "build-node"
      }
      taints = {
        dedicated = {
          key    = "dedicated"
          value  = "build"
          effect = "NO_SCHEDULE"
        }
      }

      # NOTE: AmazonEC2ContainerRegistryReadOnly is intentionally kept here
      # (pull only). Push access for build agents is granted via Pod Identity
      # below (aws_eks_pod_identity_association.jenkins_agent), scoped only
      # to the jenkins-agent ServiceAccount — not to every pod on this node.
      iam_role_additional_policies = {
        AmazonEKSWorkerNodePolicy          = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
        AmazonEKS_CNI_Policy               = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
        AmazonEC2ContainerRegistryReadOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
        AmazonSSMManagedInstanceCore       = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      min_size     = 1
      max_size     = 2
      desired_size = 1

      tags = merge(
        local.tags,
        {
          "k8s.io/cluster-autoscaler/${local.name}" = "owned"
        }
      )
    }
  }

  tags = local.tags
}

################################################################################
# Deploy SonarQube via Helm (for code quality scanning)
################################################################################

resource "helm_release" "sonarqube" {
  name             = "sonarqube"
  repository       = "https://SonarSource.github.io/helm-chart-sonarqube"
  chart            = "sonarqube"
  namespace        = "sonarqube"
  create_namespace = true

  depends_on = [module.eks]
}

################################################################################
# Namespace + ServiceAccount for Jenkins Agent Pod Identity
################################################################################

resource "kubernetes_namespace" "jenkins" {
  metadata {
    name = "jenkins"
  }
}

resource "kubernetes_service_account" "jenkins-agent" {
  metadata {
    name = "jenkins-agent"
    namespace = "jenkins"
  }
}

################################################################################
# ECR Repository — image storage + OCI Helm chart storage
# CHANGE: added. Referenced by the CI pipeline (docker/Kaniko push) and the
# CD pipeline (helm push/pull chart).
################################################################################
resource "aws_ecr_repository" "app" {
  name                 = "my-app"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = local.tags
}

################################################################################
# Jenkins Controller — EKS access entry
# CHANGE: access_scope narrowed from cluster-wide to specific namespaces,
# since Jenkins now also performs CD (helm upgrade) and shouldn't hold
# cluster-wide edit rights.
################################################################################
resource "aws_eks_access_entry" "jenkins" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.jenkins.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "jenkins_deploy" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.jenkins.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = local.jenkins_deploy_namespaces
  }
}

################################################################################
# Jenkins Agent — IAM role + Pod Identity (NEW)
# Scoped ECR push access for the ephemeral Jenkins agent pod only — not the
# controller, and not every pod on build-ng.
#
# PREREQUISITE (outside Terraform): the "jenkins" namespace and a
# "jenkins-agent" ServiceAccount must exist in the cluster (created via
# kubectl/Helm, or your Jenkins Kubernetes plugin pod template config)
# before this association takes effect.
################################################################################
resource "aws_iam_role" "jenkins_agent" {
  name = "jenkins-agent-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = ["sts:AssumeRole", "sts:TagSession"]
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "agent_ecr_push" {
  role       = aws_iam_role.jenkins_agent.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

resource "aws_eks_pod_identity_association" "jenkins_agent" {
  cluster_name    = module.eks.cluster_name
  namespace       = "jenkins"
  service_account = "jenkins-agent"
  role_arn        = aws_iam_role.jenkins_agent.arn

  depends_on = [module.eks]
}

################################################################################
# Jenkins Controller EC2
################################################################################

# CHANGE: replaced hardcoded AMI ID with a data source that always resolves
# to the latest Amazon Linux 2023 AMI at apply time, avoiding future
# "AMI not found / deprecated" failures.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-resolute-26.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_eip" "jenkins" {
  domain = "vpc"
  tags   = { Name = "jenkins-controller-eip" }
}

resource "aws_eip_association" "jenkins" {
  instance_id   = aws_instance.jenkins-controller.id
  allocation_id = aws_eip.jenkins.id
}

resource "aws_instance" "jenkins-controller" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = "t3.large"
  subnet_id                   = module.vpc.public_subnets[0]
  key_name                    = "arupdops-mumbai"
  vpc_security_group_ids      = [aws_security_group.jenkins-sg.id]
  iam_instance_profile        = aws_iam_instance_profile.jenkins.name
  monitoring                  = true

  # User data: kubectl, helm, git, AWS CLI.
  # NOTE: Docker intentionally NOT installed here — the controller does not
  # build images in this architecture; only the ephemeral agent pod does
  # (via Kaniko/BuildKit, not Docker-in-Docker). Remove this note/comment
  # if you still need Docker on the controller for another reason.
  user_data_base64 = base64encode(templatefile("${path.module}/jenkins-userdata.sh.tpl", {
    eks_cluster_endpoint = module.eks.cluster_endpoint
    eks_cluster_name     = module.eks.cluster_name
    aws_region           = local.region
    jenkins_config_repo  = local.jenkins_config_repo
    jenkins_url          = aws_eip.jenkins.public_ip
  }))

  tags = {
    Name = "jenkins-controller"
  }

  depends_on = [
    module.vpc,
    module.eks,
    aws_iam_instance_profile.jenkins
  ]
}

################################################################################
# Jenkins Security Group
# CHANGE: SSH (22) restricted to a variable CIDR instead of 0.0.0.0/0.
# SSM Session Manager (already attached via IAM) is the preferred access
# path — consider removing the SSH ingress rule entirely once confirmed.
################################################################################
resource "aws_security_group" "jenkins-sg" {
  name   = "jenkins-sg"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "jenkins-sg"
  }
}

################################################################################
# Jenkins Controller IAM Role
################################################################################
resource "aws_iam_role" "jenkins" {
  name = "jenkins-controller-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# EKS control-plane API access (DescribeCluster, etc.) — for update-kubeconfig
resource "aws_iam_role_policy_attachment" "eks_read_only" {
  role       = aws_iam_role.jenkins.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSReadOnlyAccess"
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.jenkins.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# scoped Secrets Manager read access — only the specific secrets
# jenkins-userdata.sh.tpl pulls at boot, not secretsmanager:* on everything.
# NOTE: create these four secrets in Secrets Manager before first boot
# (aws secretsmanager create-secret --name jenkins/github-token ...).
data "aws_caller_identity" "current" {}

resource "aws_iam_role_policy" "jenkins_secrets" {
  name = "jenkins-secrets-read"
  role = aws_iam_role.jenkins.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [
          "arn:aws:secretsmanager:${local.region}:${data.aws_caller_identity.current.account_id}:secret:jenkins/github-token*",
          "arn:aws:secretsmanager:${local.region}:${data.aws_caller_identity.current.account_id}:secret:jenkins/github-username*",
          "arn:aws:secretsmanager:${local.region}:${data.aws_caller_identity.current.account_id}:secret:jenkins/sonar-token*",
          "arn:aws:secretsmanager:${local.region}:${data.aws_caller_identity.current.account_id}:secret:jenkins/admin-password*",
        ]
      }
    ]
  })
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "jenkins-controller-profile"
  role = aws_iam_role.jenkins.name
}