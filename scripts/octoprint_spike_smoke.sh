#!/usr/bin/env bash
set -euo pipefail

octoprint_bin="${OCTOPRINT_BIN:-octoprint}"
port="${OCTOPRINT_SPIKE_PORT:-5017}"
spike_dir="$(mktemp -d)"
server_pid=""
api_key="$(printf '%s' "$spike_dir" | sha256sum | cut -d ' ' -f 1)"
payment_base_url="${PRINTWRIGHT_SPIKE_BASE_URL:-}"
payment_model_id="${PRINTWRIGHT_SPIKE_MODEL_ID:-0}"
payment_max_amount="${PRINTWRIGHT_SPIKE_MAX_AMOUNT:-500}"
payment_sandbox="${PRINTWRIGHT_SPIKE_SANDBOX:-false}"
payment_network="${PRINTWRIGHT_SPIKE_NETWORK:-testnet}"
payment_asset="${PRINTWRIGHT_SPIKE_ASSET:-}"
payment_hcli_path="${PRINTWRIGHT_SPIKE_HCLI_PATH:-hcli}"
payment_signer_from="${PRINTWRIGHT_SPIKE_SIGNER_FROM:-}"
expect_licensed="${PRINTWRIGHT_SPIKE_EXPECT_LICENSED:-false}"
payment_enabled=false

if [[ -n "$payment_base_url" ]]; then
  [[ "$payment_base_url" =~ ^https?://[A-Za-z0-9.:/_-]+$ ]]
  [[ "$payment_model_id" =~ ^[1-9][0-9]*$ ]]
  [[ "$payment_max_amount" =~ ^[1-9][0-9]*$ ]]
  [[ "$payment_sandbox" == "true" || "$payment_sandbox" == "false" ]]
  [[ "$payment_network" == "testnet" || "$payment_network" == "mainnet" ]]
  [[ "$payment_asset" =~ ^$|^0\.0\.[0-9]+$ ]]
  [[ "$payment_hcli_path" =~ ^[A-Za-z0-9./_-]+$ ]]
  [[ "$payment_signer_from" =~ ^$|^[A-Za-z0-9._-]+$ ]]
  payment_enabled=true
fi
if [[ "$expect_licensed" == "true" && "$payment_enabled" != "true" ]]; then
  echo "PRINTWRIGHT_SPIKE_EXPECT_LICENSED requires payment configuration" >&2
  exit 2
fi

cleanup() {
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid"
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$spike_dir"
}
trap cleanup EXIT

cat > "$spike_dir/config.yaml" <<YAML
plugins:
  virtual_printer:
    enabled: true
  printwright:
    enabled: $payment_enabled
    base_url: "$payment_base_url"
    model_id: $payment_model_id
    license_kind: "commercial_unit"
    network: "$payment_network"
    asset: "$payment_asset"
    max_amount: $payment_max_amount
    sandbox: $payment_sandbox
    hcli_path: "$payment_hcli_path"
    signer_from: "$payment_signer_from"
server:
  firstRun: false
serial:
  autoconnect: false
YAML

printf '\napi:\n  key: "%s"\n' "$api_key" >> "$spike_dir/config.yaml"

cat > "$spike_dir/licensed-part.gcode" <<'GCODE'
G28
G1 X10 Y10 Z0.2 F1200
G1 X20 Y10 E1 F600
M84
GCODE

"$octoprint_bin" serve --iknowwhatimdoing --basedir "$spike_dir" \
  --host 127.0.0.1 --port "$port" > "$spike_dir/server.log" 2>&1 &
server_pid=$!

base_url="http://127.0.0.1:$port"
for _attempt in $(seq 1 90); do
  curl -fsS -H "X-Api-Key: $api_key" "$base_url/api/version" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS -H "X-Api-Key: $api_key" "$base_url/api/version" >/dev/null
curl -fsS -H "X-Api-Key: $api_key" "$base_url/" -o "$spike_dir/ui.html"
grep -q 'Never paste a private key here' "$spike_dir/ui.html"

curl -fsS -H "Content-Type: application/json" \
  -H "X-Api-Key: $api_key" \
  -d '{"command":"connect","port":"VIRTUAL","baudrate":115200,"printerProfile":"_default","save":false,"autoconnect":false}' \
  "$base_url/api/connection" >/dev/null

for _attempt in $(seq 1 30); do
  curl -fsS -H "X-Api-Key: $api_key" "$base_url/api/connection" | grep -q 'Operational' && break
  sleep 1
done
curl -fsS -H "X-Api-Key: $api_key" "$base_url/api/connection" | grep -q 'Operational'

curl -fsS -H "X-Api-Key: $api_key" \
  -F "file=@$spike_dir/licensed-part.gcode;type=text/plain" \
  -F "select=true" -F "print=true" "$base_url/api/files/local" >/dev/null

for _attempt in $(seq 1 30); do
  grep -q 'PRINTWRIGHT_JOB_STARTED' "$spike_dir/logs/octoprint.log" 2>/dev/null && break
  sleep 1
done

event_line="$(grep 'PRINTWRIGHT_JOB_STARTED' "$spike_dir/logs/octoprint.log" | tail -1)"
test -n "$event_line"
printf '%s\n' "$event_line"

if [[ "$expect_licensed" == "true" ]]; then
  for _attempt in $(seq 1 30); do
    grep -q 'PRINTWRIGHT_LICENSED' "$spike_dir/logs/octoprint.log" 2>/dev/null && break
    sleep 1
  done
  license_line="$(grep 'PRINTWRIGHT_LICENSED' "$spike_dir/logs/octoprint.log" | tail -1 || true)"
  if [[ -z "$license_line" ]]; then
    grep 'PRINTWRIGHT_LICENSE_FAILED' "$spike_dir/logs/octoprint.log" >&2 || true
  fi
  test -n "$license_line"
  printf '%s\n' "$license_line"
fi
