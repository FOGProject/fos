#!/bin/bash
# Secure Boot enrolment helpers.
#
# Deliberately a separate library rather than more of funcs.sh: this shares no
# state, no vocabulary and no failure modes with the imaging engine, and
# funcs.sh is already ~3600 lines. Sourced only by bin/fog.enrollsb.
#
# The central constraint this file is built around (see docs/adr/0009):
# shim's MokList is a BOOT-SERVICES-ONLY variable, so the running OS cannot
# write it -- only MokManager, in boot services, can promote MokNew into
# MokList, and it demands the one-time password as proof of physical presence.
# So nothing here "enrols a MOK". It STAGES a request that a human then
# confirms at the MokManager screen. Fully automatic enrolment is the db path
# (Setup Mode), which is Phase 2 and lands beside this.

# The EFI global variable namespace. SetupMode, SecureBoot, PK, KEK and db all
# live under it; efivarfs names entries "<Name>-<guid>".
sbEfiGlobalGuid="8be4df61-93ca-11d2-aa0d-00e098032b8c"
sbEfiVarDir="/sys/firmware/efi/efivars"

# Mount efivarfs if it is not already up.
#
# fstab covers the normal case, but this is cheap insurance and it is also what
# makes the difference between "this machine has no EFI variables" and "this
# init forgot to mount them" diagnosable. A BIOS-booted client has no
# /sys/firmware/efi at all and returns 1 here -- that is not an error, it is
# the answer.
#
# Returns 0 when EFI variables are readable, 1 when the machine is not UEFI,
# 2 when it is UEFI but efivarfs could not be mounted.
sbEnsureEfiVars() {
    [[ -d /sys/firmware/efi ]] || return 1
    grep -q " ${sbEfiVarDir} efivarfs " /proc/mounts 2>/dev/null && return 0
    mkdir -p "$sbEfiVarDir" >/dev/null 2>&1
    mount -t efivarfs efivarfs "$sbEfiVarDir" >/dev/null 2>&1
    grep -q " ${sbEfiVarDir} efivarfs " /proc/mounts 2>/dev/null && return 0
    return 2
}
# Read a one-byte EFI global variable and echo its value.
#
# efivarfs entries are a 4-byte little-endian attribute mask followed by the
# variable data, so the payload of a boolean flag like SetupMode is byte 5.
# Echoes nothing and returns 1 if the variable does not exist -- firmware is
# not required to expose every variable, and an absent SetupMode is a real
# state, not a failure.
#
# $1 the variable name, e.g. SetupMode
sbEfiFlag() {
    local name="$1"
    [[ -z $name ]] && handleError "No variable name passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local path="${sbEfiVarDir}/${name}-${sbEfiGlobalGuid}"
    [[ -r $path ]] || return 1
    od -An -tu1 -j4 -N1 "$path" 2>/dev/null | tr -d '[:space:]'
}
# Echo this machine's Secure Boot posture as a single word.
#
# The four answers drive everything downstream, so they are named rather than
# left as a pair of flags a caller has to re-derive:
#
#   nonefi    BIOS/CSM boot -- Secure Boot is not a concept here
#   noefivars UEFI, but the variables are unreadable (efivarfs would not mount)
#   setup     Setup Mode: PK absent, db/KEK/PK are writable without a signature.
#             This is the state the automatic db path (Phase 2) needs.
#   enforcing User Mode with Secure Boot ON
#   disabled  User Mode with Secure Boot OFF
#
# Note that "disabled" does NOT mean db is writable: db/KEK/PK are
# authenticated variables and their write policy is enforced from the presence
# of a PK, not from whether Secure Boot enforcement is switched on. Turning
# Secure Boot off in firmware buys nothing here. Only Setup Mode does.
sbState() {
    local setup="" sb=""
    sbEnsureEfiVars
    case $? in
        1) echo "nonefi"; return 0 ;;
        2) echo "noefivars"; return 0 ;;
    esac
    setup=$(sbEfiFlag SetupMode)
    sb=$(sbEfiFlag SecureBoot)
    [[ $setup == 1 ]] && { echo "setup"; return 0; }
    [[ $sb == 1 ]] && { echo "enforcing"; return 0; }
    echo "disabled"
}
# Download the server's Secure Boot certificate to $1.
#
# The certificate is public by design -- it is the thing the server publishes
# for exactly this purpose -- so there is nothing sensitive in transit here.
# The check that matters is the fingerprint comparison the caller does next,
# not the transport.
#
# $1 destination path
sbFetchCert() {
    local dest="$1"
    [[ -z $dest ]] && handleError "No destination passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $web ]] && handleError "No web root known, cannot fetch the certificate (${FUNCNAME[0]})"
    rm -f "$dest" >/dev/null 2>&1
    curl -Lks -o "$dest" "${web}service/secureboot/MOK.der" >/dev/null 2>&1
    # A 404 still writes a file, so existence proves nothing. DER certificates
    # start with an ASN.1 SEQUENCE tag (0x30); an HTML error page does not.
    [[ -s $dest ]] || return 1
    [[ $(od -An -tx1 -N1 "$dest" 2>/dev/null | tr -d '[:space:]') == 30 ]] || return 1
    return 0
}
# Echo the SHA-256 of a DER certificate, uppercase and colon-separated.
#
# The SHA-256 of the DER bytes IS the certificate fingerprint, so no openssl
# round trip is needed -- which matters because FOS builds libopenssl without
# the openssl CLI (BR2_PACKAGE_LIBOPENSSL_BIN is not set). This is the same
# value the server's Secure Boot page prints from hash_file('sha256').
#
# $1 path to the DER certificate
sbCertFingerprint() {
    local cert="$1"
    [[ -z $cert ]] && handleError "No certificate passed (${FUNCNAME[0]})\n   Args Passed: $*"
    sha256sum "$cert" 2>/dev/null | awk '{print toupper($1)}' | sed 's/../&:/g;s/:$//'
}
# Return 0 if the certificate is already trusted by this machine.
#
# Checks the MOK list and db both: a machine that went through the Phase 2 db
# path has the key in db and no MOK entry at all, and staging a MOK request on
# it would send a technician to a blue screen for no reason.
#
# $1 path to the DER certificate
sbCertTrusted() {
    local cert="$1"
    [[ -z $cert ]] && handleError "No certificate passed (${FUNCNAME[0]})\n   Args Passed: $*"
    mokutil --test-key "$cert" 2>/dev/null | grep -qi "already enrolled" && return 0
    mokutil --db 2>/dev/null | grep -qiF "$(sbCertFingerprint "$cert" | tr -d ':')" && return 0
    return 1
}
# Stage a MOK enrolment request, without prompting.
#
# mokutil normally reads the one-time password from the terminal, which is
# useless in a task. --generate-hash=<pw> prints the SHA-512 crypt string
# non-interactively, and --import --hash-file consumes it: update_request() in
# mokutil takes the hash-file branch and never reaches get_password(). Both are
# documented options, not a piping trick -- verified against mokutil 0.7.2,
# which is what Buildroot builds.
#
# The password is NOT a secret. It authenticates nothing at rest; it exists so
# that whoever answers MokManager after the reboot is demonstrably the same
# person who asked for the enrolment. It therefore has to be shown to the
# technician, which is the caller's job.
#
# $1 path to the DER certificate
# $2 the one-time password
sbStageMok() {
    local cert="$1"
    local password="$2"
    local hashfile="/tmp/.mokpwhash"
    [[ -z $cert ]] && handleError "No certificate passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $password ]] && handleError "No password passed (${FUNCNAME[0]})\n   Args Passed: $*"
    rm -f "$hashfile" >/dev/null 2>&1
    if ! mokutil --generate-hash="$password" > "$hashfile" 2>/dev/null; then
        rm -f "$hashfile" >/dev/null 2>&1
        return 1
    fi
    # An empty or truncated hash file makes mokutil fail later with "Failed to
    # parse the string", by which point it has already been handed to the
    # variable write. Catch it here where the message can still be useful.
    if [[ ! -s $hashfile ]] || ! grep -q '^\$6\$' "$hashfile"; then
        rm -f "$hashfile" >/dev/null 2>&1
        return 1
    fi
    if ! mokutil --import "$cert" --hash-file "$hashfile" >/dev/null 2>&1; then
        rm -f "$hashfile" >/dev/null 2>&1
        return 1
    fi
    rm -f "$hashfile" >/dev/null 2>&1
    # mokutil exits 0 having written nothing in some failure paths, so confirm
    # the request actually landed rather than trusting the status. A staged
    # request that silently did not stage sends a technician to reboot a
    # machine that will boot straight past MokManager with no explanation.
    mokutil --list-new 2>/dev/null | grep -q . || return 1
    return 0
}
# Echo a one-time password for the MOK request.
#
# $sbmokpw lets an admin set one password for a whole fleet, which is the
# difference between a technician typing the same six characters down a row of
# machines and reading a different random string off each screen. Falling back
# to a random one keeps the task working when it is not set, at the cost of
# that convenience.
sbMokPassword() {
    if [[ -n $sbmokpw ]]; then
        echo "$sbmokpw"
        return 0
    fi
    # Deliberately short and unambiguous: this gets typed by hand, once, at a
    # firmware prompt with no clipboard, and it protects nothing at rest.
    tr -dc 'A-HJ-NP-Z2-9' < /dev/urandom 2>/dev/null | head -c 8
}
