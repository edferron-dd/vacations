#!/usr/bin/env bash
# Creates or updates the trip-forecast Azure Function (Flex Consumption, .NET 10 isolated) with a workspace-based
# Application Insights, deploys functions/Vacations.Forecast, smoke-tests it, and - given an instance id - hands the
# function URL and key to the EC2 host as files under C:\setup\secrets (picked up by infra/deploy-app.ps1).
#
#   ./infra/azure/deploy-forecast.sh                                   # Azure side only
#   AWS_PROFILE=ec2-demo AWS_REGION=us-east-2 ./infra/azure/deploy-forecast.sh i-09feddfcaef54e7be
#
# Requires `az login`. Everything lives in one resource group: `az group delete -n rg-vacations-forecast` removes it.
set -euo pipefail

SUBSCRIPTION="${AZ_SUBSCRIPTION:-datadog-psa-sandbox}"
LOCATION="${AZ_LOCATION:-eastus2}"
RG="${AZ_RESOURCE_GROUP:-rg-vacations-forecast}"
INSTANCE_ID="${1:-}"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

az account set --subscription "$SUBSCRIPTION"
SUB_ID=$(az account show --query id -o tsv)
# Function app and storage names are globally unique; derive a stable suffix so reruns update the same resources.
SUFFIX=$(printf '%s' "$SUB_ID/$RG" | shasum | cut -c1-6)
APP="func-vacations-forecast-$SUFFIX"
STORAGE="stvacforecast$SUFFIX"
WORKSPACE="log-vacations-forecast"
INSIGHTS="appi-vacations-forecast"
TAGS=(app=vacations-demo component=trip-forecast ts_creator=ed.ferron@datadoghq.com ts_team=psa "ts_purpose=customer demo")

echo "== Resource group $RG ($SUBSCRIPTION, $LOCATION)"
az group create -n "$RG" -l "$LOCATION" --tags "${TAGS[@]}" -o none

echo "== Log Analytics workspace + Application Insights"
az extension add --upgrade -n application-insights -y --only-show-errors
az monitor log-analytics workspace create -g "$RG" -n "$WORKSPACE" -l "$LOCATION" --retention-time 30 --tags "${TAGS[@]}" -o none
WORKSPACE_ID=$(az monitor log-analytics workspace show -g "$RG" -n "$WORKSPACE" --query id -o tsv)
az monitor app-insights component create -g "$RG" -a "$INSIGHTS" -l "$LOCATION" --workspace "$WORKSPACE_ID" \
  --application-type web --kind web --tags "${TAGS[@]}" -o none
AI_CONNECTION=$(az monitor app-insights component show -g "$RG" -a "$INSIGHTS" --query connectionString -o tsv)

echo "== Storage account $STORAGE"
az storage account create -n "$STORAGE" -g "$RG" -l "$LOCATION" --sku Standard_LRS --kind StorageV2 \
  --min-tls-version TLS1_2 --allow-blob-public-access false --tags "${TAGS[@]}" -o none

echo "== Function app $APP"
if ! az functionapp show -g "$RG" -n "$APP" -o none 2>/dev/null; then
  az functionapp create -g "$RG" -n "$APP" --storage-account "$STORAGE" --flexconsumption-location "$LOCATION" \
    --runtime dotnet-isolated --runtime-version 10 --app-insights "$INSIGHTS" --tags "${TAGS[@]}" -o none
fi
az functionapp config appsettings set -g "$RG" -n "$APP" -o none \
  --settings "APPLICATIONINSIGHTS_CONNECTION_STRING=$AI_CONNECTION"
# Azure creates the Flex plan itself, untagged; merge (not replace) so the App Insights hidden-link tag survives.
for id in $(az resource list -g "$RG" --query '[].id' -o tsv); do
  az tag update --resource-id "$id" --operation Merge --tags "${TAGS[@]}" -o none
done

echo "== Build and deploy"
dotnet publish "$REPO/functions/Vacations.Forecast/Vacations.Forecast.csproj" -c Release -o "$WORK/publish" --nologo -v quiet
(cd "$WORK/publish" && zip -qr "$WORK/forecast.zip" .)
az functionapp deployment source config-zip -g "$RG" -n "$APP" --src "$WORK/forecast.zip" -o none

# `az functionapp show` leaves defaultHostName null for Flex Consumption apps (CLI 2.74), so read the ARM resource.
BASE_URL="https://$(az resource show -g "$RG" -n "$APP" --resource-type Microsoft.Web/sites --query properties.defaultHostName -o tsv)"
# The function's key appears once the host has indexed the deployed code.
KEY=""
for _ in $(seq 1 30); do
  KEY=$(az functionapp function keys list -g "$RG" -n "$APP" --function-name Forecast --query default -o tsv 2>/dev/null || true)
  [[ -n "$KEY" ]] && break
  sleep 10
done
[[ -n "$KEY" ]] || { echo "Function 'Forecast' did not appear after deployment." >&2; exit 1; }

echo "== Smoke test"
FROM=$(date -v+3d +%F 2>/dev/null || date -d '+3 days' +%F)
TO=$(date -v+6d +%F 2>/dev/null || date -d '+6 days' +%F)
curl -sS --fail-with-body -H "x-functions-key: $KEY" \
  "$BASE_URL/api/forecast?lat=20.21&lon=-87.47&from=$FROM&to=$TO&category=BEACH&place=Quintana%20Roo,%20Mexico" \
  | python3 -c 'import json,sys; f=json.load(sys.stdin); print(f["place"], f["mode"], "|", f["summary"], "|", len(f["packing"]), "packing items")'

if [[ -n "$INSTANCE_ID" ]]; then
  echo "== Handing URL and key to $INSTANCE_ID"
  source "$REPO/infra/ssm-lib.sh"
  # The key travels as a private S3 object behind a 5-minute presigned URL (deleted afterwards),
  # so it never appears in SSM command history.
  OBJECT="s3://$ARTIFACT_BUCKET/secrets/forecast-key-$(date +%s).txt"
  printf '%s' "$KEY" | aws s3 cp - "$OBJECT" --sse AES256 --only-show-errors
  trap 'aws s3 rm "$OBJECT" --only-show-errors || true; rm -rf "$WORK"' EXIT
  KEY_URL=$(aws s3 presign "$OBJECT" --expires-in 300)
  cat > "$WORK/forecast-secrets.ps1" <<EOF
\$ErrorActionPreference = 'Stop'
\$ProgressPreference = 'SilentlyContinue'
New-Item -ItemType Directory -Force -Path C:\setup\secrets | Out-Null
Set-Content -Path C:\setup\secrets\forecast-function-url.txt -Value '$BASE_URL' -NoNewline -Encoding ASCII
Invoke-WebRequest -Uri '$KEY_URL' -OutFile C:\setup\secrets\forecast-function-key.txt -UseBasicParsing
"Wrote forecast URL and key (\$((Get-Item C:\setup\secrets\forecast-function-key.txt).Length) bytes) to C:\setup\secrets"
EOF
  ssm_run "$INSTANCE_ID" "$WORK/forecast-secrets.ps1" 300
  echo "Run infra/ship.sh $INSTANCE_ID to deploy the app with the forecast settings."
fi

echo "Function: $BASE_URL/api/forecast   Application Insights: $INSIGHTS (resource group $RG)"
