# Deployment Guide — Step by Step

Time to complete: **~25 minutes** (15 of which is CloudFormation doing the work).
Region: **us-east-1** (required — the WAF WebACL scoped to CloudFront must live there).
Cost while deployed: see `cost-estimation.md` (~$0.50/hour). **Tear it down when done.**

---

## 0 · Prerequisites

| Requirement | Check |
|-------------|-------|
| AWS CLI v2 configured | `aws sts get-caller-identity` |
| Admin or delegated permissions | VPC, EC2, RDS, ELB, CloudFront, WAFv2, S3, IAM, SNS, SSM |
| Service quotas (us-east-1) | 2+ running t3.medium, 1 db.t3.medium, ALB |
| Email inbox (for alarms) | — |

---

## 1 · Quick deploy (zero prerequisites)

```bash
git clone <your-fork-url> && cd aws-scalable-web-app

aws cloudformation deploy \
  --template-file cloudformation/template.yaml \
  --stack-name scalable-web-app \
  --capabilities CAPABILITY_NAMED_IAM \
  --region us-east-1 \
  --parameter-overrides \
      EnvironmentName=prod \
      AlarmEmail=you@example.com \
      RdsMasterUserPassword='MyStr0ng-Passw0rd!'
```

What happens, in order:
1. Network layer builds first — VPC, subnets, IGW, NAT Gateways, route tables (~3 min)
2. Security groups, IAM role, SSM parameter
3. ALB + listeners; Launch Template; RDS Multi-AZ (**the long pole — up to 12 min**)
4. S3 bucket + policy; WAF WebACL; CloudFront distribution (**~5 min**)
5. CloudWatch alarms + SNS subscription
6. The ASG launches 2 instances; user-data installs nginx; instances pass `/health` after ~90 s and the target group goes healthy

## 2 · Confirm the SNS subscription

Check the inbox for `prod alerts` and confirm the subscription — otherwise alarms fire into the void:

```bash
aws sns list-subscriptions-by-topic \
  --topic-arn $(aws sns list-topics --query "Topics[?contains(TopicArn,'prod-alerts')].TopicArn" --output text)
```

## 3 · Retrieve the outputs

```bash
aws cloudformation describe-stacks --stack-name scalable-web-app \
  --query "Stacks[0].Outputs" --output table
```

You want `CloudFrontDomain` (the entry point) and `AssetsBucketName`.

## 4 · Smoke tests

```bash
# a) Dynamic path: CloudFront → ALB → EC2 (HTTP 200, x-cache: Miss)
curl -sI https://<cloudfront-domain>/ | head -5

# b) Static path: upload an asset, fetch it twice — Miss then Hit
echo "body{color:#333}" > app.css
aws s3 cp app.css s3://<assets-bucket>/static/app.css
curl -sI https://<cloudfront-domain>/static/app.css | rg -i "x-cache"   # Miss from cloudfront
curl -sI https://<cloudfront-domain>/static/app.css | rg -i "x-cache"   # Hit  from cloudfront

# c) HTTP → HTTPS redirect
curl -sI http://<cloudfront-domain>/ | rg -i "location"                 # 301 → https://

# d) Origin lockdown: direct bucket access must be denied
curl -sI https://<assets-bucket>.s3.amazonaws.com/static/app.css        # 403 AccessDenied
```

## 5 · Test bastion-free access (Session Manager)

```bash
ASG=$(aws cloudformation describe-stacks --stack-name scalable-web-app \
        --query "Stacks[0].Outputs[?OutputKey=='AutoScalingGroupName'].OutputValue" --output text)
INSTANCE=$(aws ec2 describe-instances --filters "Name=tag:aws:autoscaling:groupName,Values=$ASG" \
        --query "Reservations[].Instances[?State.Name=='running'].InstanceId" --output text | head -1)

aws ssm start-session --target "$INSTANCE"
# Inside the session:
#   curl -s localhost:8080/health     → {"status":"ok"}
#   ss -tlnp | grep 8080              → nginx listening
```

No SSH key was ever needed — this is the SSM learning outcome in action.

