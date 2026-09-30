# Architecture Deep Dive — Design Decisions & Trade-offs

This document records the key architectural decisions (ADR style) behind Project 1, including the alternatives considered and why they were rejected. Each decision maps to one or more SAA-C03 exam domains.

---

## ADR-001 · Two Availability Zones, three subnet tiers per AZ

**Decision:** Deploy the VPC across two AZs with six subnets — public, private-app, and private-data in each AZ.

**Alternatives considered:**

| Option | Verdict |
|--------|---------|
| Single AZ, all tiers | ❌ No fault isolation — one AZ event takes the app down. Fails the HA requirement. |
| Three AZs | ✅ Better blast-radius, but triples NAT Gateway cost (+$40/mo per extra AZ) and divides a small fleet into thinner slices. Right answer at higher scale. |
| Two AZs, shared app+data subnets | ❌ Blends failure domains and forces wider NACL/SG rules; the data tier loses its "no internet" property. |

**Why the data tier gets its own subnets:** it allows a *dedicated NACL and route table with no internet route*, meaning even a fully compromised app instance cannot make the database subnet egress to the internet. This is the network-level expression of defense in depth.

**CIDR plan:** `/16` VPC with `/24` subnets leaves huge headroom (10.0.3.0/24…10.0.10.0/24 unused) for future tiers — a message queue subnet, a management subnet, or peering expansions — without re-IP-ing anything.

---

## ADR-002 · One NAT Gateway per AZ

**Decision:** Provision two NAT Gateways (one per public subnet / AZ).

**Trade-off analysis:** A single NAT Gateway saves ~$32.78/month (hourly + data processing) but creates two problems: (1) it is a single point of failure for all outbound traffic from the app tier — if its AZ dies, `dnf install`, external API calls, and S3 uploads from *both* AZs fail; (2) cross-AZ traffic through a single NAT incurs additional data-transfer charges anyway. Two NATs align cost with the reliability goal of the project.

**Rejected alternative — NAT instance:** cheaper but self-managed (patching, failover scripting, bandwidth limits), and it defeats the "no public compute" rule since a NAT instance lives in a public subnet with a public IP.

---

## ADR-003 · ALB in public subnets, EC2 fleet in private subnets

**Decision:** Only the ALB nodes and NAT Gateways live in public subnets; every EC2 instance has **no public IP at all** (`MapPublicIpOnLaunch: false` on the app subnets).

**Rationale:** the attack surface exposed to the internet shrinks to two fully managed, DDoS-protected services (ALB + NAT). There is no SSH port to brute-force, no instance-level OS exposure, and no route from the internet to the app or data tiers. Combined with WAF at the edge, untrusted input is filtered *twice* before touching application code.

---

## ADR-004 · Target-tracking Auto Scaling on CPU (40%)

**Decision:** Scale the ASG to hold `ASGAverageCPUUtilization` at 40%, with min=2 / desired=2 / max=6.

**Why 40% (not 70%):** headroom. A scale-out takes 2–5 minutes (launch + boot + bootstrap + warm-up + health checks). At 40% target, the fleet absorbs a 2× load spike *before* new capacity joins; at 70% the same spike would saturate the fleet and users would feel latency during every scale-out event. 40% costs a little more idle capacity — that is the deliberate availability-over-cost trade of this project.

**Why not step scaling:** step scaling needs hand-tuned threshold/adjustment pairs and separate alarms; target tracking derives the needed capacity automatically and behaves symmetrically for scale-in (which we keep enabled with default cooldowns — for a stateless web tier this is safe).

**Why not scheduled scaling:** web traffic here is assumed unpredictable; scheduled actions suit known office-hours patterns.

**Health check type: `ELB`.** The ASG uses *target-group* health (not just EC2 status checks), so an instance that is running but failing `/health` is replaced automatically — covering the "zombie instance" failure mode that pure EC2 checks miss.

---

## ADR-005 · RDS MySQL Multi-AZ (not Aurora, not read replicas)

**Decision:** One `db.t3.medium` MySQL 8.0 instance with `MultiAZ: true`.

**Alternatives considered:**

| Option | Verdict |
|--------|---------|
| Single-AZ RDS | ❌ Storage or instance failure = extended outage + manual restore. Fails the DR goal. |
| Aurora MySQL | ✅ Better failover (≈30 s, up to 15 replicas), but ~20% more expensive and adds engine-specific knowledge outside this project's scope. The natural upgrade path — see below. |
| Read replica for HA | ❌ Common exam trap: *read replicas are for read scaling*, not HA — replication is **asynchronous**, failover is **manual**, and the endpoint **changes**. Multi-AZ is the correct HA primitive. |

**Key exam-relevant semantics:** Multi-AZ replicates **synchronously**, failover is **automatic (~60 s)**, the **endpoint CNAME stays the same**, and the standby is **not queryable** (it's a hot standby, not a read replica). Applications need only standard connection-retry logic.

---

## ADR-006 · CloudFront with two cache behaviors (S3 + ALB)

**Decision:** One distribution, two origins: `/static/*` → S3 (cached 24 h default, managed `CachingOptimized` policy), everything else → ALB (`CachingDisabled`, `AllViewerExceptHostHeader` origin-request policy).

**Why this split:** static content typically represents 70–90% of page weight. Serving it from 600+ edge POPs removes that load from the ALB and EC2 fleet entirely — often the single cheapest performance win available. Keeping the dynamic path *uncached* preserves session/cookie correctness while still benefiting from TLS termination at the edge and Shield protection.

**Origin Access Control (OAC), not OAI:** OAI is the legacy mechanism; OAC supports SSE-KMS buckets, IPv6, and modern signing (SigV4) — the bucket policy denies every principal except `cloudfront.amazonaws.com` with a `SourceArn` condition, so the origin is unreachable even with the bucket name leaked.

---

## ADR-007 · WAF at the edge, not on the ALB

**Decision:** Attach the WAF WebACL to CloudFront (scope `CLOUDFRONT`), not the ALB.

**Rationale:** malicious traffic is dropped at the nearest edge location — it never consumes ALB LCU capacity, cross-region data transfer, or any origin compute. The same WebACL protects both cache behaviors. (Note: a `CLOUDFRONT`-scoped ACL must be created in `us-east-1` regardless of deployment region.)

---

## ADR-008 · SSM Session Manager instead of SSH/bastion

**Decision:** No bastion host, no SSH keys, no inbound port 22. The instance role includes `AmazonSSMManagedInstanceCore`, and operators connect with `aws ssm start-session`.

**Why:** a bastion is a persistent, internet-exposed, self-managed Linux box — exactly the kind of resource this architecture tries to eliminate. Session Manager gives per-session CloudWatch/S3 logging (who did what, when), IAM-based authorization, and zero firewall holes. The trade-off — no SSM if *both* the SSM agent and its VPC endpoints/Internet path are broken — is acceptable at this scale and recoverable via EC2 serial console or instance replacement.

---

## Known limitations (deliberate, documented)

1. **Instance-level state is ephemeral** — the app tier is stateless by design; sessions must live in the database or a future ElastiCache layer.
2. **RDS failover (~60 s) is visible** — clients see brief connection errors; a connection-pool retry wrapper is the standard mitigation.
3. **Single-region deployment** — DR beyond AZ redundancy (multi-region) is out of scope; Project 5 covers it.
4. **The default ALB mode is HTTP-only** (test mode). Supply `AlbCertificateArn` for end-to-end HTTPS; CloudFront→viewer is always HTTPS regardless.
