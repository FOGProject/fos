#!/bin/bash
# Secure Boot enrollment helpers.
#
# Deliberately a separate library rather than more of funcs.sh: this shares no
# state, no vocabulary and no failure modes with the imaging engine, and
# funcs.sh is already ~3600 lines. Sourced by bin/fog.enrollsb,
# bin/fog.enrollsbforce and the two registration scripts.
#
# The central constraint this file is built around (see docs/adr/0009):
# shim's MokList is a BOOT-SERVICES-ONLY variable, so the running OS cannot
# write it -- only MokManager, in boot services, can promote MokNew into
# MokList, and it demands the one-time password as proof of physical presence.
# So nothing here "enrolls a MOK". It STAGES a request that a human then
# confirms at the MokManager screen. Fully automatic enrollment is the db path
# (Setup Mode), which is Phase 2 and lands beside this.

# The EFI global variable namespace. SetupMode, SecureBoot, PK and KEK live
# under it; efivarfs names entries "<Name>-<guid>".
sbEfiGlobalGuid="8be4df61-93ca-11d2-aa0d-00e098032b8c"
# db and dbx live in their own namespace (EFI_IMAGE_SECURITY_DATABASE_GUID), NOT
# the global one. Writing "db" under the global GUID creates a junk variable
# that firmware ignores and reports success doing it, so the two are kept as
# separate constants rather than one default with an exception.
sbEfiSecurityGuid="d719b2cb-3d3a-4596-a3bc-dad00e67656f"
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
# Echo the width of the UEFI firmware in bits: "32", "64" or "unknown".
#
# This is FIRMWARE width, not CPU width, and the distinction is the whole point:
# ia32 UEFI overwhelmingly runs on 64-bit CPUs (Bay Trail and Cherry Trail
# tablets are the common case), so `uname -m` answers a different question and
# answers this one wrongly. fw_platform_size is the firmware's own declaration.
#
# Why FOS cares at all: no Microsoft-signed 32-bit shim and no signed 32-bit
# iPXE exist, so there is no Secure Boot chain an ia32 machine can boot. See the
# refusal in bin/fog.enrollsb for what that means for enrollment.
#
# The kernel has exposed fw_platform_size on every EFI boot since 4.14 and FOS
# runs 6.x, so on UEFI it is always readable. "unknown" therefore means a BIOS
# boot -- which sbState() has already caught by the time anything asks -- or
# something unforeseen. Callers should proceed on "unknown" rather than refuse:
# guessing wrong in that direction breaks x86-64 clients, which is the far more
# expensive mistake.
sbPlatformBits() {
    local path="/sys/firmware/efi/fw_platform_size"
    local bits=""
    # The readability test is what keeps a BIOS boot quiet. Reading a missing
    # file leaves $bits empty and would reach "unknown" through the wildcard
    # below anyway, but bash writes "No such file or directory" to stderr on the
    # way -- and on a BIOS-booted client that is a scary-looking line under a
    # task that is behaving correctly.
    [[ -r $path ]] || { echo "unknown"; return 0; }
    read -r bits < "$path"
    case $bits in
        32|64) echo "$bits" ;;
        *) echo "unknown" ;;
    esac
    return 0
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
    fog.curl -Ls -o "$dest" "${web}service/secureboot/MOK.der" >/dev/null 2>&1
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
# Tell the server what this enrollment actually did.
#
# WHY THIS IS NOT INFERRED FROM THE TASK COMPLETING
#
# fog.enrollsb has three exits and every one of them ends with the same
# argument-free `. /bin/fog.nonimgcomplete`, so from the server all three look
# identical: the task completed. They are not remotely the same thing.
#
#   db       the machine was in Setup Mode, `db` was written, it IS enrolled
#   trusted  it already trusted this certificate; nothing was enrolled, but the
#            trust is real and is worth recording
#   mok      a request was STAGED. The machine is NOT enrolled and will not
#            boot with Secure Boot on until a human confirms it at MokManager
#
# Recording the third as an enrollment is a lie an administrator acts on: they
# turn Secure Boot on in firmware and the machine stops booting. So the outcome
# is reported by the only party that knows it, which is this one.
#
# Best-effort by design. A server too old to have the endpoint answers 404 and
# a server that never hears us changes nothing -- in both cases the enrollment
# itself already happened and the task must still complete. So this NEVER calls
# handleError and never fails the task; it says what it did and moves on. The
# record is a convenience for the administrator, not a step in the enrollment.
#
# $1 the result: db, trusted or mok
# $2 the certificate's SHA-256 fingerprint
sbReport() {
    local result="$1"
    local cert="$2"
    local mactosend="${mac}"
    [[ -z $result || -z $cert ]] && return 0
    [[ -z $web ]] && return 0
    [[ -z $mactosend ]] && return 0
    # sbState() again rather than a value cached from the top of the task: the
    # db path CHANGES the state it is reporting -- writing the PK is what
    # leaves Setup Mode -- so the state at the end is the one that describes
    # the machine the administrator will next look at.
    callServer "${web}service/secureboot.report.php" \
        "mac=${mactosend}&result=${result}&cert=${cert}&sbstate=$(sbState)"
    [[ $serverBody == "##ok" ]] && return 0
    # Said out loud rather than swallowed. It is not a failure of the
    # enrollment, and the wording has to make that clear, or the next person
    # reads it as one and goes looking at firmware that is perfectly fine.
    echo " * Note: the enrollment succeeded but could not be recorded on the"
    echo "   FOG server (${serverReason:-${serverBody:-no answer}})."
    echo "   Set it by hand on the host's General tab if you need the record."
    return 0
}
# Return 0 if the certificate is present in the platform's db.
#
# Reads the variable and looks for the certificate's own bytes, rather than
# asking a tool and parsing what it prints. A db entry embeds the DER verbatim
# inside an EFI_SIGNATURE_LIST, so "are these bytes in that variable" is exactly
# the question, and the answer depends only on the UEFI data format -- which is
# a published spec that cannot quietly change under us. Every alternative here
# is a bet on some program's output formatting.
#
# $1 path to the DER certificate
sbCertInDb() {
    local cert="$1"
    [[ -z $cert ]] && handleError "No certificate passed (${FUNCNAME[0]})\n   Args Passed: $*"
    sbCertInVar "db-${sbEfiSecurityGuid}" "$cert"
}
# Return 0 if the certificate's bytes are in the named EFI variable.
#
# The same byte search sbCertInDb describes, for any signature database. KEK
# needs it too, and KEK lives under the global GUID, so the caller names the
# efivarfs entry in full.
#
# $1 efivarfs entry name, "<Name>-<guid>"
# $2 path to the DER certificate
sbCertInVar() {
    local var="$1"
    local cert="$2"
    [[ -z $var ]] && handleError "No variable passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $cert ]] && handleError "No certificate passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local path="${sbEfiVarDir}/${var}"
    [[ -r $path && -s $cert ]] || return 1
    local certhex dbhex
    # -v because od collapses repeated lines into "*" by default, which would
    # silently drop a run of identical bytes out of the middle of either string.
    certhex=$(od -An -tx1 -v "$cert" 2>/dev/null | tr -d '[:space:]')
    dbhex=$(od -An -tx1 -v "$path" 2>/dev/null | tr -d '[:space:]')
    [[ -n $certhex && -n $dbhex ]] || return 1
    case $dbhex in
        *"$certhex"*) return 0 ;;
    esac
    return 1
}
# Return 0 if the certificate is already trusted by this machine.
#
# Two stores, because a machine can be trusting this certificate by either
# route: the Setup Mode path puts it in db with no MOK entry at all, and the
# staged-MOK path puts it in MokList with nothing in db. Missing either one
# sends a technician to a blue screen to re-enroll something already trusted.
#
# THIS FUNCTION GOT IT WRONG ONCE, AND ONLY HARDWARE CAUGHT IT. It used to grep
# `mokutil --db` for the certificate's SHA-256. mokutil prints a **SHA1**
# fingerprint there, so the match could never fire -- and the harness stub had
# been written to emit the SHA-256 this code was looking for, so the test agreed
# with the bug. On a machine whose db already held the certificate, the task
# went on to stage a MOK anyway, which mokutil then refused (it will not stage a
# request for a certificate already in db) and the task aborted.
#
# Hence: the db half is answered from the bytes (sbCertInDb) rather than from
# any tool's output, and the MokList half matches mokutil's own strings, taken
# from the binary rather than assumed -- `mokutil --test-key` reports
# "<file> is already in db" or "CA of <file> is already enrolled", never the
# bare "already enrolled" this used to look for. Verified against mokutil 0.7.2,
# which is what Buildroot builds.
#
# $1 path to the DER certificate
sbCertTrusted() {
    local cert="$1"
    [[ -z $cert ]] && handleError "No certificate passed (${FUNCNAME[0]})\n   Args Passed: $*"
    sbCertInDb "$cert" && return 0
    case $(mokutil --test-key "$cert" 2>/dev/null) in
        *"is already in db"*|*"is already enrolled"*) return 0 ;;
    esac
    return 1
}
# Stage a MOK enrollment request, without prompting.
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
# person who asked for the enrollment. It therefore has to be shown to the
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
# ---------------------------------------------------------------------------
# The Setup Mode path (fos ADR-0009 "path A"): write the server's certificate
# straight into the platform's own Secure Boot databases, with no MokManager
# screen and no human at the keyboard.
#
# This works ONLY in Setup Mode. db/KEK/PK are authenticated variables whose
# write policy the firmware derives from whether a PK is present -- not from
# whether Secure Boot enforcement is switched on. A machine with Secure Boot
# merely turned OFF still has a PK and still refuses these writes. See sbState().
# ---------------------------------------------------------------------------

