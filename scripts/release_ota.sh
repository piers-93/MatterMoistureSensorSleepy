#!/usr/bin/env bash
#
# release_ota.sh
#
# Erzeugt aus build/icd_app.bin eine Matter-OTA-Datei (.ota) und die
# passende Provider-Metadaten-JSON (.json) fuer den python-matter-server.
# Liest VID/PID sowie PROJECT_VER / PROJECT_VER_NUMBER automatisch aus
# CMakeLists.txt, damit nichts mehr von Hand gepflegt werden muss.
#
# Optional kopiert das Script die JSON direkt in den Matter-Server-
# Add-on-Container von Home Assistant (per ssh + docker cp).
#
# Beispielnutzung:
#   scripts/release_ota.sh                # nur .ota + .json lokal erzeugen
#   HA_HOST=192.168.178.76 HA_USER=piers-93 scripts/release_ota.sh --deploy
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

# OTA-URL, die in die JSON geschrieben wird. Default: dein Nextcloud-Share.
# Wenn du die Datei dort einfach ueberschreibst, muss diese URL nie geaendert
# werden – die JSON aktualisiert sich beim naechsten Release-Lauf von selbst.

OTA_URL_DEFAULT="https://github.com/piers-93/MatterMoistureSensorSleepy/releases/latest/download/icd_app.ota"
OTA_URL="${OTA_URL:-$OTA_URL_DEFAULT}"

# Min/Max Range fuer "auf welche installierte Version darf upgedated werden"
MIN_APPLICABLE="${MIN_APPLICABLE:-1}"
# Wird unten automatisch auf (softwareVersion - 1) gesetzt, falls leer.
MAX_APPLICABLE="${MAX_APPLICABLE:-}"

# Link zu Release-Notes (optional, wird in QueryImageResponse mitgeschickt).
RELEASE_NOTES_URL="${RELEASE_NOTES_URL:-https://github.com/piers-93/MatterMoistureSensorSleepy/releases/latest}"

# Deployment-Ziel (optional)
HA_HOST="${HA_HOST:-}"
HA_USER="${HA_USER:-}"
HA_CONTAINER="${HA_CONTAINER:-addon_core_matter_server}"
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

if [[ -z "$MAX_APPLICABLE" ]]; then
    MAX_APPLICABLE=$(( PROJECT_VER_NUMBER - 1 ))
    [[ "$MAX_APPLICABLE" -lt "$MIN_APPLICABLE" ]] && MAX_APPLICABLE="$MIN_APPLICABLE"
fi

# Dezimale VID/PID fuer JSON
VID_DEC=$(printf '%d' "$VID")
PID_DEC=$(printf '%d' "$PID")

echo "  Projekt-Version : $PROJECT_VER (Number $PROJECT_VER_NUMBER)"
echo "  VID/PID         : $VID / $PID  (dec $VID_DEC / $PID_DEC)"
echo "  OTA-URL         : $OTA_URL"
echo "  Applicable      : [$MIN_APPLICABLE .. $MAX_APPLICABLE]"
echo

# ---- Optional: Build -------------------------------------------------------
if [[ "$DO_BUILD" -eq 1 ]]; then
    echo ">> idf.py build"
    idf.py build
fi

[[ -f "$BIN_PATH" ]] || { echo "Binary nicht gefunden: $BIN_PATH (--build vergessen?)" >&2; exit 1; }

mkdir -p "$OUT_DIR"
OTA_FILE="$OUT_DIR/icd_app-v${PROJECT_VER_NUMBER}.ota"
JSON_FILE="$OUT_DIR/icd_app-v${PROJECT_VER_NUMBER}.json"

# ---- OTA-Image erzeugen ----------------------------------------------------
echo ">> ota_image_tool create -> $OTA_FILE"
python3 "$OTA_TOOL" create \
    -v "$VID" -p "$PID" \
    -vn "$PROJECT_VER_NUMBER" -vs "$PROJECT_VER" \
    -da sha256 \
    "$BIN_PATH" "$OTA_FILE"

# ---- Groesse + SHA-256 (Base64) --------------------------------------------
OTA_SIZE=$(stat -c%s "$OTA_FILE")
OTA_SHA256_B64=$(openssl dgst -sha256 -binary "$OTA_FILE" | base64)

echo "  Size            : $OTA_SIZE"
echo "  SHA-256 (b64)   : $OTA_SHA256_B64"

