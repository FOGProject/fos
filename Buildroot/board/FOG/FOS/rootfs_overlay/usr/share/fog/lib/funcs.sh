#!/bin/bash
export initversion=19800101
. /usr/share/fog/lib/partition-funcs.sh
REG_LOCAL_MACHINE_XP="/ntfs/WINDOWS/system32/config/system"
REG_LOCAL_MACHINE_7="/ntfs/Windows/System32/config/SYSTEM"
# 1 to turn on massive debugging of partition table restoration
[[ -z $ismajordebug ]] && ismajordebug=0
#If a sub shell gets invoked and we lose kernel vars this will reimport them
for var in $(cat /proc/cmdline); do
	var=$(echo "${var}" | awk -F= '{name=$1; gsub(/[+][_][+]/," ",$2); gsub(/"/,"\\\"", $2); value=$2; if (length($2) == 0 || $0 !~ /=/ || $0 ~ /nvme_core\.default_ps_max_latency_us=/) {print "";} else {printf("%s=%s", name, value)}}')
    [[ -z $var ]] && continue;
    eval "export ${var}" 2>/dev/null
done
### If USB Boot device we need a way to get the kernel args properly
[[ $boottype == usb && -f /tmp/hinfo.txt ]] && . /tmp/hinfo.txt
# Below Are non parameterized functions
# These functions will run without any arguments
#
# Clears thes creen unless its a debug task
clearScreen() {
    case $isdebug in
        [Yy][Ee][Ss]|[Yy])
            clear
            ;;
    esac
}
# Displays the nice banner along with the running version
displayBanner() {
    version=$(curl -Lks ${web}service/getversion.php 2>/dev/null)
    echo "   =================================="
    echo "   ===        ====    =====      ===="
    echo "   ===  =========  ==  ===   ==   ==="
    echo "   ===  ========  ====  ==  ====  ==="
    echo "   ===  ========  ====  ==  ========="
    echo "   ===      ====  ====  ==  ========="
    echo "   ===  ========  ====  ==  ===   ==="
    echo "   ===  ========  ====  ==  ====  ==="
    echo "   ===  =========  ==  ===   ==   ==="
    echo "   ===  ==========    =====      ===="
    echo "   =================================="
    echo "   ===== Free Opensource Ghost ======"
    echo "   =================================="
    echo "   ============ Credits ============="
    echo "   = https://fogproject.org/Credits ="
    echo "   =================================="
    echo "   == Released under GPL Version 3 =="
    echo "   =================================="
    echo "   Version: $version"
    echo "   Init Version: $initversion"
    echo "   Kernel Version: $(uname -r)"
}
# Gets all system mac addresses except for loopback
#getMACAddresses() {
#    read ifaces <<< $(/usr/sbin/lshw -c network -json | jq -s '.[] | .logicalname' | tr -d '"' | tr '[:space:]' '|' | sed 's/[|]$//g')
#    read mac_addresses <<< $(/usr/sbin/lshw -c network -json | jq -s '.[] | .serial' | tr -d '"' | tr '[:space:]' '|' | sed 's/[|]$//g')
#    echo $mac_addresses
#}
# Gets all system mac addresses except for loopback
getMACAddresses() {
    read ifaces <<< $(/sbin/ip -4 -o addr | awk -F'([ /])+' '/global/ {print $2}' | tr '[:space:]' '|' | sed -e 's/^[|]//g' -e 's/[|]$//g')
    read mac_addresses <<< $(/sbin/ip -0 addr | awk 'ORS=NR%2?FS:RS' | awk "/$ifaces/ {print \$11}" | tr '[:space:]' '|' | sed -e 's/^[|]//g' -e 's/[|]$//g')
    echo $mac_addresses
}
# Gets all macs and types.
getMACTypes() {
    read macandtypes <<< $(/usr/sbin/lshw -c network -json | jq -s '.[] | .serial + " " + .handle' | tr -d '"' | tr '\n' '|' | sed 's/[|]$//g')
    echo $macandtypes
}
# Verifies that there is a network interface
verifyNetworkConnection() {
    dots "Verifying network interface configuration"
    local count=$(/sbin/ip addr | awk -F'[ /]+' '/global/{print $3}' | wc -l)
    if [[ -z $count || $count -lt 1 ]]; then
        echo "Failed"
        debugPause
        handleError "No network interfaces found (${FUNCNAME[0]})\n   Args Passed: $*"
    fi
    echo "Done"
    debugPause
}
# Verifies that the OS is valid for resizing
validResizeOS() {
    [[ $osid != @([1-2]|4|[5-7]|9|10|11|50|51) ]] && handleError " * Invalid operating system id: $osname ($osid) (${FUNCNAME[0]})\n   Args Passed: $*"
}
# Gets the graphics information from the system
getGraphics() {
    local graphics_info=$(lshw -json -C display | jq -r '.[] | select(.vendor != null) | "\(.vendor),\(.product)"')

    graphics_vendors_array=()
    graphics_products_array=()
    while IFS=',' read -r vendor product; do
        graphics_vendors_array+=("$vendor")
        graphics_products_array+=("$product")
    done <<< "$graphics_info"

    inventory_graphics_vendor=$(IFS=,; echo "${graphics_vendors_array[*]}")
    inventory_graphics_product=$(IFS=,; echo "${graphics_products_array[*]}")

    inventory_graphics_vendor64=$(echo "$inventory_graphics_vendor" | base64)
    inventory_graphics_product64=$(echo "$inventory_graphics_product" | base64)
}
# Gets the information from the system for inventory
doInventory() {
    getGraphics
    # Uniform "dmidecode -s <keyword>" lookups, driven from a var:keyword list.
    local dmifield
    for dmifield in \
        sysman:system-manufacturer \
        sysproduct:system-product-name \
        sysversion:system-version \
        sysserial:system-serial-number \
        sysuuid:system-uuid \
        biosversion:bios-version \
        biosvendor:bios-vendor \
        biosdate:bios-release-date \
        mbman:baseboard-manufacturer \
        mbproductname:baseboard-product-name \
        mbversion:baseboard-version \
        mbserial:baseboard-serial-number \
        mbasset:baseboard-asset-tag \
        cpuman:processor-manufacturer \
        cpuversion:processor-version \
        caseman:chassis-manufacturer \
        casever:chassis-version \
        caseserial:chassis-serial-number \
        caseasset:chassis-asset-tag; do
        printf -v "${dmifield%%:*}" '%s' "$(dmidecode -s "${dmifield#*:}")"
    done
    # Non-uniform inventory items kept explicit (different tools/parsing).
    sysuuid=${sysuuid,,}
    systype=$(dmidecode -t 3 | grep Type:)
    cpucurrent=$(dmidecode -t 4 | grep 'Current Speed:' | head -n1)
    cpumax=$(dmidecode -t 4 | grep 'Max Speed:' | head -n1)
    mem=$(cat /proc/meminfo | grep MemTotal | tr -d \\0)
    hdinfo=$(hdparm -i $hd 2>/dev/null | grep Model= || smartctl -i $hd | grep -A2 "Model Number" | awk -F ":" '/Model Number:/{gsub(/ /,""); modelno=$NF};/Serial Number:/{gsub(/ /,""); serialno=$NF};/Firmware Version:/{gsub(/ /,""); fwrev=$NF; print "model="modelno", fwrev="fwrev", serialno="serialno}')
    # base64-encode each inventory field into its <name>64 counterpart.
    local invfield
    for invfield in sysman sysproduct sysversion sysserial sysuuid systype \
        biosversion biosvendor biosdate mbman mbproductname mbversion mbserial \
        mbasset cpuman cpuversion cpucurrent cpumax mem hdinfo caseman casever \
        caseserial caseasset; do
        printf -v "${invfield}64" '%s' "$(echo ${!invfield} | base64)"
    done
}
# Gets the location of the SAM registry if found
getSAMLoc() {
    local path=""
    local mntpnt="${1:-/ntfs}"
    local paths="$mntpnt/WINDOWS/system32/config/SAM $mntpnt/Windows/System32/config/SAM"
    sam=""
    for path in $paths; do
        [[ ! -f $path ]] && continue
        sam="$path" && break
    done
}
# Appends dots to the end of string up to 50 characters.
# Makes the output more aligned and organized.
#
# $1 String to append dots to
dots() {
    local str="$*"
    [[ -z $str ]] && handleError "No string passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local pad=$(printf "%0.1s" "."{1..50})
    printf " * %s%*.*s" "$str" 0 $((50-${#str})) "$pad"
}
# Enables write caching on the disk passed
# If the disk does not support write caching this does nothing
#
# $1 is the drive
enableWriteCache()  {
    local disk="$1"
    [[ -z $disk ]] && handleError "No disk passed (${FUNCNAME[0]})\n   Args Passed: $*"
    wcache=$(hdparm -W $disk 2>/dev/null | tr -d '[[:space:]]' | awk -F= '/.*write-caching=/{print $2}')
    if [[ -z $wcache || $wcache == notsupported ]]; then
        echo " * Write caching not supported"
        debugPause
        return
    fi
    dots "Enabling write cache"
    hdparm -W1 $disk >/dev/null 2>&1
    case $? in
        0)
            echo "Enabled"
            ;;
        *)
            echo "Failed"
            debugPause
            handleWarning "Could not set caching status (${FUNCNAME[0]})"
            return
            ;;
    esac
    debugPause
}
# Expands partitions, as needed/capable
#
# $1 is the partition
# $2 is the fixed size partitions (can be empty)
expandPartition() {
    local part="$1"
    local fixed="$2"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local disk=""
    local part_number=0
    getDiskFromPartition "$part"
    getPartitionNumber "$part"
    local is_fixed=$(echo $fixed | awk "/(^$part_number:|:$part_number:|:$part_number$|^$part_number$)/{print 1}")
    if [[ $is_fixed -eq 1 ]]; then
        echo " * Not expanding ($part) fixed size"
        debugPause
        return
    fi
    local fstype=""
    fsTypeSetting $part
    case $fstype in
        ntfs)
            dots "Resizing $fstype volume ($part)"
            yes | ntfsresize $part -fbP >/tmp/tmpoutput.txt 2>&1
            checkStatus $? "done" "Could not resize $part (${FUNCNAME[0]})\n   Info: $(cat /tmp/tmpoutput.txt)\n   Args Passed: $*"
            debugPause
            resetFlag "$part"
            ;;
        extfs)
            dots "Resizing $fstype volume ($part)"
            e2fsck -fp $part >/tmp/e2fsck.txt 2>&1
            case $? in
                0)
                    ;;
                *)
                    e2fsck -fy $part >>/tmp/e2fsck.txt 2>&1
                    if [[ $? -gt 0 ]]; then
                        echo "Failed"
                        debugPause
                        handleError "Could not check before resize (${FUNCNAME[0]})\n   Info: $(cat /tmp/e2fsck.txt)\n   Args Passed: $*"
                    fi
                    ;;
            esac
            resize2fs $part >/tmp/resize2fs.txt 2>&1
            checkStatus $? "silent" "Could not resize $part (${FUNCNAME[0]})\n   Info: $(cat /tmp/resize2fs.txt)\n   Args Passed: $*"
            e2fsck -fp $part >/tmp/e2fsck.txt 2>&1
            case $? in
                0)
                    echo "Done"
                    ;;
                *)
                    e2fsck -fy $part >>/tmp/e2fsck.txt 2>&1
                    if [[ $? -gt 0 ]]; then
                        echo "Failed"
                        debugPause
                        handleError "Could not check after resize (${FUNCNAME[0]})\n   Info: $(cat /tmp/e2fsck.txt)\n   Args Passed: $*"
                    fi
                    echo "Done"
                    ;;
            esac
            ;;
        btrfs)
            # Based on info from @mstabrin on forums.fogproject.org
            dots "Resizing $fstype volume ($part)"
            if [[ ! -d /tmp/btrfs ]]; then
                mkdir /tmp/btrfs >>/tmp/btrfslog.txt 2>&1
                if [[ $? -gt 0 ]]; then
                    echo "Failed"
                    debugPause
                    handleError "Could not create /tmp/btrfs (${FUNCNAME[0]})\n   Info: $(cat /tmp/btrfslog.txt)\n   Args Passed: $*"
                fi
            fi
            mount -t btrfs $part /tmp/btrfs >>/tmp/btrfslog.txt 2>&1
            if [[ $? -gt 0 ]]; then
                echo "Failed"
                debugPause
                handleError "Could not mount $part to /tmp/btrfs (${FUNCNAME[0]})\n   Info: $(cat /tmp/btrfslog.txt)\n   Args Passed: $*"
            fi
            btrfs filesystem resize max /tmp/btrfs >>/tmp/btrfslog.txt 2>&1
            if [[ $? -gt 0 ]]; then
                echo "Failed"
                debugPause
                handleError "Could not resize btrfs partition (${FUNCNAME[0]})\n   Info: $(cat /tmp/btrfslog.txt)\n   Args Passed: $*"
            fi
            umount /tmp/btrfs >>/tmp/btrfslog.txt 2>&1
            if [[ $? -gt 0 ]]; then
                echo "Failed"
                debugPause
                handleError "Could not unmount $part from /tmp/btrfs (${FUNCNAME[0]}\n   Info: $(cat /tmp/btrfslog.txt)\n   Args Passed: $*)"
            fi
            echo "Done"
            ;;
        f2fs)
            if [[ $type == "down" ]]; then
                dots "Resizing $fstype volume ($part)"
                resize.f2fs $part >>/tmp/resize.f2fs.txt 2>&1
                if [[ $? -gt 0 ]]; then
                    echo "Failed"
                    debugPause
                    handleError "Could not expand f2fs partition (${FUNCNAME[0]})\n   Info: $(cat /tmp/resize.f2fs.txt)\n  Args Passed: $*"
                fi
                echo "Done"
            fi
            ;;
        xfs)
            if [[ $type == "down" ]]; then
                dots "Attempting to resize $fstype volume ($part)"

                # XFS partitions can only be expanded when there is free space after that partition.
                # Retrieving the partition number of a XFS partition that has free space after it.
                local xfsPartitionNumberThatCanBeExpanded=$(parted -s -a opt $disk "print free" | grep -i "free space" -B 1 | grep -i "xfs" | cut -d ' ' -f2)
                local currentPartitionNumber=$(echo $part | grep -o '[0-9]*$')
                if [[ "$xfsPartitionNumberThatCanBeExpanded" == "$currentPartitionNumber"a ]]; then
                    parted -s -a opt $disk "resizepart $xfsPartitionNumberThatCanBeExpanded 100%" >>/tmp/xfslog.txt 2>&1
                    if [[ $? -gt 0 ]]; then
                        echo "Failed"
                        debugPause
                        handleError "Could not resize partition $part (${FUNCNAME[0]})\n   Info: $(cat /tmp/xfslog.txt)\n   Args Passed: $*"
                    fi
                    if [[ ! -d /tmp/xfs ]]; then
                        mkdir /tmp/xfs >>/tmp/xfslog.txt 2>&1
                        if [[ $? -gt 0 ]]; then
                            echo "Failed"
                            debugPause
                            handleError "Could not create /tmp/xfs (${FUNCNAME[0]})\n   Info: $(cat /tmp/xfslog.txt)\n   Args Passed: $*"
                        fi
                    fi
                    mount -t xfs $part /tmp/xfs >>/tmp/xfslog.txt 2>&1
                    if [[ $? -gt 0 ]]; then
                        echo "Failed"
                        debugPause
                        handleError "Could not mount $part to /tmp/xfs (${FUNCNAME[0]})\n   Info: $(cat /tmp/xfslog.txt)\n   Args Passed: $*"
                    fi
                    xfs_growfs $part >>/tmp/xfslog.txt 2>&1
                    if [[ $? -gt 0 ]]; then
                        echo "Failed"
                        debugPause
                        handleError "Could not grow XFS partition $part (${FUNCNAME[0]})\n   Info: $(cat /tmp/xfslog.txt)\n   Args Passed: $*"
                    fi
                    umount /tmp/xfs >>/tmp/xfslog.txt 2>&1
                    if [[ $? -gt 0 ]]; then
                        echo Failed
                        debugPause
                        handleError "Could not unmount $part from /tmp/xfs (${FUNCNAME[0]})\n   Info: $(cat /tmp/xfslog.txt)\n   Args Passed: $*"
                    fi
                    echo "Done"
                else
                    echo "Failed, XFS partition cannot be expanded"
                fi
            fi
            ;;
        lvm)
            expandLVMPartition "$part"
            ;;
        *)
            echo " * Not expanding ($part -- $fstype)"
            debugPause
            ;;
    esac
    debugPause
    runPartprobe "$disk"
}
# Check if partition is bitlocked
#
# Bitlocker To Go GUIDs (we probably never need those but as I spend time
# to understand those are in RAW mode I'll leave them in the code for now):
# 3bd66749292ed84a8399f6a339e3d001 - INFORMATION_OFFSET_GUID
# 3b4da89280dd0e4d9e4eb1e3284eaed8 - EOW_INFORMATION_OFFSET_GUID
#
# $1 is the partition
isBitlockedPartition() {
    local part="$1"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local is_bitlocked=$(dd if=$part bs=512 count=1 2>&1 | grep -ie '-FVE-FS-')
    if [[ -n $is_bitlocked ]]; then
        handleError "Found bitlocker signature in partition $part header. Please disable BITLOCKER before capturing an image. (${FUNCNAME[0]})\n   Args Passed: $*"
    fi
}
# Gets the filesystem type of the partition passed
#
# $1 is the partition
fsTypeSetting() {
    local part="$1"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local blk_fs=$(blkid -po udev $part | awk -F= '/FS_TYPE=/{print $2}')
    case $blk_fs in
        apfs)
            fstype="apfs"
            ;;
        btrfs)
            fstype="btrfs"
            ;;
        ext[2-4])
            fstype="extfs"
            ;;
        f2fs)
            fstype="f2fs"
            ;;
        hfsplus)
            fstype="hfsp"
            ;;
        LVM2_member)
            # An LVM2 physical volume; captured per-LV (see docs/adr/0004).
            # skiplvm=1 on the kernel command line reverts to the raw blob.
            [[ $skiplvm -eq 1 ]] && fstype="imager" || fstype="lvm"
            ;;
        ntfs)
            fstype="ntfs"
            ;;
        swap)
            fstype="swap"
            ;;
        vfat)
            fstype="fat"
            ;;
        xfs)
            fstype="xfs"
            ;;
        *)
            fstype="imager"
            ;;
    esac
}
# Gets the partition entry name
#
# $1 is the partition
getPartName() {
    local part="$1"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    partname=$(blkid -po udev $part | awk -F= '/PART_ENTRY_NAME=/{print $2}')
}
# Gets the partition entry type
#
# $1 is the partition
getPartType() {
    local part="$1"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    parttype=$(blkid -po udev $part | awk -F= '/PART_ENTRY_TYPE=/{print $2}')
}
# Gets the entry schemed (dos, gpt, etc...)
#
# $1 is the partition
getPartitionEntryScheme() {
    local part="$1"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    scheme=$(blkid -po udev $part | awk -F= '/PART_ENTRY_SCHEME=/{print $2}')
}
# Checks if the partition is dos extended (mbr with logical parts)
#
# $1 is the partition
partitionIsDosExtended() {
    local part="$1"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local scheme=""
    getPartitionEntryScheme "$part"
    debugEcho "scheme = $scheme" 1>&2
    case $scheme in
        dos)
            echo "no"
            ;;
        *)
            local parttype=""
            getPartType "$part"
            debugEcho "parttype = $parttype" 1>&2
            [[ $parttype == +(0x5|0xf) ]] && echo "yes" || echo "no"
            ;;
    esac
    debugPause
}
# Returns the block size of a partition
#
# $1 is the partition
# $2 is the variable to set
getPartBlockSize() {
    local part="$1"
    local varVar="$2"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $varVar ]] && handleError "No variable to set passed (${FUNCNAME[0]})\n   Args Passed: $*"
    printf -v "$varVar" $(blockdev --getpbsz $part)
}
# Retrieve available space from NFS share
# Should only be used when the share is mounted to `/images`
getServerDiskSpaceAvailable() {
    local space=$(df -h | grep "/images" | sed -n '/dev/{s/  */ /gp}' | cut -d ' ' -f4)
    [[ $space == "0" ]] && local space="0M"
    echo $space
}
# Prepares location info for uploads
#
# $1 is the image path
prepareUploadLocation() {
    local imagePath="$1"
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    dots "Preparing backup location"
    if [[ ! -d $imagePath ]]; then
        mkdir -p $imagePath >/dev/null 2>&1
        case $? in
            0)
                ;;
            *)
                echo "Failed"
                debugPause
                local spaceAvailable=$(getServerDiskSpaceAvailable)
                handleError "Failed to create image capture path (${FUNCNAME[0]})\nServer Disk Space Available: $spaceAvailable\n   Args Passed: $*"
                ;;
        esac
    fi
    echo "Done"
    debugPause
    dots "Setting permission on $imagePath"
    chmod -R 775 $imagePath >/dev/null 2>&1
    checkStatus $? "done" "Failed to set permissions (${FUNCNAME[0]})\n   Args Passed: $*"
    debugPause
    dots "Removing any pre-existing files"
    rm -Rf $imagePath/* >/dev/null 2>&1
    checkStatus $? "done" "Could not clean files (${FUNCNAME[0]})\n   Args Passed: $*"
    debugPause
}
# Moves partitions if possible for upload (resizable images only)
#
# $1 is the partition
# $2 is the previous partition
movePartition() {
    local part="$1"
    local prevPart="$2"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    # Skip if we don't know about the previous partition, e.g. call on the very first partition
    [[ -z $prevPart ]] && return
    local disk=""
    getDiskFromPartition "$part"
    local tmp_file1="/tmp/move1.$$"
    local tmp_file2="/tmp/move2.$$"
    rm -f /tmp/move{1,2}.*
    saveSfdiskPartitions "$disk" "$tmp_file1"
    prevPartStart=$(grep "$prevPart" $tmp_file1 | cut -d',' -f1 | awk -F'=' '{print $2}' | tr -d ' ')
    prevPartSize=$(grep "$prevPart" $tmp_file1 | cut -d',' -f2 | awk -F'=' '{print $2}' | tr -d ' ')
    newStart=$(calculate "${prevPartStart}+${prevPartSize}")
    currPartStart=$(grep "$part" $tmp_file1 | cut -d',' -f1 | awk -F'=' '{print $2}' | tr -d ' ')
    if [[ $currPartStart -gt $newStart ]]; then
        echo " * Moving $part forward to close gap between end of $prevPart and start of $part."
        debugPause
        processSfdisk "$tmp_file1" move "$part" "$newStart" > "$tmp_file2"
        if [[ $ismajordebug -gt 0 ]]; then
            majorDebugEcho "Partition table *before* moving $part:"
            cat $tmp_file1
            majorDebugPause
            majorDebugEcho "Partition table *after* moving $part - will be applied when you hit ENTER:"
            cat $tmp_file2
            majorDebugPause
        fi
        applySfdiskPartitions "$disk" "$tmp_file2"
    fi
}
# Shrinks partitions for upload (resizable images only)
#
# $1 is the partition
# $2 is the fstypes file location
# $3 is the fixed partition numbers empty ok
shrinkPartition() {
    local part="$1"
    local fstypefile="$2"
    local fixed="$3"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $fstypefile ]] && handleError "No type file passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local disk=""
    local part_number=0
    getDiskFromPartition "$part"
    getPartitionNumber "$part"
    local is_fixed=$(echo $fixed | awk "/(^$part_number:|:$part_number:|:$part_number$|^$part_number$)/{print 1}")
    if [[ $is_fixed -eq 1 ]]; then
        echo " * Not shrinking ($part) as it is detected as fixed size"
        debugPause
        return
    fi
    local fstype=""
    fsTypeSetting "$part"
    echo "$part $fstype" >> $fstypefile
    local size=0
    local tmpoutput=""
    local sizentfsresize=0
    local sizeextresize=0
    local tmp_success=""
    local test_string=""
    local do_resizefs=0
    local do_resizepart=0
    local extminsize=0
    local block_size=0
    local sizeextresize=0
    local adjustedfdsize=0
    local part_block_size=0
    case $fstype in
        ntfs)
            ntfsresize -fivP $part >/tmp/tmpoutput.txt 2>&1
            if [[ ! $? -eq 0 ]]; then
                echo " * Not shrinking ($part) trying fixed size"
                debugPause
                echo "$(cat "$imagePath/d1.fixed_size_partitions" | tr -d \\0):${part_number}" > "$imagePath/d1.fixed_size_partitions"
                return
                #handleError " * (${FUNCNAME[0]})\n    Args Passed: $*\n\nFatal Error, unable to find size data out on $part. Cmd: ntfsresize -f -i -v -P $part"
            fi
            tmpoutput=$(cat /tmp/tmpoutput.txt | tr -d \\0)
            size=$(cat /tmp/tmpoutput.txt | tr -d \\0 | sed -n 's/.*you might resize at\s\+\([0-9]\+\).*$/\1/pi')
            [[ -z $size ]] && handleError " * (${FUNCNAME[0]})\n   Args Passed: $*\n\nFatal Error, Unable to determine possible ntfs size\n * To better help you debug we will run the ntfs resize\n\t but this time with full output, please wait!\n\t $(cat /tmp/tmpoutput.txt | tr -d \\0)"
            local min_slack_bytes=$((500 * 1024 * 1024))

            # percent-based slack, in bytes (integer math)
            # NOTE: relies on your calculate() handling basic math; if calculate uses bc, this is fine too.
            local sizeadd_bytes
            sizeadd_bytes=$(calculate "${percent}/100*${size}")
            [[ -z $sizeadd_bytes ]] && sizeadd_bytes=0

            # ensure at least 500MB slack
            local slack_bytes="$sizeadd_bytes"
            if [[ $slack_bytes -lt $min_slack_bytes ]]; then
                slack_bytes=$min_slack_bytes
            fi

            # target size in KiB for ntfsresize
            # (bytes -> KiB), and add slack (also bytes -> KiB)
            rm /tmp/tmpoutput.txt >/dev/null 2>&1
            sizentfsresize=$(calculate "(${size}+${slack_bytes})/1024")
            [[ -z $sizentfsresize || $sizentfsresize -lt 1 ]] && handleError " * (${FUNCNAME[0]})\n   Args Passed: $*\n\nFatal Error, Unable to determine NTFS target size with 500MB minimum slack"

            echo " * Possible resize partition size (includes >=500MB slack): ${sizentfsresize}k"
            echo " * Possible resize partition size: ${sizentfsresize}k"
            dots "Running resize test $part"
            yes | ntfsresize -fns ${sizentfsresize}k ${part} >/tmp/tmpoutput.txt 2>&1
            local ntfsstatus="$?"
            tmpoutput=$(cat /tmp/tmpoutput.txt | tr -d \\0)
            test_string=$(cat /tmp/tmpoutput.txt | egrep -io "(ended successfully|bigger than the device size|volume size is already OK)" | tr -d '[[:space:]]' | tr -d \\0)
            echo "Done"
            debugPause
            rm /tmp/tmpoutput.txt >/dev/null 2>&1
            case $test_string in
                endedsuccessfully)
                    echo " * Resize test was successful"
                    do_resizefs=1
                    do_resizepart=1
                    ntfsstatus=0
                    ;;
                biggerthanthedevicesize)
                    echo " * Not resizing filesystem $part (part too small)"
                    echo "$(cat ${imagePath}/d1.fixed_size_partitions | tr -d \\0):${part_number}" > "$imagePath/d1.fixed_size_partitions"
                    ntfsstatus=0
                    ;;
                volumesizeisalreadyOK)
                    echo " * Not resizing filesystem $part (already OK)"
                    do_resizepart=1
                    ntfsstatus=0
                    ;;
            esac
            [[ ! $ntfsstatus -eq 0 ]] && handleError "Resize test failed!\n    Info: $tmpoutput\n    (${FUNCNAME[0]})\n    Args Passed: $*"
            if [[ $do_resizefs -eq 1 ]]; then
                debugPause
                dots "Resizing filesystem"
                yes | ntfsresize -fs ${sizentfsresize}k ${part} >/tmp/output.txt 2>&1
                checkStatus $? "done" "Could not resize disk (${FUNCNAME[0]})\n   Info: $(cat /tmp/output.txt)\n   Args Passed: $*"
            fi
            if [[ $do_resizepart -eq 1 ]]; then
                debugPause
                dots "Resizing partition $part"
                getPartBlockSize "$part" "part_block_size"
                case $osid in
                    [1-2]|4)
                        resizePartition "$part" "$(calculate "$sizentfsresize*1024")" "$imagePath"
                        [[ $osid -eq 2 ]] && correctVistaMBR "$disk"
                        ;;
                    [5-7]|9|10|11)
                        [[ $part_number -eq $win7partcnt ]] && part_start=$(blkid -po udev $part 2>/dev/null | awk -F= '/PART_ENTRY_OFFSET=/{printf("%.0f\n",$2*'$part_block_size'/1000)}') || part_start=1048576
                        if [[ -z $part_start || $part_start -lt 1 ]]; then
                            echo "Failed"
                            debugPause
                            handleError "Unable to determine disk start location (${FUNCNAME[0]})\n   Args Passed: $*"
                        fi
                        adjustedfdsize=$(calculate "${sizentfsresize}*1024")
                        resizePartition "$part" "$adjustedfdsize" "$imagePath"
                        ;;
                esac
                echo "Done"
            fi
            resetFlag "$part"
            ;;
        extfs)
            dots "Checking $fstype volume ($part)"
            e2fsck -fp $part >/tmp/e2fsck.txt 2>&1
            checkStatus $? "done" "e2fsck failed to check $part (${FUNCNAME[0]})\n   Info: $(cat /tmp/e2fsck.txt)\n   Args Passed: $*"
            debugPause
            extminsize=$(resize2fs -P $part 2>/dev/null | awk -F': ' '{print $2}')
            block_size=$(dumpe2fs -h $part 2>/dev/null | awk '/^Block[ ]size:/{print $3}')
            size=$(calculate "${extminsize}*${block_size}")
            local sizeadd=$(calculate "${percent}/100*${size}")
            sizeextresize=$(calculate "${size}+${sizeadd}")
            [[ -z $sizeextresize || $sizeextresize -lt 1 ]] && handleError "Error calculating the new size of extfs ($part) (${FUNCNAME[0]})\n   Args Passed: $*"
            dots "Shrinking $fstype volume ($part)"
            resize2fs $part -M >/tmp/resize2fs.txt 2>&1
            checkStatus $? "done" "Could not shrink $fstype volume ($part) (${FUNCNAME[0]})\n   Info: $(cat /tmp/resize2fs.txt)\n   Args Passed: $*"
            debugPause
            dots "Shrinking $part partition"
            resizePartition "$part" "$sizeextresize" "$imagePath"
            echo "Done"
            debugPause
            dots "Checking $fstype volume ($part)"
            e2fsck -fp $part >/tmp/e2fsck.txt 2>&1
            case $? in
                0)
                    echo "Done"
                    ;;
                *)
                    e2fsck -fy $part >>/tmp/e2fsck.txt 2>&1
                    if [[ $? -gt 0 ]]; then
                        echo "Failed"
                        debugPause
                        handleError "Could not check expanded volume ($part) (${FUNCNAME[0]})\n   Info: $(cat /tmp/e2fsck.txt)\n   Args Passed: $*"
                    fi
                    echo "Done"
                    ;;
            esac
            ;;
        btrfs)
            # Based on info from @mstabrin on forums.fogproject.org
            # https://forums.fogproject.org/topic/15159/btrfs-postdownloadscript/3
            dots "Shrinking $part partition"
            if [[ ! -d /tmp/btrfs ]]; then
                mkdir /tmp/btrfs >>/tmp/btrfslog.txt 2>&1
                if [[ $? -gt 0 ]]; then
                    echo "Failed"
                    debugPause
                    handleError "Could not create /tmp/btrfs (${FUNCNAME[0]})\n   Info: $(cat /tmp/btrfslog.txt)\n   Args Passed: $*"
                fi
            fi
            mount -t btrfs $part /tmp/btrfs >>/tmp/btrfslog.txt 2>&1
            if [[ $? -gt 0 ]]; then
                echo "Failed"
                debugPause
                handleError "Could not mount $part to /tmp/btrfs (${FUNCNAME[0]})\n   Info: $(cat /tmp/btrfslog.txt)\n   Args Passed: $*"
            fi
            local free_size_original=$(btrfs filesystem usage -b /tmp/btrfs | grep unallocated | grep -Eo '[0-9]+')
            local fsize_pct=$(calculate_float "${percent}/100")
            local mult_val=$(calculate_float "1-${fsize_pct}")
            local free_size=$(calculate "${mult_val}*${free_size_original}")
            while ! btrfs filesystem resize -${free_size} /tmp/btrfs >>/tmp/btrfslog.txt 2>&1; do
                [[ $(echo "${mult_val} <= 0" | bc -l) -gt 0 ]] && break || mult_val=$(calculate_float "${mult_val} - 0.05")
                free_size=$(calculate "${mult_val}*${free_size_original}")
            done
            umount /tmp/btrfs >>/tmp/btrfslog.txt 2>&1
            if [[ $? -gt 0 ]]; then
                echo "Failed"
                debugPause
                handleError "Could not unmount $part from /tmp/btrfs (${FUNCNAME[0]}\n   Info: $(cat /tmp/btrfslog.txt)\n   Args Passed: $*)"
            fi
            echo "Done"
            ;;
        f2fs)
            echo " * Cannot shrink F2FS partitions"
            ;;
        xfs)
            echo " * Cannot shrink XFS partitions"
            ;;
        lvm)
            shrinkLVMPartition "$part"
            ;;
        *)
            echo " * Not shrinking ($part $fstype)"
            ;;
    esac
    debugPause
}
# Resets the dirty bits on a partition
#
# $1 is the part
resetFlag() {
    local part="$1"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local fstype=""
    fsTypeSetting "$part"
    case $fstype in
        ntfs)
            dots "Clearing ntfs flag"
            ntfsfix -b -d $part >/dev/null 2>&1
            case $? in
                0)
                    echo "Done"
                    ;;
                *)
                    echo "Failed"
                    ;;
            esac
            ;;
    esac
}
# Counts the partitions containing the fs type as passed
#
# $1 is the disk
# $2 is the part type to look for
# $3 is the variable to store the count into. This is
#    a variable variable
countPartTypes() {
    local disk="$1"
    local parttype="$2"
    local varVar="$3"
    [[ -z $disk ]] && handleError "No disk passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $parttype ]] && handleError "No partition type passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $varVar ]] && handleError "No variable to set passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local count=0
    local fstype=""
    local parts=""
    local part=""
    getPartitions "$disk"
    for part in $parts; do
        fsTypeSetting "$part"
        case $fstype in
            $parttype)
                let count+=1
                ;;
        esac
    done
    printf -v "$varVar" "$count"
}
# Writes the image to the disk
#
# $1 = Source File
# $2 = Target
# $3 = mc task or not (not required)
writeImage()  {
    local file="$1"
    local target="$2"
    local mc="$3"
    [[ -z $target ]] && handleError "No target to place image passed (${FUNCNAME[0]})\n   Args Passed: $*"
    mkfifo /tmp/pigz1
    case $mc in
        yes)
            if [[ -z $mcastrdv ]]; then
                udp-receiver --nokbd --portbase $port --ttl 32 --mcast-rdv-address $storageip 2>/dev/null >/tmp/pigz1 &
            else
                udp-receiver --nokbd --portbase $port --ttl 32 --mcast-rdv-address $mcastrdv 2>/dev/null >/tmp/pigz1 &
            fi
            ;;
        *)
            [[ -z $file ]] && handleError "No source file passed (${FUNCNAME[0]})\n   Args Passed: $*"
            cat $file >/tmp/pigz1 &
            ;;
    esac
    local format=$imgLegacy
    [[ -z $format ]] && format=$imgFormat
    set -o pipefail
    case $format in
        5|6)
            # ZSTD Compressed image.
            echo " * Imaging using Partclone (zstd)"
            zstdmt -dc </tmp/pigz1 | partclone.restore -n "Storage Location $storage, Image name $img" --ignore_crc -O ${target} -Nf 1
            ;;
        3|4)
            # Uncompressed partclone
            echo " * Imaging using Partclone (uncompressed)"
            cat </tmp/pigz1 | partclone.restore -n "Storage Location $storage, Image name $img" --ignore_crc -O ${target} -Nf 1
            # If this fails, try from compressed form.
            #[[ ! $? -eq 0 ]] && zstdmt -dc </tmp/pigz1 | partclone.restore --ignore_crc -O ${target} -N -f 1 || true
            ;;
        1)
            # Partimage
            echo " * Imaging using Partimage (gzip)"
            #zstdmt -dc </tmp/pigz1 | partimage restore ${target} stdin -f3 -b 2>/tmp/status.fog
            pigz -dc </tmp/pigz1 | partimage restore ${target} stdin -f3 -b 2>/tmp/status.fog
            ;;
        0|2)
            # GZIP Compressed partclone
            echo " * Imaging using Partclone (gzip)"
            #zstdmt -dc </tmp/pigz1 | partclone.restore -n "Storage Location $storage, Image name $img" --ignore_crc -O ${target} -N -f 1
            pigz -dc </tmp/pigz1 | partclone.restore -n "Storage Location $storage, Image name $img" --ignore_crc -O ${target} -N -f 1
            # If this fails, try uncompressed form.
            #[[ ! $? -eq 0 ]] && cat </tmp/pigz1 | partclone.restore -O ${target} --ignore_crc -N -f 1 || true
            ;;
    esac
    exitcode=$?
    set +o pipefail
    [[ ! $exitcode -eq 0 ]] && handleError "Image failed to restore and exited with exit code $exitcode (${FUNCNAME[0]})\n   Info: $(cat /tmp/partclone.log)\n   Args Passed: $*"
    rm -rf /tmp/pigz1 >/dev/null 2>&1
}
# Gets the valid restore parts. They're only
#    valid if the partition data exists for
#    the partitions on the server
#
# $1 = Disk  (e.g. /dev/sdb)
# $2 = Disk number  (e.g. 1)
# $3 = ImagePath  (e.g. /net/foo)
getValidRestorePartitions() {
    local disk="$1"
    local disk_number="$2"
    local imagePath="$3"
    local setrestoreparts="$4"
    [[ -z $disk ]] && handleError "No disk passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No disk number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local valid_parts=""
    local parts=""
    local part=""
    local imgpart=""
    local part_number=0
    local lvmfilename=""
    local split=''
    if [[ $imgFormat -eq 6 || $imgFormat -eq 4 || $imgFormat -eq 2 ]]; then
        split='*'
    fi
    getPartitions "$disk"
    for part in $parts; do
        getPartitionNumber "$part"
        [[ $imgPartitionType != all && $imgPartitionType != $part_number ]] && continue
        # A partition captured as LVM has a sidecar instead of a dNpM.img.
        if [[ -d $imagePath ]]; then
            lvmFileName "$imagePath" "$disk_number" "$part_number"
            if [[ -r $lvmfilename ]]; then
                valid_parts="$valid_parts $part"
                continue
            fi
        fi
        case $osid in
            [1-2])
                [[ ! -f $imagePath ]] && imgpart="$imagePath/d${disk_number}p${part_number}.img${split}" || imgpart="$imagePath"
                ;;
            4|[5-7]|9|10|11)
                [[ ! -f $imagePath/sys.img.000 ]] && imgpart="$imagePath/d${disk_number}p${part_number}.img${split}"
                if [[ -z $imgpart ]]; then
                    case $win7partcnt in
                        1)
                            [[ $part_number -eq 1 ]] && imgpart="$imagePath/sys.img.*"
                            ;;
                        2)
                            [[ $part_number -eq 1 ]] && imgpart="$imagePath/rec.img.000"
                            [[ $part_number -eq 2 ]] && imgpart="$imagePath/sys.img.*"
                            ;;
                        3)
                            [[ $part_number -eq 1 ]] && imgpart="$imagePath/rec.img.000"
                            [[ $part_number -eq 2 ]] && imgpart="$imagePath/rec.img.001"
                            [[ $part_number -eq 3 ]] && imgpart="$imagePath/sys.img.*"
                            ;;
                    esac
                fi
                ;;
            *)
                imgpart="$imagePath/d${disk_number}p${part_number}.img${split}"
                ;;
        esac
        ls $imgpart >/dev/null 2>&1
        [[ $? -eq 0 ]] && valid_parts="$valid_parts $part"
    done
    [[ -z $setrestoreparts ]] && restoreparts=$(echo $valid_parts | uniq | sort -V) || restoreparts="$(echo $setrestoreparts | uniq | sort -V)"
}
# Makes all swap partitions and sets uuid's in linux setups
#
# $1 = Disk  (e.g. /dev/sdb)
# $2 = Disk number  (e.g. 1)
# $3 = ImagePath  (e.g. /net/foo)
# $4 = ImagePartitionType  (e.g. all, mbr, 1, 2, 3, etc.)
makeAllSwapSystems() {
    local disk="$1"
    local disk_number="$2"
    local imagePath="$3"
    local imgPartitionType="$4"
    [[ -z $disk ]] && handleError "No disk passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No drive number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imgPartitionType ]] && handleError "No image partition type passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local swapuuidfilename=""
    swapUUIDFileName "$imagePath" "$disk_number"
    [[ -r "$swapuuidfilename" ]] || return
    local parts=""
    local part=""
    local part_number=0
    getPartitions "$disk"
    for part in $parts; do
        getPartitionNumber "$part"
        [[ $imgPartitionType == all || $imgPartitionType -eq $part_number ]] && makeSwapSystem "$swapuuidfilename" "$part"
    done
    runPartprobe "$disk"
}
# Changes the hostname on windows systems
#
# $1 = Partition
changeHostname() {
    local part="$1"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $hostname || $hostearly -eq 0 ]] && return
    local reg_hostname_keys=(
        "\ControlSet001\Services\Tcpip\Parameters\NV Hostname"
        "\ControlSet001\Services\Tcpip\Parameters\Hostname"
        "\ControlSet001\Services\Tcpip\Parameters\NV HostName"
        "\ControlSet001\Services\Tcpip\Parameters\HostName"
        "\ControlSet001\Control\ComputerName\ActiveComputerName\ComputerName"
        "\ControlSet001\Control\ComputerName\ComputerName\ComputerName"
        "\ControlSet001\services\Tcpip\Parameters\NV Hostname"
        "\ControlSet001\services\Tcpip\Parameters\Hostname"
        "\ControlSet001\services\Tcpip\Parameters\NV HostName"
        "\ControlSet001\services\Tcpip\Parameters\HostName"
        "\CurrentControlSet\Services\Tcpip\Parameters\NV Hostname"
        "\CurrentControlSet\Services\Tcpip\Parameters\Hostname"
        "\CurrentControlSet\Services\Tcpip\Parameters\NV HostName"
        "\CurrentControlSet\Services\Tcpip\Parameters\HostName"
        "\CurrentControlSet\Control\ComputerName\ActiveComputerName\ComputerName"
        "\CurrentControlSet\Control\ComputerName\ComputerName\ComputerName"
        "\CurrentControlSet\services\Tcpip\Parameters\NV Hostname"
        "\CurrentControlSet\services\Tcpip\Parameters\Hostname"
        "\CurrentControlSet\services\Tcpip\Parameters\NV HostName"
        "\CurrentControlSet\services\Tcpip\Parameters\HostName"
    )
    dots "Mounting directory"
    if [[ ! -d /ntfs ]]; then
        mkdir -p /ntfs >/dev/null 2>&1
        if [[ ! $? -eq 0 ]]; then
            echo "Failed"
            debugPause
            handleError " * Could not create mount location (${FUNCNAME[0]})\n    Args Passed: $*"
        fi
    fi
    umount /ntfs >/dev/null 2>&1
    ntfs-3g -o remove_hiberfile,rw $part /ntfs >/tmp/ntfs-mount-output 2>&1
    checkStatus $? "done-pause" " * Could not mount $part (${FUNCNAME[0]})\n    Args Passed: $*\n    Reason: $(cat /tmp/ntfs-mount-output | tr -d \\0)"
    if [[ ! -f /usr/share/fog/lib/EOFREG ]]; then
        case $osid in
            1)
                regfile="$REG_LOCAL_MACHINE_XP"
                ;;
            2|4|[5-7]|9|10|11)
                regfile="$REG_LOCAL_MACHINE_7"
                ;;
        esac
        local regkey
        {
            for regkey in "${reg_hostname_keys[@]}"; do
                echo "ed $regkey"
                echo "$hostname"
            done
            echo "q"
            echo "y"
            echo
        } >/usr/share/fog/lib/EOFREG
    fi
    if [[ -e $regfile ]]; then
        dots "Changing hostname"
        reged -e $regfile < /usr/share/fog/lib/EOFREG >/dev/null 2>&1
        case $? in
            [0-2])
                echo "Done"
                debugPause
                ;;
            *)
                echo "Failed"
                debugPause
                umount /ntfs >/dev/null 2>&1
                echo " * Failed to change hostname"
                return
                ;;
        esac
    fi
    rm -rf /usr/share/fog/lib/EOFREG
    umount /ntfs >/dev/null 2>&1
}
# Fixes windows 7/8 boot, though may need
#    to be updated to only impact windows 7
#    in which case we need a more dynamic method
#
# $1 is the partition
fixWin7boot() {
    local part="$1"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ $osid != [5-7] ]] && return
    local fstype=""
    fsTypeSetting "$part"
    [[ $fstype != ntfs ]] && return
    dots "Mounting partition"
    if [[ ! -d /bcdstore ]]; then
        mkdir -p /bcdstore >/dev/null 2>&1
        checkStatus $? "silent" " * Could not create mount location (${FUNCNAME[0]})\n    Args Passed: $*"
    fi
    ntfs-3g -o remove_hiberfile,rw $part /bcdstore >/tmp/ntfs-mount-output 2>&1
    checkStatus $? "done-pause" " * Could not mount $part (${FUNCNAME[0]})\n    Args Passed: $*\n    Reason: $(cat /tmp/ntfs-mount-output | tr -d \\0)"
    if [[ ! -f /bcdstore/Boot/BCD ]]; then
        umount /bcdstore >/dev/null 2>&1
        return
    fi
    dots "Backing up and replacing BCD"
    mv /bcdstore/Boot/BCD{,.bak} >/dev/null 2>&1
    case $? in
        0)
            ;;
        *)
            echo "Failed"
            debugPause
            umount /bcdstore >/dev/null 2>&1
            echo " * Could not create backup"
            return
            ;;
    esac
    cp /usr/share/fog/BCD /bcdstore/Boot/BCD >/dev/null 2>&1
    case $? in
        0)
            echo "Done"
            debugPause
            umount /bcdstore >/dev/null 2>&1
            ;;
        *)
            echo "Failed"
            debugPause
            umount /bcdstore >/dev/null 2>&1
            echo " * Could not copy our bcd file"
            return
            ;;
    esac
    umount /bcdstore >/dev/null 2>&1
}
# Clears out windows hiber and page files
#
# $1 is the partition
clearMountedDevices() {
    local part="$1"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    if [[ ! -d /ntfs ]]; then
        mkdir -p /ntfs >/dev/null 2>&1
        case $? in
            0)
                umount /ntfs >/dev/null 2>&1
                ;;
            *)
                handleError "Could not create mount point /ntfs (${FUNCNAME[0]})\n   Args Passed: $*"
                ;;
        esac
    fi
    case $osid in
        4|[5-7]|9|10|11)
            local fstype=""
            fsTypeSetting "$part"
            REG_HOSTNAME_MOUNTED_DEVICES_7="\MountedDevices"
            if [[ ! -f /usr/share/fog/lib/EOFMOUNT ]]; then
                echo "cd $REG_HOSTNAME_MOUNTED_DEVICES_7" >/usr/share/fog/lib/EOFMOUNT
                echo "dellallv" >>/usr/share/fog/lib/EOFMOUNT
                echo "q" >>/usr/share/fog/lib/EOFMOUNT
                echo "y" >>/usr/share/fog/lib/EOFMOUNT
                echo >> /usr/share/fog/lib/EOFMOUNT
            fi
            case $fstype in
                ntfs)
                    dots "Clearing part ($part)"
                    ntfs-3g -o remove_hiberfile,rw $part /ntfs >/tmp/ntfs-mount-output 2>&1
                    checkStatus $? "silent" " * Could not mount $part (${FUNCNAME[0]})\n    Args Passed: $*\n    Reason: $(cat /tmp/ntfs-mount-output | tr -d \\0)"
                    if [[ ! -f $REG_LOCAL_MACHINE_7 ]]; then
                        echo "Reg file not found"
                        debugPause
                        umount /ntfs >/dev/null 2>&1
                        return
                    fi
                    reged -e $REG_LOCAL_MACHINE_7 </usr/share/fog/lib/EOFMOUNT >/dev/null 2>&1
                    case $? in
                        [0-2])
                            echo "Done"
                            debugPause
                            umount /ntfs >/dev/null 2>&1
                            ;;
                        *)
                            echo "Failed"
                            debugPause
                            umount /ntfs >/dev/null 2>&1
                            echo " * Could not clear partition $part"
                            return
                            ;;
                    esac
                    ;;
            esac
            ;;
    esac
}
# Only removes the page file
#
# $1 is the device name of the windows system partition
removePageFile() {
    local part="$1"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local fstype=""
    fsTypeSetting "$part"
    [[ ! $ignorepg -eq 1 ]] && return
    case $osid in
        [1-2]|4|[5-7]|9|10|11|50|51)
            case $fstype in
                ntfs)
                    dots "Mounting partition ($part)"
                    if [[ ! -d /ntfs ]]; then
                        mkdir -p /ntfs >/dev/null 2>&1
                        checkStatus $? "silent" " * Could not create mount location (${FUNCNAME[0]})\n    Args Passed: $*"
                    fi
                    umount /ntfs >/dev/null 2>&1
                    ntfs-3g -o remove_hiberfile,rw $part /ntfs >/tmp/ntfs-mount-output 2>&1
                    checkStatus $? "done-pause" " * Could not mount $part (${FUNCNAME[0]})\n    Args Passed: $*\n    Reason: $(cat /tmp/ntfs-mount-output | tr -d \\0)"
                    if [[ -f /ntfs/pagefile.sys ]]; then
                        dots "Removing page file"
                        rm -rf /ntfs/pagefile.sys >/dev/null 2>&1
                        case $? in
                            0)
                                echo "Done"
                                debugPause
                                ;;
                            *)
                                echo "Failed"
                                debugPause
                                echo " * Could not delete the page file"
                                ;;
                        esac
                    fi
                    if [[ -f /ntfs/hiberfil.sys ]]; then
                        dots "Removing hibernate file"
                        rm -rf /ntfs/hiberfil.sys >/dev/null 2>&1
                        case $? in
                            0)
                                echo "Done"
                                debugPause
                                ;;
                            *)
                                echo "Failed"
                                debugPause
                                umount /ntfs >/dev/null 2>&1
                                echo " * Could not delete the hibernate file"
                                ;;
                        esac
                    fi
                    umount /ntfs >/dev/null 2>&1
                    ;;
            esac
            ;;
    esac
}
# Sets OS mbr, as needed, and returns the Name
#    based on the OS id passed.
#
# $1 the osid to determine the os and mbr
determineOS() {
    local osid="$1"
    [[ -z $osid ]] && handleError "No os id passed (${FUNCNAME[0]})\n   Args Passed: $*"
    case $osid in
        1)
            osname="Windows XP"
            mbrfile="/usr/share/fog/mbr/xp.mbr"
            ;;
        2)
            osname="Windows Vista"
            mbrfile="/usr/share/fog/mbr/vista.mbr"
            ;;
        3)
            osname="Windows 98"
            mbrfile=""
            ;;
        4)
            osname="Windows (Other)"
            mbrfile=""
            ;;
        5)
            osname="Windows 7"
            mbrfile="/usr/share/fog/mbr/win7.mbr"
            defaultpart2start="206848s"
            ;;
        6)
            osname="Windows 8"
            mbrfile="/usr/share/fog/mbr/win8.mbr"
            defaultpart2start="718848s"
            ;;
        7)
            osname="Windows 8.1"
            mbrfile="/usr/share/fog/mbr/win8.mbr"
            defaultpart2start="718848s"
            ;;
        8)
            osname="Apple Mac OS"
            mbrfile=""
            ;;
        9)
            osname="Windows 10"
            mbrfile=""
            ;;
        10)
            osname="Windows 11"
            mbrfile=""
            ;;
        11)
            osname="Windows Server"
            mbrfile=""
            ;;
        50)
            osname="Linux"
            mbrfile=""
            ;;
        51)
            osname="Chromium OS"
            mbrfile=""
            ;;
        99)
            osname="Other OS"
            mbrfile=""
            ;;
        *)
            handleError " * Invalid OS ID ($osid) (${FUNCNAME[0]})\n   Args Passed: $*"
            ;;
    esac
}
# Converts the string (seconds) passed to human understanding
#
# $1 the seconds to convert
sec2string() {
    local T="$1"
    [[ -z $T ]] && handleError "No string passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local d=$((T/60/60/24))
    local H=$((T/60/60%24))
    local i=$((T/60%60))
    local s=$((T%60))
    local dayspace=''
    local hourspace=''
    local minspace=''
    [[ $H > 0 ]] && dayspace=' '
    [[ $i > 0 ]] && hourspace=':'
    [[ $s > 0 ]] && minspace=':'
    (($d > 0)) && printf '%d day%s' "$d" "$dayspace"
    (($H > 0)) && printf '%d%s' "$H" "$hourspace"
    (($i > 0)) && printf '%d%s' "$i" "$minspace"
    (($s > 0)) && printf '%d' "$s"
}
# Returns the disk based off the partition passed
#
# $1 is the partition to grab the disk from
getDiskFromPartition() {
    local part="$1"
    local israw="$2"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    if [[ $israw -eq 1 ]]; then
        disk=$part
        return
    fi
    part=${part#/dev/}
    disk=$(readlink /sys/class/block/$part)
    disk=${disk%/*}
    disk=/dev/${disk##*/}
}
# Returns the number of the partition passed
#
# $1 is the partition to get the partition number for
getPartitionNumber() {
    local part="$1"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    part_number=$(echo $part | grep -o '[0-9]*$')
}
# $1 is the partition to search for.
getPartitions() {
    local disk="$1"
    [[ -z $disk ]] && disk="$hd"
    [[ -z $disk ]] && handleError "No disk found (${FUNCNAME[0]})\n   Args Passed: $*"
    parts=$(lsblk -I 3,8,9,179,202,253,259 -lpno KNAME,TYPE $disk | awk '{if ($2 ~ /part/ || $2 ~ /md/) print $1}' | sort -V | uniq)
}
normalize() {
    local input="$*"

    # If no arguments, read from stdin
    if [[ $# -eq 0 ]]; then
        input=$(cat)
    fi

    echo $(trim "$input" | xargs | tr '[:upper:]' '[:lower:]')
}
resolve_path() {
    local input="$*"

    # If no arguments, read from stdin
    if [[ $# -eq 0 ]]; then
        input=$(cat)
    fi

    echo $(readlink -f "$input" 2>/dev/null || echo "$input")
}
# Gets the hard drive on the host
# Note: This function makes a best guess
getHardDisk() {
    hd=""
    disks=""

    # Get valid devices (filter out 0B disks) once, keeping lsblk enumeration order
    local devs
    devs=$(lsblk -dpno KNAME,SIZE -I 3,8,9,179,202,253,259 | awk '$2 != "0B" && !seen[$1]++ { print $1 }')

    if [[ -n $fdrive ]]; then
        local found_match=0
        for spec in ${fdrive//,/ }; do
            local spec_resolved spec_norm spec_normalized matched
            spec_resolved=$(resolve_path "$spec")
            spec_normalized=$(normalize "$spec")
            matched=0

            for dev in $devs; do
                local size uuid serial wwn
                size=$(blockdev --getsize64 "$dev" | normalize)
                uuid=$(blkid -s UUID -o value "$dev" 2>/dev/null | normalize)
                # Grab SERIAL and WWN safely (handles blanks and spacing)
                local kv serial_raw wwn_raw
                kv="$(lsblk -pdPno SERIAL,WWN "$dev" 2>/dev/null)" || kv=""
                serial_raw="$(sed -n 's/.*SERIAL="\([^"]*\)".*/\1/p' <<<"$kv")"
                wwn_raw="$(sed -n 's/.*WWN="\([^"]*\)".*/\1/p' <<<"$kv")"

                serial="$(normalize "$serial_raw")"
                wwn="$(normalize "$wwn_raw")"

                [[ -n $isdebug ]] && {
                    echo "Comparing spec='$spec' (resolved: '$spec_resolved') with dev=$dev"
                    echo "  size=$size serial=$serial wwn=$wwn uuid=$uuid"
                }
                if [[ "x$spec_resolved" == "x$dev" || \
                      "x$spec_normalized" == "x$size" || \
                      "x$spec_normalized" == "x$wwn" || \
                      "x$spec_normalized" == "x$serial" || \
                      "x$spec_normalized" == "x$uuid" ]]; then
                    [[ -n $isdebug ]] && echo "Matched spec '$spec' to device '$dev' (size=$size, serial=$serial, wwn=$wwn, uuid=$uuid)"
                    matched=1
                    found_match=1
                    disks="$disks $dev"
                    # remove matched dev from the pool
                    devs="$(echo " $devs " | sed "s# $dev # #g; s/^ *//; s/ *$//")"
                    break
                fi
            done

            [[ $matched -eq 0 ]] && echo "WARNING: Drive spec '$spec' does not match any available device." >&2
        done

        [[ $found_match -eq 0 ]] && handleError "Fatal: No valid drives found for 'Host Primary Disk'='$fdrive'."

        disks=$(echo "$disks $devs" | xargs)   # add unmatched devices for completeness

    elif [[ "x$imgType" == "xmpa" ]]; then
        # Multi-disk image: keep enumeration order
        disks="$devs"
        if [[ "x$type" == "xdown" ]]; then
            # Expected disk sizes from image (d1.size, d2.size, ...)
            local sizefiles expected_sizes=()
            sizefiles=$(ls -1 "${imagePath}"/d*.size 2>/dev/null | sort -V)

            if [[ -n "$sizefiles" ]]; then
                local f exp
                for f in $sizefiles; do
                    # file format: d1: 123456789
                    exp="$(awk -F: '{gsub(/[[:space:]]/,"",$2); print $2}' "$f")"
                    [[ -n "$exp" ]] && expected_sizes+=("$exp")
                done

                # Actual disks (keep lsblk order)
                local actual_disks=()
                for d in $devs; do actual_disks+=("$d"); done

                # Build mapping in d1,d2,... order
                local mapped=() used=" "
                local i match candidates

                for i in "${!expected_sizes[@]}"; do
                    exp="${expected_sizes[$i]}"
                    match=""
                    candidates=0

                    # Exact match pass
                    for d in "${actual_disks[@]}"; do
                        [[ "$used" == *" $d "* ]] && continue
                        if [[ "$(blockdev --getsize64 "$d" 2>/dev/null)" == "$exp" ]]; then
                            match="$d"
                            candidates=$((candidates+1))
                        fi
                    done

                    if [[ $candidates -eq 1 ]]; then
                        mapped+=("$match")
                        used+=" $match "
                        continue
                    fi

                    # Ambiguous or missing -> warn and fall back
                    echo "WARNING: Could not uniquely match disk for expected size $exp (found $candidates exact matches). Falling back to enumeration order." >&2
                    mapped=()
                    break
                done

                if [[ ${#mapped[@]} -gt 0 ]]; then
                    disks="${mapped[*]}"
                    hd="${mapped[0]}"
                    return 0
                fi
            fi
        fi
    else
        if [[ -n $largesize ]]; then
            # Auto-select largest available drive
            hd=$(
                for d in $devs; do
                    echo "$(blockdev --getsize64 "$d") $d"
                done | sort -k1,1nr -k2,2 | head -1 | cut -d' ' -f2
            )
        else
            for d in $devs; do
                hd="$d"
                break
            done
        fi
        [[ -z $hd ]] && handleError "Could not determine a suitable disk automatically."
        disks="$hd"
    fi

    # Set primary hard disk
    hd=$(awk '{print $1}' <<< "$disks")
}

# Finds the hard drive info and set's up the type
findHDDInfo() {
    dots "Looking for Hard Disk(s)"
    getHardDisk
    if [[ -z $hd || -z $disks ]]; then
        echo "Failed"
        debugPause
        handleError "Could not find hard disk ($0)\n   Args Passed: $*"
    fi
    echo "Done"
    debugPause
    case $imgType in
        [Nn]|mps|dd)
            case $type in
                down)
                    diskSize=$(lsblk --bytes -dplno SIZE -I 3,8,9,179,259 $hd)
                    [[ $diskSize -gt 2199023255552 ]] && layPartSize="2tB"
                    echo " * Using Disk: $hd"
                    [[ $imgType == +([nN]) ]] && validResizeOS
                    enableWriteCache "$hd"
                    ;;
                up)
                    dots "Reading Partition Tables"
                    if [[ $imgType == "dd" ]]; then
                        echo "Skipped"
                    else
                        runPartprobe "$hd"
                        getPartitions "$hd"
                        if [[ -z $parts ]]; then
                            echo "Failed"
                            debugPause
                            handleError "Could not find partitions ($0)\n    Args Passed: $*"
                        fi
                        echo "Done"
                    fi
                    debugPause
                    ;;
            esac
            echo " * Using Hard Disk: $hd"
            ;;
        mpa)
            case $type in
                up)
                    for disk in $disks; do
                        dots "Reading Partition Tables on $disk"
                        getPartitions "$disk"
                        if [[ -z $parts ]]; then
                            echo "Failed"
                            debugPause
                            echo " * No partitions for disk $disk"
                            debugPause
                            continue
                        fi
                        echo "Done"
                        debugPause
                    done
                    ;;
            esac
            echo " * Using Hard Disks: $disks"
            ;;
    esac
}

# Imaging complete
completeTasking() {
    case $type in
        up)
            chmod -R 775 "$imagePath" >/dev/null 2>&1
            killStatusReporter
            . /bin/fog.imgcomplete
            ;;
        down)
            killStatusReporter
            if [[ -f /images/postdownloadscripts/fog.postdownload ]]; then
                postdownpath="/images/postdownloadscripts/"
                . ${postdownpath}fog.postdownload
            fi
            [[ $capone -eq 1 ]] && exit 0
            if [[ $osid == +([1-2]|4|[5-7]|9|10|11) ]]; then
                for disk in $disks; do
                    getPartitions "$disk"
                    for part in $parts; do
                        fsTypeSetting "$part"
                        [[ $fstype == ntfs ]] && changeHostname "$part"
                    done
                done
            fi
            . /bin/fog.imgcomplete
            ;;
    esac
}
# Corrects mbr layout for Vista OS
#
# $1 is the disk to correct for
correctVistaMBR() {
    local disk="$1"
    [[ -z $disk ]] && handleError "No disk passed (${FUNCNAME[0]})\n   Args Passed: $*"
    dots "Correcting Vista MBR"
    dd if=$disk of=/tmp.mbr count=1 bs=512 >/dev/null 2>&1
    checkStatus $? "silent" "Could not create backup (${FUNCNAME[0]})\n   Args Passed: $*"
    xxd /tmp.mbr /tmp.mbr.txt >/dev/null 2>&1
    checkStatus $? "silent" "xxd command failed (${FUNCNAME[0]})\n   Args Passed: $*"
    rm /tmp.mbr >/dev/null 2>&1
    checkStatus $? "silent" "Couldn't remove /tmp.mbr file (${FUNCNAME[0]})\n   Args Passed: $*"
    fogmbrfix /tmp.mbr.txt /tmp.mbr.fix.txt >/dev/null 2>&1
    checkStatus $? "silent" "fogmbrfix failed to operate (${FUNCNAME[0]})\n   Args Passed: $*"
    rm /tmp.mbr.txt >/dev/null 2>&1
    checkStatus $? "silent" "Could not remove the text file (${FUNCNAME[0]})\n   Args Passed: $*"
    xxd -r /tmp.mbr.fix.txt /mbr.mbr >/dev/null 2>&1
    checkStatus $? "silent" "Could not run second xxd command (${FUNCNAME[0]})\n   Args Passed: $*"
    rm /tmp.mbr.fix.txt >/dev/null 2>&1
    checkStatus $? "silent" "Could not remove the fix file (${FUNCNAME[0]})\n   Args Passed: $*"
    dd if=/mbr.mbr of="$disk" count=1 bs=512 >/dev/null 2>&1
    checkStatus $? "done" "Could not apply fixed MBR (${FUNCNAME[0]})\n   Args Passed: $*"
    debugPause
}
# Prints an error with visible information
#
# $1 is the string to inform what went wrong
handleError() {
    local str="$1"
    local parts=""
    local part=""
    echo "##############################################################################"
    echo "#                                                                            #"
    echo "#                         An error has been detected!                        #"
    echo "#                                                                            #"
    echo "##############################################################################"
    echo "Init Version: $initversion"
    echo -e "$str\n"
    echo "Kernel variables and settings:"
    cat /proc/cmdline | sed 's/ad.*=.* //g'
    #
    # expand the file systems in the restored partitions
    #
    # Windows 7, 8, 8.1:
    # Windows 2000/XP, Vista:
    # Linux:
    if [[ -n $2 ]]; then
        case $osid in
            [1-2]|4|[5-7]|9|10|11|50|51)
                if [[ -n "$hd" ]]; then
                    getPartitions "$hd"
                    for part in $parts; do
                        expandPartition "$part"
                    done
                fi
                ;;
        esac
    fi
    if [[ -z $isdebug ]]; then
        echo "##############################################################################"
        echo "#                                                                            #"
        echo "#                      Computer will reboot in 1 minute                      #"
        echo "#                                                                            #"
        echo "##############################################################################"
        usleep 60000000
    else
        debugPause
    fi
    exit 1
}
# Prints a visible banner describing an issue but not breaking
#
# $1 The string to inform the user what the problem is
handleWarning() {
    local str="$1"
    echo "##############################################################################"
    echo "#                                                                            #"
    echo "#                        A warning has been detected!                        #"
    echo "#                                                                            #"
    echo "##############################################################################"
    echo -e "$str"
    echo "##############################################################################"
    echo "#                                                                            #"
    echo "#                          Will continue in 1 minute                         #"
    echo "#                                                                            #"
    echo "##############################################################################"
    usleep 60000000
    debugPause
}
# Re-reads the partition table of the disk passed
#
# $1 is the disk
runPartprobe() {
    local disk="$1"
    [[ -z $disk ]] && handleError "No disk passed (${FUNCNAME[0]})\n   Args Passed: $*"
    umount /ntfs /bcdstore >/dev/null 2>&1
    udevadm settle
    blockdev --rereadpt $disk >/dev/null 2>&1
    [[ ! $? -eq 0 ]] && handleError "Failed to read back partitions (${FUNCNAME[0]})\n   Args Passed: $*"
}
# Sends a command list to a file for use when debugging
#
# $1 The string of the command needed to run.
debugCommand() {
    local str="$1"
    case $isdebug in
        [Yy][Ee][Ss]|[Yy])
            echo -e "$str" >> /tmp/cmdlist
            ;;
    esac
}
# Escapes the passed item where needed
#
# $1 the item that needs to be escaped
escapeItem() {
    local item="$1"
    echo $item | sed -r 's%/%\\/%g'
}
# uploadFormat
# Description:
# Tells the system what format to upload in, whether split or not.
# Expects first argument to be the fifo to send to.
# Expects part of the filename in the case of resizable
#    will append 000 001 002 automatically
#
# $1 The fifo name (file in file out)
# $2 The file to upload into on the server
uploadFormat() {
    local fifo="$1"
    local file="$2"
    [[ -z $fifo ]] && handleError "Missing file in file out (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $file ]] && handleError "Missing file name to store (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ ! -e $fifo ]] && mkfifo $fifo >/dev/null 2>&1
    local cores=$(nproc)
    cores=$((cores - 1))
    [[ $cores -lt 1 ]] && cores=1
    case $imgFormat in
        6)
            # ZSTD Split files compressed.
            ( set -o pipefail; zstdmt --rsyncable --ultra $PIGZ_COMP < $fifo | split -a 3 -d -b 200m - ${file}. ) &
            ;;
        5)
            # ZSTD compressed.
            zstdmt --rsyncable --ultra $PIGZ_COMP < $fifo > ${file}.000 &
            ;;
        4)
            # Split files uncompressed.
            ( set -o pipefail; cat $fifo | split -a 3 -d -b 200m - ${file}. ) &
            ;;
        3)
            # Uncompressed.
            cat $fifo > ${file}.000 &
            ;;
        2)
            # GZip/piGZ Split file compressed.
            ( set -o pipefail; pigz $PIGZ_COMP < $fifo | split -a 3 -d -b 200m - ${file}. ) &
            ;;
        *)
            # GZip/piGZ Compressed.
            pigz $PIGZ_COMP < $fifo > ${file}.000 &
        ;;
    esac
    formatPID=$!
}
# Thank you, fractal13 Code Base
#
# Save enough MBR and embedding area to capture all of GRUB
# Strategy is to capture EVERYTHING before the first partition.
# Then, leave a marker that this is a GRUB MBR for restoration.
# We could get away with less storage, but more details are required
# to parse the information correctly.  It would make the process
# more complicated.
#
# See the discussion about the diskboot.img and the sector list
# here: http://banane-krumm.de/bootloader/grub2.html
#
# Expects:
# the device name (e.g. /dev/sda) as the first parameter,
# the disk number (e.g. 1) as the second parameter
# the directory to store images in (e.g. /image/dev/xyz) as the third parameter
#
# $1 is the disk
# $2 is the disk number
# $3 is the image path to save the file to.
# $4 is the determinator of sgdisk use or not
saveGRUB() {
    local disk="$1"
    local disk_number="$2"
    local imagePath="$3"
    local sgdisk="$4"
    [[ -z $disk ]] && handleError "No disk passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No drive number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    # Determine the number of sectors to copy
    # Hack Note: print $4+0 causes the column to be interpretted as a number
    #            so the comma is tossed
    local count=$(flock $disk sfdisk -d $disk 2>/dev/null | awk '/start=[ ]*[1-9]/{print $4+0}' | sort -n | head -n1)
    local has_grub=$(dd if=$disk bs=512 count=1 2>&1 | grep -i 'grub')
    local hasgrubfilename=""
    if [[ -n $has_grub ]]; then
        hasGrubFileName "$imagePath" "$disk_number" "$sgdisk"
        touch $hasgrubfilename
    fi
    # Ensure that no more than 1MiB of data is copied (already have this size used elsewhere)
    [[ $count -gt 2048 ]] && count=2048
    [[ $count -eq 8 || $count -eq 63 ]] && count=1
    local mbrfilename=""
    MBRFileName "$imagePath" "$disk_number" "mbrfilename" "$sgdisk"
    dd if=$disk of=$mbrfilename count=$count bs=512 >/dev/null 2>&1
}
# Checks for the existence of the grub embedding area in the image directory.
# Echos 1 for true, and 0 for false.
#
# Expects:
# the device name (e.g. /dev/sda) as the first parameter,
# the disk number (e.g. 1) as the second parameter
# the directory images stored in (e.g. /image/xyz) as the third parameter
# $1 is the disk
# $2 is the disk number
# $3 is the image path
# $4 is the sgdisk determinator
hasGRUB() {
    local disk_number="$1"
    local imagePath="$2"
    local sgdisk="$3"
    [[ -z $disk_number ]] && handleError "No drive number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local hasgrubfilename=""
    hasGrubFileName "$imagePath" "$disk_number" "$sgdisk"
    hasGRUB=0
    [[ -e $hasgrubfilename ]] && hasGRUB=1
}
# Restore the grub boot record and all of the embedding area data
# necessary for grub2.
#
# Expects:
# the device name (e.g. /dev/sda) as the first parameter,
# the disk number (e.g. 1) as the second parameter
# the directory images stored in (e.g. /image/xyz) as the third parameter
# $1 is the disk
# $2 is the disk number
# $3 is the image path
# $4 is the sgdisk determinator
restoreGRUB() {
    local disk="$1"
    local disk_number="$2"
    local imagePath="$3"
    local sgdisk="$4"
    [[ -z $disk ]] && handleError "No disk passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No drive number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local tmpMBR=""
    MBRFileName "$imagePath" "$disk_number" "tmpMBR" "$sgdisk"
    local count=$(du -B 512 $tmpMBR | awk '{print $1}')
    [[ $count -eq 8 || $count -eq 63 ]] && count=1
    dd if=$tmpMBR of=$disk bs=512 count=$count >/dev/null 2>&1
    runPartprobe "$disk"
}
# Waits for enter if system is debug type
debugPause() {
    case $isdebug in
        [Yy][Ee][Ss]|[Yy])
            echo " * Press [Enter] key to continue"
            read  -p "$*"
            ;;
        *)
            return
            ;;
    esac
}
# Handle the exit status of the immediately-preceding command using the shared
# Done/Failed idiom. Usage:
#   checkStatus <status> <success-mode> <error-message> [extra handleError args...]
# <success-mode> controls what is emitted when <status> is 0:
#   done        -> echo "Done"
#   done-pause  -> echo "Done"; debugPause
#   silent      -> emit nothing
# On any non-zero status: echo "Failed"; debugPause; handleError <message> <extra...>.
# The caller expands ${FUNCNAME[0]} and $* into <error-message> itself, so the
# function name and args shown match the original inline case block exactly.
checkStatus() {
    local status="$1" mode="$2" msg="$3"
    shift 3
    case $status in
        0)
            case $mode in
                done)
                    echo "Done"
                    ;;
                done-pause)
                    echo "Done"
                    debugPause
                    ;;
                silent)
                    ;;
            esac
            ;;
        *)
            echo "Failed"
            debugPause
            handleError "$msg" "$@"
            ;;
    esac
}
debugEcho() {
    local str="$*"
    case $isdebug in
        [Yy][Ee][Ss]|[Yy])
            echo "$str"
            ;;
        *)
            return
            ;;
    esac
}
majorDebugEcho() {
    [[ $ismajordebug -ge 1 ]] && echo "$*"
}
majorDebugPause() {
    [[ ! $ismajordebug -gt 0 ]] && return
    echo " * Press [Enter] key to continue"
    read -p "$*"
}
# Build "$imagePath/d<disk_number>.<suffix>" into the named variable. Validation
# errors report the calling helper (FUNCNAME[1]), not this generator.
partitionFileName() {
    local imagePath="$1"  # e.g. /net/dev/foo
    local disk_number="$2"    # e.g. 1
    local suffix="$3"
    local __outvar="$4"
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[1]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No disk number passed (${FUNCNAME[1]})\n   Args Passed: $*"
    printf -v "$__outvar" '%s' "$imagePath/d${disk_number}.${suffix}"
}
swapUUIDFileName() { partitionFileName "$1" "$2" "original.swapuuids" swapuuidfilename; }
sfdiskPartitionFileName() { partitionFileName "$1" "$2" "partitions" sfdiskoriginalpartitionfilename; }
sfdiskLegacyOriginalPartitionFileName() { partitionFileName "$1" "$2" "original.partitions" sfdisklegacyoriginalpartitionfilename; }
sfdiskMinimumPartitionFileName() { partitionFileName "$1" "$2" "minimum.partitions" sfdiskminimumpartitionfilename; }
fixedSizePartitionsFileName() { partitionFileName "$1" "$2" "fixed_size_partitions" fixed_size_file; }
sfdiskOriginalPartitionFileName() {
    local imagePath="$1"  # e.g. /net/dev/foo
    local disk_number="$2"    # e.g. 1
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No disk number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    sfdiskPartitionFileName "$imagePath" "$disk_number"
}
hasGrubFileName() {
    local imagePath="$1"  # e.g. /net/dev/foo
    local disk_number="$2"    # e.g. 1
    local sgdisk="$3"
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No disk number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    hasgrubfilename="$imagePath/d${disk_number}.has_grub"
    [[ -n $sgdisk ]] && hasgrubfilename="$imagePath/d${disk_number}.grub.mbr"
}
MBRFileName() {
    local imagePath="$1"  # e.g. /net/dev/foo
    local disk_number="$2"    # e.g. 1
    local varVar="$3"
    local sgdisk="$4"
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No disk number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $varVar ]] && handleError "No variable to set passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local mbr=""
    local hasGRUB=0
    hasGRUB "$disk_number" "$imagePath" "$sgdisk"
    [[ -n $sgdisk && $hasGRUB -eq 1 ]] && mbr="$imagePath/d${disk_number}.grub.mbr" || mbr="$imagePath/d${disk_number}.mbr"
    case $type in
        down)
            [[ ! -f $mbr && -n $mbrfile ]] && mbr="$mbrfile"
            printf -v "$varVar" "$mbr"
            [[ -z $mbr ]] && handleError "Image store corrupt, unable to locate MBR, no default file specified (${FUNCNAME[0]})\n    Args Passed: $*\n    $varVar Variable set to: ${!varVar}"
            [[ ! -f $mbr ]] && handleError "Image store corrupt, unable to locate MBR, no file found (${FUNCNAME[0]})\n    Args Passed: $*\n    Variable set to: ${!varVar}\n    $varVar Variable set to: ${!varVar}"
            ;;
        up)
            printf -v "$varVar" "$mbr"
            ;;
    esac
}
EBRFileName() {
    local path="$1"  # e.g. /net/dev/foo
    local disk_number="$2"    # e.g. 1
    local part_number="$3"    # e.g. 5
    [[ -z $path ]] && handleError "No path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No disk number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $part_number ]] && ebrfilename="" || ebrfilename="$path/d${disk_number}p${part_number}.ebr"
}
tmpEBRFileName() {
    local disk_number="$1"
    local part_number="$2"
    [[ -z $disk_number ]] && handleError "No disk number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $part_number ]] && handleError "No partition number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local ebrfilename=""
    EBRFileName "/tmp" "$disk_number" "$part_number"
    tmpebrfilename="$ebrfilename"
}
lvmFileName() {
    local imagePath="$1"  # e.g. /net/dev/foo
    local disk_number="$2"    # e.g. 1
    local part_number="$3"    # e.g. 2
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No disk number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $part_number ]] && handleError "No partition number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    lvmfilename="$imagePath/d${disk_number}p${part_number}.lvm"
}
lvmVgcfgFileName() {
    local lvmfilename=""
    lvmFileName "$1" "$2" "$3"
    lvmvgcfgfilename="${lvmfilename}.vgcfg"
}
lvmLVImageFileName() {
    local imagePath="$1"  # e.g. /net/dev/foo
    local disk_number="$2"    # e.g. 1
    local part_number="$3"    # e.g. 2
    local lv_name="$4"    # e.g. root
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No disk number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $part_number ]] && handleError "No partition number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $lv_name ]] && handleError "No logical volume name passed (${FUNCNAME[0]})\n   Args Passed: $*"
    lvmlvimagefilename="$imagePath/d${disk_number}p${part_number}.${lv_name}.img"
}
#
# Works for MBR/DOS or GPT style partition tables
# Only saves PT information if the type is "all" or "mbr"
#
# For MBR/DOS style PT
#   Saves the MBR as everything before the start of the first partition (512+ bytes)
#      This includes the DOS MBR or GRUB.  Don't know about other bootloaders
#      This includes the 4 primary partitions
#   The EBR of extended and logical partitions is actually the first 512 bytes of
#      the partition, so we don't need to save/restore them here.
#
#
savePartitionTablesAndBootLoaders() {
    local disk="$1"                    # e.g. /dev/sda
    local disk_number="$2"                 # e.g. 1
    local imagePath="$3"               # e.g. /net/dev/foo
    local osid="$4"                    # e.g. 50
    local imgPartitionType="$5"
    local sfdiskfilename="$6"
    [[ -z $disk ]] && handleError "No disk passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No drive number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $osid ]] && handleError "No osid passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imgPartitionType ]] && handleError "No img part type passed (${FUNCNAME[0]})\n   Args Passed: $*"
    if [[ -z $sfdiskfilename ]]; then
        sfdiskPartitionFileName "$imagePath" "$disk_number"
        sfdiskfilename="$sfdiskoriginalpartitionfilename"
    fi
    local hasgpt=0
    hasGPT "$disk"
    local have_extended_partition=0  # e.g. 0 or 1-n (extended partition count)
    local strdots=""
    [[ $hasgpt -eq 0 ]] && have_extended_partition=$(flock $disk sfdisk -l $disk 2>/dev/null | egrep "^${disk}.* (Extended|W95 Ext'd \(LBA\))$" | wc -l)
    runPartprobe "$disk"
    case $hasgpt in
        0)
            strdots="Saving Partition Tables (MBR)"
            case $osid in
                4|50|51)
                    [[ $disk_number -eq 1 ]] && strdots="Saving Partition Tables and GRUB (MBR)"
                    ;;
            esac
            dots "$strdots"
            saveGRUB "$disk" "$disk_number" "$imagePath"
            flock $disk sfdisk -d $disk 2>/dev/null > $sfdiskfilename
            echo "Done"
            debugPause
            [[ $have_extended_partition -ge 1 ]] && saveAllEBRs "$disk" "$disk_number" "$imagePath"
            echo "Done"
            ;;
        1)
            dots "Saving Partition Tables (GPT)"
            saveGRUB "$disk" "$disk_number" "$imagePath" "true"
            sgdisk -b "$imagePath/d${disk_number}.mbr" $disk >/dev/null 2>&1
            if [[ ! $? -eq 0 ]]; then
                echo "Failed"
                debugPause
                handleError "Error trying to save GPT partition tables (${FUNCNAME[0]})\n   Args Passed: $*"
            fi
            flock $disk sfdisk -d $disk 2>/dev/null > $sfdiskfilename
            echo "Done"
            ;;
    esac
    runPartprobe "$disk"
    debugPause
}
clearPartitionTables() {
    local disk="$1"
    [[ -z $disk ]] && handleError "No disk passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ $nombr -eq 1 ]] && return
    dots "Erasing current MBR/GPT Tables"
    sgdisk -Z $disk >/dev/null 2>&1
    case $? in
        0)
            echo "Done"
            ;;
        2)
            echo "Done, but cleared corrupted partition."
            ;;
        *)
            echo "Failed"
            debugPause
            handleError "Error trying to erase partition tables (${FUNCNAME[0]})\n   Args Passed: $*"
            ;;
    esac
    runPartprobe "$disk"
    debugPause
}
# Low-level reformats an NVMe namespace to a target logical sector size when the
# device exposes a matching LBA format, so an image captured at that sector size
# can deploy to it. Returns 0 only after the reformat is confirmed to have taken
# effect; returns non-zero (leaving the disk untouched) for a non-NVMe device, a
# device with no matching metadata-free LBA format, or any reformat failure, so
# the caller can fall back to refusing the deploy.
#
# $1 is the disk (e.g. /dev/nvme0n1)
# $2 is the wanted logical sector size in bytes (the image's sector size)
nvmeReformatToSectorSize() {
    local disk="$1"
    local wantsize="$2"
    [[ $disk == *[Nn][Vv][Mm][Ee]* ]] || return 1
    # `nvme id-ns` prints one line per LBA format, e.g.
    #   lbaf  1 : ms:0   lbads:12 rp:0x2 (in use)
    # where the logical block size is 2^lbads bytes. Pick the first metadata-free
    # (ms:0) format whose size equals the image's sector size.
    local lbaf=$(nvme id-ns "$disk" 2>/dev/null | awk -v want="$wantsize" '
        $1 == "lbaf" {
            idx = $2; sub(/:$/, "", idx); ms = ""; lbads = ""
            for (i = 3; i <= NF; i++) {
                if ($i ~ /^ms:/)    ms = substr($i, 4)
                if ($i ~ /^lbads:/) lbads = substr($i, 7)
            }
            if (ms == 0 && lbads != "" && 2 ^ lbads == want) { print idx; exit }
        }')
    [[ -z $lbaf ]] && return 1
    echo ""
    echo " *** Logical sector-size mismatch on $disk ***"
    echo "   This image was captured with ${wantsize}-byte logical sectors."
    echo "   $disk is an NVMe device that exposes a matching ${wantsize}-byte LBA format (lbaf $lbaf)."
    echo "   FOS will LOW-LEVEL REFORMAT this namespace to ${wantsize}-byte sectors so the image can deploy."
    echo "   This ERASES the drive (the deploy would erase it regardless) and cannot be undone."
    echo ""
    echo " You have 60 seconds to power off this computer to cancel!"
    local s=""
    for ((s = 60; s > 0; s--)); do
        printf "\r   Reformatting %s in %2d second(s)...  " "$disk" "$s"
        usleep 1000000
    done
    printf "\n"
    dots "Reformatting $disk to ${wantsize}-byte sectors"
    nvme format "$disk" --lbaf="$lbaf" --force >/dev/null 2>&1
    local fmtexit=$?
    if [[ $fmtexit -ne 0 ]]; then
        echo "Failed"
        return 1
    fi
    runPartprobe "$disk"
    local newsize=$(blockdev --getss "$disk" 2>/dev/null)
    if [[ $newsize -ne $wantsize ]]; then
        echo "Failed"
        return 1
    fi
    echo "Done"
    return 0
}
# Emits (on stdout) one device-class-specific line for the sector-size-mismatch
# refusal, telling the operator whether this class of target could ever match the
# image's sector size and where the fix lives if so. Emits nothing for classes
# with no useful class-specific advice (plain SATA/SAS/USB targets); the generic
# remedy in the refusal message covers those. The per-class reasoning — why only
# NVMe gets an automatic reformat — is docs/adr/0005-non-nvme-sector-size-mismatch-stays-refusal-only.md
#
# $1 is the disk (e.g. /dev/mmcblk0)
# $2 is the image's sector size in bytes
# $3 is the target disk's sector size in bytes
sectorSizeMismatchHint() {
    local disk="$1"
    local wantsize="$2"
    local havesize="$3"
    local name="${disk##*/}"
    case "$name" in
        mmcblk*)
            echo "$disk is an eMMC/SD device; its ${havesize}-byte logical sector size is fixed by the MMC/SD specification and cannot be changed. Only an image captured on ${havesize}-byte-sector hardware can deploy to it."
            ;;
        nvme*)
            echo "$disk is an NVMe device but exposes no metadata-free ${wantsize}-byte LBA format, so it cannot be low-level reformatted to match this image."
            ;;
        vd*|xvd*)
            echo "$disk is a virtual disk; its logical sector size is set by the hypervisor (e.g. the disk's logical_block_size property in QEMU/libvirt) and can only be changed in the VM configuration."
            ;;
        sd*)
            # UFS modules surface as plain SCSI disks; the transport only shows in
            # the SCSI host driver's name (ufshcd), so classify via sysfs.
            local host=$(readlink -f "/sys/block/$name/device" 2>/dev/null | grep -o 'host[0-9][0-9]*' | head -1)
            local hostdriver=""
            [[ -n $host ]] && hostdriver=$(cat "/sys/class/scsi_host/$host/proc_name" 2>/dev/null)
            [[ $hostdriver == ufshcd* ]] && echo "$disk is a UFS device; its ${havesize}-byte logical sector size is fixed when the module is provisioned at the factory and cannot be changed in the field. Only an image captured on ${havesize}-byte-sector hardware can deploy to it."
            ;;
    esac
}
# Refuses a deploy when the target disk's logical sector size does not match the
# sector size the image was captured with. Partition-table LBA units and
# filesystem metadata bake in the source disk's logical sector size at capture
# and are not rewritten on restore, so a mismatch yields an unmountable/
# unbootable result. The source size is read from the stored sfdisk dump's
# "sector-size:" line and the target size comes from `blockdev --getss`; we only
# refuse when both are known and differ. sfdisk did not emit "sector-size:"
# until util-linux 2.35 (~2020), so an older dump (including a genuine 4Kn one)
# records no source size; there we allow the deploy rather than guess 512 and
# wrongly refuse a matching 4Kn->4Kn deploy that works today. See
# docs/adr/0001-sector-size-geometry-match-or-refuse.md
#
# When both sizes are known and differ, we first try to make the target match by
# low-level reformatting an NVMe namespace to the image's sector size
# (nvmeReformatToSectorSize); only if that is impossible do we refuse. See
# docs/adr/0002-nvme-reformat-target-to-match-image.md
#
# $1 is the disk (e.g. /dev/sda)
# $2 is the disk number
# $3 is the image path
validateImageSectorSize() {
    local disk="$1"
    local disk_number="$2"
    local imagePath="$3"
    [[ -z $disk ]] && handleError "No disk passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No drive number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local targetsectorsize=$(blockdev --getss $disk 2>/dev/null)
    # If the target size can't be read, don't introduce a new failure.
    [[ -z $targetsectorsize ]] && return 0
    local sfdiskminimumpartitionfilename=""
    local sfdiskoriginalpartitionfilename=""
    local sfdisklegacyoriginalpartitionfilename=""
    sfdiskMinimumPartitionFileName "$imagePath" "$disk_number"
    sfdiskPartitionFileName "$imagePath" "$disk_number"
    sfdiskLegacyOriginalPartitionFileName "$imagePath" "$disk_number"
    local sfdiskfilename=""
    local candidate=""
    for candidate in "$sfdiskminimumpartitionfilename" "$sfdiskoriginalpartitionfilename" "$sfdisklegacyoriginalpartitionfilename"; do
        [[ -r $candidate ]] && sfdiskfilename="$candidate" && break
    done
    # The source size is only known if the dump recorded it. With no dump, or a
    # pre-util-linux-2.35 dump that has no "sector-size:" line, the source size
    # is unknown; allow the deploy rather than guess and risk a wrong refusal.
    local imagesectorsize=""
    [[ -n $sfdiskfilename ]] && imagesectorsize=$(awk '/^sector-size:/{print $2; exit}' "$sfdiskfilename")
    [[ -z $imagesectorsize ]] && return 0
    if [[ $imagesectorsize -ne $targetsectorsize ]]; then
        nvmeReformatToSectorSize "$disk" "$imagesectorsize" && return 0
        local hint=$(sectorSizeMismatchHint "$disk" "$imagesectorsize" "$targetsectorsize")
        [[ -n $hint ]] && hint="\n   ${hint}"
        handleError "Sector size mismatch (${FUNCNAME[0]})\n   Image was captured on a disk with ${imagesectorsize}-byte logical sectors, but $disk uses ${targetsectorsize}-byte logical sectors.\n   Partition-table and filesystem geometry cannot be translated between logical sector sizes, so this image cannot be deployed to this disk.${hint}\n   Deploy this image only to a disk with ${imagesectorsize}-byte logical sectors, or capture a new image on a disk with ${targetsectorsize}-byte logical sectors."
    fi
}
# Restores the partition tables and boot loaders
#
# $1 is the disk
# $2 is the disk number
# $3 is the image path
# $4 is the osid
# $5 is the image partition type
restorePartitionTablesAndBootLoaders() {
    local disk="$1"
    local disk_number="$2"
    local imagePath="$3"
    local osid="$4"
    local imgPartitionType="$5"
    [[ -z $disk ]] && handleError "No disk passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No drive number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $osid ]] && handleError "No osid passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imgPartitionType ]] && handleError "No image part type passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local tmpMBR=""
    local strdots=""
    if [[ $nombr -eq 1 ]]; then
        echo " * Skipping partition tables and MBR"
        debugPause
        return
    fi
    validateImageSectorSize "$disk" "$disk_number" "$imagePath"
    clearPartitionTables "$disk"
    majorDebugEcho "Partition table should be empty now."
    majorDebugShowCurrentPartitionTable "$disk" "$disk_number"
    majorDebugPause
    MBRFileName "$imagePath" "$disk_number" "tmpMBR"
    [[ ! -f $tmpMBR ]] && handleError "Image Store Corrupt: Unable to locate MBR (${FUNCNAME[0]})\n   Args Passed: $*"
    local table_type=""
    getDesiredPartitionTableType "$imagePath" "$disk_number"
    majorDebugEcho "Trying to restore to $table_type partition table."
    if [[ $table_type == GPT ]]; then
        dots "Restoring Partition Tables (GPT)"
        restoreGRUB "$disk" "$disk_number" "$imagePath" "true"
        sgdisk -z $disk >/dev/null 2>&1
        sgdisk -gl $tmpMBR $disk >/tmp/sgdisk-gl.err 2>&1
        sgdiskexit="$?"
        if [[ ! $sgdiskexit -eq 0 ]]; then
            echo "Failed"
            debugPause
            [[ -r /tmp/sgdisk-gl.err ]] && cat /tmp/sgdisk-gl.err
            echo "Find the detailed error message above this line. Use Shift-PageUp to scroll upwards."
            handleError "Error trying to restore GPT partition tables (${FUNCNAME[0]})\n   Args Passed: $*\n    CMD Tried: sgdisk -gl $tmpMBR $disk\n    Exit returned code: $sgdiskexit"
        fi
        rm -f /tmp/sgdisk-gl.err
        global_gptcheck="yes"
        echo "Done"
    else
        case $osid in
            50|51)
                strdots="Restoring Partition Tables and GRUB (MBR)"
                ;;
            *)
                strdots="Restoring Partition Tables (MBR)"
                ;;
        esac
        dots "$strdots"
        restoreGRUB "$disk" "$disk_number" "$imagePath"
        echo "Done"
        debugPause
        majorDebugShowCurrentPartitionTable "$disk" "$disk_number"
        majorDebugPause
        ebrcount=$(ls -1 $imagePath/*.ebr 2>/dev/null | wc -l)
        [[ $ebrcount -gt 0 ]] && restoreAllEBRs "$disk" "$disk_number" "$imagePath" "$imgPartitionType"
        local sfdiskoriginalpartitionfilename=""
        local sfdisklegacyoriginalpartitionfilename=""
        sfdiskPartitionFileName "$imagePath" "$disk_number"
        sfdiskLegacyOriginalPartitionFileName "$imagePath" "$disk_number"
        if [[ -r $sfdiskoriginalpartitionfilename ]]; then
            dots "Inserting Extended partitions (Original)"
            flock $disk sfdisk $disk < $sfdiskoriginalpartitionfilename >/dev/null 2>&1
            case $? in
                0)
                    echo "Done"
                    ;;
                *)
                    echo "Failed"
                    ;;
            esac
        elif [[ -e $sfdisklegacyoriginalpartitionfilename ]]; then
            dots "Inserting Extended partitions (Legacy)"
            flock $disk sfdisk $disk < $sfdisklegacyoriginalpartitionfilename >/dev/null 2>&1
            case $? in
                0)
                    echo "Done"
                    ;;
                *)
                    echo "Failed"
                    ;;
            esac
        else
            echo " * No extended partitions"
        fi
    fi
    debugPause
    runPartprobe "$disk"
    majorDebugShowCurrentPartitionTable "$disk" "$disk_number"
    majorDebugPause
}
savePartition() {
    local part="$1"
    local disk_number="$2"
    local imagePath="$3"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No drive number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local part_number=0
    getPartitionNumber "$part"
    local fstype=""
    local parttype=""
    local imgpart=""
    local fifoname="/tmp/pigz1"
    if [[ $imgPartitionType != all && $imgPartitionType != $part_number ]]; then
        echo " * Skipping partition $part ($part_number)"
        debugPause
        return
    fi
    echo " * Processing Partition: $part ($part_number)"
    debugPause
    fsTypeSetting "$part"
    getPartType "$part"
    local ebrfilename=""
    local swapuuidfilename=""
    case $fstype in
        swap)
            echo " * Saving swap partition UUID"
            swapUUIDFileName "$imagePath" "$disk_number"
            saveSwapUUID "$swapuuidfilename" "$part"
            ;;
        lvm)
            saveLVMPartition "$part" "$disk_number" "$imagePath"
            ;;
        imager)
            echo " * Using partclone.$fstype"
            debugPause
            imgpart="$imagePath/d${disk_number}p${part_number}.img"
            uploadFormat "$fifoname" "$imgpart"
            partclone.$fstype -n "Storage Location $storage, Image name $img" -cs $part -O $fifoname -Nf 1
            exitcode=$?
            wait $formatPID 2>/dev/null
            formatexit=$?
            [[ $exitcode -eq 0 && ! $formatexit -eq 0 ]] && exitcode=$formatexit
            case $exitcode in
                0)
                    mv ${imgpart}.000 $imgpart >/dev/null 2>&1
                    echo " * Image Captured"
                    debugPause
                    ;;
                *)
                    local spaceAvailable=$(getServerDiskSpaceAvailable)
                    handleError "Failed to complete capture (${FUNCNAME[0]})\n    Args Passed: $*\n    CMD: partclone.$fstype -n \"Storage Location $storage, Image name $img\" -s -O $fifoname -Nf 1\n    Exit code: $exitcode\n    Server Disk Space Available: $spaceAvailable"
                    ;;
            esac
            ;;
        *)
            case $parttype in
                0x5|0xf)
                    echo " * Not capturing content of extended partition"
                    debugPause
                    EBRFileName "$imagePath" "$disk_number" "$part_number"
                    touch "$ebrfilename"
                    ;;
                *)
                    echo " * Using partclone.$fstype"
                    debugPause
                    imgpart="$imagePath/d${disk_number}p${part_number}.img"
                    uploadFormat "$fifoname" "$imgpart"
                    partclone.$fstype -n "Storage Location $storage, Image name $img" -cs $part -O $fifoname -Nf 1 -a0
                    exitcode=$?
                    wait $formatPID 2>/dev/null
                    formatexit=$?
                    [[ $exitcode -eq 0 && ! $formatexit -eq 0 ]] && exitcode=$formatexit
                    case $exitcode in
                        0)
                            mv ${imgpart}.000 $imgpart >/dev/null 2>&1
                            echo " * Image Captured"
                            debugPause
                            ;;
                        *)
                            local spaceAvailable=$(getServerDiskSpaceAvailable)
                            handleError "Failed to complete capture (${FUNCNAME[0]})\n    Args Passed: $*\n    CMD: partclone.$fstype -n \"Storage Location $storage, Image name $img\" -cs -O $fifoname -Nf 1 -a0\n    Exit code: $exitcode\n    Server Disk Space Available: $spaceAvailable"
                            ;;
                    esac
                    ;;
            esac
            ;;
    esac
    rm -rf $fifoname >/dev/null 2>&1
}
restorePartition() {
    local part="$1"
    local disk_number="$2"
    local imagePath="$3"
    local mc="$4"
    local split=''
    if [[ $imgFormat -eq 6 || $imgFormat -eq 4 || $imgFormat -eq 2 ]]; then
        split='*'
    fi
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No disk number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    if [[ $imgPartitionType != all && $imgPartitionType != $part_number ]]; then
        echo " * Skipping partition: $part ($part_number)"
        debugPause
        return
    fi
    local imgpart=""
    local ebrfilename=""
    local disk=""
    local part_number=0
    local israw=0
    if [[ $imgType == "dd" ]]; then
        israw=1
    fi
    getDiskFromPartition "$part" "$israw"
    getPartitionNumber "$part"
    echo " * Processing Partition: $part ($part_number)"
    debugPause
    case $imgType in
        dd)
            imgpart="$imagePath"
            ;;
        n|mps|mpa)
            case $osid in
                [1-2])
                    [[ -f $imagePath ]] && imgpart="$imagePath" || imgpart="$imagePath/d${disk_number}p${part_number}.img${split}"
                    ;;
                4|8|50|51|99)
                    imgpart="$imagePath/d${disk_number}p${part_number}.img${split}"
                    ;;
                [5-7]|9|10|11)
                    [[ ! -f $imagePath/sys.img.000 ]] && imgpart="$imagePath/d${disk_number}p${part_number}.img${split}"
                    if [[ -z $imgpart ]] ;then
                        [[ -r $imagePath/sys.img.000 ]] && win7partcnt=1
                        [[ -r $imagePath/rec.img.000 ]] && win7partcnt=2
                        [[ -r $imagePath/rec.img.001 ]] && win7partcnt=3
                        case $win7partcnt in
                            1)
                                imgpart="$imagePath/sys.img.*"
                                ;;
                            2)
                                case $part_number in
                                    1)
                                        imgpart="$imagePath/rec.img.000"
                                        ;;
                                    2)
                                        imgpart="$imagePath/sys.img.*"
                                        ;;
                                esac
                                ;;
                            3)
                                case $part_number in
                                    1)
                                        imgpart="$imagePath/rec.img.000"
                                        ;;
                                    2)
                                        imgpart="$imagePath/rec.img.001"
                                        ;;
                                    3)
                                        imgpart="$imagePath/sys.img.*"
                                        ;;
                                esac
                                ;;
                        esac
                    fi
                    ;;
            esac
            ;;
        *)
            handleError "Invalid Image Type $imgType (${FUNCNAME[0]})\n   Args Passed: $*"
            ;;
    esac
    # A partition captured as LVM has a sidecar instead of a dNpM.img.
    local lvmfilename=""
    [[ -d $imagePath ]] && lvmFileName "$imagePath" "$disk_number" "$part_number"
    if [[ -n $lvmfilename && -r $lvmfilename ]]; then
        restoreLVMPartition "$part" "$disk_number" "$imagePath" "$mc"
        runPartprobe "$disk"
        return
    fi
    ls $imgpart >/dev/null 2>&1
    if [[ ! $? -eq 0 ]]; then
        EBRFileName "$imagePath" "$disk_number" "$part_number"
        [[ -e $ebrfilename ]] && echo " * Not deploying content of extended partition" || echo " * Partition File Missing: $imgpart"
        runPartprobe "$disk"
        return
    fi
    writeImage "$imgpart" "$part" "$mc"
    runPartprobe "$disk"
    resetFlag "$part"
}
runFixparts() {
    local disk="$1"
    [[ -z $disk ]] && handleError "No disk passed (${FUNCNAME[0]})\n   Args Passed: $*"
    echo
    dots "Attempting fixparts"
    fixparts $disk </usr/share/fog/lib/EOFFIXPARTS >/dev/null 2>&1
    checkStatus $? "done" "Could not fix partition layout (${FUNCNAME[0]})\n   Args Passed: $*" "yes"
    debugPause
    runPartprobe "$disk"
}
killStatusReporter() {
    dots "Stopping FOG Status Reporter"
    kill -9 $statusReporter >/dev/null 2>&1
    case $? in
        0)
            echo "Done"
            ;;
        *)
            echo "Failed"
            ;;
    esac
    debugPause
}
prepareResizeDownloadPartitions() {
    local disk="$1"
    local disk_number="$2"
    local imagePath="$3"
    local osid="$4"
    local imgPartitionType="$5"
    [[ -z $disk ]] && handleError "No disk passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No disk number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $osid ]] && handleError "No osid passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imgPartitionType ]] && handleError "No image partition type  passed (${FUNCNAME[0]})\n   Args Passed: $*"
    if [[ $nombr -eq 1 ]]; then
        echo -e " * Skipping partition preperation\n"
        debugPause
        return
    fi
    restorePartitionTablesAndBootLoaders "$disk" "$disk_number" "$imagePath" "$osid" "$imgPartitionType"
    local do_fill=0
    fillDiskWithPartitionsIsOK "$disk" "$imagePath" "$disk_number"
    majorDebugEcho "Filling disk = $do_fill"
    dots "Attempting to expand/fill partitions"
    if [[ $do_fill -eq 0 ]]; then
        echo "Failed"
        debugPause
        handleError "Fatal Error: Could not resize partitions (${FUNCNAME[0]})\n   Args Passed: $*"
    fi
    fillDiskWithPartitions "$disk" "$imagePath" "$disk_number"
    echo "Done"
    debugPause
    runPartprobe "$disk"
}
# $1 is the disks
# $2 is the image path
# $3 is the image partition type (either all or partition number)
# $4 is the flag to say whether this is multicast or not
performRestore() {
    local disks="$1"
    local disk=""
    local imagePath="$2"
    local imgPartitionType="$3"
    local mc="$4"
    [[ -z $disks ]] && handleError "No disks passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imgPartitionType ]] && handleError "No partition type passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local disk_number=1
    local part_number=0
    local restoreparts=""
    local sfdiskoriginalpartitionfilename=""
    [[ $imgType =~ [Nn] ]] && local tmpebrfilename=""
    for disk in $disks; do
        sfdiskoriginalpartitionfilename=""
        sfdiskOriginalPartitionFileName "$imagePath" "$disk_number"
        getValidRestorePartitions "$disk" "$disk_number" "$imagePath" "$restoreparts"
        [[ -z $restoreparts ]] && handleError "No image file(s) found that would match the partition(s) to be restored (${FUNCNAME[0]})\n   Args Passed: $*"
        for restorepart in $restoreparts; do
            getPartitionNumber "$restorepart"
            [[ $imgType =~ [Nn] ]] && tmpEBRFileName "$disk_number" "$part_number"
            restorePartition "$restorepart" "$disk_number" "$imagePath" "$mc"
            [[ $imgType =~ [Nn] ]] && restoreEBR "$restorepart" "$tmpebrfilename"
            [[ $imgType =~ [Nn] ]] && expandPartition "$restorepart" "$fixed_size_partitions"
            [[ $osid == +([5-7]) && $imgType =~ [Nn] ]] && fixWin7boot "$restorepart"
        done
        restoreparts=""
        echo " * Resetting UUIDs for $disk"
        debugPause
        restoreUUIDInformation "$disk" "$sfdiskoriginalpartitionfilename" "$disk_number" "$imagePath"
        echo " * Resetting swap systems"
        debugPause
        makeAllSwapSystems "$disk" "$disk_number" "$imagePath" "$imgPartitionType"
        let disk_number+=1
    done
}
# Gets the file system identifier.
# $1 is the partition to get.
getFSID() {
    local part="$1"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local disk
    getDiskFromPartition "$part"
    fsid="$(flock $disk sfdisk -d "$disk" |  grep "$part" | sed -n 's/.*Id=\([0-9]\+\).*\(,\|\).*/\1/p')"
}
# Gets any lvm layouts.
# $1 is the partition to search within.
getLVM() {
    local part="$1"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    vgscan >/dev/null 2>&1
    local vggroup
    getVolumeGroup "${part}"
    [[ -z $vggroup ]] && return
    changeVolumeGroup "${vggroup}"
    read lvmGUID lvmSIZE <<< $(vgs --noheadings -v ${vggroup} --units s 2>/dev/null | awk '{printf("%s %s", $9, gensub(/[Ss]/,"","g",$7))}')
}
# Gets the volume group name/label.
# $1 The partition to check on.
getVolumeGroup() {
    local part="$1"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    vggroup=$(pvs --noheadings ${part} | sed -n "s|.*${part}[[:space:]]\+\([A-Za-z0-9_-]\+\)[[:space:]]\+.*|\1|p")
}
# Changes to volume group
# $1 The group name to change to.
changeVolumeGroup() {
    local vggroup="$1"
    [[ -z $vggroup ]] && handleError "No group name passed (${FUNCNAME[0]})\n   Args Passed: $*"
    vgchange -a y "$vggroup"
}
# Get's volume labels from volume group.
# $1 The group to get logical volumes from.
getLogicalVolumes() {
    local vggroup="$1"
    [[ -z $vggroup ]] && handleError "No group name passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local lvs
    local lgvol
    lgvols=""
    lvs=$(lvs --noheadings ${vggroup} | sed -n 's|[[:space:]]\+\([A-Za-z0-9_-]\+\)[[:space:]]\+.*|\1|p')
    for lgvol in ${lvs}; do
        lgvols=(${lgvols} ${lgvol})
    done
}
# Get's volume device mapper.
# $1 The volume to get
# $2 The group to get
getLGDevice() {
    local lgvol="$1"
    local lggroup="$2"
    [[ -z $lgvol ]] && handleError "No volume device passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $lggroup ]] && handleError "No volume group passed (${FUNCNAME[0]})\n   Args Passed: $*"
    lgdev="/dev/mapper/${lggroup}-${lgvol}"
    read lgvUUID lgvSIZE <<< $(lvs --noheadings -v ${lggroup} --units s 2>/dev/null | awk '/'${lgvol}'/ {printf("%s %s", $5, gensub(/[Ss]/,"","g",$10))}')
}
# --- LVM per-LV capture and deploy (docs/adr/0004, resize docs/adr/0006) ----
#
# A partition holding an LVM2 physical volume is not sector-imaged. Capture
# writes sidecar files next to the usual dNpM ones plus one partclone image
# per logical volume:
#   dNpM.lvm        versioned schema: PV/VG identity and one line per LV
#   dNpM.lvm.vgcfg  vgcfgbackup output (complete LVM metadata, all UUIDs)
#   dNpM.<lv>.img   partclone image per non-swap LV
# Resizable captures first shrink the ext filesystems inside the LVs and
# record per-LV minimum sizes (LVMFORMAT 2), letting the deploy fill engine
# scale the PV partition. Deploy dispatches on the target partition size:
# same size or larger restores with pvcreate --restorefile + vgcfgrestore
# (all UUIDs preserved; extra space goes to the LVs proportionally), smaller
# rebuilds the stack with vgcreate/lvcreate at the recorded minimums plus a
# proportional share (VG/LV UUIDs regenerate; PV, filesystem, and swap UUIDs
# survive). LV devices are addressed as /dev/<vg>/<lv> and never enter the
# partition-name machinery.
#
# Streams one block device through partclone into the image store, the same
# way savePartition's inline capture does for a plain partition.
#
# $1 = source block device
# $2 = destination image file
# $3 = partclone type (extfs, ntfs, imager, ...)
savePartclone() {
    local src="$1"
    local imgfile="$2"
    local pctype="$3"
    [[ -z $src ]] && handleError "No source device passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imgfile ]] && handleError "No image file passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $pctype ]] && handleError "No partclone type passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local fifoname="/tmp/pigz1"
    local checksum="-a0"
    [[ $pctype == imager ]] && checksum=""
    echo " * Using partclone.$pctype"
    debugPause
    uploadFormat "$fifoname" "$imgfile"
    partclone.$pctype -n "Storage Location $storage, Image name $img" -cs $src -O $fifoname -Nf 1 $checksum
    exitcode=$?
    wait $formatPID 2>/dev/null
    formatexit=$?
    [[ $exitcode -eq 0 && ! $formatexit -eq 0 ]] && exitcode=$formatexit
    case $exitcode in
        0)
            mv ${imgfile}.000 $imgfile >/dev/null 2>&1
            echo " * Image Captured"
            debugPause
            ;;
        *)
            local spaceAvailable=$(getServerDiskSpaceAvailable)
            handleError "Failed to complete capture (${FUNCNAME[0]})\n    Args Passed: $*\n    CMD: partclone.$pctype -n \"Storage Location $storage, Image name $img\" -cs $src -O $fifoname -Nf 1 $checksum\n    Exit code: $exitcode\n    Server Disk Space Available: $spaceAvailable"
            ;;
    esac
    rm -rf $fifoname >/dev/null 2>&1
}
# Interrogates the LVM stack on a PV partition. Sets:
#   lvm_vggroup      volume group name (empty if none)
#   lvm_pvuuid       PV UUID
#   lvm_pvsize       PV size in 512-byte sectors
#   lvm_unsupported  why per-LV handling cannot apply (empty if supported)
#
# $1 = partition device holding the PV
probeLVMPartition() {
    local part="$1"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    vgscan >/dev/null 2>&1
    lvm_vggroup=$(trim "$(pvs --noheadings -o vg_name "$part" 2>/dev/null)")
    lvm_pvuuid=$(trim "$(pvs --noheadings -o pv_uuid "$part" 2>/dev/null)")
    lvm_pvsize=$(pvs --noheadings --units s --nosuffix -o pv_size "$part" 2>/dev/null | awk '{printf("%d",$1)}')
    local pvcount=$(vgs --noheadings -o pv_count "$lvm_vggroup" 2>/dev/null | awk '{printf("%d",$1)}')
    lvm_unsupported=""
    if [[ -z $lvm_vggroup ]]; then
        lvm_unsupported="no volume group found on the physical volume"
    elif [[ $pvcount -ne 1 ]]; then
        lvm_unsupported="volume group $lvm_vggroup spans $pvcount physical volumes"
    elif lvs --noheadings -o lv_layout "$lvm_vggroup" 2>/dev/null | grep -qv '^[[:space:]]*linear[[:space:]]*$'; then
        lvm_unsupported="volume group $lvm_vggroup contains non-linear volumes (thin/RAID/cache/snapshot)"
    fi
}
# Shrinks the ext filesystems inside a supported LVM stack ahead of capture
# and records how small each LV — and the whole PV partition — could be
# rebuilt on a deploy target. The LVs themselves are not reduced; partclone
# only captures the shrunken filesystem's used blocks either way. Layouts
# probeLVMPartition rejects are demoted to fixed size, which is exactly the
# Phase 1 behavior.
# Writes /tmp/<part>.lvmmin: one "LV <name> <minsectors>" line per LV plus
# "PARTMIN <sectors>", consumed by saveLVMPartition and
# applyLVMMinimumSizes.
#
# $1 = partition device holding the PV
shrinkLVMPartition() {
    local part="$1"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local part_number=0
    getPartitionNumber "$part"
    probeLVMPartition "$part"
    if [[ -n $lvm_unsupported ]]; then
        echo " * LVM layout is not supported for per-LV capture: $lvm_unsupported"
        echo " * Not shrinking ($part) trying fixed size"
        debugPause
        echo "$(cat "$imagePath/d1.fixed_size_partitions" | tr -d \\0):${part_number}" > "$imagePath/d1.fixed_size_partitions"
        return
    fi
    local vggroup="$lvm_vggroup"
    dots "Activating volume group ($vggroup)"
    vgchange -ay "$vggroup" >/dev/null 2>&1
    checkStatus $? "done" "Could not activate volume group $vggroup (${FUNCNAME[0]})\n   Args Passed: $*"
    udevadm settle >/dev/null 2>&1
    debugPause
    local extentsize=$(vgs --noheadings --units s --nosuffix -o vg_extent_size "$vggroup" 2>/dev/null | awk '{printf("%d",$1)}')
    local pestart=$(pvs --noheadings --units s --nosuffix -o pe_start "$part" 2>/dev/null | awk '{printf("%d",$1)}')
    [[ -z $extentsize || $extentsize -lt 1 ]] && handleError "Could not read extent size of $vggroup (${FUNCNAME[0]})\n   Args Passed: $*"
    local minfile="/tmp/${part##*/}.lvmmin"
    echo -n "" > "$minfile"
    local totalextents=0
    local lvname=""
    local lvsize=""
    local minsectors=0
    while read -r lvname lvsize; do
        [[ -z $lvname ]] && continue
        lvsize=${lvsize%.*}
        local lvdev="/dev/${vggroup}/${lvname}"
        [[ ! -e $lvdev ]] && handleError "Logical volume device missing: $lvdev (${FUNCNAME[0]})\n   Args Passed: $*"
        local fstype=""
        fsTypeSetting "$lvdev"
        minsectors=$lvsize
        if [[ $fstype == extfs ]]; then
            dots "Checking $fstype volume ($lvdev)"
            e2fsck -fp $lvdev >/tmp/e2fsck.txt 2>&1
            checkStatus $? "done" "e2fsck failed to check $lvdev (${FUNCNAME[0]})\n   Info: $(cat /tmp/e2fsck.txt)\n   Args Passed: $*"
            debugPause
            local extminsize=$(resize2fs -P $lvdev 2>/dev/null | awk -F': ' '{print $2}')
            local block_size=$(dumpe2fs -h $lvdev 2>/dev/null | awk '/^Block[ ]size:/{print $3}')
            local size=$(calculate "${extminsize}*${block_size}")
            local sizeadd=$(calculate "${percent}/100*${size}")
            local sizeextresize=$(calculate "${size}+${sizeadd}")
            [[ -z $sizeextresize || $sizeextresize -lt 1 ]] && handleError "Error calculating the minimum size of extfs ($lvdev) (${FUNCNAME[0]})\n   Args Passed: $*"
            dots "Shrinking $fstype volume ($lvdev)"
            resize2fs $lvdev -M >/tmp/resize2fs.txt 2>&1
            checkStatus $? "done" "Could not shrink $fstype volume ($lvdev) (${FUNCNAME[0]})\n   Info: $(cat /tmp/resize2fs.txt)\n   Args Passed: $*"
            debugPause
            dots "Checking $fstype volume ($lvdev)"
            e2fsck -fp $lvdev >/tmp/e2fsck.txt 2>&1
            case $? in
                0)
                    echo "Done"
                    ;;
                *)
                    e2fsck -fy $lvdev >>/tmp/e2fsck.txt 2>&1
                    if [[ $? -gt 0 ]]; then
                        echo "Failed"
                        debugPause
                        handleError "Could not check shrunken volume ($lvdev) (${FUNCNAME[0]})\n   Info: $(cat /tmp/e2fsck.txt)\n   Args Passed: $*"
                    fi
                    echo "Done"
                    ;;
            esac
            debugPause
            # ceil to sectors; calculate() rounds, which could go under
            minsectors=$(( (sizeextresize + 511) / 512 ))
            [[ $minsectors -gt $lvsize ]] && minsectors=$lvsize
        else
            echo " * Not shrinking ($lvdev $fstype)"
            debugPause
        fi
        echo "LV $lvname $minsectors" >> "$minfile"
        totalextents=$(( totalextents + (minsectors + extentsize - 1) / extentsize ))
    done < <(lvs --noheadings --units s --nosuffix -o lv_name,lv_size "$vggroup" 2>/dev/null)
    # one spare extent absorbs metadata rounding on the rebuilt target
    local pvminsectors=$(( pestart + (totalextents + 1) * extentsize ))
    [[ $pvminsectors -gt $lvm_pvsize ]] && pvminsectors=$lvm_pvsize
    echo "PARTMIN $pvminsectors" >> "$minfile"
    vgchange -an "$vggroup" >/dev/null 2>&1 || echo " * Warning: could not deactivate volume group $vggroup"
}
# Grows the ext filesystems inside a supported LVM stack out to their LV
# boundaries. Runs on the source after capture (undoing shrinkLVMPartition)
# and on the deploy target (claiming space the restore added to the LVs).
# Layouts probeLVMPartition rejects were captured raw and are skipped.
#
# $1 = partition device holding the PV
expandLVMPartition() {
    local part="$1"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    probeLVMPartition "$part"
    if [[ -n $lvm_unsupported ]]; then
        echo " * Not expanding ($part) $lvm_unsupported"
        debugPause
        return
    fi
    local vggroup="$lvm_vggroup"
    dots "Activating volume group ($vggroup)"
    vgchange -ay "$vggroup" >/dev/null 2>&1
    checkStatus $? "done" "Could not activate volume group $vggroup (${FUNCNAME[0]})\n   Args Passed: $*"
    udevadm settle >/dev/null 2>&1
    debugPause
    local lvname=""
    while read -r lvname; do
        [[ -z $lvname ]] && continue
        local lvdev="/dev/${vggroup}/${lvname}"
        local fstype=""
        fsTypeSetting "$lvdev"
        [[ $fstype != extfs ]] && continue
        dots "Resizing $fstype volume ($lvdev)"
        e2fsck -fp $lvdev >/tmp/e2fsck.txt 2>&1
        case $? in
            0)
                ;;
            *)
                e2fsck -fy $lvdev >>/tmp/e2fsck.txt 2>&1
                if [[ $? -gt 0 ]]; then
                    echo "Failed"
                    debugPause
                    handleError "Could not check before resize (${FUNCNAME[0]})\n   Info: $(cat /tmp/e2fsck.txt)\n   Args Passed: $*"
                fi
                ;;
        esac
        resize2fs $lvdev >/tmp/resize2fs.txt 2>&1
        checkStatus $? "silent" "Could not resize $lvdev (${FUNCNAME[0]})\n   Info: $(cat /tmp/resize2fs.txt)\n   Args Passed: $*"
        e2fsck -fp $lvdev >/tmp/e2fsck.txt 2>&1
        case $? in
            0)
                echo "Done"
                ;;
            *)
                e2fsck -fy $lvdev >>/tmp/e2fsck.txt 2>&1
                if [[ $? -gt 0 ]]; then
                    echo "Failed"
                    debugPause
                    handleError "Could not check after resize (${FUNCNAME[0]})\n   Info: $(cat /tmp/e2fsck.txt)\n   Args Passed: $*"
                fi
                echo "Done"
                ;;
        esac
        debugPause
    done < <(lvs --noheadings -o lv_name "$vggroup" 2>/dev/null | awk '{print $1}')
    vgchange -an "$vggroup" >/dev/null 2>&1 || echo " * Warning: could not deactivate volume group $vggroup"
}
# Rewrites each shrunken PV partition's size in the minimum-size sfdisk dump
# to the PARTMIN shrinkLVMPartition recorded, so the deploy fill engine may
# scale the partition down to it. Starts are left alone — the fill engine
# repacks them. A no-op for disks without a shrunken LVM stack.
#
# $1 = disk
# $2 = disk number
# $3 = image path
applyLVMMinimumSizes() {
    local disk="$1"
    local disk_number="$2"
    local imagePath="$3"
    [[ -z $disk ]] && handleError "No disk passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No disk number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local sfdiskminimumpartitionfilename=""
    sfdiskMinimumPartitionFileName "$imagePath" "$disk_number"
    local parts=""
    local part=""
    getPartitions "$disk"
    for part in $parts; do
        local minfile="/tmp/${part##*/}.lvmmin"
        [[ ! -r $minfile ]] && continue
        local pvminsectors=$(awk '$1=="PARTMIN"{print $2; exit}' "$minfile")
        [[ -z $pvminsectors ]] && continue
        # the dump's size= values are in its own logical sectors, PARTMIN
        # is 512-byte sectors
        local secsize=$(awk '$1=="sector-size:"{print $2; exit}' "$sfdiskminimumpartitionfilename")
        [[ -z $secsize ]] && secsize=512
        local minsize=$(( (pvminsectors * 512 + secsize - 1) / secsize ))
        dots "Recording LVM minimum size for ($part)"
        awk -v part="$part" -v newsize="$minsize" '$1 == part {sub(/size=[[:space:]]*[0-9]+/, "size=" newsize)} {print}' "$sfdiskminimumpartitionfilename" > /tmp/lvmmindump.tmp
        checkStatus $? "silent" "Could not rewrite minimum partition dump (${FUNCNAME[0]})\n   Args Passed: $*"
        mv /tmp/lvmmindump.tmp "$sfdiskminimumpartitionfilename"
        checkStatus $? "done" "Could not replace minimum partition dump (${FUNCNAME[0]})\n   Args Passed: $*"
        debugPause
    done
}
# Captures an LVM2 PV partition: sidecar metadata plus one image per LV.
# Unsupported topologies (multi-PV VG, non-linear LVs) fall back to the
# raw partclone.imager blob — the pre-LVM behavior — with a loud notice.
# On resizable captures shrinkLVMPartition has already run; its recorded
# minimums go into the sidecar so a smaller target can rebuild the stack.
#
# $1 = partition device holding the PV
# $2 = disk number
# $3 = image path
saveLVMPartition() {
    local part="$1"
    local disk_number="$2"
    local imagePath="$3"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No drive number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    local part_number=0
    getPartitionNumber "$part"
    probeLVMPartition "$part"
    local vggroup="$lvm_vggroup"
    local pvuuid="$lvm_pvuuid"
    local pvsize="$lvm_pvsize"
    if [[ -n $lvm_unsupported ]]; then
        echo " * LVM layout is not supported for per-LV capture: $lvm_unsupported"
        echo " * Falling back to raw capture of the whole physical volume"
        debugPause
        savePartclone "$part" "$imagePath/d${disk_number}p${part_number}.img" "imager"
        return
    fi
    dots "Activating volume group ($vggroup)"
    vgchange -ay "$vggroup" >/dev/null 2>&1
    checkStatus $? "done" "Could not activate volume group $vggroup (${FUNCNAME[0]})\n   Args Passed: $*"
    udevadm settle >/dev/null 2>&1
    debugPause
    local lvmfilename=""
    local lvmvgcfgfilename=""
    lvmFileName "$imagePath" "$disk_number" "$part_number"
    lvmVgcfgFileName "$imagePath" "$disk_number" "$part_number"
    dots "Saving LVM metadata"
    vgcfgbackup -f "$lvmvgcfgfilename" "$vggroup" >/dev/null 2>&1
    checkStatus $? "done" "Could not back up LVM metadata of $vggroup (${FUNCNAME[0]})\n   Args Passed: $*"
    debugPause
    local vguuid=$(trim "$(vgs --noheadings -o vg_uuid "$vggroup" 2>/dev/null)")
    local extentsize=$(vgs --noheadings --units s --nosuffix -o vg_extent_size "$vggroup" 2>/dev/null | awk '{printf("%d",$1)}')
    # non-resizable captures have no minfile: minimums default to the sizes
    local minfile="/tmp/${part##*/}.lvmmin"
    local pvminsize=""
    [[ -r $minfile ]] && pvminsize=$(awk '$1=="PARTMIN"{print $2; exit}' "$minfile")
    [[ -z $pvminsize ]] && pvminsize=$pvsize
    echo "LVMFORMAT 2" > "$lvmfilename"
    echo "PV $pvuuid $part $pvsize $pvminsize" >> "$lvmfilename"
    echo "VG $vggroup $vguuid $extentsize" >> "$lvmfilename"
    local lvname=""
    local lvuuid=""
    local lvsize=""
    local lvminsize=""
    while read -r lvname lvuuid lvsize; do
        [[ -z $lvname ]] && continue
        local lvdev="/dev/${vggroup}/${lvname}"
        [[ ! -e $lvdev ]] && handleError "Logical volume device missing: $lvdev (${FUNCNAME[0]})\n   Args Passed: $*"
        local fstype=""
        fsTypeSetting "$lvdev"
        # A PV nested inside an LV is out of scope; capture that LV raw.
        [[ $fstype == lvm ]] && fstype="imager"
        lvminsize=""
        [[ -r $minfile ]] && lvminsize=$(awk -v lv="$lvname" '$1=="LV" && $2==lv {print $3; exit}' "$minfile")
        [[ -z $lvminsize ]] && lvminsize=${lvsize%.*}
        if [[ $fstype == swap ]]; then
            local swapuuid=$(blkid -po udev "$lvdev" | awk -F= '/FS_UUID=/{print $2}')
            echo "LV $lvname $lvuuid ${lvsize%.*} $lvminsize $fstype - ${swapuuid:--}" >> "$lvmfilename"
            echo " * Saving swap volume UUID ($lvdev)"
            debugPause
            continue
        fi
        local lvmlvimagefilename=""
        lvmLVImageFileName "$imagePath" "$disk_number" "$part_number" "$lvname"
        echo "LV $lvname $lvuuid ${lvsize%.*} $lvminsize $fstype ${lvmlvimagefilename##*/} -" >> "$lvmfilename"
        echo " * Processing Logical Volume: $lvdev ($fstype)"
        debugPause
        savePartclone "$lvdev" "$lvmlvimagefilename" "$fstype"
    done < <(lvs --noheadings --units s --nosuffix -o lv_name,lv_uuid,lv_size "$vggroup" 2>/dev/null)
    vgchange -an "$vggroup" >/dev/null 2>&1 || echo " * Warning: could not deactivate volume group $vggroup"
}
# Grows a restored volume group into a target partition larger than the
# original PV: pvresize claims the new space, then the free extents are
# spread across the non-swap LVs proportionally to their original sizes —
# the same policy the fill engine applies to partitions. Swap LVs keep
# their original size. Filesystems grow later, in expandLVMPartition.
# Format-2 sidecars only.
#
# $1 = partition device holding the PV
# $2 = volume group
# $3 = sidecar file
growLVMPartition() {
    local part="$1"
    local vggroup="$2"
    local lvmfilename="$3"
    [[ -z $lvmfilename ]] && handleError "No sidecar file passed (${FUNCNAME[0]})\n   Args Passed: $*"
    dots "Growing physical volume ($part)"
    pvresize "$part" >/dev/null 2>&1
    checkStatus $? "done" "Could not grow physical volume on $part (${FUNCNAME[0]})\n   Args Passed: $*"
    debugPause
    local freeextents=$(vgs --noheadings -o vg_free_count "$vggroup" 2>/dev/null | awk '{printf("%d",$1)}')
    [[ $freeextents -lt 1 ]] && return
    local tag=""
    local lvname=""
    local lvuuid=""
    local lvsize=""
    local lvminsize=""
    local lvfstype=""
    local lvimage=""
    local swapuuid=""
    local totalorig=0
    local lastlv=""
    while read -r tag lvname lvuuid lvsize lvminsize lvfstype lvimage swapuuid; do
        [[ $tag != LV || $lvfstype == swap ]] && continue
        totalorig=$(( totalorig + lvsize ))
        lastlv=$lvname
    done < "$lvmfilename"
    [[ $totalorig -lt 1 ]] && return
    local usedextents=0
    local share=0
    while read -r tag lvname lvuuid lvsize lvminsize lvfstype lvimage swapuuid; do
        [[ $tag != LV || $lvfstype == swap ]] && continue
        if [[ $lvname == $lastlv ]]; then
            share=$(( freeextents - usedextents ))
        else
            share=$(( freeextents * lvsize / totalorig ))
        fi
        usedextents=$(( usedextents + share ))
        [[ $share -lt 1 ]] && continue
        dots "Growing logical volume ($lvname)"
        lvextend -l +${share} "/dev/${vggroup}/${lvname}" >/dev/null 2>&1
        checkStatus $? "done" "Could not grow logical volume $lvname (${FUNCNAME[0]})\n   Args Passed: $*"
        debugPause
    done < "$lvmfilename"
}
# Rebuilds an LVM stack in a target partition smaller than the original PV.
# vgcfgrestore cannot apply metadata describing more extents than the PV
# holds, so the stack is recreated with the standard tools instead: each
# non-swap LV gets its recorded minimum plus a share of the surplus
# proportional to its original size; swap LVs keep their original size.
# The PV UUID, VG/LV names, filesystem UUIDs, and swap UUIDs all survive;
# the VG and LV UUIDs regenerate (docs/adr/0006). Format-2 sidecars only.
#
# $1 = partition device to hold the PV
# $2 = PV UUID to recreate
# $3 = volume group name
# $4 = extent size in 512-byte sectors
# $5 = sidecar file
rebuildLVMPartition() {
    local part="$1"
    local pvuuid="$2"
    local vggroup="$3"
    local extentsize="$4"
    local lvmfilename="$5"
    [[ -z $lvmfilename ]] && handleError "No sidecar file passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $extentsize || $extentsize -lt 1 ]] && handleError "No extent size in LVM sidecar (${FUNCNAME[0]})\n   Args Passed: $*"
    dots "Recreating physical volume"
    pvcreate -ff -y --norestorefile --uuid "$pvuuid" "$part" >/dev/null 2>&1
    checkStatus $? "done" "Could not recreate physical volume on $part (${FUNCNAME[0]})\n   Args Passed: $*"
    debugPause
    dots "Recreating volume group ($vggroup)"
    vgcreate -y -s "${extentsize}s" "$vggroup" "$part" >/dev/null 2>&1
    checkStatus $? "done" "Could not recreate volume group $vggroup (${FUNCNAME[0]})\n   Args Passed: $*"
    debugPause
    local freeextents=$(vgs --noheadings -o vg_free_count "$vggroup" 2>/dev/null | awk '{printf("%d",$1)}')
    local tag=""
    local lvname=""
    local lvuuid=""
    local lvsize=""
    local lvminsize=""
    local lvfstype=""
    local lvimage=""
    local swapuuid=""
    local totalminextents=0
    local totalorig=0
    local lastlv=""
    while read -r tag lvname lvuuid lvsize lvminsize lvfstype lvimage swapuuid; do
        [[ $tag != LV ]] && continue
        if [[ $lvfstype == swap ]]; then
            totalminextents=$(( totalminextents + (lvsize + extentsize - 1) / extentsize ))
        else
            totalminextents=$(( totalminextents + (lvminsize + extentsize - 1) / extentsize ))
            totalorig=$(( totalorig + lvsize ))
            lastlv=$lvname
        fi
    done < "$lvmfilename"
    local surplus=$(( freeextents - totalminextents ))
    [[ $surplus -lt 0 ]] && handleError "Partition $part is too small for the minimum LVM layout ($freeextents extents available, $totalminextents needed) (${FUNCNAME[0]})\n   Args Passed: $*"
    local usedsurplus=0
    local share=0
    local extents=0
    while read -r tag lvname lvuuid lvsize lvminsize lvfstype lvimage swapuuid; do
        [[ $tag != LV ]] && continue
        if [[ $lvfstype == swap ]]; then
            extents=$(( (lvsize + extentsize - 1) / extentsize ))
        else
            if [[ $lvname == $lastlv ]]; then
                share=$(( surplus - usedsurplus ))
            else
                share=$(( surplus * lvsize / totalorig ))
            fi
            usedsurplus=$(( usedsurplus + share ))
            extents=$(( (lvminsize + extentsize - 1) / extentsize + share ))
        fi
        dots "Recreating logical volume ($lvname)"
        lvcreate -y -Wn -Zn -l "$extents" -n "$lvname" "$vggroup" >/dev/null 2>&1
        checkStatus $? "done" "Could not recreate logical volume $lvname (${FUNCNAME[0]})\n   Args Passed: $*"
        debugPause
    done < "$lvmfilename"
    dots "Activating volume group ($vggroup)"
    vgchange -ay "$vggroup" >/dev/null 2>&1
    checkStatus $? "done" "Could not activate volume group $vggroup (${FUNCNAME[0]})\n   Args Passed: $*"
    udevadm settle >/dev/null 2>&1
    debugPause
}
# Recreates and restores an LVM2 stack captured by saveLVMPartition,
# dispatching on the target partition's size. Same size or larger runs
# LVM's own disaster-recovery procedure — pvcreate --restorefile plus
# vgcfgrestore — so the PV, VG, and every LV come back with their original
# UUIDs and exact segment layout; a larger target then grows the stack
# (growLVMPartition). A smaller target rebuilds the stack at the recorded
# minimums (rebuildLVMPartition) or refuses if it cannot fit. Failures are
# fatal (docs/adr/0003).
#
# $1 = partition device to hold the PV
# $2 = disk number
# $3 = image path
# $4 = multicast flag
restoreLVMPartition() {
    local part="$1"
    local disk_number="$2"
    local imagePath="$3"
    local mc="$4"
    [[ -z $part ]] && handleError "No partition passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $disk_number ]] && handleError "No disk number passed (${FUNCNAME[0]})\n   Args Passed: $*"
    [[ -z $imagePath ]] && handleError "No image path passed (${FUNCNAME[0]})\n   Args Passed: $*"
    if [[ $mc == yes ]]; then
        # The sender must emit this partition's LV files in sidecar order
        # (docs/adr/0007); against an older server the receivers would join
        # the wrong file's session, so refuse before the target is touched.
        local servercaps=$(curl -Lks "${web}service/getversion.php?caps=1" 2>/dev/null)
        [[ $servercaps != *mclvm* ]] && handleError "The FOG server does not support multicast deploy of LVM images; update the server or deploy unicast (${FUNCNAME[0]})\n   Args Passed: $*"
    fi
    local part_number=0
    getPartitionNumber "$part"
    local lvmfilename=""
    local lvmvgcfgfilename=""
    lvmFileName "$imagePath" "$disk_number" "$part_number"
    lvmVgcfgFileName "$imagePath" "$disk_number" "$part_number"
    [[ ! -r $lvmvgcfgfilename ]] && handleError "LVM metadata backup missing: $lvmvgcfgfilename (${FUNCNAME[0]})\n   Args Passed: $*"
    local lvmformat=$(head -n 1 "$lvmfilename")
    case $lvmformat in
        "LVMFORMAT 1"|"LVMFORMAT 2")
            ;;
        *)
            handleError "Image was captured with a newer LVM format ($lvmformat), update FOS (${FUNCNAME[0]})\n   Args Passed: $*"
            ;;
    esac
    local pvuuid=$(awk '$1=="PV"{print $2; exit}' "$lvmfilename")
    local pvsize=$(awk '$1=="PV"{print $4; exit}' "$lvmfilename")
    local pvminsize=$(awk '$1=="PV"{print $5; exit}' "$lvmfilename")
    [[ -z $pvminsize ]] && pvminsize=$pvsize
    local vggroup=$(awk '$1=="VG"{print $2; exit}' "$lvmfilename")
    local extentsize=$(awk '$1=="VG"{print $4; exit}' "$lvmfilename")
    [[ -z $pvuuid || -z $vggroup || -z $pvsize ]] && handleError "Incomplete LVM sidecar: $lvmfilename (${FUNCNAME[0]})\n   Args Passed: $*"
    local targetsize=$(blockdev --getsz "$part" 2>/dev/null)
    [[ -z $targetsize || $targetsize -lt 1 ]] && handleError "Could not read the size of $part (${FUNCNAME[0]})\n   Args Passed: $*"
    # Refuse before the target is touched.
    if [[ $targetsize -lt $pvsize ]]; then
        [[ $lvmformat == "LVMFORMAT 1" ]] && handleError "Target partition $part is smaller than the original physical volume and the image records no LVM minimum sizes; recapture with a current FOS or deploy to a same-size-or-larger disk (${FUNCNAME[0]})\n   Args Passed: $*"
        [[ $targetsize -lt $pvminsize ]] && handleError "Target partition $part ($targetsize sectors) is smaller than the minimum this image can shrink to ($pvminsize sectors) (${FUNCNAME[0]})\n   Args Passed: $*"
    fi
    local split=''
    if [[ $imgFormat -eq 6 || $imgFormat -eq 4 || $imgFormat -eq 2 ]]; then
        split='*'
    fi
    echo " * Restoring LVM volume group ($vggroup) to $part"
    debugPause
    # A previous life of this target may have left volume groups active;
    # stale device mappings would collide with the names being restored.
    vgchange -an >/dev/null 2>&1
    wipefs -a "$part" >/dev/null 2>&1
    if [[ $targetsize -ge $pvsize ]]; then
        dots "Recreating physical volume"
        pvcreate -ff -y --uuid "$pvuuid" --restorefile "$lvmvgcfgfilename" "$part" >/dev/null 2>&1
        checkStatus $? "done" "Could not recreate physical volume on $part (${FUNCNAME[0]})\n   Args Passed: $*"
        debugPause
        dots "Restoring volume group metadata"
        vgcfgrestore -f "$lvmvgcfgfilename" "$vggroup" >/dev/null 2>&1
        checkStatus $? "done" "Could not restore volume group metadata of $vggroup (${FUNCNAME[0]})\n   Args Passed: $*"
        debugPause
        dots "Activating volume group ($vggroup)"
        vgchange -ay "$vggroup" >/dev/null 2>&1
        checkStatus $? "done" "Could not activate volume group $vggroup (${FUNCNAME[0]})\n   Args Passed: $*"
        udevadm settle >/dev/null 2>&1
        debugPause
        # format 1 recorded no per-LV originals to distribute by; its extra
        # space stays unallocated in the VG, exactly as Phase 1 left it
        if [[ $targetsize -gt $pvsize && $lvmformat == "LVMFORMAT 2" ]]; then
            growLVMPartition "$part" "$vggroup" "$lvmfilename"
        fi
    else
        rebuildLVMPartition "$part" "$pvuuid" "$vggroup" "$extentsize" "$lvmfilename"
    fi
    local tag=""
    local lvname=""
    local lvuuid=""
    local lvsize=""
    local lvminsize=""
    local lvfstype=""
    local lvimage=""
    local swapuuid=""
    while read -r tag lvname lvuuid lvsize lvminsize lvfstype lvimage swapuuid; do
        [[ $tag != LV ]] && continue
        if [[ $lvmformat == "LVMFORMAT 1" ]]; then
            # format 1 has no minimum-size column; shift the trailing fields
            swapuuid=$lvimage
            lvimage=$lvfstype
            lvfstype=$lvminsize
            lvminsize=$lvsize
        fi
        local lvdev="/dev/${vggroup}/${lvname}"
        [[ ! -e $lvdev ]] && handleError "Logical volume missing after restore: $lvdev (${FUNCNAME[0]})\n   Args Passed: $*"
        if [[ $lvfstype == swap ]]; then
            dots "Recreating swap volume ($lvname)"
            local option=""
            [[ -n $swapuuid && $swapuuid != - ]] && option="-U $swapuuid"
            mkswap $option "$lvdev" >/dev/null 2>&1
            checkStatus $? "done" "Could not create swap on $lvdev (${FUNCNAME[0]})\n   Args Passed: $*"
            debugPause
            continue
        fi
        [[ -z $lvimage || $lvimage == - ]] && continue
        local imgfile="$imagePath/${lvimage}${split}"
        ls $imgfile >/dev/null 2>&1
        [[ ! $? -eq 0 ]] && handleError "Logical volume image missing: $imgfile (${FUNCNAME[0]})\n   Args Passed: $*"
        echo " * Processing Logical Volume: $lvdev"
        debugPause
        writeImage "$imgfile" "$lvdev" "$mc"
    done < "$lvmfilename"
    # Leave the stack inactive so the deployed OS boots from a clean state.
    vgchange -an "$vggroup" >/dev/null 2>&1 || echo " * Warning: could not deactivate volume group $vggroup"
}
# Trims character from string
# $1 The variable to trim
trim() {
    local var="$1"
    var="${var#${var%%[![:space:]]*}}"
    var="${var%${var##*[![:space:]]}}"
    echo -n "$var"
}
# Calculates information
calculate() {
    echo $(awk 'BEGIN{printf "%.0f\n", '$*'}')
}
# Calculates information and returns full float
calculate_float() {
    echo $(awk 'BEGIN{printf "%f\n", '$*'}');
}
