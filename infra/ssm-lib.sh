# Shared helpers for scripts that run PowerShell on the EC2 host through SSM. Source it; needs AWS_PROFILE/AWS_REGION.

ARTIFACT_BUCKET="${ARTIFACT_BUCKET:-ec2-api-demo-artifacts-439537465448}"

# ssm_run <instance-id> <script.ps1> [timeout-seconds] - runs the script, waits, prints its output, fails if it failed.
ssm_run() {
  local instance="$1" script="$2" timeout="${3:-1800}" params cmd status
  params="$(mktemp)"
  python3 -c 'import json,sys; print(json.dumps({"commands":[open(sys.argv[1]).read()],"executionTimeout":[sys.argv[2]]}))' \
    "$script" "$timeout" > "$params"
  cmd=$(aws ssm send-command --instance-ids "$instance" --document-name AWS-RunPowerShellScript \
    --parameters "file://$params" --query Command.CommandId --output text)
  rm -f "$params"
  echo "SSM command $cmd sent to $instance; waiting..."
  while true; do
    status=$(aws ssm get-command-invocation --command-id "$cmd" --instance-id "$instance" \
      --query Status --output text 2>/dev/null || echo Pending)
    case "$status" in
      Pending|InProgress|Delayed) sleep 10 ;;
      *) break ;;
    esac
  done
  aws ssm get-command-invocation --command-id "$cmd" --instance-id "$instance" \
    --query '[StandardOutputContent, StandardErrorContent]' --output text | grep -v -E '^\s*$' || true
  echo "SSM status: $status"
  [[ "$status" == "Success" ]]
}
