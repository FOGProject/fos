#!/bin/bash
#
# Assertion harness for fog.curl, the TLS trust decision on every FOS call to
# the FOG server (fos#102, docs/adr/0020).
#
#   tests/checks/tls-trust.sh
#
# Every call site used to pass curl -k, so FOS talked to whatever answered for
# $web. fog.curl now picks pinned, verified or insecure. A stub curl cannot
# prove any of that, because the thing under test is what real curl does with
# a real certificate. So this runs the shipped fog.curl against real curl and
# a local HTTPS server, with a throwaway CA and server key made for each run.
#
# Needs openssl and python3 on the host. No root, no network beyond 127.0.0.1.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HERE/../../Buildroot/board/FOG/FOS/rootfs_overlay/bin"
LIB="$HERE/../../Buildroot/board/FOG/FOS/rootfs_overlay/usr/share/fog/lib"
INITD="$HERE/../../Buildroot/board/FOG/FOS/rootfs_overlay/etc/init.d"
[[ -f $BIN/fog.curl ]] || { echo "ERROR: cannot find fog.curl under $BIN" >&2; exit 2; }
for t in openssl python3 curl; do
    command -v "$t" >/dev/null || { echo "ERROR: $t is required" >&2; exit 2; }
done

SANDBOX=$(mktemp -d)
SERVER_PID=""
cleanup() {
    [[ -n $SERVER_PID ]] && kill "$SERVER_PID" 2>/dev/null
    rm -rf "$SANDBOX"
}
trap cleanup EXIT

sed "s#^statefile=.*#statefile=\"$SANDBOX/fog.tls\"#" "$BIN/fog.curl" > "$SANDBOX/fog.curl"
chmod +x "$SANDBOX/fog.curl"

# A CA, a server certificate it signs for 127.0.0.1, and a second CA that
# signs nothing. The second one is the bundle of a machine that does not
# trust this server -- the FOG-installer-CA case.
(
    cd "$SANDBOX" || exit 1
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=test-ca \
        -keyout ca.key -out ca.pem
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=other-ca \
        -keyout other.key -out other.pem
    openssl req -newkey rsa:2048 -nodes -subj /CN=127.0.0.1 \
        -keyout srv.key -out srv.csr
    printf 'subjectAltName=IP:127.0.0.1\n' > srv.ext
    openssl x509 -req -in srv.csr -CA ca.pem -CAkey ca.key -CAcreateserial \
        -days 1 -extfile srv.ext -out srv.pem
) >/dev/null 2>&1 || { echo "ERROR: could not generate test certificates" >&2; exit 2; }

# The pin, computed the way the server computes it: SHA-256 of the DER
# SubjectPublicKeyInfo, base64. This is also what curl --pinnedpubkey wants.
PIN=$(openssl x509 -in "$SANDBOX/srv.pem" -pubkey -noout \
    | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64)
OTHERPIN=$(openssl x509 -in "$SANDBOX/other.pem" -pubkey -noout \
    | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64)

cat > "$SANDBOX/server.py" <<'EOF'
import http.server, ssl, sys
class H(http.server.BaseHTTPRequestHandler):
    def reply(self):
        n = int(self.headers.get('Content-Length') or 0)
        if n:
            self.rfile.read(n)
        self.send_response(200)
        self.send_header('Content-Length', '2')
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(b'ok')
    do_GET = do_POST = do_HEAD = reply
    def log_message(self, *a):
        pass
