#!/bin/bash
oIFS=$IFS
for var in $(cat /proc/cmdline); do
    IFS=$oIFS
    read name value <<< $(echo "$var" | grep =.* | awk -F= '{name=$1;$1="";gsub(/[ \t]+$/,"",$0);gsub(/^[ \t]+/,"",$0); gsub(/[+][_][+]/," ",$0); value=$0; print name; print value;}')
    IFS=$'\n'
    [[ -z $value ]] && continue
    value=$(echo $value | sed 's/\"//g')
    printf -v "$name" -- "$value"
done
IFS=$oIFS
nodepath= $(which node)
if [ "$type" == "web" ] && [ "$fogserver" != "" ]; then
	/usr/bin/psplash-write "MSG Contacting FOG Server..."
	/usr/bin/psplash-write "PROGRESS 80"
	wget http://$fogserver/boot/bootloader.js -O /usr/share/fog/bootloader.js
	$nodepath /usr/share/fog/bootloader.js
	/usr/bin/psplash-write "MSG Starting FOS..."
	/usr/bin/psplash-write "PROGRESS 90"
fi



