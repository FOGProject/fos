#!/bin/bash
#
# Assertion harness for the explicit filesystem type on FOS's NFS mounts.
#
#   tests/checks/nfs-mount-type.sh
#
# Why this exists. FOS mounts the storage node with a hardcoded NFS option
# list (nolock,proto=tcp,rsize=...,intr,noatime) and, until now, no -t. That
# worked only because busybox mount infers NFS on its own -- and it does so
# from the SOURCE STRING, not from the options: singlemount() in
# util-linux/mount.c takes the NFS branch only when the source contains a ':'
# whose first '/' comes after it. FOS's init ships no mount.nfs helper and
# busybox is built without FEATURE_MOUNT_NFS, so there is no second chance.
#
# When storage= is empty or malformed the inference silently fails, and
# busybox falls through to get_block_backed_filesystems() -- it walks every
# block-backed entry in /proc/filesystems and tries each one in turn. Each
# rejects 'nolock' as an unknown parameter, so the console fills with errors
# naming local filesystems that were never involved:
#
#     ext3: Unknown parameter 'nolock'
#     ext2: Unknown parameter 'nolock'
#     ...
#
# That is what a Raspberry Pi 4 reporter saw in forums topic 18229, and it
# sent the diagnosis toward the mount options for a day. With -t nfs present
# mp->mnt_type is set, the walk is skipped entirely, and a bad storage= gets
# one NFS error naming the actual source.
#
# The check is a grep because the invariant is textual and the failure is a
# console message rather than a return code -- there is nothing to execute
# that would reproduce it off-target. It anchors the whole call site rather
# than just the flag, so a rewritten mount line is a visible failure.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HERE/../../Buildroot/board/FOG/FOS/rootfs_overlay/bin"

fails=0
checked=0

# Any mount carrying NFS-only options is an NFS mount and must say so.
while IFS=: read -r file line text; do
    checked=$((checked + 1))
    if [[ $text != *"mount -t nfs "* ]]; then
        echo "FAIL [$(basename "$file"):$line] NFS mount without an explicit -t nfs"
        echo "       $(echo "$text" | sed 's/^[[:space:]]*//')"
        fails=$((fails + 1))
    else
        echo "  checked $(basename "$file"):$line"
    fi
done < <(grep -rn '^[[:space:]]*mount .*nolock' "$BIN")

if [[ $checked -eq 0 ]]; then
    echo "FAIL: found no nolock mounts at all -- has the storage mount moved?"
    exit 1
fi

echo
if [[ $fails -eq 0 ]]; then
    echo "PASS: $checked NFS mount(s) name their filesystem type"
    exit 0
fi
echo "FAILED: $fails of $checked NFS mount(s) rely on busybox inferring the type"
exit 1
