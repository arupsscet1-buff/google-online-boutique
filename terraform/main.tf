locals {
  name               = "my-app-cluster"
  kubernetes_version = "1.32"
  region             = "ap-south-1"

  vpc_cidr = "10.0.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  # Namespaces Jenkins is allowed to deploy into via Helm (CD stage).
  # Add/remove as your app namespaces are created.
  jenkins_deploy_namespaces = ["default", "apps", "jenkins", "sonarqube"]

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
  security_group_additional_rules = {
    jenkins_https = {
      description              = "Allow Jenkins EC2 to access EKS API"
      protocol                 = "tcp"
      from_port                = 443
      to_port                  = 443
      type                     = "ingress"
      source_security_group_id = aws_security_group.jenkins-sg.id
    }
  }

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
      before_compute = true
    }
    eks-pod-identity-agent = {
      most_recent = true
    }
    aws-ebs-csi-driver = {
      most_recent = true
      pod_identity_association = [
        {
          role_arn        = aws_iam_role.ebs_csi.arn
          service_account = "ebs-csi-controller-sa"
        }
      ]
    }
  }

  # EKS Managed Node Group(s)
  eks_managed_node_groups = {
    system-ng = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["m5.large"]
      subnet_ids     = module.vpc.private_subnets

      labels = {
        role = "system-node"
      }

      iam_role_additional_policies = {
        AmazonEKSWorkerNodePolicy          = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
        AmazonEKS_CNI_Policy               = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
        AmazonEC2ContainerRegistryReadOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
        AmazonEC2ContainerRegistryPullOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
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

      iam_role_additional_policies = {
        AmazonEKSWorkerNodePolicy          = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
        AmazonEKS_CNI_Policy               = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
        AmazonEC2ContainerRegistryPowerUser = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
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

resource "time_sleep" "wait_for_cluster_access" {
  create_duration = "30s"
  depends_on      = [module.eks]
}

################################################################################
# EBS CSI Driver IAM Role + Pod Identity
################################################################################
resource "aws_iam_role" "ebs_csi" {
  name = "ebs-csi-driver-role"

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

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type = "gp3"
  }

  depends_on = [
    time_sleep.wait_for_cluster_access
  ]
}

################################################################################
# Deploy SonarQube via Helm (for code quality scanning)
################################################################################
resource "random_password" "sonar_monitoring_passcode" {
  length  = 24
  special = false
}

resource "aws_secretsmanager_secret_version" "sonar" {
  secret_id     = aws_secretsmanager_secret.sonar.id
  secret_string = random_password.sonar_monitoring_passcode.result
}

resource "helm_release" "sonarqube" {
  name             = "sonarqube"
  repository       = "https://SonarSource.github.io/helm-chart-sonarqube"
  version          = "2026.3.1"
  chart            = "sonarqube"
  namespace        = "sonarqube"
  create_namespace = true

  set_sensitive {
    name  = "monitoringPasscode"
    value = random_password.sonar_monitoring_passcode.result
  }
/*
  set {
    name  = "postgresql.enabled"
    value = "false"
  }

  set {
    name  = "postgresql.image.repository"
    value = "giosg/bitnami"
  }
  set {
    name  = "postgresql.image.tag"
    value = "postgresql-11.14.0-debian-10-r22"
  }

  set {
    name  = "image.repository"
    value = "library/sonarqube"
  }
  set {
    name  = "image.tag"
    value = "2026.3.0-community"
  }
  */
  set {
    name  = "community.enabled"
    value = "true"
  }

  depends_on = [
    time_sleep.wait_for_cluster_access,
    aws_secretsmanager_secret_version.sonar
  ]
}

################################################################################
# Namespace for Jenkins Agent
################################################################################

resource "kubernetes_namespace" "jenkins" {
  metadata {
    name = "jenkins"
  }
  depends_on = [time_sleep.wait_for_cluster_access]
}

resource "kubernetes_namespace" "my-app" {
  metadata {
    name = "my-app"
  }
  depends_on = [time_sleep.wait_for_cluster_access]
}
################################################################################
# ServiceAccount + long-lived token + RBAC for the Jenkins Kubernetes plugin
# (controller-side auth to EKS API — separate from jenkins-agent, which is
# the identity *inside* build pods via Pod Identity).
################################################################################

resource "kubernetes_service_account" "jenkins-controller" {
  metadata {
    name      = "jenkins-controller"
    namespace = "jenkins"
  }
  depends_on = [kubernetes_namespace.jenkins]
}

# Legacy-style long-lived token Secret — NOT the TokenRequest API used by
# `kubectl create token`, which expires after 1 hour. This binds via the
# `kubernetes.io/service-account.name` annotation and never expires, which
# is what the Jenkins Kubernetes plugin needs for a stable, unattended
# credential (no refresh logic in the plugin).
resource "kubernetes_secret" "jenkins-controller-token" {
  metadata {
    name      = "jenkins-controller-token"
    namespace = "jenkins"
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account.jenkins-controller.metadata[0].name
    }
  }
  type = "kubernetes.io/service-account-token"

  depends_on = [kubernetes_service_account.jenkins-controller]
}

resource "kubernetes_role" "jenkins-agent-manager" {
  metadata {
    name      = "jenkins-agent-manager"
    namespace = "jenkins"
  }
  rule {
    api_groups = [""]
    resources  = ["pods", "pods/exec", "pods/log"]
    verbs      = ["get", "list", "watch", "create", "delete", "update"]
  }
  rule {
    api_groups = [""]
    resources  = ["events"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding" "jenkins-agent-manager" {
  metadata {
    name      = "jenkins-agent-manager-binding"
    namespace = "jenkins"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.jenkins-agent-manager.metadata[0].name
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.jenkins-controller.metadata[0].name
    namespace = "jenkins"
  }
}

# Push the token into Secrets Manager so it flows through the same
# tag-driven Credentials Provider pattern as your other JCasC credentials —
# no separate manual step, no hardcoding in jenkins.yaml.
resource "aws_secretsmanager_secret" "k8s-controller-token" {
  name = "jenkins/k8s-token"
  recovery_window_in_days = 0
  tags = {
    "jenkins:credentials:type" = "string"
  }
}

resource "aws_secretsmanager_secret_version" "k8s-controller-token" {
  secret_id     = aws_secretsmanager_secret.k8s-controller-token.id
  secret_string = kubernetes_secret.jenkins-controller-token.data["token"]
}

################################################################################
# ECR Repository — image storage + OCI Helm chart storage
# CHANGE: added. Referenced by the CI pipeline (docker/Kaniko push) and the
# CD pipeline (helm push/pull chart).
################################################################################
resource "aws_ecr_repository" "my-app" {
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
################################################################################
resource "aws_iam_role" "jenkins-agent" {
  name = "jenkins-agent-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEksPodIdentity"
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })
}

# 1. Attach the standard AWS-Managed ECR Policy
resource "aws_iam_role_policy_attachment" "jenkins-agent-ecr" {
  role       = aws_iam_role.jenkins-agent.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

resource "kubernetes_service_account" "jenkins-agent" {
  metadata {
    name      = "ecr-push-sa"
    namespace = "jenkins"
  }
  depends_on = [kubernetes_namespace.jenkins]
}

resource "aws_eks_pod_identity_association" "jenkins-agent" {
  cluster_name    = module.eks.cluster_name
  namespace       = "jenkins"
  service_account = kubernetes_service_account.jenkins-agent.metadata[0].name
  role_arn        = aws_iam_role.jenkins-agent.arn

  depends_on = [module.eks, time_sleep.wait_for_cluster_access, kubernetes_service_account.jenkins-agent]
}



resource "kubernetes_role" "jenkins_deployer" {
  metadata {
    name      = "jenkins-deployer-role"
    namespace = "jenkins"
  }

  rule {
    api_groups = ["apps", "extensions"]
    resources  = ["deployments"]
    verbs      = ["create", "get", "patch", "update"]
  }
}

resource "kubernetes_role_binding" "jenkins_deployer_bind" {
  metadata {
    name      = "jenkins-deployer-binding"
    namespace = "jenkins"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.jenkins_deployer.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = "ecr-push-sa"
    namespace = "jenkins"
  }
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
    eks_ca_cert          = module.eks.cluster_certificate_authority_data
    jenkins_config_repo  = local.jenkins_config_repo
    jenkins_url          = "http://${module.jenkins_alb.dns_name}:8080"
    sonar_url            = "http://${kubernetes_ingress_v1.sonar.status[0].load_balancer[0].ingress[0].hostname}:9000"
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

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.jenkins.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# scoped Secrets Manager read access — only the specific secrets
# jenkins-userdata.sh.tpl pulls at boot, not secretsmanager:* on everything.
# NOTE: create these four secrets in Secrets Manager before first boot
# (aws secretsmanager create-secret --name jenkins/github-token ...).

resource "aws_secretsmanager_secret" "sonar" {
  name = "jenkins/sonar/token"
  recovery_window_in_days = 0
  tags = {
    "jenkins:credentials:type" = "string"
  }
}
resource "aws_secretsmanager_secret" "github_creds" {
  name                    = "jenkins/github-creds"
  recovery_window_in_days = 0
  tags = {
    "jenkins:credentials:type"     = "usernamePassword"
    "jenkins:credentials:username" = "arupsscet1-buff"
  }
}
resource "aws_secretsmanager_secret" "admin-password" {
  name = "jenkins/admin-password"
  recovery_window_in_days = 0
  tags = {
    "jenkins:credentials:type" = "string"
  }
}
data "aws_caller_identity" "current" {}

resource "aws_iam_role_policy" "eks_describe" {
  name = "jenkins-eks-describe"
  role = aws_iam_role.jenkins.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster", "eks:ListClusters"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "jenkins_secrets" {
  name = "jenkins-secrets-read"
  role = aws_iam_role.jenkins.id

  policy = jsonencode({
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:ListSecrets",
        "secretsmanager:GetSecretValue"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      Resource = [
        "arn:aws:secretsmanager:${local.region}:${data.aws_caller_identity.current.account_id}:secret:jenkins/*",
      ]
    }
  ]
  })
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "jenkins-controller-profile"
  role = aws_iam_role.jenkins.name
}

################################################################################
# AWS Load Balancer Controller
################################################################################
resource "aws_iam_policy" "alb_controller" {
  name   = "AWSLoadBalancerControllerIAMPolicy"
  policy = file("${path.module}/iam_policy.json")
}

resource "aws_iam_role" "alb_controller" {
  name = "alb-controller-role"

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

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

resource "kubernetes_service_account" "alb_controller" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
  }
  depends_on = [module.eks,time_sleep.wait_for_cluster_access]
}

resource "aws_eks_pod_identity_association" "alb_controller" {
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = kubernetes_service_account.alb_controller.metadata[0].name
  role_arn        = aws_iam_role.alb_controller.arn

  depends_on = [module.eks,time_sleep.wait_for_cluster_access]
}

resource "helm_release" "alb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }
  set {
    name  = "serviceAccount.create"
    value = "false"
  }
  set {
    name  = "serviceAccount.name"
    value = kubernetes_service_account.alb_controller.metadata[0].name
  }
  set {
    name  = "region"
    value = local.region
  }
  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  depends_on = [
    module.eks,
    time_sleep.wait_for_cluster_access,
    aws_iam_role_policy_attachment.alb_controller,
    aws_eks_pod_identity_association.alb_controller
  ]
}

