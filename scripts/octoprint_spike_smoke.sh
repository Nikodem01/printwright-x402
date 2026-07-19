#!/usr/bin/env bash
set -euo pipefail

octoprint_bin="${OCTOPRINT_BIN:-octoprint}"
port="${OCTOPRINT_SPIKE_PORT:-5017}"
spike_dir="$(mktemp -d)"
server_pid=""
api_key="$(printf '%s' "$spike_dir" | sha256sum | cut -d ' ' -f 1)"

cleanup() {
  if [[ -n "$server_pid" ]] && kill -0 "$server_pid" 2>/dev/null; then
    kill "$server_pid"
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$spike_dir"
}
trap cleanup EXIT

cat > "$spike_dir/config.yaml" <<'YAML'
plugins:
  virtual_printer:
    enabled: true
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
