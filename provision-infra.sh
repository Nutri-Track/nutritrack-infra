#!/usr/bin/env bash
###############################################################################
#  NutriTrack — Production AWS Infrastructure Provisioning Script
#  ---------------------------------------------------------------
#  Provisions foundational VPC / Networking / Security-Group / Bastion
#  infrastructure required for a future EKS-based microservices platform.
#
#  Usage:
#    chmod +x provision-infra.sh
#    ./provision-infra.sh
#
#  Prerequisites:
#    - AWS CLI v2 installed & configured (aws configure)
#    - IAM user/role with Administrator or equivalent permissions
#    - jq installed (sudo yum install jq / brew install jq)
#    - bash ≥ 4
###############################################################################
set -euo pipefail

###############################################################################
# 1. VARIABLES — edit these before first run
###############################################################################
PROJECT="nutritrack"
ENV="prod"
PREFIX="${PROJECT}-${ENV}"

AWS_REGION="us-east-1"
AZ1="${AWS_REGION}a"
AZ2="${AWS_REGION}b"

VPC_CIDR="10.0.0.0/16"

# Subnet CIDRs
PUBLIC_SUBNET_AZ1_CIDR="10.0.1.0/24"
PUBLIC_SUBNET_AZ2_CIDR="10.0.2.0/24"
PRIVATE_APP_SUBNET_AZ1_CIDR="10.0.11.0/24"
PRIVATE_APP_SUBNET_AZ2_CIDR="10.0.12.0/24"
PRIVATE_DB_SUBNET_AZ1_CIDR="10.0.21.0/24"

# Bastion config — CHANGE THIS to your public IP (use https://checkip.amazonaws.com)
MY_IP="157.51.241.139/32"   # <-- Replace with your IP in CIDR notation

# Bastion instance type & AMI (Amazon Linux 2023 in us-east-1)
BASTION_INSTANCE_TYPE="t2.micro"
# We will resolve the latest AL2023 AMI dynamically below.

# Bastion SSH Key Pair Name
BASTION_KEY_NAME="us-east"

# EKS cluster name (for tagging only — cluster is NOT created here)
EKS_CLUSTER_NAME="${PREFIX}-eks"

# Common tags applied to every resource
OWNER="nutritrack-team"

###############################################################################
# Helper: tag shorthand
###############################################################################
tag() {
  # Usage: tag <resource-id> <Name-tag-value> [extra Key=Value pairs...]
  local rid="$1"; shift
  local name="$1"; shift
  local tags="Key=Name,Value=${name} Key=Project,Value=${PROJECT} Key=Environment,Value=${ENV} Key=Owner,Value=${OWNER} Key=ManagedBy,Value=aws-cli"
  for extra in "$@"; do tags+=" ${extra}"; done
  aws ec2 create-tags --region "${AWS_REGION}" --resources "${rid}" --tags ${tags}
}

info()  { echo -e "\n\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }

###############################################################################
# 2. VPC
###############################################################################
info "Creating VPC: ${PREFIX}-vpc (${VPC_CIDR})"

VPC_ID=$(aws ec2 create-vpc \
  --region "${AWS_REGION}" \
  --cidr-block "${VPC_CIDR}" \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=${PREFIX}-vpc},{Key=Project,Value=${PROJECT}},{Key=Environment,Value=${ENV}}]" \
  --query 'Vpc.VpcId' --output text)

# Enable DNS support & hostnames (required for EKS)
aws ec2 modify-vpc-attribute --region "${AWS_REGION}" --vpc-id "${VPC_ID}" --enable-dns-support    '{"Value":true}'
aws ec2 modify-vpc-attribute --region "${AWS_REGION}" --vpc-id "${VPC_ID}" --enable-dns-hostnames  '{"Value":true}'

ok "VPC created: ${VPC_ID}"

###############################################################################
# 3. SUBNETS
###############################################################################
create_subnet() {
  local name="$1" cidr="$2" az="$3"
  local sid
  sid=$(aws ec2 create-subnet \
    --region "${AWS_REGION}" \
    --vpc-id "${VPC_ID}" \
    --cidr-block "${cidr}" \
    --availability-zone "${az}" \
    --tag-specifications "ResourceType=subnet,Tags=[{Key=Name,Value=${name}},{Key=Project,Value=${PROJECT}},{Key=Environment,Value=${ENV}}]" \
    --query 'Subnet.SubnetId' --output text)
  ok "Subnet ${name} => ${sid} (${cidr} / ${az})"
  echo "${sid}"
}

