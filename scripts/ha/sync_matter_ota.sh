#!/bin/bash
#
# sync_matter_ota.sh
#
# Laeuft im Advanced SSH & Web Terminal Add-on von Home Assistant.
# Holt regelmaessig eine OTA-Provider-JSON von einer URL (z.B. Nextcloud-Share)
# und kopiert sie in den Matter-Server-Add-on-Container, sobald sich der
# SHA-256 geaendert hat. Macht anschliessend stop+start, damit der Loader
# die neue Datei wirklich einliest.
#
# Pfad in HA: /config/sync_matter_ota.sh
#
# Aufruf einmalig (als Daemon im Hintergrund) ueber Add-on init_commands:
#   nohup /config/sync_matter_ota.sh daemon >> /config/matter_ota.log 2>&1 &
#
# Oder manuell zum Testen:
#   bash -x /config/sync_matter_ota.sh once
#
set -euo pipefail

# ---- Konfiguration ---------------------------------------------------------
JSON_URL="${JSON_URL:-https://github.com/piers-93/MatterMoistureSensorSleepy/releases/latest/download/icd_app.json}"
JSON_NAME="${JSON_NAME:-icd_app.json}"

ADDON_CONTAINER="${ADDON_CONTAINER:-addon_core_matter_server}"
ADDON_SLUG="${ADDON_SLUG:-core_matter_server}"
ADDON_OTA_DIR="${ADDON_OTA_DIR:-/config/ota}"

INTERVAL_SEC="${INTERVAL_SEC:-3600}"   # 60 min Default
LOG_FILE="${LOG_FILE:-/config/matter_ota.log}"

# ---- Helpers ---------------------------------------------------------------
log() {
    local line
    line="$(date '+%F %T') $*"
    printf '%s\n' "$line"
    printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null || true
}

sync_once() {
    local tmp new old sw_ver target
    tmp=$(mktemp)
    if ! curl -fsSL "$JSON_URL" -o "$tmp"; then
        log "ERROR: download fehlgeschlagen ($JSON_URL)"
        rm -f "$tmp"
        return 1
    fi

    # Sanity-Check: ist es ueberhaupt gueltige OTA-JSON?
    if ! grep -q '"modelVersion"' "$tmp"; then
        log "ERROR: heruntergeladene Datei enthaelt kein 'modelVersion' Feld"
        rm -f "$tmp"
        return 1
    fi

    # Versionsnummer aus JSON ziehen (fuer eindeutigen Dateinamen im Container)
    sw_ver=$(sed -nE 's/.*"softwareVersion"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' "$tmp" \
             | head -n1)
    if [[ -z "$sw_ver" ]]; then
        log "ERROR: konnte softwareVersion nicht aus JSON lesen"
        rm -f "$tmp"
        return 1
    fi
    target="icd_app-v${sw_ver}.json"

    new=$(sha256sum "$tmp" | awk '{print $1}')
    old=$(docker exec "$ADDON_CONTAINER" sha256sum "$ADDON_OTA_DIR/$target" 2>/dev/null \
          | awk '{print $1}' || true)

    if [[ "$new" == "${old:-}" ]]; then
        log "no change (v=$sw_ver sha=$new)"
        rm -f "$tmp"
        return 0
    fi

    log "change detected: v=$sw_ver old=${old:-none} new=$new"

    # Alte JSONs wegraeumen, damit der Loader nicht durch alte Versionen
    # verwirrt wird und der Ordner sauber bleibt.
    docker exec "$ADDON_CONTAINER" sh -c \
        "mkdir -p $ADDON_OTA_DIR && rm -f $ADDON_OTA_DIR/icd_app-v*.json $ADDON_OTA_DIR/icd_app.json"

    docker cp "$tmp" "$ADDON_CONTAINER:$ADDON_OTA_DIR/$target"
    rm -f "$tmp"

    log "copied to $ADDON_CONTAINER:$ADDON_OTA_DIR/$target"

    # Da wir die JSON unter einem NEUEN Dateinamen (icd_app-vN.json) ablegen,
    # reicht ein simples 'restart'. (Editiert man dieselbe Datei, braucht der
    # Matter-Server-Loader ein echtes stop+start - hier nicht der Fall.)
    log "addon restart: $ADDON_SLUG"
    ha apps restart "$ADDON_SLUG" >/dev/null
    log "addon ready"
}

# ---- Main ------------------------------------------------------------------
MODE="${1:-once}"

case "$MODE" in
    once)
        sync_once
        ;;
    daemon)
        log "daemon start (interval=${INTERVAL_SEC}s, url=$JSON_URL)"
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