# ---- JSON erzeugen ---------------------------------------------------------
cat > "$JSON_FILE" <<EOF
{
  "modelVersion": {
    "vid": $VID_DEC,
    "pid": $PID_DEC,
    "softwareVersion": $PROJECT_VER_NUMBER,
    "softwareVersionString": "$PROJECT_VER",
    "cdVersionNumber": 1,
    "firmwareInformation": "",
    "softwareVersionValid": true,
    "otaUrl": "$OTA_URL",
    "otaFileSize": "$OTA_SIZE",
    "otaChecksum": "$OTA_SHA256_B64",
    "otaChecksumType": 1,
    "minApplicableSoftwareVersion": $MIN_APPLICABLE,
    "maxApplicableSoftwareVersion": $MAX_APPLICABLE,
    "releaseNotesUrl": "$RELEASE_NOTES_URL"
  }
}
EOF

echo ">> JSON geschrieben: $JSON_FILE"

# ---- Optional: in HA-Container deployen ------------------------------------
if [[ "$DEPLOY" -eq 1 ]]; then
    [[ -n "$HA_HOST" && -n "$HA_USER" ]] \
        || { echo "Fuer --deploy bitte HA_HOST und HA_USER setzen" >&2; exit 1; }

    REMOTE_TMP="/tmp/$(basename "$JSON_FILE")"
    echo ">> scp $JSON_FILE -> $HA_USER@$HA_HOST:$REMOTE_TMP"
    scp "$JSON_FILE" "$HA_USER@$HA_HOST:$REMOTE_TMP"

    echo ">> docker cp $REMOTE_TMP -> $HA_CONTAINER:$HA_OTA_DIR/"
    ssh "$HA_USER@$HA_HOST" \
        "docker exec $HA_CONTAINER mkdir -p $HA_OTA_DIR && \
         docker cp $REMOTE_TMP $HA_CONTAINER:$HA_OTA_DIR/ && \
         rm $REMOTE_TMP && \
         docker exec $HA_CONTAINER ls -la $HA_OTA_DIR/"

    if [[ "$DO_RESTART" -ne 1 ]]; then
        echo
        echo "Hinweis: Matter-Server-Add-on neu starten, damit die JSON eingelesen wird."
        echo "         (oder --restart zusaetzlich mitgeben)"
    fi
fi

# ---- Optional: Matter-Server-Add-on per Supervisor-API neu starten ---------
if [[ "$DO_RESTART" -eq 1 ]]; then
    # WICHTIG: 'restart' reicht beim Matter-Server-Add-on NICHT, weil der
    # JSON-OTA-Loader nur beim echten Prozess-Start laeuft. Daher stop+start.
    #
    # Variante A: HA REST API von aussen (braucht HA_API_URL + HA_TOKEN)
    if [[ -n "$HA_API_URL" && -n "$HA_TOKEN" ]]; then
        echo ">> Stop+Start per HA REST API: $HA_API_URL"
        curl -fsSL -X POST \
            -H "Authorization: Bearer $HA_TOKEN" \
            "$HA_API_URL/api/hassio/addons/$HA_ADDON_SLUG/stop" >/dev/null
        curl -fsSL -X POST \
            -H "Authorization: Bearer $HA_TOKEN" \
            "$HA_API_URL/api/hassio/addons/$HA_ADDON_SLUG/start" >/dev/null
        echo "   ok"
    # Variante B: per SSH ueber Supervisor-Socket (braucht HA_HOST/HA_USER)
    elif [[ -n "$HA_HOST" && -n "$HA_USER" ]]; then
        echo ">> Stop+Start per ssh: ha addons stop/start $HA_ADDON_SLUG"
        ssh "$HA_USER@$HA_HOST" \
            "ha addons stop $HA_ADDON_SLUG && ha addons start $HA_ADDON_SLUG"
    else
        echo "Fuer --restart bitte entweder HA_API_URL + HA_TOKEN, oder HA_HOST + HA_USER setzen" >&2
        exit 1
    fi
fi

echo
echo "Fertig."
echo "  -> .ota nach $OTA_URL hochladen (sofern noch nicht passiert),"
if [[ "$DO_RESTART" -ne 1 ]]; then
    echo "  -> Matter-Server-Add-on neu starten,"
fi
echo "  -> in HA: Einstellungen -> System -> Nach Updates suchen."
