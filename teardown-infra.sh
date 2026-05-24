#!/usr/bin/env bash
###############################################################################
#  NutriTrack — Infrastructure Teardown Script
#  ---------------------------------------------------------------
#  Destroys ALL resources created by provision-infra.sh.
#  Run this to avoid ongoing AWS charges.
#
#  Usage:
#    chmod +x teardown-infra.sh
#    ./teardown-infra.sh
###############################################################################
set -euo pipefail

PROJECT="nutritrack"
ENV="prod"
PREFIX="${PROJECT}-${ENV}"
AWS_REGION="us-east-1"
BASTION_KEY_NAME="us-east"

info()  { echo -e "\n\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }

###############################################################################
# Lookup VPC by Name tag
###############################################################################
info "Looking up VPC: ${PREFIX}-vpc"
VPC_ID=$(aws ec2 describe-vpcs --region "${AWS_REGION}" \
  --filters "Name=tag:Name,Values=${PREFIX}-vpc" \
  --query 'Vpcs[0].VpcId' --output text 2>/dev/null || echo "None")

if [[ "${VPC_ID}" == "None" || -z "${VPC_ID}" ]]; then
  warn "VPC not found — nothing to tear down."
  exit 0
fi
ok "Found VPC: ${VPC_ID}"

###############################################################################
# 1. Terminate Bastion EC2 instances
###############################################################################
info "Terminating bastion instances …"
INSTANCE_IDS=$(aws ec2 describe-instances --region "${AWS_REGION}" \
  --filters "Name=tag:Name,Values=${PREFIX}-bastion" "Name=instance-state-name,Values=running,stopped,pending" \
  --query 'Reservations[].Instances[].InstanceId' --output text)

if [[ -n "${INSTANCE_IDS}" && "${INSTANCE_IDS}" != "None" ]]; then
  aws ec2 terminate-instances --region "${AWS_REGION}" --instance-ids ${INSTANCE_IDS} > /dev/null
  info "Waiting for instance termination …"
  aws ec2 wait instance-terminated --region "${AWS_REGION}" --instance-ids ${INSTANCE_IDS}
  ok "Bastion instances terminated"
else
  warn "No bastion instances found"
fi

###############################################################################
# 2. Delete Key Pair
###############################################################################
info "Deleting key pair: ${BASTION_KEY_NAME}"
aws ec2 delete-key-pair --region "${AWS_REGION}" --key-name "${BASTION_KEY_NAME}" 2>/dev/null || true
rm -f "${BASTION_KEY_NAME}.pem"
ok "Key pair deleted"

###############################################################################
# 3. Delete NAT Gateways & wait
###############################################################################
info "Deleting NAT Gateways …"
NATGW_IDS=$(aws ec2 describe-nat-gateways --region "${AWS_REGION}" \
  --filter "Name=vpc-id,Values=${VPC_ID}" "Name=state,Values=available" \
  --query 'NatGateways[].NatGatewayId' --output text)

for ngw in ${NATGW_IDS}; do
  aws ec2 delete-nat-gateway --region "${AWS_REGION}" --nat-gateway-id "${ngw}" > /dev/null
  info "  Deleting ${ngw} …"
done

if [[ -n "${NATGW_IDS}" && "${NATGW_IDS}" != "None" ]]; then
  info "Waiting for NAT Gateways to be deleted (1-2 min) …"
  for ngw in ${NATGW_IDS}; do
    aws ec2 wait nat-gateway-deleted --region "${AWS_REGION}" --nat-gateway-ids "${ngw}" 2>/dev/null || true
  done
  ok "NAT Gateways deleted"
fi

###############################################################################
# 4. Release Elastic IPs
###############################################################################
info "Releasing Elastic IPs …"
EIP_ALLOCS=$(aws ec2 describe-addresses --region "${AWS_REGION}" \
  --filters "Name=tag:Project,Values=${PROJECT}" "Name=tag:Environment,Values=${ENV}" \
  --query 'Addresses[].AllocationId' --output text)

for alloc in ${EIP_ALLOCS}; do
  aws ec2 release-address --region "${AWS_REGION}" --allocation-id "${alloc}" 2>/dev/null || true
  info "  Released ${alloc}"
done
ok "Elastic IPs released"

###############################################################################
# 5. Delete custom route table associations & route tables
###############################################################################
info "Cleaning up route tables …"
RT_IDS=$(aws ec2 describe-route-tables --region "${AWS_REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Project,Values=${PROJECT}" \
  --query 'RouteTables[].RouteTableId' --output text)

for rt in ${RT_IDS}; do
  # Remove associations (skip main)
  ASSOC_IDS=$(aws ec2 describe-route-tables --region "${AWS_REGION}" \
    --route-table-ids "${rt}" \
    --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' --output text)
  for assoc in ${ASSOC_IDS}; do
    aws ec2 disassociate-route-table --region "${AWS_REGION}" --association-id "${assoc}" 2>/dev/null || true
  done
  aws ec2 delete-route-table --region "${AWS_REGION}" --route-table-id "${rt}" 2>/dev/null || true
  info "  Deleted RT: ${rt}"
done
ok "Route tables cleaned"

###############################################################################
# 6. Detach & Delete Internet Gateway
###############################################################################
info "Deleting Internet Gateway …"
IGW_IDS=$(aws ec2 describe-internet-gateways --region "${AWS_REGION}" \
  --filters "Name=attachment.vpc-id,Values=${VPC_ID}" \
  --query 'InternetGateways[].InternetGatewayId' --output text)

for igw in ${IGW_IDS}; do
  aws ec2 detach-internet-gateway --region "${AWS_REGION}" --internet-gateway-id "${igw}" --vpc-id "${VPC_ID}" 2>/dev/null || true
  aws ec2 delete-internet-gateway --region "${AWS_REGION}" --internet-gateway-id "${igw}" 2>/dev/null || true
  info "  Deleted IGW: ${igw}"
done
ok "Internet Gateway deleted"

###############################################################################
# 7. Delete Security Groups (non-default)
###############################################################################
info "Deleting security groups …"
SG_IDS=$(aws ec2 describe-security-groups --region "${AWS_REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:Project,Values=${PROJECT}" \
  --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text)

for sg in ${SG_IDS}; do
  aws ec2 delete-security-group --region "${AWS_REGION}" --group-id "${sg}" 2>/dev/null || true
  info "  Deleted SG: ${sg}"
done
ok "Security groups deleted"

###############################################################################
# 8. Delete Subnets
###############################################################################
info "Deleting subnets …"
SUBNET_IDS=$(aws ec2 describe-subnets --region "${AWS_REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'Subnets[].SubnetId' --output text)

for sub in ${SUBNET_IDS}; do
  aws ec2 delete-subnet --region "${AWS_REGION}" --subnet-id "${sub}" 2>/dev/null || true
  info "  Deleted subnet: ${sub}"
done
ok "Subnets deleted"

###############################################################################
# 9. Delete VPC
###############################################################################
info "Deleting VPC: ${VPC_ID}"
aws ec2 delete-vpc --region "${AWS_REGION}" --vpc-id "${VPC_ID}"
ok "VPC deleted: ${VPC_ID}"

echo ""
echo "============================================================"
echo "  NutriTrack Infrastructure — Teardown Complete"
echo "============================================================"
