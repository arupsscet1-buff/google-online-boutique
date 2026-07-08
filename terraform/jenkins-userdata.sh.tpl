#!/bin/bash
set -e

# ------------------------------------------------------------------
# Values injected by Terraform via templatefile() — do not hardcode.
# ------------------------------------------------------------------
EKS_CLUSTER_ENDPOINT="${eks_cluster_endpoint}"
EKS_CLUSTER_NAME="${eks_cluster_name}"
AWS_REGION="${aws_region}"
JENKINS_CONFIG_REPO="${jenkins_config_repo}"
JENKINS_URL=${jenkins_url}

sudo apt update -y
sudo apt install fontconfig openjdk-21-jre
java -version

# ------------------------------------------------------------------
# Install Jenkins
# ------------------------------------------------------------------
sudo wget -O /etc/apt/keyrings/jenkins-keyring.asc \
https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key
echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc]" \
https://pkg.jenkins.io/debian-stable binary/ | sudo tee \
/etc/apt/sources.list.d/jenkins.list > /dev/null
sudo apt update
sudo apt install jenkins

# ------------------------------------------------------------------
# kubectl + Helm (for the controller's own troubleshooting/CD use)
# ------------------------------------------------------------------
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
mv kubectl /usr/local/bin/

curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# ------------------------------------------------------------------
# Pull JCasC config + plugins list from your platform-config repo
# ------------------------------------------------------------------
git clone "$JENKINS_CONFIG_REPO" /tmp/jenkins-config
mkdir -p /var/lib/jenkins/casc_configs
cp /tmp/jenkins-config/jenkins.yaml /var/lib/jenkins/casc_configs/jenkins.yaml
cp /tmp/jenkins-config/plugins.txt /var/lib/jenkins/plugins.txt

# ------------------------------------------------------------------
# Install plugins, then start Jenkins
# ------------------------------------------------------------------
jenkins-plugin-cli --plugin-file /var/lib/jenkins/plugins.txt

sudo systemctl enable jenkins
sudo systemctl start jenkins