info "Creating subnets …"

PUBLIC_SUBNET_AZ1=$(create_subnet "${PREFIX}-public-subnet-az1"      "${PUBLIC_SUBNET_AZ1_CIDR}"       "${AZ1}")
PUBLIC_SUBNET_AZ2=$(create_subnet "${PREFIX}-public-subnet-az2"      "${PUBLIC_SUBNET_AZ2_CIDR}"       "${AZ2}")
PRIVATE_APP_SUBNET_AZ1=$(create_subnet "${PREFIX}-private-app-subnet-az1" "${PRIVATE_APP_SUBNET_AZ1_CIDR}" "${AZ1}")
PRIVATE_APP_SUBNET_AZ2=$(create_subnet "${PREFIX}-private-app-subnet-az2" "${PRIVATE_APP_SUBNET_AZ2_CIDR}" "${AZ2}")
PRIVATE_DB_SUBNET_AZ1=$(create_subnet "${PREFIX}-private-db-subnet-az1"   "${PRIVATE_DB_SUBNET_AZ1_CIDR}"  "${AZ1}")

# Enable auto-assign public IP on public subnets
aws ec2 modify-subnet-attribute --region "${AWS_REGION}" --subnet-id "${PUBLIC_SUBNET_AZ1}" --map-public-ip-on-launch
aws ec2 modify-subnet-attribute --region "${AWS_REGION}" --subnet-id "${PUBLIC_SUBNET_AZ2}" --map-public-ip-on-launch

###############################################################################
# 4. EKS / KARPENTER DISCOVERY TAGS ON SUBNETS
###############################################################################
info "Applying EKS & Karpenter discovery tags to subnets …"

# Public subnets → external ELB
tag "${PUBLIC_SUBNET_AZ1}" "${PREFIX}-public-subnet-az1" \
  "Key=kubernetes.io/role/elb,Value=1" \
  "Key=karpenter.sh/discovery,Value=${EKS_CLUSTER_NAME}"
tag "${PUBLIC_SUBNET_AZ2}" "${PREFIX}-public-subnet-az2" \
  "Key=kubernetes.io/role/elb,Value=1" \
  "Key=karpenter.sh/discovery,Value=${EKS_CLUSTER_NAME}"

# Private app subnets → internal ELB
tag "${PRIVATE_APP_SUBNET_AZ1}" "${PREFIX}-private-app-subnet-az1" \
  "Key=kubernetes.io/role/internal-elb,Value=1" \
  "Key=karpenter.sh/discovery,Value=${EKS_CLUSTER_NAME}"
tag "${PRIVATE_APP_SUBNET_AZ2}" "${PREFIX}-private-app-subnet-az2" \
  "Key=kubernetes.io/role/internal-elb,Value=1" \
  "Key=karpenter.sh/discovery,Value=${EKS_CLUSTER_NAME}"

ok "Subnet tags applied"

###############################################################################
# 5. INTERNET GATEWAY
###############################################################################
info "Creating Internet Gateway: ${PREFIX}-igw"

IGW_ID=$(aws ec2 create-internet-gateway \
  --region "${AWS_REGION}" \
  --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=Name,Value=${PREFIX}-igw},{Key=Project,Value=${PROJECT}},{Key=Environment,Value=${ENV}}]" \
  --query 'InternetGateway.InternetGatewayId' --output text)

aws ec2 attach-internet-gateway --region "${AWS_REGION}" --internet-gateway-id "${IGW_ID}" --vpc-id "${VPC_ID}"

ok "IGW created & attached: ${IGW_ID}"

###############################################################################
# 6. ELASTIC IPs FOR NAT GATEWAYS
###############################################################################
info "Allocating Elastic IPs for NAT Gateways …"

EIP_AZ1=$(aws ec2 allocate-address --region "${AWS_REGION}" --domain vpc \
  --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${PREFIX}-natgw-eip-az1},{Key=Project,Value=${PROJECT}},{Key=Environment,Value=${ENV}}]" \
  --query 'AllocationId' --output text)

