#!/usr/bin/env bash
# Ships this repo to the EC2 host and redeploys: zip -> private S3 bucket -> short-lived presigned URL -> SSM,
# which unpacks to C:\apps\src\ec2-api-demo, applies the idempotent DB migrations and runs infra\deploy-app.ps1.
# Usage: AWS_PROFILE=ec2-demo AWS_REGION=us-east-2 ./infra/ship.sh i-09feddfcaef54e7be
set -euo pipefail

INSTANCE_ID="${1:?usage: $0 <instance-id>}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
source "$REPO/infra/ssm-lib.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

(cd "$REPO" && zip -qr "$WORK/app.zip" . -x '*/bin/*' '*/obj/*' '*/.venv/*' '*__pycache__*' '*.env' '*.DS_Store' \
  '.claude/*' 'functions/*/local.settings.json')
aws s3 cp "$WORK/app.zip" "s3://$ARTIFACT_BUCKET/app.zip" --only-show-errors
URL=$(aws s3 presign "s3://$ARTIFACT_BUCKET/app.zip" --expires-in 900)

cat > "$WORK/ship.ps1" <<EOF
\$ErrorActionPreference = 'Stop'
\$ProgressPreference = 'SilentlyContinue'
\$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine')
\$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
\$src = 'C:\apps\src\ec2-api-demo'
New-Item -ItemType Directory -Force -Path C:\setup\downloads | Out-Null
Invoke-WebRequest -Uri '$URL' -OutFile C:\setup\downloads\app.zip -UseBasicParsing
Remove-Item \$src -Recurse -Force -ErrorAction SilentlyContinue
Expand-Archive C:\setup\downloads\app.zip -DestinationPath \$src -Force
Get-ChildItem \$src -Recurse -File | Unblock-File
& "\$src\db\setup-db.ps1"
& "\$src\infra\deploy-app.ps1"
EOF
ssm_run "$INSTANCE_ID" "$WORK/ship.ps1" 1800