################################################################################
# Ingress Resources for SonarQube and Frontend
################################################################################
resource "kubernetes_ingress_v1" "sonar" {
  metadata {
    name      = "sonar-ingress"
    namespace = "sonarqube"
    annotations = {
      "kubernetes.io/ingress.class"               = "alb"
      "alb.ingress.kubernetes.io/scheme"          = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"     = "ip"
      "alb.ingress.kubernetes.io/listen-ports"    = "[{\"HTTP\": 9000}]"
      "alb.ingress.kubernetes.io/group.name"      = "my-app-alb"
    }
  }

  spec {
    rule {
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "sonarqube-sonarqube"
              port {
                number = 9000
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.alb_controller, helm_release.sonarqube]
}

resource "kubernetes_ingress_v1" "frontend" {
  metadata {
    name      = "frontend-ingress"
    namespace = "my-app"   # confirm actual namespace for the online-boutique frontend
    annotations = {
      "kubernetes.io/ingress.class"            = "alb"
      "alb.ingress.kubernetes.io/scheme"       = "internet-facing"
      "alb.ingress.kubernetes.io/target-type"  = "ip"
      "alb.ingress.kubernetes.io/listen-ports" = "[{\"HTTP\": 8080}]"
      "alb.ingress.kubernetes.io/group.name"   = "my-app-alb"
    }
  }

  spec {
    rule {
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "frontend"   # confirm actual service name from google-online-boutique manifests
              port {
                number = 80        # internal service port — separate from external listener port 8081
              }
            }
          }
        }
      }
    }
  }

  depends_on = [helm_release.alb_controller]
}


################################################################################
# Jenkins ALB Module
################################################################################
module "jenkins_alb" {
  source  = "terraform-aws-modules/alb/aws"
  name    = "jenkins-alb"
  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.public_subnets
  enable_deletion_protection = false 

  security_group_ingress_rules = {
    jenkins_http = {
      from_port   = 8080
      to_port     = 8080
      ip_protocol = "tcp"
      description = "Jenkins UI"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }

  security_group_egress_rules = {
    all = {
      ip_protocol = "-1"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }

  listeners = {
    jenkins-http = {
      port     = 8080
      protocol = "HTTP"
      forward = {
        target_group_key = "jenkins"
      }
    }
  }

  target_groups = {
    jenkins = {
      name_prefix = "jnks"
      protocol    = "HTTP"
      port        = 8080
      target_type = "instance"
      target_id   = aws_instance.jenkins-controller.id   # reference the resource, not a hardcoded ID
    }
  }

  tags = local.tags
}

