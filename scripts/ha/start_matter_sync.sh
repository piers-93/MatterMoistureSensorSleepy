#!/bin/sh
#
# start_matter_sync.sh
#
# Launcher fuer den Matter-OTA-Sync-Daemon.
# Wird vom "Advanced SSH & Web Terminal" Add-on per init_commands ausgefuehrt,
# kann aber auch manuell gestartet werden.
#
# Pfad in HA:        /config/start_matter_sync.sh
# Ruft auf:          /config/matter/ota/sync_matter_ota.sh daemon
#
# Eintrag in Add-on Configuration -> init_commands:
#   - /config/start_matter_sync.sh
#

# Marker: hinterlaesst Zeitstempel + Uptime, damit man sehen kann,
# ob init_commands beim Add-on-/Host-Boot wirklich gefeuert hat.
date "+%F %T  init_commands ran (uptime=$(cut -d. -f1 /proc/uptime)s)" \
    >> /config/start_matter_sync.log

# eventuell laufenden alten Daemon beenden (idempotent: schadet nicht, wenn keiner laeuft)
pkill -f sync_matter_ota.sh 2>/dev/null

# Neuen Daemon im Hintergrund starten, ueberlebt das Beenden der SSH-Session.
# setsid loest den Prozess aus der Session-Gruppe -> wird vom s6-Init nicht reaped.
# BOOT_DELAY_SEC=120: nach Host-Reboot 2 min warten, bis Docker / Matter-Server
# stabil oben sind, bevor der erste Sync versucht wird.
# stdout/stderr ins normale OTA-Log umleiten, damit auch Crashes sichtbar sind.
BOOT_DELAY_SEC=120 nohup setsid /config/matter/ota/sync_matter_ota.sh daemon \
    >> /config/matter_ota.log 2>&1 &
