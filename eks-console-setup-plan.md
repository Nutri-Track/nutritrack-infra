# AWS Console UI Guide: Complete Amazon EKS Setup for NutriTrack

This guide is an exhaustive, field-by-field walkthrough of every screen and setting
you will encounter when creating the NutriTrack EKS cluster through the AWS Console.

---

## Prerequisites (Install in AWS CloudShell or your local terminal)

Before beginning, ensure you have the following CLIs available:

- **AWS CLI v2** — Pre-installed in CloudShell. Locally: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
- **kubectl** — Pre-installed in CloudShell. Locally: https://kubernetes.io/docs/tasks/tools/
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

Two IAM roles are required before creating the cluster. These cannot be created from the
EKS wizard itself — they must exist beforehand.

---

### Step 1.1: Create EKS Cluster Role

This role allows the EKS control plane to manage AWS resources on your behalf.

1. Open **AWS Console → IAM → Roles → Create role**.
2. **Trusted entity type** → Select **AWS service**.
3. **Use case** → In the dropdown, search for and select **EKS**.
4. Under the use case list that appears below → Select **EKS - Cluster**. Click **Next**.
5. On the **Add permissions** page → The policy **`AmazonEKSClusterPolicy`** is
   automatically added. Do NOT remove it. Click **Next**.
6. **Role name** → Enter: `nutritrack-prod-eks-cluster-role`
7. **Description** → (Optional) Enter: `EKS Cluster role for NutriTrack production`
8. **Tags** → Click **Add tag** and add:
   - Key: `Project` → Value: `nutritrack`
   - Key: `Environment` → Value: `prod`
9. Click **Create role**.

---

### Step 1.2: Create EKS Node Group Role

This role allows EC2 worker nodes to call AWS APIs (e.g., pull images from ECR, attach ENIs).

1. Open **AWS Console → IAM → Roles → Create role**.
2. **Trusted entity type** → Select **AWS service**.
3. **Use case** → Select **EC2**. Click **Next**.
4. On the **Add permissions** page → Search for and **check** the following three policies one by one:
   - `AmazonEKSWorkerNodePolicy`
   - `AmazonEC2ContainerRegistryReadOnly`
   - `AmazonEKS_CNI_Policy`
5. Verify all three are checked in the **Permissions policies** list. Click **Next**.
6. **Role name** → Enter: `nutritrack-prod-eks-node-role`
7. **Description** → (Optional) Enter: `EKS Node Group role for NutriTrack production`
8. **Tags** → Add the same tags as above.
9. Click **Create role**.

---

## Phase 2: Create the EKS Cluster — 6-Step Wizard

Navigate to **AWS Console → Elastic Kubernetes Service (EKS) → Clusters → Create cluster**.

---

### Wizard Step 1: Configure Cluster

This page configures the fundamental identity and version of your cluster.

| Field | Value |
|---|---|
| **Name** | `nutritrack-prod-eks` |
| **Kubernetes version** | `1.32` (select the latest available stable version) |
| **Cluster IAM role** | Select `nutritrack-prod-eks-cluster-role` |

#### Bootstrap cluster administrator access section

| Field | Value |
|---|---|
| **Bootstrap cluster administrator access** | Enable toggle → ON |
| **Cluster authentication mode** | Select **EKS API and ConfigMap** (recommended for flexibility) |
| **Grant cluster administrator access to the IAM principal** | Leave checked (this grants your current IAM user admin access at creation) |

#### Secrets encryption section

| Field | Value |
|---|---|
| **Secrets encryption** | Leave **disabled** unless you have a KMS key setup (optional for academic projects) |

#### Tags section

Click **Add tag** and add:
- Key: `Project` → Value: `nutritrack`
- Key: `Environment` → Value: `prod`
- Key: `ManagedBy` → Value: `aws-console`

Click **Next**.

---

### Wizard Step 2: Specify Networking

This is the most critical page — all subnet and security group configuration happens here.

#### VPC