EIP_AZ2=$(aws ec2 allocate-address --region "${AWS_REGION}" --domain vpc \
  --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Name,Value=${PREFIX}-natgw-eip-az2},{Key=Project,Value=${PROJECT}},{Key=Environment,Value=${ENV}}]" \
  --query 'AllocationId' --output text)

ok "EIPs allocated: ${EIP_AZ1}, ${EIP_AZ2}"

###############################################################################
# 7. NAT GATEWAYS
###############################################################################
info "Creating NAT Gateway AZ1: ${PREFIX}-natgw-az1"

NATGW_AZ1=$(aws ec2 create-nat-gateway \
  --region "${AWS_REGION}" \
  --subnet-id "${PUBLIC_SUBNET_AZ1}" \
  --allocation-id "${EIP_AZ1}" \
  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${PREFIX}-natgw-az1},{Key=Project,Value=${PROJECT}},{Key=Environment,Value=${ENV}}]" \
  --query 'NatGateway.NatGatewayId' --output text)

info "Creating NAT Gateway AZ2: ${PREFIX}-natgw-az2"

NATGW_AZ2=$(aws ec2 create-nat-gateway \
  --region "${AWS_REGION}" \
  --subnet-id "${PUBLIC_SUBNET_AZ2}" \
  --allocation-id "${EIP_AZ2}" \
  --tag-specifications "ResourceType=natgateway,Tags=[{Key=Name,Value=${PREFIX}-natgw-az2},{Key=Project,Value=${PROJECT}},{Key=Environment,Value=${ENV}}]" \
  --query 'NatGateway.NatGatewayId' --output text)

info "Waiting for NAT Gateways to become available (this can take 1-2 minutes) …"
aws ec2 wait nat-gateway-available --region "${AWS_REGION}" --nat-gateway-ids "${NATGW_AZ1}" "${NATGW_AZ2}"

ok "NAT Gateways ready: ${NATGW_AZ1}, ${NATGW_AZ2}"

###############################################################################
# 8. ROUTE TABLES
###############################################################################

# --- 8a. Public Route Table ---
info "Creating public route table: ${PREFIX}-public-rt"

PUBLIC_RT=$(aws ec2 create-route-table \
  --region "${AWS_REGION}" \
  --vpc-id "${VPC_ID}" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PREFIX}-public-rt},{Key=Project,Value=${PROJECT}},{Key=Environment,Value=${ENV}}]" \
  --query 'RouteTable.RouteTableId' --output text)

aws ec2 create-route --region "${AWS_REGION}" --route-table-id "${PUBLIC_RT}" \
  --destination-cidr-block 0.0.0.0/0 --gateway-id "${IGW_ID}" > /dev/null

aws ec2 associate-route-table --region "${AWS_REGION}" --route-table-id "${PUBLIC_RT}" --subnet-id "${PUBLIC_SUBNET_AZ1}" > /dev/null
aws ec2 associate-route-table --region "${AWS_REGION}" --route-table-id "${PUBLIC_RT}" --subnet-id "${PUBLIC_SUBNET_AZ2}" > /dev/null

ok "Public RT: ${PUBLIC_RT} → IGW ${IGW_ID}"

# --- 8b. Private App Route Table AZ1 ---
info "Creating private app route table AZ1: ${PREFIX}-private-app-rt-az1"

PRIVATE_APP_RT_AZ1=$(aws ec2 create-route-table \
  --region "${AWS_REGION}" \
  --vpc-id "${VPC_ID}" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PREFIX}-private-app-rt-az1},{Key=Project,Value=${PROJECT}},{Key=Environment,Value=${ENV}}]" \
  --query 'RouteTable.RouteTableId' --output text)

aws ec2 create-route --region "${AWS_REGION}" --route-table-id "${PRIVATE_APP_RT_AZ1}" \
  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "${NATGW_AZ1}" > /dev/null

aws ec2 associate-route-table --region "${AWS_REGION}" --route-table-id "${PRIVATE_APP_RT_AZ1}" --subnet-id "${PRIVATE_APP_SUBNET_AZ1}" > /dev/null

ok "Private App RT AZ1: ${PRIVATE_APP_RT_AZ1} → NATGW ${NATGW_AZ1}"

