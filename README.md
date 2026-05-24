# NutriTrack — AWS Infrastructure (CLI)

Production-grade foundational AWS infrastructure for the NutriTrack microservices platform, provisioned entirely via AWS CLI.

## Architecture

```
Region: us-east-1 (AZ1: us-east-1a, AZ2: us-east-1b)

VPC: 10.0.0.0/16
├── Public Subnets        (10.0.1.0/24, 10.0.2.0/24)   → IGW
├── Private App Subnets   (10.0.11.0/24, 10.0.12.0/24) → NAT GWs
└── Private DB Subnet     (10.0.21.0/24)                → NAT GW AZ1
```

## What Gets Created

| Resource | Name | Count |
|---|---|---|
| VPC | `nutritrack-prod-vpc` | 1 |
| Public Subnets | `nutritrack-prod-public-subnet-az{1,2}` | 2 |
| Private App Subnets | `nutritrack-prod-private-app-subnet-az{1,2}` | 2 |
| Private DB Subnet | `nutritrack-prod-private-db-subnet-az1` | 1 |
| Internet Gateway | `nutritrack-prod-igw` | 1 |
| NAT Gateways | `nutritrack-prod-natgw-az{1,2}` | 2 |
| Elastic IPs | `nutritrack-prod-natgw-eip-az{1,2}` | 2 |
| Route Tables | public, private-app (×2), private-db | 4 |
| Security Groups | bastion, alb, eks-node, mysql | 4 |
| Bastion Host | `nutritrack-prod-bastion` (t2.micro) | 1 |
| Key Pair | `nutritrack-prod-bastion-key` | 1 |

## Prerequisites

1. **AWS CLI v2** — [Install guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
2. **jq** — `sudo yum install jq` or `brew install jq`
3. **AWS credentials configured** — `aws configure` with a user/role that has EC2/VPC/SSM permissions
4. **bash ≥ 4**

## Quick Start

```bash
# 1. Edit the MY_IP variable in provision-infra.sh to your public IP
#    Find your IP: curl -s https://checkip.amazonaws.com
#    Format: x.x.x.x/32

# 2. Make scripts executable
chmod +x provision-infra.sh teardown-infra.sh

# 3. Provision infrastructure (~3-5 minutes)
./provision-infra.sh

# 4. SSH into bastion
ssh -i nutritrack-prod-bastion-key.pem ec2-user@<BASTION_PUBLIC_IP>
```

## Teardown

```bash
# Destroy ALL resources (to avoid ongoing charges)
./teardown-infra.sh
```

## Cost Note

**NAT Gateways** incur hourly charges (~$0.045/hr each × 2 = ~$2.16/day). Tear down when not in use.

## What's NOT Included (By Design)

- EKS cluster / node groups
- RDS / MySQL instances
- Route53 / ACM / CloudFront
- CI/CD pipelines
- Kubernetes manifests / Helm charts
- Monitoring stack