| Field | Value |
|---|---|
| **VPC** | Select `nutritrack-prod-vpc` (CIDR: 10.0.0.0/16) |

> After selecting the VPC, the subnets and security groups will auto-populate. You must
> manually correct the selections below.

#### Subnets

Remove any auto-selected subnets and select **only** the following:

| Subnet Name | CIDR | AZ |
|---|---|---|
| `nutritrack-prod-private-app-subnet-az1` | 10.0.11.0/24 | us-east-1a |
| `nutritrack-prod-private-app-subnet-az2` | 10.0.12.0/24 | us-east-1b |

> **Important**: Do NOT include the public subnets or the private DB subnet here.
> EKS control plane ENIs must live in the private app subnets only.

#### Security groups

| Field | Value |
|---|---|
| **Security groups** | Select `nutritrack-prod-eks-node-sg` |

> Remove any other auto-selected security groups. Only `nutritrack-prod-eks-node-sg` should be selected.

#### Cluster endpoint access

| Field | Value |
|---|---|
| **Cluster endpoint access** | Select **Public and private** |

> This allows `kubectl` access from CloudShell/your laptop via the public endpoint,
> while node-to-control-plane traffic uses the private endpoint within the VPC.

#### Private access CIDR (only visible when "Public and private" is selected)

| Field | Value |
|---|---|
| **Public access CIDR** | Leave as `0.0.0.0/0` (you can restrict to your IP for production hardening) |

#### Custom networking (Advanced)

Leave all fields under this section at defaults. Do NOT change:
- CIDR ranges
- Service IPv4 range

#### IP family

| Field | Value |
|---|---|
| **IP family** | `IPv4` |

Click **Next**.

---

### Wizard Step 3: Configure Observability

This page controls Amazon CloudWatch logging and monitoring for the control plane.

#### Control plane logging

| Log Type | Setting |
|---|---|
| **API server** | Disable (Enable if you want detailed API audit logs) |
| **Audit** | Disable (Enable in full production environments) |
| **Authenticator** | Disable |
| **Controller manager** | Disable |
| **Scheduler** | Disable |

> For an academic/project presentation you can leave all disabled to avoid CloudWatch costs.
> For full production, enable **API server** and **Audit** at minimum.

#### Amazon CloudWatch observability

| Field | Value |
|---|---|
| **Enable Amazon CloudWatch observability** | Leave unchecked (optional, incurs cost) |

Click **Next**.

---

### Wizard Step 4: Select Add-ons

Add-ons are managed plugins that extend Kubernetes functionality. The following defaults
are pre-selected and must stay:

| Add-on | Action |
|---|---|
| **Amazon VPC CNI** | ✅ Keep selected (required for pod networking) |
| **CoreDNS** | ✅ Keep selected (required for in-cluster DNS) |
| **kube-proxy** | ✅ Keep selected (required for network rules) |
| **Amazon EKS Pod Identity Agent** | ✅ Keep selected (required for IRSA in newer clusters) |

> Do NOT deselect any of the above four add-ons.

Click **Next**.

---

### Wizard Step 5: Configure Selected Add-ons Settings

On this page you configure the version of each selected add-on.

For each of the four add-ons listed:

| Add-on | Version | Configuration |
|---|---|---|
| **Amazon VPC CNI** | Leave at `latest` default | No changes |
| **CoreDNS** | Leave at `latest` default | No changes |
| **kube-proxy** | Leave at `latest` default | No changes |
| **Amazon EKS Pod Identity Agent** | Leave at `latest` default | No changes |

> For each add-on, the **"Optional configuration schema"** section can be left blank.
> The **"Conflict resolution method"** should be set to **Overwrite** (or leave default).

Click **Next**.

---

### Wizard Step 6: Review and Create

Carefully review all the settings on this page before creating:

