# Technical Plan: Amazon Route 53 & SSL/TLS (ACM) Integration

This plan details how to connect your custom domain (using Amazon Route 53) and secure it with SSL/TLS certificates (using AWS Certificate Manager - ACM) for the NutriTrack microservices deployed on Amazon EKS.

---

## Architecture Flow

```
User (https://app.nutritrack.com)
  │
  ▼
Route 53 (DNS Query resolved to ALB Alias)
  │
  ▼
Application Load Balancer (ALB decrypts SSL on Port 443 using ACM Cert)
  │
  ▼
EKS Worker Nodes / Pods (HTTP Port 80)
```

---

## Phase 1: Configure Route 53 Hosted Zone
First, you need a public hosted zone in Route 53 for your domain.

1. Navigate to the **Route 53 Console**.
2. Click **Hosted zones** on the left menu, then click **Create hosted zone**.
3. Configure settings:
   - **Domain name**: Your registered domain (e.g., `nutritrack.com` or `yourdomain.com`).
   - **Type**: **Public hosted zone**.
4. Click **Create hosted zone**.
5. *Note*: If you registered your domain with a third-party registrar (like GoDaddy, Namecheap), copy the 4 Name Server (NS) records created by Route 53 and paste them into your registrar's DNS settings panel.

---

## Phase 2: Request SSL Certificate in AWS Certificate Manager (ACM)
To support secure HTTPS traffic, request a free SSL certificate from ACM.

1. Navigate to the **Certificate Manager (ACM) Console** in `us-east-1` (the certificate must be in the same region as the ALB).
2. Click **Request a certificate** -> Select **Request a public certificate** -> Click **Next**.
3. Configure the certificate:
   - **Fully qualified domain name**: Enter your domain name. It is recommended to include wildcards to cover subdomains:
     * `yourdomain.com`
     * `*.yourdomain.com`
   - **Validation method**: Select **DNS validation** (Recommended).
4. Click **Request**.
5. Once requested, go to the certificate details page and click **Create records in Route 53**. This will automatically add the required CNAME verification records to your hosted zone.
6. The certificate status will update from `Pending validation` to `Issued` within a few minutes.

---

## Phase 3: Update Kubernetes Ingress for SSL Termination
Now, configure the **AWS Load Balancer Controller** to look up your ACM certificate and bind it to the Application Load Balancer.

Update your Kubernetes `Ingress` manifest to include the appropriate annotations:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nutritrack-ingress
  namespace: default
  annotations:
    # Tell EKS to create an Application Load Balancer
    kubernetes.io/ingress.class: alb
    # ALB listens to both internet-facing traffic
    alb.ingress.kubernetes.io/scheme: internet-facing
    # Specify the target type (IP mode is recommended for EKS Fargate/Nodes)
    alb.ingress.kubernetes.io/target-type: ip
    
    # ── HTTPS Configuration ──
    # Specify the ARN of your ACM Certificate
    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-east-1:<ACCOUNT_ID>:certificate/<CERTIFICATE_ID>
    # Tell ALB to listen on both HTTP (80) and HTTPS (443) ports
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP": 80}, {"HTTPS": 443}]'
    # Enable automatic HTTP to HTTPS redirection
    alb.ingress.kubernetes.io/ssl-redirect: '443'
spec:
  rules:
    - host: app.yourdomain.com  # <-- Your domain mapped in Route 53
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: nutritrack-frontend
                port:
                  number: 80
```

---

## Phase 4: Route Traffic to the ALB (Two Options)

Once you apply the Ingress manifest, the AWS Load Balancer Controller creates the ALB. You need to tell Route 53 to forward traffic for `app.yourdomain.com` to this new ALB.

### Option A: Manual Mapping (Quickest)
1. In the **EKS/Kubernetes terminal**, retrieve the DNS name of the ALB:
   ```bash
   kubectl get ingress nutritrack-ingress
   ```
   *(Copy the Address, e.g., `k8s-default-nutritra-xxxxxx.us-east-1.elb.amazonaws.com`)*.
2. Go to the **Route 53 Console** -> select your Hosted Zone.
3. Click **Create record**.
4. Configure settings:
   - **Record name**: `app` (to create `app.yourdomain.com`).
   - **Record type**: **A - Routes traffic to an IPv4 address and some AWS resources**.
   - Toggle **Alias** to **ON**.
   - Under **Route traffic to**:
     - Choose **Alias to Application and Classic Load Balancer**.
     - Select region: **us-east-1**.
     - Select your Application Load Balancer from the list.
5. Click **Create records**.

---

### Option B: Automatic Mapping with `external-dns` (Enterprise/GitOps)
Instead of manually mapping records, you can deploy the `external-dns` controller inside EKS, which automatically creates and deletes Route 53 DNS records when Ingresses are created or modified.

1. **Create IAM Policy for external-dns**:
   Create a policy allowing EKS nodes to modify Route 53 record sets:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": [
           "route53:ChangeResourceRecordSets"
         ],
         "Resource": [
           "arn:aws:route53:::hostedzone/<HOSTED_ZONE_ID>"
         ]
       },
       {
         "Effect": "Allow",
         "Action": [
           "route53:ListHostedZones",
           "route53:ListResourceRecordSets"
         ],
         "Resource": [
           "*"
         ]
       }
     ]
   }
   ```
2. **Bind Policy using `eksctl` IRSA**:
   ```bash
   eksctl create iamserviceaccount \
     --cluster=nutritrack-prod-eks \
     --namespace=kube-system \
     --name=external-dns \
     --attach-policy-arn=arn:aws:iam::<ACCOUNT_ID>:policy/ExternalDNSPolicy \
     --approve
   ```
3. **Deploy external-dns via Helm**:
   ```bash
   helm repo add bitnami https://charts.bitnami.com/bitnami
   helm install external-dns bitnami/external-dns \
     -n kube-system \
     --set provider=aws \
     --set aws.zoneType=public \
     --set txtOwnerId=nutritrack-prod-eks \
     --set serviceAccount.create=false \
     --set serviceAccount.name=external-dns
   ```
Once deployed, the `host: app.yourdomain.com` defined in your Ingress manifest will be automatically registered in Route 53 by the controller without manual intervention!
