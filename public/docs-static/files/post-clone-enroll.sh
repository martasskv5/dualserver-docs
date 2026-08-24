#!/bin/bash
set -euo pipefail
AUTHENTIK_URL="${1:-}"
ENROLLMENT_TOKEN="${2:-}"
DEPLOYMENT_NAME="${3:-$(hostname)}"

if [[ -z "$AUTHENTIK_URL" || -z "$ENROLLMENT_TOKEN" ]]; then
    echo "Usage: $0 <authentik_url> <enrollment_token> [deployment_name]"
    exit 1
fi

systemctl start authentik-sysd
sleep 2

ak-sysd domains join "$DEPLOYMENT_NAME" \
    --authentik-url "$AUTHENTIK_URL" \
    --token "$ENROLLMENT_TOKEN"

systemctl restart ssh