| Section | Expected Value |
|---|---|
| **Cluster name** | `nutritrack-prod-eks` |
| **Kubernetes version** | `1.32` (or latest you selected) |
| **Cluster service role** | `nutritrack-prod-eks-cluster-role` |
| **VPC** | `nutritrack-prod-vpc` |
| **Subnets** | Only the 2 private app subnets |
| **Security groups** | `nutritrack-prod-eks-node-sg` |
| **Endpoint access** | Public and private |
| **API server logging** | Disabled |
| **Add-ons** | VPC CNI, CoreDNS, kube-proxy, Pod Identity Agent |

Once everything is confirmed, click **Create cluster**.

> The cluster status will show **Creating**. This takes approximately **10–15 minutes**.
> You can watch the status in the EKS Console. Wait for status to change to **Active** before proceeding.

---

## Phase 3: Add Managed Node Group (Worker Nodes)

Once the cluster shows **Active** status:

1. Click on the cluster name `nutritrack-prod-eks`.
2. Click the **Compute** tab.
3. Scroll down to **Node groups** → click **Add node group**.

---

### Node Group Step 1: Configure Node Group

| Field | Value |
|---|---|
| **Name** | `nutritrack-prod-node-group` |
| **Node IAM role** | Select `nutritrack-prod-eks-node-role` |

#### Launch template (Advanced)

| Field | Value |
|---|---|
| **Launch template** | None — Do NOT use a custom launch template |

#### Kubernetes labels (optional)

Add:
- Key: `role` → Value: `worker`

#### Kubernetes taints (optional)

Leave empty.

#### Tags

Add:
- Key: `Project` → Value: `nutritrack`
- Key: `Environment` → Value: `prod`

Click **Next**.

---

### Node Group Step 2: Set Compute and Scaling Configuration

| Field | Value |
|---|---|
| **AMI type** | `Amazon Linux 2023 (AL2023_x86_64_STANDARD)` |
| **Capacity type** | `On-Demand` |
| **Instance types** | Remove default, type and select `t3.medium` |
| **Disk size** | `20 GiB` |

#### Scaling configuration

| Field | Value |
|---|---|
| **Minimum size** | `2` |
| **Maximum size** | `4` |
| **Desired size** | `2` |

#### Update configuration

| Field | Value |
|---|---|
| **Maximum unavailable** | `1` (number of nodes that can be unavailable during updates) |

Click **Next**.

---

### Node Group Step 3: Specify Networking

| Field | Value |
|---|---|
| **Subnets** | Select ONLY: `nutritrack-prod-private-app-subnet-az1` and `nutritrack-prod-private-app-subnet-az2` |

#### SSH access to nodes

| Field | Value |
|---|---|
| **Allow SSH remote access to nodes** | Toggle **ON** |
| **EC2 Key Pair** | Select `us-east` |
| **Allow SSH access from** | Select **Specific security groups** → choose `nutritrack-prod-bastion-sg` |

> This ensures only the Bastion host can SSH into the worker nodes (not open to internet).

Click **Next**.

---

### Node Group Step 4: Review and Create

Review all node group settings:

| Section | Expected Value |
|---|---|
| **Node group name** | `nutritrack-prod-node-group` |
| **Node IAM role** | `nutritrack-prod-eks-node-role` |
| **AMI type** | `AL2023_x86_64_STANDARD` |
| **Instance type** | `t3.medium` |
| **Disk** | `20 GiB` |
| **Desired / Min / Max** | `2 / 2 / 4` |
| **Subnets** | Both private app subnets only |
| **SSH key pair** | `us-east` |
| **SSH source** | `nutritrack-prod-bastion-sg` |

Click **Create**. Nodes will take approximately 5–7 minutes to join the cluster.

---

## Phase 4: Connect kubectl to Your Cluster

Run this in AWS CloudShell or your local terminal after nodes are Active:

```bash
aws eks update-kubeconfig --region us-east-1 --name nutritrack-prod-eks
```

Test connectivity:
```bash
kubectl get nodes
```