## 6 · Watch Auto Scaling work

```bash
# From the SSM session (one instance), burn CPU on both cores for 5 minutes:
sudo dnf install -y stress
stress --cpu 2 --timeout 300
```

Then watch two things:
- **CloudWatch → EC2 Auto Scaling groups → Activity**: target-tracking policy adds an instance when fleet-average CPU holds above 40%
- **Target group**: the new instance registers, passes 2 consecutive health checks, and starts receiving traffic

Scale-in happens automatically after the load stops (default 10-minute cooldown for scale-in decisions).

## 7 · Test a zero-downtime config change (instance refresh)

```bash
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name "$ASG" \
  --preferences '{"MinHealthyPercentage": 100, "InstanceWarmup": 60}'
```

Instances are replaced one at a time while the ALB keeps serving — verify with `watch curl -s -o /dev/null -w "%{http_code}\n" https://<cloudfront-domain>/` in a second terminal.

## 8 · (Optional) Production HTTPS with a custom domain

The zero-prerequisite mode terminates TLS at CloudFront (always HTTPS to viewers) but walks HTTP between CloudFront and the ALB. To go end-to-end TLS:

1. Create/reuse a Route 53 hosted zone for your domain (the template creates one automatically if you pass `DomainName=app.example.com`)
2. Request a **DNS-validated ACM certificate in us-east-1** for `app.example.com` (CloudFront) and another in the deploy region for the ALB:
   ```bash
   aws acm request-certificate --domain-name app.example.com \
     --validation-method DNS --region us-east-1
   aws acm request-certificate --domain-name internal-alb.example.com \
     --validation-method DNS --region us-east-1
   ```
3. Add the validation CNAMEs to your zone, wait for `ISSUED`
4. Redeploy with both certificates:
   ```bash
   aws cloudformation deploy ... \
     --parameter-overrides DomainName=app.example.com \
       AlbCertificateArn=<deploy-region-cert-arn>
   ```
5. Update the CloudFront distribution's viewer certificate to the us-east-1 cert via the console/CLI, then attach `app.example.com` as an alias — now both legs are TLS.

## 9 · Cleanup (do not skip!)

```bash
# 1. Empty the bucket (delete-stack fails otherwise)
aws s3 rm s3://<assets-bucket> --recursive

# 2. Unlock the database
aws cloudformation deploy --template-file cloudformation/template.yaml \
  --stack-name scalable-web-app --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides RdsDeletionProtection=false AlarmEmail=you@example.com \
    RdsMasterUserPassword='MyStr0ng-Passw0rd!'

# 3. Delete everything
aws cloudformation delete-stack --stack-name scalable-web-app
aws cloudformation wait stack-delete-complete --stack-name scalable-web-app

# 4. Remove the final RDS snapshot if you don't want it (billed per GB-month)
aws rds describe-db-snapshots --query "DBSnapshots[].DBSnapshotIdentifier"
aws rds delete-db-snapshot --db-snapshot-id <snapshot-id>
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Stack stuck in `CREATE_IN_PROGRESS` > 30 min | RDS Multi-AZ provisioning or CFN distribution | Normal up to ~15 min each; check **Events** tab before panicking |
| Target group unhealthy | user-data failed (check `/var/log/cloud-init-output.log` via SSM) | `systemctl status nginx`, `curl localhost:8080/health` |
| 502 from CloudFront | ALB has no healthy targets, or test-mode origin mismatch | Check TG health; if you supplied `AlbCertificateArn`, confirm cert is in the deploy region and `ISSUED` |
| `EntityAlreadyExists` on deploy | `EnvironmentName` collides with a previous stack's named resources | Change `EnvironmentName` (e.g. `prod2`) or delete the old stack |
| WAF creation fails in non-us-east-1 | CLOUDFRONT-scope ACLs live only in us-east-1 | Deploy in us-east-1 or set `EnableWaf=false` |
| Bucket delete fails | Objects remain | `aws s3 rm ... --recursive` (versioned buckets: add `--versioning` or use lifecycle expire) |
