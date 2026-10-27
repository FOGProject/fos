# TLS trust for the FOG server

Every FOS call to the FOG server passed `curl -k`, so FOS never checked who
answered for `$web` (fos#102). The host token, the task data and the status
reports all went to whatever server answered.

We decided **every call goes through `bin/fog.curl`, which trusts the server in
one of three modes: a public-key pin passed as `fogpin=` on the kernel command
line, the CA bundle the init now carries, or -- when neither applies -- the old
`-k` behavior with a warning.**

## The modes

| Mode | When | What curl does |
|---|---|---|
| pinned | `fogpin=` is on the command line | `-k --pinnedpubkey sha256//<pin>`. A mismatch is exit 90, and the call fails. |
| verified | no pin, and the chain verifies against `/etc/ssl/certs/ca-certificates.crt` | plain curl, chain checked |
| insecure | no pin, and the chain does not verify (curl 60) or the init has no bundle (curl 77) | `-k`, after one warning on the console |

`-k` stays in pinned mode on purpose. A FOG server's certificate is usually
signed by the CA the FOG installer generates, which no bundle carries, so the
chain check would fail on exactly the servers that pin. curl enforces
`--pinnedpubkey` under `-k`; `tests/checks/tls-trust.sh` case 3 proves it
against real curl.

`fog.curl` probes `$web` once per boot to choose between verified and
insecure, and records the answer in `/tmp/fog.tls`. A probe that fails for a
network reason records nothing, so the next call probes again. It probes
rather than retrying the failed call because a retried call prints its `-w`
output twice, and `callServer()` parses that output.

## Why the pin travels on the command line

The alternative was to write a pin file into each `init.xz` at install time.
It was rejected because it is no more secure and costs more.

- **The same channel delivers both.** iPXE downloads the init and the command
  line together. An attacker who can rewrite the command line can also replace
  the whole init, pin file included.
- **A pin in the init goes stale.** When the server's certificate rotates, an
  injected pin stops matching, and imaging fails until someone re-injects it.
  The server computes a command-line pin from its current key at each boot.
- **Injection modifies released artifacts.** `init.xz` is a 256 MiB ext4 image
  (it needs a root loop mount to change), `arm_init.cpio.gz` is a cpio, every
  init update needs the step again, and the result no longer matches the
  release's hash. One init could also carry only one server's pin.
- **A pin means nothing apart from the address it pins.** It must come from
  the same place as `web=`. If ADR-0011's boot-config redesign moves `web=`
  into a signed UKI addon, `fogpin=` moves into that addon with it.

## Why insecure is a fallback and not a refusal

An old server, or one whose boot menu does not send `fogpin=`, has to keep
imaging. The fallback opens nothing new to an attacker: whoever can strip
`fogpin=` from the command line can also rewrite `web=` and point FOS at a
server of their choosing. Refusing would break every existing self-signed
install for no gain.

## What this does not protect

The boot itself. FOS trusts the kernel, the init and the command line that
iPXE hands it, and pinning cannot change that. Protecting that channel is
iPXE's job (HTTPS with the FOG CA built in), on the server side.

A server on plain `http://` is unaffected, which is most of them today: there
is no certificate to check, so nothing changes for them.

## Consequences

- The init carries Buildroot's `ca-certificates` (about 220 KB) on all three
  arches. libcurl is already built against
  `/etc/ssl/certs/ca-certificates.crt`.
- No call site may run `curl` directly or pass `-k` to `fog.curl`.
  `tests/checks/tls-trust.sh` cases 11 and 12 enforce both.
- `callServer()` reports curl exit 90 as a pin mismatch, not as an unreachable
  server.
- The server half -- emitting `fogpin=` in the iPXE boot menu -- lives in
  FOGProject/fogproject. Until it ships, every HTTPS install runs in verified
  or insecure mode.