# --- 8c. Private App Route Table AZ2 ---
info "Creating private app route table AZ2: ${PREFIX}-private-app-rt-az2"

PRIVATE_APP_RT_AZ2=$(aws ec2 create-route-table \
  --region "${AWS_REGION}" \
  --vpc-id "${VPC_ID}" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PREFIX}-private-app-rt-az2},{Key=Project,Value=${PROJECT}},{Key=Environment,Value=${ENV}}]" \
  --query 'RouteTable.RouteTableId' --output text)

aws ec2 create-route --region "${AWS_REGION}" --route-table-id "${PRIVATE_APP_RT_AZ2}" \
  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "${NATGW_AZ2}" > /dev/null

aws ec2 associate-route-table --region "${AWS_REGION}" --route-table-id "${PRIVATE_APP_RT_AZ2}" --subnet-id "${PRIVATE_APP_SUBNET_AZ2}" > /dev/null

ok "Private App RT AZ2: ${PRIVATE_APP_RT_AZ2} → NATGW ${NATGW_AZ2}"

# --- 8d. Private DB Route Table ---
info "Creating private DB route table: ${PREFIX}-private-db-rt"

PRIVATE_DB_RT=$(aws ec2 create-route-table \
  --region "${AWS_REGION}" \
  --vpc-id "${VPC_ID}" \
  --tag-specifications "ResourceType=route-table,Tags=[{Key=Name,Value=${PREFIX}-private-db-rt},{Key=Project,Value=${PROJECT}},{Key=Environment,Value=${ENV}}]" \
  --query 'RouteTable.RouteTableId' --output text)

aws ec2 create-route --region "${AWS_REGION}" --route-table-id "${PRIVATE_DB_RT}" \
  --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "${NATGW_AZ1}" > /dev/null

aws ec2 associate-route-table --region "${AWS_REGION}" --route-table-id "${PRIVATE_DB_RT}" --subnet-id "${PRIVATE_DB_SUBNET_AZ1}" > /dev/null

ok "Private DB RT: ${PRIVATE_DB_RT} → NATGW ${NATGW_AZ1}"

###############################################################################
# 9. SECURITY GROUPS
###############################################################################

# --- 9a. Bastion SG ---
info "Creating security group: ${PREFIX}-bastion-sg"

BASTION_SG=$(aws ec2 create-security-group \
  --region "${AWS_REGION}" \
  --group-name "${PREFIX}-bastion-sg" \
  --description "Bastion host - SSH from admin IP only" \
  --vpc-id "${VPC_ID}" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${PREFIX}-bastion-sg},{Key=Project,Value=${PROJECT}},{Key=Environment,Value=${ENV}}]" \
  --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress --region "${AWS_REGION}" --group-id "${BASTION_SG}" \
  --protocol tcp --port 22 --cidr "${MY_IP}" > /dev/null

ok "Bastion SG: ${BASTION_SG} (SSH from ${MY_IP})"

# --- 9b. ALB SG ---
info "Creating security group: ${PREFIX}-alb-sg"

ALB_SG=$(aws ec2 create-security-group \
  --region "${AWS_REGION}" \
  --group-name "${PREFIX}-alb-sg" \
  --description "Application Load Balancer - HTTP/HTTPS from internet" \
  --vpc-id "${VPC_ID}" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${PREFIX}-alb-sg},{Key=Project,Value=${PROJECT}},{Key=Environment,Value=${ENV}}]" \
  --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress --region "${AWS_REGION}" --group-id "${ALB_SG}" \
  --protocol tcp --port 80 --cidr "0.0.0.0/0" > /dev/null
aws ec2 authorize-security-group-ingress --region "${AWS_REGION}" --group-id "${ALB_SG}" \
  --protocol tcp --port 443 --cidr "0.0.0.0/0" > /dev/null

ok "ALB SG: ${ALB_SG} (HTTP 80 + HTTPS 443 from 0.0.0.0/0)"

# --- 9c. EKS Node SG ---
info "Creating security group: ${PREFIX}-eks-node-sg"

