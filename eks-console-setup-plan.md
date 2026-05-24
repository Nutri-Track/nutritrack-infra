# AWS Console UI Guide: Complete Amazon EKS Setup

This guide provides step-by-step instructions to provision your production-grade EKS cluster, node groups, and prerequisites using the **AWS Management Console** web interface.

---

## Prerequisites (Install in AWS CloudShell or your local terminal)

Before beginning, ensure you have the following CLIs available:
- **AWS CLI v2** — Pre-installed in CloudShell. Locally: [Install guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
- **kubectl** — Pre-installed in CloudShell. Locally: [Install guide](https://kubernetes.io/docs/tasks/tools/)
- **eksctl** — Required for OIDC & IRSA setup (Phase 5). Install in CloudShell:
  ```bash
  curl -sLO "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz"
  tar -xzf eksctl_Linux_amd64.tar.gz -C /tmp
  sudo mv /tmp/eksctl /usr/local/bin
  eksctl version
  ```
- **helm** — Required for controller installation (Phase 5). Install in CloudShell:
  ```bash
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  helm version
  ```

---

## Phase 1: Create IAM Roles in the IAM Console

Before creating the cluster, you must provision two IAM roles: one for the EKS control plane (cluster) and one for the EC2 worker nodes.

### Step 1.1: Create EKS Cluster Role
1. Open the **AWS Management Console** and navigate to the **IAM Console**.
2. In the left navigation pane, click **Roles**, then click **Create role**.
3. Under **Trusted entity type**, select **AWS service**.
4. In the **Service or use case** dropdown, select **EKS**, then choose **EKS - Cluster** under the use cases. Click **Next**.
5. The policy **`AmazonEKSClusterPolicy`** will be automatically selected. Click **Next**.
6. Set the **Role name** to: `nutritrack-prod-eks-cluster-role`.
7. (Optional) Under **Tags**, add `Project = nutritrack` and `Environment = prod`.
8. Click **Create role**.

### Step 1.2: Create EKS Node Group Role
1. In the **IAM Console**, click **Roles**, then click **Create role**.
2. Under **Trusted entity type**, select **AWS service**.
3. In the **Service or use case** dropdown, select **EC2**. Click **Next**.
4. Search for and check the boxes next to the following **three policies**:
   - `AmazonEKSWorkerNodePolicy`
   - `AmazonEC2ContainerRegistryReadOnly`
   - `AmazonEKS_CNI_Policy`
5. Click **Next**.
6. Set the **Role name** to: `nutritrack-prod-eks-node-role`.
7. Click **Create role**.

---

## Phase 2: Create the EKS Cluster in the EKS Console

### Step 2.1: Cluster Settings
1. Navigate to the **Elastic Kubernetes Service (EKS)** console in `us-east-1` (N. Virginia).
2. On the right, click **Add cluster** -> **Create**.
3. Configure the following:
   - **Name**: `nutritrack-prod-eks`
   - **Kubernetes version**: Select the latest stable version (e.g., `1.28` or `1.29`).
   - **Cluster service role**: Select the `nutritrack-prod-eks-cluster-role` created in Phase 1.
4. Click **Next**.

### Step 2.2: Networking & Security Groups
1. **VPC**: Select `nutritrack-prod-vpc`.
2. **Subnets**: Select **only** the private app subnets:
   - `nutritrack-prod-private-app-subnet-az1`
   - `nutritrack-prod-private-app-subnet-az2`
   *(Remove the public subnets and private DB subnet if they are auto-selected)*.
3. **Security groups**: Select the security group named `nutritrack-prod-eks-node-sg`.
4. **Cluster endpoint access**: Select **Public and private**. This allows you to manage the cluster publicly (e.g., from CloudShell or your laptop) while worker node traffic remains isolated.
5. Click **Next**.

### Step 2.3: Configure Logging & Add-ons
1. **Control plane logging**: Keep disabled (or select if you wish to monitor API Server logs via CloudWatch). Click **Next**.
2. **Select add-ons**: Leave default add-ons selected (`kube-proxy`, `CoreDNS`, `Amazon VPC CNI`). Click **Next**.
3. **Configure selected add-ons settings**: Leave at default version settings. Click **Next**.
4. **Review and create**: Verify all configurations and click **Create**.
   *(The cluster status will show as `Creating`. It takes about 10-12 minutes to change to `Active`)*.

---

## Phase 3: Add Managed Node Group (Worker Nodes)

Once your cluster status is **Active**, you can add worker nodes.

1. In the EKS Console, click on your cluster name: `nutritrack-prod-eks`.
2. Select the **Compute** tab.
3. Scroll down to the **Node groups** section and click **Add node group**.
4. Configure the following settings:
   - **Name**: `nutritrack-prod-node-group`
   - **Node IAM role**: Select `nutritrack-prod-eks-node-role` created in Phase 1.
   - Click **Next**.
5. **Set compute and scaling configuration**:
   - **AMI type**: Amazon Linux 2023 (or AL2)
   - **Capacity type**: On-Demand
   - **Instance types**: `t3.medium` (or `t2.medium`)
   - **Disk size**: `20 GiB`
   - **Minimum size**: `2`
   - **Maximum size**: `4`
   - **Desired size**: `2`
   - Click **Next**.
6. **Specify networking**:
   - **Subnets**: Confirm **only** the private app subnets are selected (`nutritrack-prod-private-app-subnet-az1` and `nutritrack-prod-private-app-subnet-az2`).
   - **Configure SSH Access**: You have two options:
     - **Option A (Recommended)**: Enable SSH access and select the `us-east` key pair. This lets you SSH into nodes via the Bastion host if needed for debugging.
     - **Option B**: Disable remote access if you prefer to rely solely on `kubectl` and AWS Systems Manager (SSM) for node access.
   - Click **Next**.
7. **Review and create**: Verify configurations and click **Create**.
   *(It takes about 5 minutes for the nodes to spin up and join the cluster).*

---

## Phase 4: Configure Local Access (kubeconfig)

To manage your cluster using `kubectl` (either in your local terminal or in AWS CloudShell), run this command:

```bash
aws eks update-kubeconfig --region us-east-1 --name nutritrack-prod-eks
```
Test connection:
```bash
kubectl get nodes
```
You should see 2 worker nodes listed in `Ready` status.

---

## Phase 5: Enable OpenID Connect (OIDC) & AWS Load Balancer Controller

To provision ALBs dynamically from ingress manifests, the cluster must be associated with an OIDC provider.

### Step 5.1: Associate OIDC Provider
1. Go to the EKS Console and select your cluster.
2. Under the **Overview** tab, copy the **OpenID Connect provider URL** (e.g., `https://oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B716D3041E`).
3. Navigate to the **IAM Console**.
4. In the left navigation, click **Identity providers** -> **Add provider**.
5. Select **OpenID Connect**.
6. Configure:
   - **Provider URL**: Paste the URL you copied.
   - **Audience**: Type `sts.amazonaws.com`.
7. Click **Get thumbprint**, then click **Add provider**.

### Step 5.2: Create IAM Policy & Role for the Controller
Because the controller needs to talk to the AWS API (to build ALBs), you need to create an IAM policy.

1. Run the following in your terminal to create the IAM policy:
   ```bash
   curl -s -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
   
   aws iam create-policy \
     --policy-name AWSLoadBalancerControllerIAMPolicy \
     --policy-document file://iam_policy.json
   ```
2. Create the Service Account and bind it to a new IAM Role (replaces manual Trust Policy JSON creation):
   ```bash
   eksctl create iamserviceaccount \
     --cluster=nutritrack-prod-eks \
     --namespace=kube-system \
     --name=aws-load-balancer-controller \
     --role-name AmazonEKSLoadBalancerControllerRole \
     --attach-policy-arn=arn:aws:iam::<YOUR_ACCOUNT_ID>:policy/AWSLoadBalancerControllerIAMPolicy \
     --region us-east-1 \
     --approve
   ```

### Step 5.3: Install via Helm
Run these commands in your terminal to complete the controller installation:
```bash
# 1. Install cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.2/cert-manager.yaml

# 2. Add EKS Helm chart repo
helm repo add eks https://aws.github.io/eks-charts
helm repo update

# 3. Install the controller
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=nutritrack-prod-eks \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller
```
