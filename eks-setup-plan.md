# Technical Plan: EKS Cluster, Private MySQL, & AWS Load Balancer Controller Setup

This document provides complete, step-by-step instructions to manually set up the container orchestration layer, database, and ingress routing for the NutriTrack microservices application.

---

## Architecture Overview

```
VPC: 10.0.0.0/16
├── Public Subnets        (10.0.1.0/24, 10.0.2.0/24)   → Public ALBs (AWS Load Balancer Controller)
├── Private App Subnets   (10.0.11.0/24, 10.0.12.0/24) → EKS Control Plane & Worker Nodes
└── Private DB Subnet     (10.0.21.0/24)                → MySQL (EC2 Instance)
```

---

## Prerequisites
Before starting, ensure the following utilities are installed in your terminal environment (e.g. AWS CloudShell or your local terminal):
1. **kubectl** — Kubernetes command-line tool. [Install instructions](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/)
2. **eksctl** — CLI tool for managing EKS clusters. [Install instructions](https://eksctl.io/installation/)
3. **helm** — Package manager for Kubernetes. [Install instructions](https://helm.sh/docs/intro/install/)

---

## Phase 1: Provision Amazon EKS Cluster in Private Subnets

We will launch the EKS Control Plane and worker nodes inside the private application subnets (`10.0.11.0/24` and `10.0.12.0/24`) to ensure they are isolated from public ingress.

### Step 1.1: Create EKS IAM Roles
1. **EKS Cluster Role**:
   - Create a role named `nutritrack-prod-eks-cluster-role` trusted by `eks.amazonaws.com`.
   - Attach the standard managed policy `AmazonEKSClusterPolicy`.
2. **EKS Node Group Role**:
   - Create a role named `nutritrack-prod-eks-node-role` trusted by `ec2.amazonaws.com`.
   - Attach the following managed policies:
     - `AmazonEKSWorkerNodePolicy`
     - `AmazonEC2ContainerRegistryReadOnly`
     - `AmazonEKS_CNI_Policy`

### Step 1.2: Initialize the EKS Cluster
Deploy the cluster using `eksctl` config for precise control over networking and security groups:

1. Create a configuration file named `eks-cluster-config.yaml`:
   ```yaml
   apiVersion: eksctl.io/v1alpha5
   kind: ClusterConfig

   metadata:
     name: nutritrack-prod-eks
     region: us-east-1
     version: "1.28"

   vpc:
     id: "VPC_ID"               # Replace with nutritrack-prod-vpc ID
     securityGroup: "NODE_SG"   # Replace with nutritrack-prod-eks-node-sg ID
     subnets:
       private:
         us-east-1a:
           id: "SUB_AZ1_ID"     # Replace with nutritrack-prod-private-app-subnet-az1 ID
         us-east-1b:
           id: "SUB_AZ2_ID"     # Replace with nutritrack-prod-private-app-subnet-az2 ID

   managedNodeGroups:
     - name: nutritrack-prod-node-group
       instanceType: t3.medium
       desiredCapacity: 2
       minSize: 2
       maxSize: 4
       privateNetworking: true
       iam:
         withAddonPolicies:
           imageBuilder: true
           autoScaler: true
           ebs: true
   ```
2. Trigger EKS cluster creation:
   ```bash
   eksctl create cluster -f eks-cluster-config.yaml
   ```
   *(This process takes approximately 15 minutes to configure resources and launch node groups).*

### Step 1.3: Update kubeconfig
Verify your terminal can communicate with the cluster:
```bash
aws eks update-kubeconfig --region us-east-1 --name nutritrack-prod-eks
kubectl get nodes
```

---

## Phase 2: Deploy MySQL in Private DB Subnet (EC2)

MySQL will run inside a dedicated EC2 instance in the private database subnet (`10.0.21.0/24`) and will only accept database traffic (port `3306`) coming from the EKS nodes.

### Step 2.1: Discover IDs
Run the following queries to get the correct Subnet and Security Group IDs:
```bash
# Get Private DB Subnet
aws ec2 describe-subnets --filters "Name=tag:Name,Values=nutritrack-prod-private-db-subnet-az1" --query 'Subnets[0].SubnetId' --output text

# Get MySQL Security Group
aws ec2 describe-security-groups --filters "Name=tag:Name,Values=nutritrack-prod-mysql-sg" --query 'SecurityGroups[0].GroupId' --output text
```

### Step 2.2: Launch the Instance
Run the launch command using the resolved IDs and the `us-east` key pair:
```bash
# Resolve latest Amazon Linux 2023 AMI
AMI_ID=$(aws ssm get-parameters --names "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" --query 'Parameters[0].Value' --output text)

# Launch EC2 instance
aws ec2 run-instances \
  --image-id $AMI_ID \
  --instance-type t3.micro \
  --key-name us-east \
  --subnet-id <DB_SUBNET_ID> \
  --security-group-ids <MYSQL_SG_ID> \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=nutritrack-prod-mysql},{Key=Role,Value=database}]"
```

### Step 2.3: SSH and Database Configuration
1. SSH into the Bastion host:
   ```bash
   ssh -i us-east.pem ec2-user@<BASTION_PUBLIC_IP>
   ```
2. From the Bastion host, SSH into the private MySQL instance using its private IP:
   ```bash
   ssh -i us-east.pem ec2-user@<MYSQL_PRIVATE_IP>
   ```
3. Install MariaDB/MySQL server:
   ```bash
   sudo dnf install mariadb105-server -y
   sudo systemctl enable --now mariadb
   ```
4. Access SQL CLI and configure a database user allowed to connect from the VPC CIDR (`10.0.0.0/16`):
   ```sql
   CREATE DATABASE nutritrack;
   CREATE USER 'nutri_user'@'10.0.0.0/16' IDENTIFIED BY 'production_secure_password';
   GRANT ALL PRIVILEGES ON nutritrack.* TO 'nutri_user'@'10.0.0.0/16';
   FLUSH PRIVILEGES;
   EXIT;
   ```
5. Edit `/etc/my.cnf.d/mariadb-server.cnf` to allow MariaDB to bind to all interfaces:
   ```ini
   [mysqld]
   bind-address = 0.0.0.0
   ```
6. Restart database daemon:
   ```bash
   sudo systemctl restart mariadb
   ```

---

## Phase 3: Configure AWS Load Balancer Controller (ALB Ingress)

The AWS Load Balancer Controller is an controller component that runs inside EKS and automatically provisions Application Load Balancers (ALBs) when a Kubernetes Ingress resource is created.

### Step 3.1: Configure IAM Roles for Service Accounts (IRSA)
1. Associate IAM OIDC Provider with the cluster:
   ```bash
   eksctl utils associate-iam-oidc-provider --cluster nutritrack-prod-eks --approve
   ```
2. Download and create the official IAM Policy:
   ```bash
   curl -s -O https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
   
   aws iam create-policy \
     --policy-name AWSLoadBalancerControllerIAMPolicy \
     --policy-document file://iam_policy.json
   ```
3. Create the Service Account and bind it to a new IAM Role:
   ```bash
   eksctl create iamserviceaccount \
     --cluster=nutritrack-prod-eks \
     --namespace=kube-system \
     --name=aws-load-balancer-controller \
     --role-name AmazonEKSLoadBalancerControllerRole \
     --attach-policy-arn=arn:aws:iam::<ACCOUNT_ID>:policy/AWSLoadBalancerControllerIAMPolicy \
     --approve
   ```

### Step 3.2: Deploy cert-manager
`cert-manager` handles injecting webhook certificates required by the controller webhook configuration:
```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.2/cert-manager.yaml
```
Verify that cert-manager pods are ready before proceeding:
```bash
kubectl wait --namespace cert-manager --for=condition=ready pod --selector=app.kubernetes.io/instance=cert-manager --timeout=90s
```

### Step 3.3: Install AWS Load Balancer Controller via Helm
1. Add the EKS Helm charts repo:
   ```bash
   helm repo add eks https://aws.github.io/eks-charts
   helm repo update
   ```
2. Deploy the controller (disable automatic Service Account creation since we created it via `eksctl`):
   ```bash
   helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
     -n kube-system \
     --set clusterName=nutritrack-prod-eks \
     --set serviceAccount.create=false \
     --set serviceAccount.name=aws-load-balancer-controller
   ```
3. Verify controller deployment:
   ```bash
   kubectl rollout status deployment/aws-load-balancer-controller -n kube-system
   ```

---

## Phase 4: Verification (Sample Application Ingress)

Deploy a sample 2048 game deployment to verify that the ingress controller detects the resources and builds a public-facing Application Load Balancer.

1. Deploy sample application:
   ```bash
   kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/examples/2048/2048_full.yaml
   ```
2. Monitor deployment resources:
   ```bash
   kubectl get ingress/ingress-2048 -n game-2048
   ```
3. Copy the Address (e.g. `k8s-game2048-ingress2-xxxxxx.us-east-1.elb.amazonaws.com`) and paste it into your browser to verify routing.