# Download a signed variable update (PK.auth / KEK.auth / db.auth) to $2.
#
# Nothing here is secret and nothing here is trusted on the strength of the
# transport: the blob is a signed authenticated-variable update, and once the
# platform has a PK it verifies the signature itself. The check below exists to
# catch a 404 page or a truncated download, not an attacker.
#
# $1 variable name (PK, KEK, db)
# $2 destination path
sbFetchAuthVar() {
    local name="$1"
    local dest="$2"
    [[ -z $name ]] && handleError "No variable name passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $dest ]] && handleError "No destination passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $web ]] && handleError "No web root known, cannot fetch ${name}.auth (${FUNCNAME[0]})"
    rm -f "$dest" >/dev/null 2>&1
    fog.curl -Ls -o "$dest" "${web}service/secureboot/${name}.auth" >/dev/null 2>&1
    [[ -s $dest ]] || return 1
    # An EFI_VARIABLE_AUTHENTICATION_2 descriptor is a 16-byte EFI_TIME followed
    # by a WIN_CERTIFICATE_UEFI_GUID header, so bytes 20..23 are wRevision
    # (0x0200) and wCertificateType (0x0EF1), both little-endian. Checking those
    # four bytes distinguishes a real .auth from an HTML error page or a
    # half-written file, which a size check alone does not.
    [[ $(od -An -tx1 -j20 -N4 "$dest" 2>/dev/null | tr -d '[:space:]') == 0002f10e ]] || return 1
    return 0
}
# Write a signed variable update into efivarfs.
#
# efivarfs demands the whole thing in ONE write(): a 4-byte little-endian
# attribute mask immediately followed by the payload. A short or split write is
# rejected outright, which is why the attribute prefix and the .auth body are
# concatenated into one file and pushed with a single dd block rather than
# `cat a b > var`. cat happens to do one write for a file this size, but that is
# a property of its buffer size, not a guarantee.
#
# Attributes 0x27 = NON_VOLATILE|BOOTSERVICE_ACCESS|RUNTIME_ACCESS|
# TIME_BASED_AUTHENTICATED_WRITE_ACCESS. The authenticated bit is not optional:
# without it the firmware treats the payload as raw data rather than a signed
# update, and either rejects it or stores garbage.
#
# $1 variable name (PK, KEK, db)
# $2 namespace GUID
# $3 path to the .auth file
# $4 optional attribute byte, as a printf escape. Defaults to \x27. Pass \x67
#    (the above plus APPEND_WRITE) to add entries to a variable instead of
#    replacing it.
sbWriteEfiAuthVar() {
    local name="$1"
    local guid="$2"
    local authfile="$3"
    local attr="${4:-\x27}"
    [[ -z $name ]] && handleError "No variable name passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $guid ]] && handleError "No GUID passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -s $authfile ]] || return 1
    local path="${sbEfiVarDir}/${name}-${guid}"
    local payload="/tmp/.sbauth.${name}"
    rm -f "$payload" >/dev/null 2>&1
    printf "${attr}"'\x00\x00\x00' > "$payload" 2>/dev/null || return 1
    cat "$authfile" >> "$payload" 2>/dev/null || return 1
    local size
    size=$(stat -c %s "$payload" 2>/dev/null)
    [[ -n $size && $size -gt 4 ]] || { rm -f "$payload"; return 1; }
    # The kernel sets the immutable flag on existing efivarfs entries so that a
    # stray `rm -rf /sys` cannot brick the firmware. Clearing it is the intended
    # way to update one. A variable that does not exist yet has no flag to
    # clear, so a failure here is only interesting if the file is there.
    if [[ -e $path ]]; then
        chattr -i "$path" >/dev/null 2>&1
    fi
    # iflag=fullblock so a short read cannot turn this into two writes;
    # conv=notrunc because efivarfs does not implement truncation and dd's
    # default O_TRUNC on a variable that already exists is not meaningful.
    if ! dd if="$payload" of="$path" bs="$size" count=1 conv=notrunc \
            iflag=fullblock >/dev/null 2>&1; then
        rm -f "$payload" >/dev/null 2>&1
        return 1
    fi
    rm -f "$payload" >/dev/null 2>&1
    [[ -s $path ]] || return 1
    return 0
}
# Enroll this server's certificate into the platform's Secure Boot databases.
#
# Order is db, then KEK, then PK, and it is not interchangeable. Writing PK is
# what takes the platform OUT of Setup Mode; from that moment every further
# write must carry a signature the firmware will check. Do PK first and the db
# and KEK writes that follow are rejected, leaving a machine that enforces
# Secure Boot and trusts nothing -- recoverable only at the firmware screen.
#
# A failure part-way through is NOT that trap: db and KEK written without a PK
# leaves the platform still in Setup Mode, still booting anything, exactly as it
# was found. So this aborts loudly on the first failure (ADR-0003) rather than
# pressing on to the write that would close the door.
#
# Returns 0 on success, 1 on any failure. The caller reports; this does not
# print, so it stays testable.
sbEnrollDb() {
    local var guid authfile
    # Fetch all three BEFORE writing any. A download that fails halfway would
    # otherwise leave the platform mid-enrollment for no better reason than a
    # web server hiccup, and the fetch is free to retry while a partial write
    # is not.
    for var in db KEK PK; do
        authfile="/tmp/${var}.auth"
        sbFetchAuthVar "$var" "$authfile" || return 1
    done
    for var in db KEK PK; do
        [[ $var == db ]] && guid="$sbEfiSecurityGuid" || guid="$sbEfiGlobalGuid"
        sbWriteEfiAuthVar "$var" "$guid" "/tmp/${var}.auth" || return 1
    done
    # SetupMode flipping 1 -> 0 is the firmware confirming it accepted the PK,
    # and it is the only confirmation available from a running OS: SecureBoot
    # stays 0 until the next boot, because firmware computes it during POST.
    # Checking it here turns "dd wrote some bytes" into "the platform enrolled".
    [[ $(sbEfiFlag SetupMode) == 0 ]] || return 1
    return 0
}
# Add Microsoft's 2023 CAs to db on a machine that is NOT in Setup Mode.
#
# WHY: Windows servicing is replacing the boot manager with one signed by
# "Windows UEFI CA 2023". An image captured after that change carries the new
# boot manager, and a target whose db has only the 2011 CAs refuses it with
# "Security Policy Violation" (forums topic 18246). The disk is correct; the
# firmware does not trust it yet. See docs/adr/0019.
#
# HOW: Microsoft publishes each CA as a signed db update, signed by
# "Microsoft Corporation KEK CA 2011". Almost every PC carries that key in KEK,
# so the firmware accepts the update in User Mode, Secure Boot on or off. This
# is the same file Windows servicing and fwupd apply. The files live in
# /usr/share/fog/secureboot/ and are byte-identical to microsoft/secureboot_objects.
#
# APPEND, never replace: attribute 0x67 adds the entries and leaves the rest of
# db alone. Microsoft signed the update with the append bit set, and the
# signature covers the attributes, so a 0x27 write fails verification and adds
# nothing (OVMF, 2026-09-16). A firmware that skipped that check would replace
# db with this one CA.
#
# Each CA is added only where its 2011 counterpart is already in db. That is
# Microsoft's own rule, and it keeps the owner's policy: a machine that does
# not trust Windows or third-party code today does not start to.
#
# Echoes one line per CA it added. Returns 0 when nothing needed adding or
# every addition was confirmed; 1 when a write failed or the firmware did not
# apply it; 2 when a CA is missing but KEK lacks Microsoft's key, so no signed
# update can apply. The caller reports; this does not decide policy.
sbMsDbUpdate() {
    local dir="/usr/share/fog/secureboot"
    local entry update old new needed=""
    # update file : 2011 CA that must be present : 2023 CA it adds
    for entry in \
        "DBUpdate2024.bin:MicWinProPCA2011.der:WindowsUEFICA2023.der" \
        "DBUpdate3P2023.bin:MicCorUEFCA2011.der:MicrosoftUEFICA2023.der" \
        "DBUpdateOROM2023.bin:MicCorUEFCA2011.der:MicCorOptionROMCA2023.der"; do
        IFS=: read -r update old new <<< "$entry"
        sbCertInDb "${dir}/${old}" || continue
        sbCertInDb "${dir}/${new}" && continue
        needed="${needed} ${update}:${new}"
    done
    [[ -z $needed ]] && return 0
    # Checked once, before any write. Without Microsoft's KEK the firmware
    # rejects every one of these, so trying is noise, not a diagnosis.
    sbCertInVar "KEK-${sbEfiGlobalGuid}" "${dir}/MicCorKEKCA2011.der" || return 2
    for entry in $needed; do
        IFS=: read -r update new <<< "$entry"
        sbWriteEfiAuthVar db "$sbEfiSecurityGuid" "${dir}/${update}" '\x67' || return 1
        # Re-read db from the firmware. efivarfs accepts bytes the firmware can
        # still decline, so a clean dd is not proof the CA is trusted.
        sbCertInDb "${dir}/${new}" || return 1
        echo "${new%.der}"
    done
    return 0
}
# Enroll this FOG server's certificate on this machine, by whichever path the
# firmware allows.
#
# The whole of the Enroll Secure Boot task, lifted out of bin/fog.enrollsb so
# that registration can run the same steps (fogproject#1860). Two callers want
# two different things from a failure, so the caller names the handler:
#
#   handleError    the task. Enrolling is the only thing it was asked to do,
#                  so a failure aborts it (ADR-0003).
#   handleWarning  registration. The host is already registered by the time
#                  this runs; a failed enrollment must not undo that or stop
#                  the inventory, so it says what happened and carries on.
#
# On success sets $sbOutcome to the outcome sbReport records -- db, trusted or
# mok -- and $sbFingerprint to the certificate's SHA-256, and returns 0. It
# does NOT report or complete anything itself: only the task has a task for
# the server to match the report against.
#
# Returns 1 when the handler returned, which only a non-fatal one does.
#
# $1 the failure handler: handleError or handleWarning
sbEnroll() {
    local fail="$1"
    local cert="/tmp/MOK.der"
    local state added ca password
    [[ -z $fail ]] && handleError "No failure handler passed (${FUNCNAME[0]})\n   Args Passed: $*"
    sbOutcome=""
    sbFingerprint=""

    dots "Checking firmware state"
    state=$(sbState)
    echo "$state"
    debugPause

    case $state in
        nonefi)
            # Not a failure of this task so much as a task pointed at the wrong
            # machine, but it is still a task that cannot do what it was asked
            # to. Per ADR-0003 that aborts rather than reporting a success that
            # enrolled nothing.
            "$fail" "This machine booted in BIOS/CSM mode, where Secure Boot does not exist. ($0)\n   Nothing was enrolled. Switch the firmware to UEFI and run this again."
            return 1
            ;;
        noefivars)
            "$fail" "UEFI firmware was detected but efivarfs could not be mounted. ($0)\n   FOS cannot read or write EFI variables, so nothing was enrolled."
            return 1
            ;;
    esac

    # 32-bit UEFI is refused outright rather than degraded to the db path. See
    # docs/adr/0009-secure-boot-enrolment-paths.md and FOGProject/fos#140.
    #
    # The db write would succeed -- nothing in it is architecture-specific --
    # and that is precisely the trap. No Microsoft-signed 32-bit shim and no
    # signed 32-bit iPXE exist, so this machine cannot boot FOG under Secure
    # Boot enforcement whether or not the certificate is enrolled. Meanwhile the
    # only state where this can run on ia32 at all is Setup Mode (nothing is
    # enforcing, so the unsigned chain boots), and the last thing the db path
    # does is write the PK -- which is what LEAVES Setup Mode. Degrading would
    # therefore take a machine FOG can image today, make it enforceable, and
    # leave it with nothing signed to boot, irreversibly from the client's side.
    #
    # Checked before the certificate fetch and before the already-trusted
    # short-circuit: no db contents make enrollment useful here, so there is no
    # state in which continuing tells the admin something more useful than this.
    if [[ $(sbPlatformBits) == 32 ]]; then
        "$fail" "This machine has 32-bit UEFI firmware, which FOG cannot enroll. ($0)\n   No Microsoft-signed 32-bit shim and no signed 32-bit iPXE exist, so it\n   cannot boot FOG under Secure Boot enforcement even with this key trusted.\n   Nothing was enrolled and nothing was changed. Leave Secure Boot off here."
        return 1
    fi

    # Microsoft's 2023 CAs, before the FOG certificate and before the
    # already-trusted exit: the machine in forums topic 18246 already trusted
    # FOG and still could not boot a Windows image. Setup Mode skips this,
    # because sbEnrollDb writes a db that already holds these CAs. See
    # docs/adr/0019.
    if [[ $state == enforcing || $state == disabled ]]; then
        dots "Checking Microsoft 2023 CAs"
        added=$(sbMsDbUpdate)
        case $? in
            0)
                [[ -z $added ]] && echo "Present" || echo "Added"
                for ca in $added; do
                    echo "   * Added $ca to db"
                done
                ;;
            1)
                echo "Failed"
                debugPause
                "$fail" "The firmware did not accept Microsoft's signed db update. ($0)\n   No existing db entry was removed. A Windows image whose boot manager is\n   signed by Windows UEFI CA 2023 will not boot here with Secure Boot on.\n   Check for a firmware update from the vendor."
                return 1
                ;;
            2)
                echo "Skipped"
                handleWarning "This machine's db lacks Microsoft's 2023 CAs, and its KEK does not hold\n   Microsoft Corporation KEK CA 2011, so no signed update can add them.\n   A Windows image whose boot manager is signed by Windows UEFI CA 2023\n   will not boot here with Secure Boot on. Nothing was changed."
                ;;
        esac
        debugPause
    fi

    dots "Fetching certificate"
    if ! sbFetchCert "$cert"; then
        echo "Failed"
        debugPause
        "$fail" "Could not download a usable certificate from ${web}service/secureboot/MOK.der ($0)\n   Secure Boot signing may not be configured on this FOG server;\n   check the Secure Boot page under FOG Configuration."
        return 1
    fi
    echo "Done"
    debugPause

    # Shown and reported for the record, not as a security gate: FOS is already
    # running a kernel this same server signed and served, so a server that
    # could hand us the wrong certificate could equally have handed us the
    # wrong kernel. The value of it is that it matches what the Secure Boot page
    # displays and what sbReport stores against the host, so an enrollment can
    # be audited after the fact -- "enrolled in March" says nothing about
    # whether this machine trusts what the server is serving today, and a
    # fingerprint does.
    sbFingerprint=$(sbCertFingerprint "$cert")
    echo " * Certificate SHA-256:"
    echo "     $sbFingerprint"
    echo

    if sbCertTrusted "$cert"; then
        echo " * This certificate is already trusted by this machine. Nothing to do."
        echo
        # Reported even though nothing was enrolled here. "This machine already
        # trusts the certificate the server is serving today" is the answer the
        # administrator was after; recording nothing would leave the host
        # looking never-enrolled and invite the same task again on the next
        # sweep.
        sbOutcome="trusted"
        return 0
    fi

    if [[ $state == setup ]]; then
        # The automatic path. Preferred over staging a MOK whenever it is
        # available, because it finishes here: no reboot into MokManager, no
        # password, nobody at the keyboard. Only reachable in Setup Mode -- see
        # sbState().
        echo " * This machine is in Setup Mode, so its Secure Boot databases can be"
        echo "   written directly. Enrolling automatically; no MOK Manager step is"
        echo "   needed."
        echo
        dots "Enrolling Secure Boot keys"
        if ! sbEnrollDb; then
            echo "Failed"
            debugPause
            # Deliberately spells out the state the machine is left in. A
            # partial enrollment stops before the PK write, so the platform is
            # still in Setup Mode and still boots exactly what it booted before
            # -- that is worth saying, because "Secure Boot enrollment failed"
            # otherwise reads like the machine may now be unbootable, and
            # someone will make an unnecessary trip to the firmware screen.
            "$fail" "Automatic Secure Boot enrollment failed. ($0)\n   This machine is still in Setup Mode and still boots as it did before;\n   nothing has been made unbootable.\n   Check that ${web}service/secureboot/ serves PK.auth, KEK.auth and db.auth --\n   the FOG server needs efitools installed to produce them."
            return 1
        fi
        echo "Done"
        debugPause

        echo
        echo "=============================================================================="
        echo " Secure Boot is now enrolled on this machine."
        echo
        echo "   This FOG server's certificate is in the platform's db, and Microsoft's"
        echo "   certificates were enrolled alongside it, so Windows and FOG's own"
        echo "   signed PXE chain both still boot."
        echo
        echo " The machine has left Setup Mode. Secure Boot enforcement takes effect on"
        echo " the next boot; turn it on in the firmware if it is not already."
        echo "=============================================================================="
        echo
        sbOutcome="db"
        return 0
    fi

    password=$(sbMokPassword)
    if [[ -z $password ]]; then
        "$fail" "Could not determine a one-time password for the MOK request. ($0)"
        return 1
    fi

    dots "Staging MOK enrollment request"
    if ! sbStageMok "$cert" "$password"; then
        echo "Failed"
        debugPause
        "$fail" "The MOK enrollment request was NOT staged. ($0)\n   Do not reboot expecting a MokManager prompt; nothing is pending.\n   See the messages above for what ran."
        return 1
    fi
    echo "Done"
    debugPause

    # The 10-second line is shim's, not ours: MokManager counts down from 10
    # (MokTimeout) and deletes MokNew before it shows anything, so a missed
    # prompt discards the request rather than deferring it. Worth saying now
    # that registration can stage one ahead of an imaging reboot nobody is
    # watching.
    echo
    echo "=============================================================================="
    echo " A Secure Boot enrollment request is now pending on this machine."
    echo
    echo "   ONE-TIME PASSWORD:   $password"
    echo
    echo " On the next boot, a blue MOK Manager screen appears instead of the normal"
    echo " boot. Press a key within 10 seconds, or the request is discarded and has"
    echo " to be staged again. Then work through it in this order:"
    echo
    echo "   1. Enroll MOK"
    echo "   2. View key 0        <- check it names your FOG server"
    echo "   3. Continue"
    echo "   4. Yes"
    echo "   5. Enter the password above"
    echo "   6. Reboot"
    echo
    echo " If MOK Manager does NOT appear, this machine did not boot through a shim"
    echo " and nothing has been enrolled."
    echo "=============================================================================="
    echo
    # Held, not flashed. S99fog runs `reboot -f` the moment the script returns,
    # so a random password was on screen for about two seconds -- measured in a
    # VM through Quick Registration -- and nobody could answer MokManager with
    # it. With $sbmokpw set, the technician already knows it, so nothing waits.
    if [[ -z $sbmokpw ]]; then
        echo " * Write the password down. Press Enter to reboot (rebooting in 5 minutes)."
        read -r -t 300 _ || :
    fi
    # "mok", NOT "db": nothing is enrolled yet and will not be until a human
    # works through MokManager. The server records this as pending for exactly
    # that reason -- see ADR 0029 decision 6.
    sbOutcome="mok"
    return 0
}
# Enroll at the end of registration, when the administrator asked for it.
#
# Opt-in through sbenroll=true on the kernel command line -- set it fleet-wide
# in FOG's global kernel arguments. Exactly "true", like mdraid=true, so that
# sbenroll=0 does not switch it on. Without it registration behaves exactly as before. It is
# opt-in because, on a machine that is not in Setup Mode, it stages a MOK
# request -- and an unattended Quick Registration would otherwise send every
# new machine to a MOK Manager screen nobody is there to answer.
#
# Runs while Secure Boot is still off, which is what lets one boot do both:
# FOS could not have booted to register this machine otherwise, unless it
# already trusts the certificate, which sbEnroll then reports and leaves alone.
#
# Nothing is reported to the server. secureboot.report.php only accepts a
# report while an Enroll Secure Boot task is in flight for the host, and there
# is none here, so a report would only print a "could not be recorded" note.
#
# BIOS and 32-bit UEFI machines are skipped with one line rather than warned
# about: with sbenroll set fleet-wide, every such machine that registers would
# otherwise sit through a one-minute warning for something it was never going
# to be able to do.
sbEnrollAtRegistration() {
    [[ $sbenroll == true ]] || return 0
    echo
    echo " * Secure Boot enrollment requested (sbenroll=true)"
    if [[ $(sbState) == nonefi ]]; then
        echo "   Skipped: this machine booted in BIOS/CSM mode."
        return 0
    fi
    if [[ $(sbPlatformBits) == 32 ]]; then
        echo "   Skipped: 32-bit UEFI firmware cannot boot FOG under Secure Boot."
        return 0
    fi
    sbEnroll handleWarning
}