EKS_NODE_SG=$(aws ec2 create-security-group \
  --region "${AWS_REGION}" \
  --group-name "${PREFIX}-eks-node-sg" \
  --description "EKS worker nodes - internal cluster and ALB traffic" \
  --vpc-id "${VPC_ID}" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${PREFIX}-eks-node-sg},{Key=Project,Value=${PROJECT}},{Key=Environment,Value=${ENV}}]" \
  --query 'GroupId' --output text)

# Node-to-node (all traffic within the same SG)
aws ec2 authorize-security-group-ingress --region "${AWS_REGION}" --group-id "${EKS_NODE_SG}" \
  --protocol -1 --source-group "${EKS_NODE_SG}" > /dev/null

# ALB → nodes (HTTP target traffic 30000-32767 NodePort range + 80/443/8080)
aws ec2 authorize-security-group-ingress --region "${AWS_REGION}" --group-id "${EKS_NODE_SG}" \
  --protocol tcp --port 30000-32767 --source-group "${ALB_SG}" > /dev/null
aws ec2 authorize-security-group-ingress --region "${AWS_REGION}" --group-id "${EKS_NODE_SG}" \
  --protocol tcp --port 80 --source-group "${ALB_SG}" > /dev/null
aws ec2 authorize-security-group-ingress --region "${AWS_REGION}" --group-id "${EKS_NODE_SG}" \
  --protocol tcp --port 443 --source-group "${ALB_SG}" > /dev/null
aws ec2 authorize-security-group-ingress --region "${AWS_REGION}" --group-id "${EKS_NODE_SG}" \
  --protocol tcp --port 8080 --source-group "${ALB_SG}" > /dev/null

# Bastion → nodes (SSH)
aws ec2 authorize-security-group-ingress --region "${AWS_REGION}" --group-id "${EKS_NODE_SG}" \
  --protocol tcp --port 22 --source-group "${BASTION_SG}" > /dev/null

# Kubernetes API & Kubelet (VPC-wide for control plane communication)
aws ec2 authorize-security-group-ingress --region "${AWS_REGION}" --group-id "${EKS_NODE_SG}" \
  --protocol tcp --port 443 --cidr "${VPC_CIDR}" > /dev/null
aws ec2 authorize-security-group-ingress --region "${AWS_REGION}" --group-id "${EKS_NODE_SG}" \
  --protocol tcp --port 10250 --cidr "${VPC_CIDR}" > /dev/null

# CoreDNS
aws ec2 authorize-security-group-ingress --region "${AWS_REGION}" --group-id "${EKS_NODE_SG}" \
  --protocol tcp --port 53 --cidr "${VPC_CIDR}" > /dev/null
aws ec2 authorize-security-group-ingress --region "${AWS_REGION}" --group-id "${EKS_NODE_SG}" \
  --protocol udp --port 53 --cidr "${VPC_CIDR}" > /dev/null

ok "EKS Node SG: ${EKS_NODE_SG}"

# --- 9d. MySQL SG ---
info "Creating security group: ${PREFIX}-mysql-sg"

MYSQL_SG=$(aws ec2 create-security-group \
  --region "${AWS_REGION}" \
  --group-name "${PREFIX}-mysql-sg" \
  --description "MySQL - access from EKS nodes only" \
  --vpc-id "${VPC_ID}" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${PREFIX}-mysql-sg},{Key=Project,Value=${PROJECT}},{Key=Environment,Value=${ENV}}]" \
  --query 'GroupId' --output text)

aws ec2 authorize-security-group-ingress --region "${AWS_REGION}" --group-id "${MYSQL_SG}" \
  --protocol tcp --port 3306 --source-group "${EKS_NODE_SG}" > /dev/null

ok "MySQL SG: ${MYSQL_SG} (3306 from EKS nodes only)"

###############################################################################
# 10. BASTION HOST (EC2)
###############################################################################
info "Resolving latest Amazon Linux 2023 AMI …"

