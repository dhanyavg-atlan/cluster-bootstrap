#!/usr/bin/env bash
# Task 2 — register the freshly-created cluster into Devtron.
# Runs AFTER `tofu apply`. Reads the cluster endpoint + cd-user token from tofu
# outputs and POSTs them to the Devtron orchestrator API (POST /orchestrator/cluster).
# Field names verified against devtron-labs/devtron specs/cluster/cluster-management.yaml.
set -euo pipefail

: "${DEVTRON_HOST:?set DEVTRON_HOST, e.g. devtron.example.com}"
: "${DEVTRON_API_TOKEN:?set DEVTRON_API_TOKEN (Global Configs -> API Tokens)}"
PLANE="${PLANE:-poc3}"

ENDPOINT="$(tofu output -raw cluster_endpoint)"
TOKEN="$(tofu output -raw cd_user_token)"

curl -sS -X POST "https://${DEVTRON_HOST}/orchestrator/cluster" \
  -H "token: ${DEVTRON_API_TOKEN}" \
  -H "Content-Type: application/json" \
  -d @- <<JSON
{
  "cluster_name": "${PLANE}",
  "server_url": "${ENDPOINT}",
  "config": { "bearer_token": "${TOKEN}" },
  "insecure-skip-tls-verify": true
}
JSON

echo
echo "registered ${PLANE} (${ENDPOINT}) into Devtron"