srv = http.server.HTTPServer(('127.0.0.1', 0), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(sys.argv[1], sys.argv[2])
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
open(sys.argv[3], 'w').write(str(srv.server_address[1]))
srv.serve_forever()
EOF
python3 -I "$SANDBOX/server.py" "$SANDBOX/srv.pem" "$SANDBOX/srv.key" "$SANDBOX/port" 2>/dev/null &
SERVER_PID=$!
for _ in $(seq 50); do [[ -s $SANDBOX/port ]] && break; sleep 0.1; done
[[ -s $SANDBOX/port ]] || { echo "ERROR: the test HTTPS server did not start" >&2; exit 2; }
WEB="https://127.0.0.1:$(cat "$SANDBOX/port")/fog/"
# A port nothing listens on: the network-failure case.
DEAD="https://127.0.0.1:1/fog/"

pass=0
fail=0
note() {
    if [[ -z $2 ]]; then
        echo "PASS: $1"
        pass=$((pass + 1))
    else
        echo "FAIL: $1 ($2)"
        fail=$((fail + 1))
    fi
}

# run <bundle> <fogpin> <web> -- runs fog.curl as a call site does, with the
# state file as it stands. Sets rc, out and err.
run() {
    local bundle="$1" pin="$2" web="$3"
    shift 3
    out=$(CURL_CA_BUNDLE="$bundle" fogpin="$pin" web="$web" \
        "$SANDBOX/fog.curl" -Ls "$@" "${web}service/hostinfo.php" 2>"$SANDBOX/err")
    rc=$?
    err=$(cat "$SANDBOX/err")
}
state() { cat "$SANDBOX/fog.tls" 2>/dev/null; }
reset() { rm -f "$SANDBOX/fog.tls"; }

# --- pinned ---------------------------------------------------------------
reset
run "$SANDBOX/other.pem" "$PIN" "$WEB"
e=""
[[ $rc -eq 0 && $out == ok ]] || e="rc=$rc out='$out'"
note "1. a matching pin connects to a server no bundle trusts" "$e"
e=""
[[ -z $(state) ]] || e="state='$(state)'"
note "1b. ... and the pinned path records no verified/insecure state" "$e"

reset
run "$SANDBOX/other.pem" "${PIN%=}" "$WEB"
e=""
[[ $rc -eq 0 && $out == ok ]] || e="rc=$rc out='$out'"
note "2. the pin works without its = padding, as the cmdline parser exports it" "$e"

reset
run "$SANDBOX/ca.pem" "$OTHERPIN" "$WEB"
e=""
[[ $rc -eq 90 ]] || e="rc=$rc, want 90"
[[ -z $out ]] || e="$e; a body came back: '$out'"
[[ $err == *fogpin=* ]] || e="$e; the refusal does not name fogpin="
note "3. a wrong pin refuses, even when the bundle trusts the server" "$e"

reset
run "$SANDBOX/other.pem" "$PIN" "$WEB" --data "hosttoken=secret"
e=""
[[ $rc -eq 0 && $out == ok ]] || e="rc=$rc out='$out'"
note "4. a pinned POST carries its data" "$e"

# --- verified -------------------------------------------------------------
reset
run "$SANDBOX/ca.pem" "" "$WEB"
e=""
[[ $rc -eq 0 && $out == ok ]] || e="rc=$rc out='$out'"
[[ $(state) == verified ]] || e="$e; state='$(state)'"
[[ -z $err ]] || e="$e; warned: $err"
note "5. no pin, trusted chain: verifies, records verified, says nothing" "$e"

# The state says verified and the chain does not verify: if fog.curl were
# still passing -k this would succeed.
run "$SANDBOX/other.pem" "" "$WEB"
e=""
[[ $rc -eq 60 ]] || e="rc=$rc, want 60"
note "6. verified mode really checks the chain (no -k)" "$e"

# --- insecure fallback ----------------------------------------------------
reset
run "$SANDBOX/other.pem" "" "$WEB"
e=""
[[ $rc -eq 0 && $out == ok ]] || e="rc=$rc out='$out'"
[[ $(state) == insecure ]] || e="$e; state='$(state)'"
[[ $err == *WARNING*"$WEB"* ]] || e="$e; no warning naming the server"
note "7. no pin, untrusted chain: warns, falls back to -k, still works" "$e"
run "$SANDBOX/other.pem" "" "$WEB"
e=""
[[ $rc -eq 0 && $out == ok ]] || e="rc=$rc out='$out'"
[[ -z $err ]] || e="$e; warned again: $err"
note "7b. the warning is printed once per boot, not once per call" "$e"

reset
run "$SANDBOX/no-such-bundle.pem" "" "$WEB"
e=""
[[ $rc -eq 0 && $out == ok ]] || e="rc=$rc out='$out'"
[[ $(state) == insecure ]] || e="$e; state='$(state)'"
note "8. an init with no CA bundle falls back the same way" "$e"

# --- what is not a trust answer -------------------------------------------
reset
run "$SANDBOX/ca.pem" "" "$DEAD"
e=""
[[ $rc -ne 0 ]] || e="rc=0 against a closed port"
[[ -z $(state) ]] || e="$e; recorded '$(state)' from a network failure"
[[ -z $err ]] || e="$e; warned: $err"
note "9. a network failure records nothing, so the next call probes again" "$e"

# callServer turns curl's 90 into a reason a person can act on.
e=""
grep -q 'rc -eq 90' "$LIB/funcs.sh" || e="callServer has no case for curl exit 90"
note "10. callServer names a pin mismatch" "$e"

# --- every call site goes through fog.curl ---------------------------------
# Any curl invocation outside fog.curl itself bypasses the trust decision.
raw=$(grep -rnE '(^|[^.[:alnum:]_])curl[[:space:]]+-' "$BIN" "$LIB" "$INITD" \
    | grep -v '/fog\.curl:' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')
e=""
[[ -z $raw ]] || e="raw curl at: $(echo "$raw" | cut -d: -f1,2 | tr '\n' ' ')"
note "11. no call site runs curl directly" "$e"

# A call site that hands fog.curl its own -k turns verified mode off for that
# call, and fog.curl cannot tell.
insecure=$(grep -rnE '(^|[^[:alnum:]_])fog\.curl[[:space:]]+(-[A-Za-z]*k|.*[[:space:]]-[A-Za-z]*k[[:space:]]|.*--insecure)' \
    "$BIN" "$LIB" "$INITD" | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')
e=""
[[ -z $insecure ]] || e="-k passed at: $(echo "$insecure" | cut -d: -f1,2 | tr '\n' ' ')"
note "12. no call site passes -k to fog.curl" "$e"

echo
echo "passed: $pass   failed: $fail"
[[ $fail -eq 0 ]]
