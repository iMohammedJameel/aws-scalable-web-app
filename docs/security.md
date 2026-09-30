# Security Controls — Detailed Reference

This document expands the security table in the main README with the concrete rules, policies, and hardening measures implemented in the CloudFormation template.

---

## 1 · Edge security

### AWS WAF WebACL (attached to CloudFront)

| Rule | Priority | Action | Purpose |
|------|----------|--------|---------|
| `AWSManagedRulesCommonRuleSet` | 10 | Count/Block (managed) | OWASP Top 10 — SQLi (`SQLi_BODY`, `SQLi_QUERYARGS`…), XSS, LFI/RFI, size restrictions |
| `AWSManagedRulesKnownBadInputsRuleSet` | 20 | Block (managed) | Log4J RCE, SSRF, bad-bot signatures, proxying attempts |
| `RateLimitPerIP` | 30 | Block | > 2,000 requests / 5 min from a single IP — absorbs scrapers and credential stuffing |

**Operational notes:**
- All rules emit CloudWatch metrics and sampled requests — inspect the **WAF → Sampled requests** tab before moving a rule from Count to Block in a real deployment.
- To tune a false positive, add `ExcludedRules` / rule-action overrides rather than disabling the whole group.
- A CLOUDFRONT-scoped ACL is created in **us-east-1** — this stack deploys there.

### AWS Shield Standard
Included automatically on CloudFront and ALB. Always-on L3/L4 (SYN floods, UDP reflection) detection and inline mitigation. Shield Advanced (paid) adds L7 protection, DDoS response team, and cost-protection — relevant only once revenue justifies it.

### ACM / TLS
- Viewer → CloudFront: TLS 1.2+ enforced via `ViewerProtocolPolicy: redirect-to-https` on **both** cache behaviors; HTTP is 301'd to HTTPS.
- CloudFront → ALB origin: `https-only` + TLSv1.2 when `AlbCertificateArn` is supplied (test mode falls back to HTTP origin — never do this in production).
- The free `*.cloudfront.net` certificate covers the distribution domain out of the box.

---

## 2 · Network security

### Subnet placement

| Tier | Public? | Route 0.0.0.0/0 | Internet exposure |
|------|---------|-----------------|-------------------|
| ALB nodes | Yes | → IGW | Ports 80/443 only, SG-controlled |
| NAT GW | Yes | → IGW | None (return traffic only) |
| EC2 app | No | → NAT GW (per-AZ) | None — cannot be *reached* from internet |
| RDS | No | **No route** | None — cannot even *reach* the internet |

### Security Groups (stateful, instance-level)

```
AlbSecurityGroup
  IN  tcp:80, tcp:443  from 0.0.0.0/0      # public entry
  OUT all              to anywhere          # ALB needs broad egress for responses

AppSecurityGroup
  IN  tcp:8080         from AlbSecurityGroup     # ONLY the ALB reaches the app
  IN  tcp:0-65535      from AppSecurityGroup     # intra-tier traffic
  # port 22: NOT OPEN — SSM only

DatabaseSecurityGroup
  IN  tcp:3306         from AppSecurityGroup     # ONLY the app tier reaches MySQL
```

**SG-referencing:** rules reference *security group IDs*, not CIDRs — when the ASG launches a new instance it inherits the correct reachability automatically, and there is no stale-IP drift.

### Network ACLs (stateless, subnet-level) — data tier

The data-subnet NACL denies everything except intra-VPC TCP and DNS:

| # | Direction | Proto | Ports | Source/Dest | Effect |
|---|-----------|-------|-------|-------------|--------|
| 100 | Inbound | TCP | all | VPC CIDR | app→DB :3306, replication, ephemeral replies |
| 110 | Inbound | UDP | 53 | VPC CIDR | DNS resolution |
| 100 | Outbound | TCP | all | VPC CIDR | responses + replication initiation |
| 110 | Outbound | UDP | 53 | VPC CIDR | DNS |

Because NACLs are stateless, both directions are required; because a custom NACL's default is **deny**, any flow not listed (i.e., *anything internet-bound*) is dropped even if someone later adds an internet route to the data subnets. This is the backstop that contains a compromised app host: it may reach the DB on 3306, but the DB subnet will never exfiltrate to the internet.

---

## 3 · Compute & identity security

**IAM instance role (least privilege):**
- `AmazonSSMManagedInstanceCore` — Session Manager + SSM agent registration
- `CloudWatchAgentServerPolicy` — publish custom metrics/logs
- Inline: `s3:GetObject`/`ListBucket` on **only** the assets bucket; `ssm:GetParameter` on **only** the `/prod/db-password` parameter

No policy uses `*` resources or actions; no credentials are stored on disk — the instance uses its role via the metadata service.

**IMDSv2 required:** `HttpTokens: required` in the launch template blocks the classic SSRF→IAM-credentials attack (CAP_NET_RAW + 169.254.169.254). Session-oriented tokens must be requested with PUT, which plain SSRF payloads rarely do.

**EBS encryption:** every instance volume is created with `Encrypted: true` (AWS-managed KMS key by default).

**No SSH:** no key pairs, no bastion, port 22 closed at the SG — the fleet's only management plane is SSM, which is authenticated by IAM, authorized by the role, and fully audited.

---

## 4 · Data security

**RDS:**
- `StorageEncrypted: true` — KMS-encrypted at rest (data, logs, snapshots, and automated backups)
- `PubliclyAccessible: false` — RDS refuses a public IP even if misconfigured subnets would allow one
- `DeletionProtection: true` — the console/API cannot silently delete the database
- 35-day automated backups + point-in-time recovery
- Only the app-tier SG can open 3306; TLS to the DB can be enforced with a parameter-group `require_secure_transport=ON`

**S3:**
- Block Public Access: all four flags ON (kills every public-access vector, including accidental ACLs)
- Bucket policy: `Deny` any request where `aws:SecureTransport = false` (TLS-only)
- Read access restricted to the CloudFront OAC principal, conditioned on the distribution's ARN — direct curl to the bucket returns 403
- Versioning ON — protects against overwrite/delete fat-fingers, prerequisite for object lock

**SSM Parameter Store:**
- The DB password reaches instances via a SecureString-capable parameter readable only by the app role — never baked into AMIs or user-data

---

## 5 · Detection & audit

- **CloudWatch alarms** on ALB unhealthy hosts, ALB 5xx rate, RDS CPU, and RDS connections page the on-call via SNS email
- **CloudTrail** (account-level, enable once) records every API call that created/modified the resources above
- **WAF sampled requests** provide per-rule request visibility
- **RDS log exports** (error, slow query, general) stream to CloudWatch Logs
- **SSM session logs** can be streamed to S3/CloudWatch by attaching a session-preferences document

---

## 6 · Hardening roadmap (beyond project scope)

1. Restrict the ALB SG to the CloudFront managed prefix list (`com.amazonaws.global.cloudfront.origin-facing`) so the ALB cannot be bypassed
2. Add a custom origin header shared between CloudFront and the app as a second bypass check
3. Move the DB password to **Secrets Manager** with automatic rotation (Project 8 territory)
4. Enable GuardDuty + Security Hub for managed threat detection
5. AWS Config rules (e.g., `encrypted-volumes`, `s3-bucket-public-read-prohibited`) with auto-remediation
