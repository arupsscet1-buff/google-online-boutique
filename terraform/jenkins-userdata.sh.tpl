#!/bin/bash
set -e

# ------------------------------------------------------------------
# Values injected by Terraform via templatefile() — do not hardcode.
# ------------------------------------------------------------------
EKS_CLUSTER_ENDPOINT="${eks_cluster_endpoint}"
EKS_CA_CERT="${eks_ca_cert}"
EKS_CLUSTER_NAME="${eks_cluster_name}"
AWS_REGION="${aws_region}"
JENKINS_CONFIG_REPO="${jenkins_config_repo}"
JENKINS_URL="${jenkins_url}"

sudo apt update -y
sudo apt install fontconfig openjdk-21-jre -y
java -version

# ------------------------------------------------------------------
# Install Jenkins
# ------------------------------------------------------------------
sudo wget -O /etc/apt/keyrings/jenkins-keyring.asc \
https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key
sudo echo "deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc]" \
https://pkg.jenkins.io/debian-stable binary/ | sudo tee \
/etc/apt/sources.list.d/jenkins.list > /dev/null
sudo apt update
sudo apt install jenkins -y

# ------------------------------------------------------------------
# kubectl + Helm (for the controller's own troubleshooting/CD use)
# ------------------------------------------------------------------
sudo curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo chmod +x kubectl
sudo mv kubectl /usr/local/bin/

sudo curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# ------------------------------------------------------------------
# Pull JCasC config + plugins list from your platform-config repo
# ------------------------------------------------------------------
sudo mkdir -p /tmp/jenkins-config
sudo git clone "$JENKINS_CONFIG_REPO" /tmp/jenkins-config
sudo mkdir -p /var/lib/jenkins/casc_configs
sudo cp /tmp/jenkins-config/jenkins/jenkins.yaml /var/lib/jenkins/casc_configs/jenkins.yaml

# ------------------------------------------------------------------
# Install plugins, then start Jenkins
# ------------------------------------------------------------------
sudo mkdir -p /opt/jenkins-tools
sudo wget https://github.com/jenkinsci/plugin-installation-manager-tool/releases/download/2.15.0/jenkins-plugin-manager-2.15.0.jar -O /opt/jenkins-tools/jenkins-plugin-manager.jar
sudo cp /tmp/jenkins-config/jenkins/plugins.txt /opt/jenkins-tools/plugins.txt
sudo java -jar /opt/jenkins-tools/jenkins-plugin-manager.jar --war /usr/share/java/jenkins.war -d /var/lib/jenkins/plugins --plugin-file /opt/jenkins-tools/plugins.txt


# ------------------------------------------------------------------
# Export non-secret deployment values into the Jenkins service
# environment (jenkins.yaml is git-cloned, not templatefile()'d,
# so these must reach the process via systemd, not the boot shell).
# ------------------------------------------------------------------
sudo mkdir -p /etc/systemd/system/jenkins.service.d
cat <<EOF | sudo tee /etc/systemd/system/jenkins.service.d/override.conf
[Service]
Environment="EKS_CLUSTER_ENDPOINT=$EKS_CLUSTER_ENDPOINT"
Environment="JENKINS_URL=$JENKINS_URL"
Environment="CASC_JENKINS_CONFIG=/var/lib/jenkins/casc_configs/jenkins.yaml"
EOF
sudo systemctl daemon-reload


# ------------------------------------------------------------------
# start Jenkins
# ------------------------------------------------------------------
sudo systemctl enable jenkins
sudo systemctl start jenkins
