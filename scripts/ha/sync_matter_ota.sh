#!/bin/bash
#
# sync_matter_ota.sh
#
# Laeuft im Advanced SSH & Web Terminal Add-on von Home Assistant.
# Holt regelmaessig eine Matter-OTA-Datei (.ota) von einer URL (z.B. GitHub
# Release-Asset) und legt sie in den Matter-Server-Add-on-Container, sobald
# sich der SHA-256 geaendert hat. Startet anschliessend das Add-on neu, damit
# matter.js die Datei beim Boot scannt, importiert und intern uebernimmt.
#
# WICHTIG (matter.js Server >= 9.0):
#   - Es werden NUR *.ota* eingelesen, *.json* werden ignoriert.
#   - Nach erfolgreichem Import LOESCHT matter.js die Datei aus /config/ota/.
#   - Wir koennen daher nicht im Container nachschauen, was zuletzt drin lag;
#     stattdessen merken wir uns die letzte importierte SHA-256 in einem
#     State-File auf /config.
#
# Pfad in HA: /homeassistant/matter/ota/sync_matter_ota.sh
#
# Aufruf einmalig (als Daemon im Hintergrund) ueber Add-on init_commands:
#   nohup /homeassistant/matter/ota/sync_matter_ota.sh daemon >> /homeassistant/matter/ota/matter_ota.log 2>&1 &
#
# Oder manuell zum Testen:
#   bash -x /homeassistant/matter/ota/sync_matter_ota.sh once
#
set -euo pipefail

# ---- Konfiguration ---------------------------------------------------------
OTA_URL="${OTA_URL:-https://github.com/piers-93/MatterMoistureSensorSleepy/releases/latest/download/icd_app.ota}"
OTA_NAME="${OTA_NAME:-icd_app.ota}"

ADDON_CONTAINER="${ADDON_CONTAINER:-addon_core_matter_server}"
ADDON_SLUG="${ADDON_SLUG:-core_matter_server}"
ADDON_OTA_DIR="${ADDON_OTA_DIR:-/config/ota}"

INTERVAL_SEC="${INTERVAL_SEC:-3600}"   # 60 min Default
LOG_FILE="${LOG_FILE:-/config/matter_ota.log}"
STATE_FILE="${STATE_FILE:-/config/.matter_ota_last_sha}"

# ---- Helpers ---------------------------------------------------------------
log() {
    local line
    line="$(date '+%F %T') $*"
    printf '%s\n' "$line"
    printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null || true
}

sync_once() {
    local tmp new old
    tmp=$(mktemp)
    if ! curl -fsSL "$OTA_URL" -o "$tmp"; then
        log "ERROR: download fehlgeschlagen ($OTA_URL)"
        rm -f "$tmp"
        return 1
    fi

    # Sanity-Check: nicht leer, plausible Mindestgroesse (~100 KB).
    # Die echte Format-Validierung macht matter.js beim Import - wir merken
    # an "Datei wurde nicht geloescht", wenn was schiefging.
    local size
    size=$(stat -c%s "$tmp" 2>/dev/null || echo 0)
    if [[ "$size" -lt 102400 ]]; then
        log "ERROR: heruntergeladene Datei zu klein ($size Bytes - HTML-Fehlerseite?)"
        rm -f "$tmp"
        return 1
    fi

    new=$(sha256sum "$tmp" | awk '{print $1}')
    old=""
    [[ -f "$STATE_FILE" ]] && old=$(<"$STATE_FILE")

    if [[ "$new" == "$old" ]]; then
        log "no change (sha=$new)"
        rm -f "$tmp"
        return 0
    fi

    log "change detected: old=${old:-none} new=$new"

    # Alte .ota-Reste wegraeumen (matter.js loescht eigene Files normalerweise,
    # aber wir koennten z.B. nach einem fehlgeschlagenen Import noch was liegen
    # haben - sicherheitshalber Ordner vorher leeren).
    docker exec "$ADDON_CONTAINER" sh -c \
        "mkdir -p $ADDON_OTA_DIR && rm -f $ADDON_OTA_DIR/*.ota" || true

    docker cp "$tmp" "$ADDON_CONTAINER:$ADDON_OTA_DIR/$OTA_NAME"
    rm -f "$tmp"

    log "copied to $ADDON_CONTAINER:$ADDON_OTA_DIR/$OTA_NAME"

    log "addon restart: $ADDON_SLUG"
    ha apps restart "$ADDON_SLUG" >/dev/null

    # Kurz warten, dann pruefen ob die Datei vom Server importiert (= geloescht)
    # wurde - schoenes Erfolgs-/Misserfolg-Signal.
    sleep 20
    if docker exec "$ADDON_CONTAINER" test -f "$ADDON_OTA_DIR/$OTA_NAME"; then
        log "WARN: $OTA_NAME ist noch da - matter.js hat sie evtl. nicht importiert (Logs pruefen)"
    else
        log "ok: import bestaetigt ($OTA_NAME wurde von matter.js uebernommen)"
        # Erst nach erfolgreichem Import als 'bekannt' markieren - so versucht
        # der Daemon es beim naechsten Tick nochmal, falls Import schiefging.
        printf '%s\n' "$new" > "$STATE_FILE"
    fi
}

# ---- Main ------------------------------------------------------------------
MODE="${1:-once}"

case "$MODE" in
    once)
        sync_once
        ;;
    daemon)
        log "daemon start (interval=${INTERVAL_SEC}s, url=$OTA_URL)"
        # Boot-Puffer: nach einem Host-Reboot startet das SSH-Add-on
        # (und damit dieser Daemon via init_commands) eventuell schneller
        # als der Docker-/Supervisor-Dienst bzw. das Matter-Server-Add-on.
        # 30s warten, damit der erste sync_once nicht ins Leere laeuft.
        sleep "${BOOT_DELAY_SEC:-30}"
        while true; do
            sync_once || true
            sleep "$INTERVAL_SEC"
        done
        ;;
    *)
        echo "Usage: $0 [once|daemon]" >&2
        exit 2
        ;;
esac
