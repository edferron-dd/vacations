#!/usr/bin/env bash
# Runs provision-ec2.ps1 on a Windows EC2 instance via SSM Run Command and waits for it to finish.
# Usage: AWS_REGION=us-east-1 ./infra/deploy.sh i-0123456789abcdef0
set -euo pipefail

INSTANCE_ID="${1:?usage: $0 <instance-id>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PARAMS="$(mktemp)"
trap 'rm -f "$PARAMS"' EXIT

ping=$(aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[0].PingStatus' --output text)
if [[ "$ping" != "Online" ]]; then
  echo "Instance $INSTANCE_ID is not registered/online in SSM (status: $ping)." >&2
  echo "Attach an instance profile with AmazonSSMManagedInstanceCore and ensure outbound HTTPS." >&2
  exit 1
fi

python3 -c 'import json,sys; print(json.dumps({"commands":[open(sys.argv[1]).read()],"executionTimeout":["7200"]}))' \
  "$SCRIPT_DIR/provision-ec2.ps1" > "$PARAMS"

CMD_ID=$(aws ssm send-command \
  --instance-ids "$INSTANCE_ID" \
  --document-name AWS-RunPowerShellScript \
  --comment "Provision reservations demo host" \
  --parameters "file://$PARAMS" \
  --query Command.CommandId --output text)
echo "SSM command $CMD_ID sent. Oracle XE alone can take 15-40 min; polling every 60s..."

while true; do
  status=$(aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
    --query Status --output text 2>/dev/null || echo Pending)
  echo "$(date +%H:%M:%S) $status"
  case "$status" in
    Pending|InProgress|Delayed) sleep 60 ;;
    *) break ;;
  esac
done

aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$INSTANCE_ID" \
  --query '[StandardOutputContent, StandardErrorContent]' --output text
[[ "$status" == "Success" ]]
