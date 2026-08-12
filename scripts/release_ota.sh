#!/usr/bin/env bash
#
# release_ota.sh
#
# Erzeugt aus build/icd_app.bin eine Matter-OTA-Datei (.ota) und kopiert sie
# optional direkt in den Matter-Server-Add-on-Container.
#
# WICHTIG (matter.js Server >= 9.0):
#   - Es werden NUR die *.ota* eingelesen, *.json* werden ignoriert.
#   - Beim Start des Servers wird die .ota importiert und ANSCHLIESSEND aus
#     /config/ota/ GELOESCHT (intern in den Server-Storage uebernommen).
#   - VID/PID/SoftwareVersion werden direkt aus dem .ota-Image extrahiert,
#     daher ist keine separate JSON-Metadatendatei mehr noetig.
#
# Liest VID/PID sowie PROJECT_VER / PROJECT_VER_NUMBER automatisch aus
# CMakeLists.txt, damit nichts mehr von Hand gepflegt werden muss.
#
# Beispielnutzung:
#   scripts/release_ota.sh                # nur .ota lokal erzeugen
#   scripts/release_ota.sh --build        # vorher idf.py build
#   HA_HOST=192.168.178.76 HA_USER=piers-93 scripts/release_ota.sh --deploy
#   scripts/release_ota.sh --all          # build + deploy + restart
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

# ---- Defaults / Overrides --------------------------------------------------
VID="${VID:-0xFFF2}"
PID="${PID:-0x8001}"
BIN_PATH="${BIN_PATH:-build/icd_app.bin}"
OUT_DIR="${OUT_DIR:-out/ota}"

# Release Notes URL (optional). Wird in den OTA-Header eingebettet und von
# matter.js beim Import gelesen -> HA zeigt diese URL beim Update-Eintrag an.
# Default zeigt immer auf den aktuell neuesten GitHub-Release.
RELEASE_NOTES_URL="${RELEASE_NOTES_URL:-https://github.com/piers-93/MatterMoistureSensorSleepy/releases/tag/SoilMoisture}"

# Deployment-Ziel (optional)
HA_HOST="${HA_HOST:-}"
HA_USER="${HA_USER:-}"
HA_CONTAINER="${HA_CONTAINER:-app_core_matter_server}"
HA_OTA_DIR="${HA_OTA_DIR:-/config/ota}"
# Add-on-Slug fuer Supervisor-API-Restart
HA_ADDON_SLUG="${HA_ADDON_SLUG:-core_matter_server}"
# Long-Lived Access Token aus HA-Profil (fuer Add-on-Restart per REST API)
# Optional auch ueber Datei: HA_TOKEN_FILE=~/.ha_token
HA_TOKEN="${HA_TOKEN:-}"
if [[ -z "$HA_TOKEN" && -n "${HA_TOKEN_FILE:-}" && -f "$HA_TOKEN_FILE" ]]; then
    HA_TOKEN="$(<"$HA_TOKEN_FILE")"
fi
HA_API_URL="${HA_API_URL:-}"  # z.B. http://192.168.178.76:8123

DEPLOY=0
DO_BUILD=0
DO_RESTART=0
for arg in "$@"; do
    case "$arg" in
        --deploy)  DEPLOY=1 ;;
        --build)   DO_BUILD=1 ;;
        --restart) DO_RESTART=1 ;;
        --all)     DO_BUILD=1; DEPLOY=1; DO_RESTART=1 ;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0 ;;
        *) echo "Unbekanntes Argument: $arg" >&2; exit 2 ;;
    esac
done

# ---- Tooling pruefen -------------------------------------------------------
: "${ESP_MATTER_PATH:?ESP_MATTER_PATH ist nicht gesetzt}"
MATTER_SDK_PATH="${MATTER_SDK_PATH:-$ESP_MATTER_PATH/connectedhomeip/connectedhomeip}"
OTA_TOOL="$MATTER_SDK_PATH/src/app/ota_image_tool.py"
[[ -f "$OTA_TOOL" ]] || { echo "ota_image_tool.py nicht gefunden: $OTA_TOOL" >&2; exit 1; }

# ---- Version + Metadaten aus CMakeLists.txt lesen --------------------------
CMAKE_FILE="$PROJECT_DIR/CMakeLists.txt"
PROJECT_VER=$(grep -E '^[[:space:]]*set\(PROJECT_VER[[:space:]]+"' "$CMAKE_FILE" \
              | head -n1 | sed -E 's/.*"([^"]+)".*/\1/')
PROJECT_VER_NUMBER=$(grep -E '^[[:space:]]*set\(PROJECT_VER_NUMBER[[:space:]]+' "$CMAKE_FILE" \
                    | head -n1 | sed -E 's/.*set\(PROJECT_VER_NUMBER[[:space:]]+([0-9]+).*/\1/')

[[ -n "$PROJECT_VER" && -n "$PROJECT_VER_NUMBER" ]] \
    || { echo "Konnte PROJECT_VER / PROJECT_VER_NUMBER nicht aus CMakeLists.txt lesen" >&2; exit 1; }

echo "  Projekt-Version : $PROJECT_VER (Number $PROJECT_VER_NUMBER)"
echo "  VID/PID         : $VID / $PID"
echo

# ---- Optional: Build -------------------------------------------------------
if [[ "$DO_BUILD" -eq 1 ]]; then
    echo ">> idf.py build"
    idf.py build
fi

[[ -f "$BIN_PATH" ]] || { echo "Binary nicht gefunden: $BIN_PATH (--build vergessen?)" >&2; exit 1; }

mkdir -p "$OUT_DIR"
OTA_FILE="$OUT_DIR/icd_app-v${PROJECT_VER_NUMBER}.ota"

