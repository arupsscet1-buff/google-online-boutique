output "jenkins_public_ip" {
  value = aws_instance.jenkins-controller.public_ip
}

output "jenkins_url" {
  value = "http://${aws_instance.jenkins-controller.public_ip}:8080"
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}