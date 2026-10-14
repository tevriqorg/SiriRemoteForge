#!/bin/bash
#
# install.sh — install the "Siri Remote Mic" capture supervisor as a system LaunchDaemon.
#
# This is the one privileged step of the whole feature: it grants the supervisor standing root so
# PacketLogger can keep one Bluetooth HCI stream open without a per-use password. The installed
# supervisor starts PacketLogger + srm_router at daemon load and keeps that stream warm; user Voice
# presses no longer launch privileged capture processes. Actual remote-mic activity is still derived
# from fresh shared-ring frames, so an idle remote does not present as an active audio producer.
#
# Idempotent: safe to re-run to update the binaries. Needs sudo (installs to system locations).
#
set -e
cd "$(dirname "$0")"

SUPPORT="/Library/Application Support/SiriRemoteMic"
PLIST_SRC="au.holodata.SiriRemoteMic.captured.plist"
PLIST_DST="/Library/LaunchDaemons/au.holodata.SiriRemoteMic.captured.plist"
ROUTER_SRC="../router/srm_router"

[ -x srm_captured ] || { echo "build first: ./build.sh"; exit 1; }
[ -x "$ROUTER_SRC" ] || { echo "build the router first: (cd ../router && ./build.sh)"; exit 1; }

echo "installing daemon + router → $SUPPORT"
sudo mkdir -p "$SUPPORT"
sudo cp srm_captured "$SUPPORT/srm_captured"
sudo cp "$ROUTER_SRC" "$SUPPORT/srm_router"
sudo chown root:wheel "$SUPPORT/srm_captured" "$SUPPORT/srm_router"
sudo chmod 755 "$SUPPORT/srm_captured" "$SUPPORT/srm_router"

echo "installing LaunchDaemon → $PLIST_DST"
sudo cp "$PLIST_SRC" "$PLIST_DST"
sudo chown root:wheel "$PLIST_DST"
sudo chmod 644 "$PLIST_DST"

echo "(re)loading the daemon"
sudo launchctl unload -w "$PLIST_DST" 2>/dev/null || true
sudo launchctl load -w "$PLIST_DST"

echo "✓ installed. Status:"
sudo launchctl list | grep -i SiriRemoteMic || echo "(not listed — check /var/log/srm_captured.log)"
echo "log: /var/log/srm_captured.log"