# ---- OTA-Image erzeugen ----------------------------------------------------
echo ">> ota_image_tool create -> $OTA_FILE"
OTA_ARGS=(
    -v "$VID" -p "$PID"
    -vn "$PROJECT_VER_NUMBER" -vs "$PROJECT_VER"
    -da sha256
)
if [[ -n "$RELEASE_NOTES_URL" ]]; then
    echo "  Release Notes   : $RELEASE_NOTES_URL"
    OTA_ARGS+=( -rn "$RELEASE_NOTES_URL" )
fi
python3 "$OTA_TOOL" create \
    "${OTA_ARGS[@]}" \
    "$BIN_PATH" "$OTA_FILE"

# ---- Eingebettete Firmware-Version pruefen ---------------------------------
# Liest die tatsaechlich in der App-Binary (im OTA-Payload) eingebettete
# esp_app_desc-Version. Diese ist massgeblich fuer die von HA angezeigte
# SoftwareVersionString - unabhaengig vom OTA-Header. Weicht sie von
# PROJECT_VER ab, wurde meist ein Rebuild vergessen -> Abbruch.
EMBEDDED_VER=$(python3 - "$OTA_FILE" <<'PY'
import sys, struct
data = open(sys.argv[1], 'rb').read()
idx = data.find(struct.pack('<I', 0xABCD5432))
print(data[idx+16:idx+48].split(b'\0', 1)[0].decode(errors='replace') if idx >= 0 else '')
PY
)
echo "  Firmware in OTA : ${EMBEDDED_VER:-<nicht gefunden>}"
if [[ "$EMBEDDED_VER" != "$PROJECT_VER" ]]; then
    echo "FEHLER: Eingebettete Firmware-Version ('$EMBEDDED_VER') != PROJECT_VER ('$PROJECT_VER')." >&2
    echo "       Vermutlich fehlt ein Rebuild. Nutze 'scripts/release_ota.sh --build'." >&2
    exit 1
fi

# ---- Groesse + SHA-256 (Base64) zur Info -----------------------------------
OTA_SIZE=$(stat -c%s "$OTA_FILE")
OTA_SHA256_B64=$(openssl dgst -sha256 -binary "$OTA_FILE" | base64)

echo "  Size            : $OTA_SIZE"
echo "  SHA-256 (b64)   : $OTA_SHA256_B64"

# ---- Optional: in HA-Container deployen ------------------------------------
if [[ "$DEPLOY" -eq 1 ]]; then
    [[ -n "$HA_HOST" && -n "$HA_USER" ]] \
        || { echo "Fuer --deploy bitte HA_HOST und HA_USER setzen" >&2; exit 1; }

    REMOTE_TMP="/tmp/$(basename "$OTA_FILE")"
    echo ">> scp $OTA_FILE -> $HA_USER@$HA_HOST:$REMOTE_TMP"
    scp "$OTA_FILE" "$HA_USER@$HA_HOST:$REMOTE_TMP"

    echo ">> docker cp $REMOTE_TMP -> $HA_CONTAINER:$HA_OTA_DIR/"
    ssh "$HA_USER@$HA_HOST" \
        "docker exec $HA_CONTAINER mkdir -p $HA_OTA_DIR && \
         docker cp $REMOTE_TMP $HA_CONTAINER:$HA_OTA_DIR/ && \
         rm $REMOTE_TMP && \
         docker exec $HA_CONTAINER ls -la $HA_OTA_DIR/"

    if [[ "$DO_RESTART" -ne 1 ]]; then
        echo
        echo "Hinweis: Matter-Server-Add-on neu starten, damit die .ota importiert wird."
        echo "         (oder --restart zusaetzlich mitgeben)"
        echo "Nach erfolgreichem Import wird die Datei aus $HA_OTA_DIR/ entfernt."
    fi
fi

# ---- Optional: Matter-Server-Add-on neu starten ----------------------------
if [[ "$DO_RESTART" -eq 1 ]]; then
    # matter.js scannt /config/ota/ nur beim Start. 'ha apps restart' macht
    # intern stop+start - reicht hier.
    #
    # Variante A: HA REST API von aussen (braucht HA_API_URL + HA_TOKEN)
    if [[ -n "$HA_API_URL" && -n "$HA_TOKEN" ]]; then
        echo ">> Restart per HA REST API: $HA_API_URL"
        curl -fsSL -X POST \
            -H "Authorization: Bearer $HA_TOKEN" \
            "$HA_API_URL/api/hassio/addons/$HA_ADDON_SLUG/restart" >/dev/null
        echo "   ok"
    # Variante B: per SSH ueber Supervisor-Socket (braucht HA_HOST/HA_USER)
    elif [[ -n "$HA_HOST" && -n "$HA_USER" ]]; then
        echo ">> Restart per ssh: ha apps restart $HA_ADDON_SLUG"
        ssh "$HA_USER@$HA_HOST" "ha apps restart $HA_ADDON_SLUG"
    else
        echo "Fuer --restart bitte entweder HA_API_URL + HA_TOKEN, oder HA_HOST + HA_USER setzen" >&2
        exit 1
    fi
fi

echo
echo "Fertig."
echo "  -> $OTA_FILE bei GitHub als Release-Asset 'icd_app.ota' anhaengen"
echo "     (Release als 'Latest' markieren - der HA-Sync-Daemon zieht es dann automatisch)."
if [[ "$DO_RESTART" -ne 1 ]]; then
    echo "  -> Matter-Server-Add-on neu starten,"
fi
echo "  -> HA findet das Update beim naechsten Device-QueryImage."