Expected output — you should see 2 nodes in `Ready` status:
```
NAME                           STATUS   ROLES    AGE   VERSION
ip-10-0-11-xxx.ec2.internal    Ready    <none>   2m    v1.32.x
ip-10-0-12-xxx.ec2.internal    Ready    <none>   2m    v1.32.x
```

---

## Phase 5: Enable OIDC & Deploy AWS Load Balancer Controller

### Step 5.1: Associate OIDC Provider via IAM Console

1. Go to **EKS Console → Clusters → nutritrack-prod-eks → Overview tab**.
2. Scroll down and copy the **OpenID Connect provider URL**.
   It looks like: `https://oidc.eks.us-east-1.amazonaws.com/id/XXXXXXXXXXXXXXXX`
3. Navigate to **IAM Console → Identity providers → Add provider**.
4. Fill in:
   - **Provider type**: `OpenID Connect`
   - **Provider URL**: Paste the URL you copied from step 2.
   - Click **Get thumbprint** (AWS fetches and validates the SSL thumbprint automatically).
   - **Audience**: Type `sts.amazonaws.com`
5. Click **Add provider**.

---

### Step 5.2: Create ALB Controller IAM Policy & Service Account

Run the following commands in **AWS CloudShell**:

```bash
# 1. Download the official IAM policy document
curl -s -o iam_policy.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

# 2. Create the IAM policy in your AWS account
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json

# Note the Policy ARN output — you will need it in the next command.
# Example: arn:aws:iam::123456789012:policy/AWSLoadBalancerControllerIAMPolicy

# 3. Create IAM Service Account and bind it to the policy
#    Replace <YOUR_ACCOUNT_ID> with your actual 12-digit AWS Account ID
eksctl create iamserviceaccount \
  --cluster=nutritrack-prod-eks \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --role-name AmazonEKSLoadBalancerControllerRole \
  --attach-policy-arn=arn:aws:iam::<YOUR_ACCOUNT_ID>:policy/AWSLoadBalancerControllerIAMPolicy \
  --region us-east-1 \
  --approve
```

---

### Step 5.3: Install cert-manager

Required as a dependency for the ALB controller webhook:

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.13.2/cert-manager.yaml

# Wait for cert-manager pods to be ready before proceeding
kubectl wait --namespace cert-manager \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/instance=cert-manager \
  --timeout=90s
```

---

### Step 5.4: Install AWS Load Balancer Controller via Helm

```bash
# 1. Add the EKS Helm charts repository
helm repo add eks https://aws.github.io/eks-charts
helm repo update

# 2. Install the controller
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=nutritrack-prod-eks \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set region=us-east-1 \
  --set vpcId=$(aws ec2 describe-vpcs \
      --filters "Name=tag:Name,Values=nutritrack-prod-vpc" \
      --query 'Vpcs[0].VpcId' \
      --output text \
      --region us-east-1)
```

---

### Step 5.5: Verify Installation

```bash
# Check controller pods are running
kubectl get deployment -n kube-system aws-load-balancer-controller

# Expected output:
# NAME                           READY   UP-TO-DATE   AVAILABLE   AGE
# aws-load-balancer-controller   2/2     2            2           1m

# Check controller logs (optional)
kubectl logs -n kube-system \
  -l app.kubernetes.io/name=aws-load-balancer-controller \
  --tail=20
```

---

## Quick Reference: NutriTrack EKS Summary

| Resource | Value |
|---|---|
| **Cluster name** | `nutritrack-prod-eks` |
| **Region** | `us-east-1` |
| **Kubernetes version** | `1.32` (latest) |
| **Cluster Role** | `nutritrack-prod-eks-cluster-role` |
| **Node Role** | `nutritrack-prod-eks-node-role` |
| **Node group** | `nutritrack-prod-node-group` |
| **Instance type** | `t3.medium` |
| **Node count** | 2 desired, 2 min, 4 max |
| **Worker node subnets** | `private-app-az1`, `private-app-az2` |
| **SSH key** | `us-east` |
| **SSH source** | `nutritrack-prod-bastion-sg` |
| **Endpoint access** | Public and private |
