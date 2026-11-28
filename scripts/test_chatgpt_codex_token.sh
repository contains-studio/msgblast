#!/bin/bash
# Runs the installed `codex app-server` with Connect with ChatGPT's launch config against the actual token
# listener and helper command, with a fixture account and a local stand-in for api.openai.com. It checks
# that Codex runs the helper and sends its token, and that ~/.codex is not used. No request leaves this Mac.
set -euo pipefail
root="$(cd -- "$(dirname -- "$0")/.." && pwd)"
frameworks="${1:-$root/build/contributor-tests}/Build/Products/Debug"
if [[ ! -d "$frameworks/msgblastCore.framework" ]]; then
    echo "Build msgblast in the selected derived-data directory before running this check." >&2
    exit 1
fi
command -v codex >/dev/null || { echo "Install the Codex CLI to run this check." >&2; exit 1; }
frameworks="$(cd -- "$frameworks" && pwd)"
# A short folder, because a Unix socket path is limited to 104 bytes.
tmp="$(mktemp -d /tmp/msgblast-chatgpt.XXXXXX)"
trap 'kill "${fixture:-}" 2>/dev/null && wait "$fixture" 2>/dev/null; rm -rf "$tmp"' EXIT
xcrun swiftc -swift-version 6 -parse-as-library -module-cache-path "$tmp/module-cache" \
    -target "$(uname -m)-apple-macos15.0" -I "$frameworks" -F "$frameworks" -framework msgblastCore \
    -Xlinker -rpath -Xlinker "$frameworks" \
    "$root/msgblast/App/ChatGPTTokenListener.swift" "$root/scripts/fixtures/chatgpt_codex_token.swift" -o "$tmp/msgblast"
export CHATGPT_FIXTURE_SUPPORT="$tmp/support"
mkdir -p "$CHATGPT_FIXTURE_SUPPORT"
"$tmp/msgblast" > "$tmp/launch.json" &
fixture=$!
for _ in $(seq 50); do [[ -s "$tmp/launch.json" ]] && break; sleep 0.1; done

if "$tmp/msgblast" __chatgpt-token oaiapp_other 2> "$tmp/other.txt"; then echo "FAIL: another account got a token" >&2; exit 1; fi
grep -q "connection changed" "$tmp/other.txt"
[[ "$(stat -f %Lp "$CHATGPT_FIXTURE_SUPPORT/chatgpt")" == 700 ]]

/usr/bin/python3 - "$tmp/launch.json" <<'PY'
import http.server, json, os, subprocess, sys, threading, time
launch = json.load(open(sys.argv[1]))
seen = []
class Stand_in(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        seen.append((self.path, self.headers.get("Authorization")))
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(b'{"models":[]}')
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Stand_in)
threading.Thread(target=server.serve_forever, daemon=True).start()
base = "http://127.0.0.1:%d/v1" % server.server_address[1]
config = [value.replace("https://api.openai.com/v1", base) for value in launch["launchConfig"]]
env = {k: v for k, v in os.environ.items() if k not in ("OPENAI_API_KEY", "OPENAI_BASE_URL")}
env["CODEX_HOME"] = launch["codexHome"]
codex = subprocess.Popen(["codex", "app-server"] + sum([["-c", value] for value in config], []), cwd=launch["codexHome"],
                         stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)
for message in [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"clientInfo": {"name": "msgblast", "title": "msgblast", "version": "0"}}},
                {"jsonrpc": "2.0", "method": "initialized"}, {"jsonrpc": "2.0", "id": 2, "method": "model/list", "params": {}}]:
    codex.stdin.write((json.dumps(message) + "\n").encode()); codex.stdin.flush()
deadline = time.time() + 20
while not seen and time.time() < deadline: time.sleep(0.2)
codex.kill()
assert seen, "Codex never asked the stand-in for models"
assert all(path.startswith("/v1/models") and auth == "Bearer fixture-access-token" for path, auth in seen), seen
assert launch["codexHome"].startswith(os.environ["CHATGPT_FIXTURE_SUPPORT"]), launch["codexHome"]
print("Codex sent the fixture token from msgblast __chatgpt-token on %d model request(s); CODEX_HOME was the support folder." % len(seen))
PY
