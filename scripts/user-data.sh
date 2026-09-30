#!/bin/bash
# ============================================================================
# EC2 user-data bootstrap — SAA-C03 Project 1 (Scalable Web App)
# ----------------------------------------------------------------------------
# Runs as root on first launch of every instance in the Auto Scaling group.
# Installs nginx, exposes the app on :8080 (the port the App Security Group
# allows from the ALB Security Group), and creates the /health endpoint the
# ALB target group polls every 15 seconds.
#
# The same script is embedded (Base64) in the CloudFormation launch template;
# this copy exists for review, testing, and customization.
# ============================================================================

set -euxo pipefail

# ── 1. Web server ───────────────────────────────────────────────────────────
dnf install -y nginx
systemctl enable --now nginx

# ── 2. Health endpoint (ALB target group checks GET /health) ────────────────
mkdir -p /usr/share/nginx/html
cat > /usr/share/nginx/html/health <<'EOF'
{"status":"ok"}
EOF

# ── 3. Landing page (proves end-to-end path through CloudFront → ALB) ──────
cat > /usr/share/nginx/html/index.html <<EOF
<html><head><title>SAA-C03 Project 1</title></head>
<body style="font-family:sans-serif;text-align:center;padding-top:60px">
<h1>Scalable Web App &mdash; it works!</h1>
<p>Instance: $(hostname -f)</p>
<p>Served via CloudFront &rarr; ALB &rarr; Auto Scaling Group</p>
</body></html>
EOF

# ── 4. App listener on :8080 (allowed by AppSecurityGroup from ALB-SG only) ─
cat > /etc/nginx/default.d/8080.conf <<'EOF'
server {
    listen 8080;
    location / {
        root /usr/share/nginx/html;
        index index.html;
    }
    location = /health {
        return 200 '{"status":"ok"}';
        add_header Content-Type application/json;
    }
}
EOF

systemctl restart nginx

# ── 5. CloudWatch agent (optional but recommended) ──────────────────────────
dnf install -y amazon-cloudwatch-agent
# The instance role carries CloudWatchAgentServerPolicy, so the agent can
# publish memory/disk metrics that EC2 does not report by default.
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json <<'EOF'
{
  "metrics": {
    "namespace": "Project1/WebTier",
    "metrics_collected": {
      "mem": { "measurement": ["mem_used_percent"] },
      "disk": { "measurement": ["used_percent"], "resources": ["/"] }
    }
  }
}
EOF
systemctl enable --now amazon-cloudwatch-agent

echo "Bootstrap complete."
