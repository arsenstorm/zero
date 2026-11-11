#!/bin/bash
# release.yml's notarisation: submits $1 with notarytool and the App Store Connect API key (API_KEY, API_KEY_ID,
# API_ISSUER_ID), waits, prints Apple's log if it's refused, then staples the ticket to $2 and checks it.
set -euo pipefail
key="$RUNNER_TEMP/AuthKey.p8"
base64 --decode <<<"$API_KEY" > "$key"
auth=(--key "$key" --key-id "$API_KEY_ID" --issuer "$API_ISSUER_ID")
result=$(xcrun notarytool submit "$1" "${auth[@]}" --wait --timeout 1h --output-format json || true)
status=$(jq -r '.status // empty' <<<"$result" 2>/dev/null || true)
if [ "$status" != Accepted ]; then
  echo "::error::Notarisation of $1 ended as '${status:-no result}'"
  id=$(jq -r '.id // empty' <<<"$result" 2>/dev/null || true)
  [ -z "$id" ] || xcrun notarytool log "$id" "${auth[@]}"
  exit 1
fi
xcrun stapler staple "$2"
xcrun stapler validate "$2"
