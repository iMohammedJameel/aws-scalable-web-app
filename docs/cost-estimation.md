# Cost Estimation — Detailed Breakdown

Region: **us-east-1 (N. Virginia)** · Pricing: on-demand, list prices (Oct 2025), rounded. Verify with the [AWS Pricing Calculator](https://calculator.aws/) before committing budget.

---

## Baseline stack (2 instances, idle-to-light load)

| # | Service | Resource | Monthly |
|---|---------|----------|---------:|
| 1 | EC2 | 2 × t3.medium (2 vCPU, 4 GB) × 730 h | $60.52 |
| 2 | EBS | 2 × 20 GB gp3 | $3.20 |
| 3 | ALB | base + ~1 LCU | $18.50 |
| 4 | NAT Gateway | 2 × $0.045/h | $65.70 |
| 5 | NAT data processing | 2 × 20 GB × $0.045/GB | $1.80 |
| 6 | RDS Multi-AZ | db.t3.medium × 2 (Multi-AZ doubles instance) × $0.104/h* | $151.84 |
| 7 | RDS storage | 50 GB gp3 × 2 (Multi-AZ) | $23.00 |
| 8 | RDS backups | ≤ 100 GB free (35-day retention) | $0.00 |
| 9 | CloudFront | 100 GB egress + 5 M requests (PriceClass_100) | $11.50 |
| 10 | S3 | 20 GB + requests | $2.10 |
| 11 | CloudWatch | 4 alarms + metrics | $3.00 |
| 12 | SNS / SSM / Route 53 | SNS email, SSM sessions, 0 queries | $0.00 |
| | **Total (baseline)** | | **≈ $341** |

*t3/t4g "burstable" pricing assumes minimal credit exhaustion at idle. Under sustained CPU the effective price rises.

## Production-shape estimate (1 TB egress, 10 M requests, 6 instances at peak, 100 GB RDS)

| Driver | Monthly |
|--------|--------:|
| EC2 avg 3 × t3.medium | $90.78 |
| RDS Multi-AZ db.m5.large (sustained load) + 100 GB | $305.00 |
| CloudFront 1 TB + 10 M req | $92.00 |
| NAT 2 × 100 GB processed | $73.70 |
| Everything else (as above) | $90.00 |
| **Total (production shape)** | **≈ $650** |

---

## Cost drivers — what actually moves the bill

1. **RDS Multi-AZ (≈45%)** — the single biggest line. It buys HA, not performance.
2. **NAT Gateways (≈20%)** — the classic "why is my bill huge" service; each AZ needs one here for resilience.
3. **EC2 fleet** — scales 2→6 with demand (that's the point of target tracking).
4. **CloudFront egress** — grows linearly with traffic but *replaces* more expensive ALB/EC2 egress for static content.

## Optimization levers, ranked by effort

| Lever | Saving | Effort | Trade-off |
|-------|--------|--------|-----------|
| **Graviton t4g.medium** (drop-in ARM) | ~20% of EC2 | Low — change one parameter | Requires ARM-compatible app stack |
| **Compute Savings Plan 1-yr** on steady baseline | ~30% of EC2+ALB | Low (commitment) | Use-it-or-lose-it commitment |
| **RDS Reserved Instance 1-yr** | ~30% of RDS | Low (commitment) | Same as above |
| **Single NAT Gateway** | ~$33/mo | Low | Cross-AZ charges + AZ SPOF for egress |
| **RDS Single-AZ for dev/stage** | ~50% of RDS | Low | No auto-failover — never for prod |
| **CloudFront Savings Bundle** | 30% of CDN | Low | 12-month commit, up-front |
| **Scheduled scale-down at night (dev envs)** | up to 65% of EC2 | Medium | Latency on morning scale-up |
| **Aurora Serverless v2** instead of RDS | varies | Medium | Different engine semantics; pay-per-ACU can undercut Multi-AZ at low load |
| **Instance refresh to spot-capacity mixed ASG** | up to 70% of EC2 | Medium | Interruption handling needed — fine for stateless web tiers |

## Destroying the stack (most important cost control)

This architecture is **not** free-tier friendly. When you finish the project:

```bash
aws s3 rm s3://<assets-bucket> --recursive            # CloudFormation cannot delete a non-empty bucket
aws cloudformation update-stack ... RdsDeletionProtection=false   # unlock the DB
aws cloudformation delete-stack --stack-name scalable-web-app
```

The template's `DeletionPolicy: Snapshot` on the DB instance leaves a final snapshot (billed at $0.095/GB-mo) — delete it if you don't need it:

```bash
aws rds delete-db-snapshot --db-snapshot-id <final-snapshot-id>
```
