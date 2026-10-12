#!/bin/bash
# End-to-end tests of the VNC engine against a real TigerVNC server in Docker, using the headless vncprobe
# harness (same engine as the app). Requires Docker.
#
# Optional: also test an external server, e.g. an RSA-AES (wayvnc/TigerVNC) or macOS server:
#   EXTERNAL_HOST=10.0.0.5 EXTERNAL_PORT=5900 EXTERNAL_USER=me EXTERNAL_PASSWORD=secret scripts/integration-test.sh
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PORT=5911
CONTAINER=emvnc-integration
PASSWORD=testpass
WORK="$(mktemp -d -t emvnc-it)"
FAILURES=0

pass() { printf '  \033[32m✔\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✘\033[0m %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Building vncprobe and the test server image…"
swift build --package-path "$ROOT/Packages/EmVNCKit" --product vncprobe >/dev/null || exit 1
PROBE="$(swift build --package-path "$ROOT/Packages/EmVNCKit" --show-bin-path)/vncprobe"
docker build -q -t emvnc-test-server "$ROOT/Tests/IntegrationServer" >/dev/null || exit 1

cleanup
docker run -d --rm -p "127.0.0.1:$PORT:5901" -e VNC_PASSWORD="$PASSWORD" --name "$CONTAINER" emvnc-test-server >/dev/null || exit 1
sleep 2

in_server() { docker exec "$CONTAINER" sh -c "$1"; }

echo "TigerVNC (VNC Password authentication)"

if VNC_PASSWORD="$PASSWORD" "$PROBE" --host 127.0.0.1 --port "$PORT" --screenshot "$WORK/screen.png" 2>"$WORK/connect.log" \
   && [[ -s "$WORK/screen.png" ]] && grep -q "negotiated: VNC Password" "$WORK/connect.log"; then
    pass "connects, authenticates and captures a $(sips -g pixelWidth -g pixelHeight "$WORK/screen.png" | awk '/pixel/ {printf "%s", $2 "x"}' | sed 's/x$//') framebuffer"
else
    fail "connect with VNC password"; cat "$WORK/connect.log"
fi

if VNC_PASSWORD=wrong "$PROBE" --host 127.0.0.1 --port "$PORT" 2>"$WORK/wrong.log"; then
    fail "wrong password was accepted"
elif grep -q "\[authenticationFailed\]" "$WORK/wrong.log"; then
    pass "wrong password is reported as an authentication failure"
else
    fail "wrong password produced an unexpected error"; cat "$WORK/wrong.log"
fi

if "$PROBE" --host 127.0.0.1 --port "$PORT" --auth appleRemoteDesktop 2>"$WORK/unsupported.log"; then
    fail "unsupported method connected"
elif grep -q "\[unsupportedSecurity\]" "$WORK/unsupported.log"; then
    pass "requesting a method the server does not offer fails with an actionable message"
else
    fail "unsupported method produced an unexpected error"; cat "$WORK/unsupported.log"
fi

LINES_BEFORE=$(in_server 'wc -l < /tmp/keys.log')
VNC_PASSWORD="$PASSWORD" "$PROBE" --host 127.0.0.1 --port "$PORT" --click 100,100 --type 'Hi!é' 2>/dev/null
sleep 0.5
KEYS=$(in_server "tail -n +$((LINES_BEFORE + 1)) /tmp/keys.log" | grep -a -o 'keysym 0x[0-9a-f]*, [A-Za-z_]*' | awk '{print $3}' | tr '\n' ' ')
if [[ "$KEYS" == *" H "*" i "*"exclam"*"eacute"* ]]; then
    pass "keyboard input arrives as the right keysyms ($KEYS)"
else
    fail "keyboard input (got: $KEYS)"
fi

TEXT=$'emvnc → 遠端 ✓\nsecond line'
VNC_PASSWORD="$PASSWORD" "$PROBE" --host 127.0.0.1 --port "$PORT" --send-clipboard "$TEXT" --hold 4 2>/dev/null &
PROBE_PID=$!
sleep 2.5
REMOTE=$(in_server 'DISPLAY=:1 timeout 3 xclip -o -selection clipboard')
wait $PROBE_PID
if [[ "$REMOTE" == "$TEXT" ]]; then
    pass "clipboard local → remote (UTF-8, multi-line, Extended Clipboard)"
else
    fail "clipboard local → remote (got: $REMOTE)"
fi

VNC_PASSWORD="$PASSWORD" "$PROBE" --host 127.0.0.1 --port "$PORT" --expect-clipboard --timeout 10 2>"$WORK/clip.log" &
PROBE_PID=$!
sleep 2.5
in_server 'printf "遠端 → Mac 🚀\r\nline 2" | DISPLAY=:1 xclip -selection clipboard -loops 2 &'
wait $PROBE_PID
if grep -q 'received clipboard text: "遠端 → Mac 🚀\\nline 2"' "$WORK/clip.log"; then
    pass "clipboard remote → local (CRLF normalised to LF)"
else
    fail "clipboard remote → local"; cat "$WORK/clip.log"
fi

if [[ -n "${EXTERNAL_HOST:-}" ]]; then
    echo "External server ${EXTERNAL_HOST}:${EXTERNAL_PORT:-5900}"

    if VNC_PASSWORD="${EXTERNAL_PASSWORD:-}" "$PROBE" --host "$EXTERNAL_HOST" --port "${EXTERNAL_PORT:-5900}" \
         --user "${EXTERNAL_USER:-}" --screenshot "$WORK/external.png" 2>"$WORK/external.log"; then
        pass "$(grep -o 'negotiated: .*' "$WORK/external.log")"
    else
        fail "external server"; cat "$WORK/external.log"
    fi
fi

echo
if [[ $FAILURES -eq 0 ]]; then
    echo "All integration tests passed."
else
    echo "$FAILURES integration test(s) failed."
fi

exit $FAILURES