AL2023_AMI=$(aws ssm get-parameters \
  --region "${AWS_REGION}" \
  --names "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query 'Parameters[0].Value' --output text)

ok "AMI resolved: ${AL2023_AMI}"

# Create SSH Key Pair
info "Creating SSH Key Pair: ${BASTION_KEY_NAME}"
aws ec2 delete-key-pair --region "${AWS_REGION}" --key-name "${BASTION_KEY_NAME}" 2>/dev/null || true
rm -f "${BASTION_KEY_NAME}.pem"

aws ec2 create-key-pair \
  --region "${AWS_REGION}" \
  --key-name "${BASTION_KEY_NAME}" \
  --key-type ed25519 \
  --tag-specifications "ResourceType=key-pair,Tags=[{Key=Name,Value=${BASTION_KEY_NAME}},{Key=Project,Value=${PROJECT}},{Key=Environment,Value=${ENV}}]" \
  --query 'KeyMaterial' --output text > "${BASTION_KEY_NAME}.pem"

chmod 400 "${BASTION_KEY_NAME}.pem"
ok "Key pair saved: ${BASTION_KEY_NAME}.pem"

info "Launching Bastion Host: ${PREFIX}-bastion"

BASTION_ID=$(aws ec2 run-instances \
  --region "${AWS_REGION}" \
  --image-id "${AL2023_AMI}" \
  --instance-type "${BASTION_INSTANCE_TYPE}" \
  --key-name "${BASTION_KEY_NAME}" \
  --subnet-id "${PUBLIC_SUBNET_AZ1}" \
  --security-group-ids "${BASTION_SG}" \
  --associate-public-ip-address \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${PREFIX}-bastion},{Key=Project,Value=${PROJECT}},{Key=Environment,Value=${ENV}},{Key=Role,Value=bastion}]" \
  --query 'Instances[0].InstanceId' --output text)

info "Waiting for bastion instance to reach running state …"
aws ec2 wait instance-running --region "${AWS_REGION}" --instance-ids "${BASTION_ID}"

BASTION_PUBLIC_IP=$(aws ec2 describe-instances --region "${AWS_REGION}" \
  --instance-ids "${BASTION_ID}" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

ok "Bastion running: ${BASTION_ID} (Public IP: ${BASTION_PUBLIC_IP})"

###############################################################################
# 11. SUMMARY
###############################################################################
echo ""
echo "============================================================"
echo "  NutriTrack Production Infrastructure — Provisioning Complete"
echo "============================================================"
echo ""
echo "  VPC               : ${VPC_ID}"
echo "  ├─ Public Sub AZ1 : ${PUBLIC_SUBNET_AZ1}"
echo "  ├─ Public Sub AZ2 : ${PUBLIC_SUBNET_AZ2}"
echo "  ├─ Priv App AZ1   : ${PRIVATE_APP_SUBNET_AZ1}"
echo "  ├─ Priv App AZ2   : ${PRIVATE_APP_SUBNET_AZ2}"
echo "  └─ Priv DB  AZ1   : ${PRIVATE_DB_SUBNET_AZ1}"
echo ""
echo "  Internet Gateway   : ${IGW_ID}"
echo "  NAT Gateway AZ1    : ${NATGW_AZ1}"
echo "  NAT Gateway AZ2    : ${NATGW_AZ2}"
echo ""
echo "  Route Tables"
echo "  ├─ Public          : ${PUBLIC_RT}"
echo "  ├─ Priv App AZ1    : ${PRIVATE_APP_RT_AZ1}"
echo "  ├─ Priv App AZ2    : ${PRIVATE_APP_RT_AZ2}"
echo "  └─ Priv DB         : ${PRIVATE_DB_RT}"
echo ""
echo "  Security Groups"
echo "  ├─ Bastion         : ${BASTION_SG}"
echo "  ├─ ALB             : ${ALB_SG}"
echo "  ├─ EKS Node        : ${EKS_NODE_SG}"
echo "  └─ MySQL           : ${MYSQL_SG}"
echo ""
echo "  Bastion Host       : ${BASTION_ID}"
echo "  Bastion Public IP  : ${BASTION_PUBLIC_IP}"
echo "  Bastion Key Name   : ${BASTION_KEY_NAME}"
echo ""
echo "  SSH Command:"
echo "    ssh -i ${BASTION_KEY_NAME}.pem ec2-user@${BASTION_PUBLIC_IP}"
echo ""
echo "============================================================"
echo "  Next steps:"
echo "    1. Create EKS cluster in private app subnets"
echo "    2. Deploy MySQL in private DB subnet"
echo "    3. Configure ALB Ingress Controller"
echo "============================================================"
