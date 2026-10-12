#!/bin/sh
# VNC_PASSWORD selects the password; SECURITY selects TigerVNC security types (default VncAuth).
set -e
mkdir -p /root/.vnc
printf '%s\n' "${VNC_PASSWORD:-testpass}" | vncpasswd -f > /root/.vnc/passwd
chmod 600 /root/.vnc/passwd

Xvnc :1 -rfbport 5901 -geometry 1280x800 -depth 24 \
     -SecurityTypes "${SECURITY:-VncAuth}" -PasswordFile /root/.vnc/passwd \
     -AlwaysShared -SendCutText=1 -AcceptCutText=1 > /tmp/xvnc.log 2>&1 &

export DISPLAY=:1
for i in $(seq 1 50); do xdpyinfo >/dev/null 2>&1 && break; sleep 0.1; done

# Every key event reaching the X server is logged here for the tests to inspect
stdbuf -oL xev -root -event keyboard > /tmp/keys.log 2>&1 &

# Something visible on screen
xterm -geometry 60x8+760+620 -fa Monospace -fs 12 -e sh -c 'echo emvnc integration server; sleep infinity' &

wait
