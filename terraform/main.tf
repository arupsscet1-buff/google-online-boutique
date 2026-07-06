locals {
  name               = "my-app-cluster"
  kubernetes_version = "1.32"
  region             = "ap-south-1"

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

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

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = local.tags
}

################################################################################
# EKS Module (with ALL fixes)
################################################################################
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name                   = local.name
  kubernetes_version     = local.kubernetes_version
  endpoint_public_access = true
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

      #UPDATED - All required policies
      iam_role_additional_policies = {
        AmazonEKSWorkerNodePolicy            = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
        AmazonEKS_CNI_Policy                 = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
        AmazonEC2ContainerRegistryReadOnly   = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
        AmazonSSMManagedInstanceCore         = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
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

      #UPDATED - All required policies
      iam_role_additional_policies = {
        AmazonEKSWorkerNodePolicy            = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
        AmazonEKS_CNI_Policy                 = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
        AmazonEC2ContainerRegistryReadOnly   = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
        AmazonSSMManagedInstanceCore         = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      min_size     = 1
      max_size     = 1
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
    type = "cluster"
  }
}

################################################################################
# Jenkins Controller EC2
################################################################################
resource "aws_instance" "jenkins-controller" {
  ami                         = "ami-01a00762f46d584a1"
  instance_type               = "t3.large"
  subnet_id                   = module.vpc.public_subnets[0]
  associate_public_ip_address = true
  key_name                    = "arupdops-mumbai"
  vpc_security_group_ids      = [aws_security_group.jenkins-sg.id]
  iam_instance_profile        = aws_iam_instance_profile.jenkins.name
  monitoring                  = true

  # User data to install kubectl,docker,git and AWS CLI
  user_data_base64 = base64encode(<<-EOF
              #!/bin/bash
              set -e
              dnf update -y
              dnf install -y docker git curl
              
              # Install kubectl
              curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
              chmod +x kubectl
              mv kubectl /usr/local/bin/
              
              # Start Docker
              systemctl start docker
              systemctl enable docker
              usermod -aG docker ec2-user
              EOF
  )

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
# Jenkins IAM Role (CORRECTED)
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

# Correct policy for EC2 to access EKS
resource "aws_iam_role_policy_attachment" "eks_read_only" {
  role       = aws_iam_role.jenkins.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSReadOnlyAccess"
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.jenkins.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "jenkins-controller-profile"
  role = aws_iam_role.jenkins.name
}
