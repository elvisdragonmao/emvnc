# Disposable TigerVNC server for emvnc integration tests (VNC Password auth, Extended Clipboard).
FROM debian:bookworm-slim

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      tigervnc-standalone-server tigervnc-tools xclip x11-utils xdotool xterm procps zenity \
 && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 5901
ENTRYPOINT ["/entrypoint.sh"]
