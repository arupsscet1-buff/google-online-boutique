output "jenkins_public_ip" {
  value = aws_instance.jenkins-controller.public_ip
}

output "jenkins_ec2_url" {
  value = "http://${aws_instance.jenkins-controller.public_ip}:8080"
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_ca_cert" {
  value = module.eks.cluster_certificate_authority_data
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}

################################################################################
# Jenkins ALB (Terraform-managed)
################################################################################
output "jenkins_alb_dns_name" {
  description = "DNS name of the Jenkins ALB"
  value       = module.jenkins_alb.dns_name
}

output "jenkins_url" {
  description = "Full URL to access Jenkins"
  value       = "http://${module.jenkins_alb.dns_name}:8080"
}

################################################################################
# AWS Load Balancer Controller-provisioned ALB (Sonar + Frontend)
# Both Ingress resources share the same group.name ("my-app-alb"), so the
# controller provisions ONE ALB for both — their hostnames should match
# once the controller finishes reconciling.
################################################################################
output "sonar_url" {
  description = "Full URL to access SonarQube"
  value       = try(
    "http://${kubernetes_ingress_v1.sonar.status[0].load_balancer[0].ingress[0].hostname}:9000",
    "Not yet provisioned — check again after a minute or two"
  )
}

output "frontend_url" {
  description = "Full URL to access the app frontend"
  value       = try(
    "http://${kubernetes_ingress_v1.frontend.status[0].load_balancer[0].ingress[0].hostname}:80",
    "Not yet provisioned — check again after a minute or two"
  )
}