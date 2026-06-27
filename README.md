# Bodenfeuchtigkeitssensor mit ESP32H2 als LIT Device
Bodenfeuchtigkeitssensor, alle 10min wird der Wert übermittelt, Rest Light Sleep (30uA)

## ESP-IDF aktivieren (+Matter Pfad setzen)

```bash
source ~/esp-idf/export.sh
source ~/esp-matter/export.sh
```

## Device setzen (ESP32H2 als LIT Device ("Long Idle Time"))

```bash
idf.py -D SDKCONFIG_DEFAULTS="sdkconfig.defaults.esp32h2.lit" set-target esp32h2
```

## Factory Partition auf 0x10000 flashen

```bash
esptool.py --chip esp32h2 --port /dev/ttyACM0 --baud 460800 write_flash 0x10000 "out/fff2_8001/407bf0e4-99aa-4545-a8c4-aeb171f4edf5/407bf0e4-99aa-4545-a8c4-aeb171f4edf5-partition.bin"
```

## Rest flashen (Bootloader, Partition Table, App, OTA_data)

```bash
idf.py -p /dev/ttyACM0 flash
```

oder mit Monitor:

```bash
idf.py -p /dev/ttyACM0 flash monitor
```


## Voraussetzung: Einstellungen in menuconfig für Factory Partition

Folgende Settings in `menuconfig` setzen (`idf.py menuconfig`):

- **Component config → CHIP Device Layer → Commissioning options**
  - Use ESP32 Factory Data Provider
  - Use ESP32 Device Instance Info Provider
- **Component config → ESP Matter → Device Instance Info Provider options**
  - Device Instance Info - Factory
- **Component config → ESP Matter → DAC Provider options**
  - Attestation - Factory

## Matter QR Code

Der Matter QR Code steht in der Datei  
`\out\fff2_8001\<...>_codes.csv`  
oder direkt als PNG-Datei im selben Ordner.

Matter QR Code Generator auch unter:  
[https://thekuwayama.github.io/matter_qrcode_generator/](https://thekuwayama.github.io/matter_qrcode_generator/)

## Matter Informationen

Matter Informationen wurden über das Skript  
`\scripts\generate_factory_partition.sh`  
erstellt (mit esp-matter-mfg-tool). Informationen können hier einfach angepasst werden.
Das Skript flasht jetzt automatisch am Ende (auf Nachfrage)

## USB zu WSL durchschleifen mit usbipd

```bash
usbipd list
usbipd attach -a --wsl --busid <busid>
# vorher mit als admin gestartetem cmd Fenster:
usbipd bind --busid <busid>
```

## Verdrahtungsplan

![Wiring](image/MoistureSensorWiring.png)


## Optimierungen Ruhestrom
-RGB LED heruntergelötet (WSxxx)
-3V3 Wandler ersetzt durch ADP162AUJZ-3.3-R7 (spart 80uA)
-GPIO 8 auf high (JTAG deaktiviert)
-NE555 durch ICM7555 (Nanoamperebereich statt 8mA)
-Akkumessung sehr hochohmig (2+4.7 Megaohm, nur 0.6uA)

-gesamt etwa 30uA im Light Sleep, gemessen in der Akkuzuleitung.

# Matter-OTA-Auto-Sync auf Home Assistant einrichten

Diese Anleitung richtet einen Daemon auf Home Assistant ein, der regelmäßig
das neueste `.ota`-Firmware-Release vom GitHub-Repository abholt und an den
Matter-Server weitergibt. Sobald eine neue Version online ist, bekommen die
Matter-Geräte sie beim nächsten Wake-up automatisch angeboten.

## Voraussetzungen auf Home Assistant

Folgende Add-ons müssen installiert und gestartet sein:

1. **Advanced SSH & Web Terminal** (zum Anlegen der Skripte mit `nano` und für den Daemon)
2. **Matter Server** (Version 9.0 oder neuer)

### Matter-Server konfigurieren

Im **Matter Server** Add-on unter *Configuration* setzen:

```yaml
enable_test_net_dcl: true
Extra Matter Server arguments: --ota-provider-dir /config/ota
```

Hinweis: `ota_provider_dir` zeigt aus Sicht des Add-on-Containers auf
`/data/ota` — vom Host bzw. von der SSH-Konsole aus erreichbar als
`/config/ota`. **Beides ist derselbe Ordner.**


## Skripte anlegen (z.B. SSH-Terminal mit nano)

Im **Advanced SSH & Web Terminal** Add-on werden beide Skripte mit `nano`
direkt angelegt. Vorteil: keine CRLF-Probleme, `chmod +x` geht im selben
Rutsch.

### Datei 1: `/config/matter/ota/sync_matter_ota.sh`

```bash
mkdir -p /config/matter/ota
nano /config/matter/ota/sync_matter_ota.sh
```

Inhalt der Datei [sync_matter_ota.sh](sync_matter_ota.sh) komplett
hineinkopieren, dann `Ctrl+O`, `Enter`, `Ctrl+X`.


### Datei 2: `/config/start_matter_sync.sh`

```bash
nano /config/start_matter_sync.sh
```

Inhalt der Datei [start_matter_sync.sh](start_matter_sync.sh) komplett
hineinkopieren, dann `Ctrl+O`, `Enter`, `Ctrl+X`.

### Ausführbar machen

```bash
chmod +x /config/matter/ota/sync_matter_ota.sh /config/start_matter_sync.sh
```

## Funktionstest

```bash
# Einmaliger Lauf — holt die Datei, kopiert sie rein, restartet Matter-Server
/config/matter/ota/sync_matter_ota.sh once

# Log ansehen
tail -n 20 /config/matter_ota.log
```

Erwartete Ausgabe:

```
... change detected: old=none new=<sha>
... copied to addon_core_matter_server:/config/ota/icd_app.ota
... addon restart: core_matter_server
... ok: import bestaetigt (icd_app.ota wurde von matter.js uebernommen)
```

Wenn da `WARN: ... noch da` steht, hat matter.js den Import abgelehnt — dann
Matter-Server-Logs prüfen.

## Daemon dauerhaft starten

```bash
/config/start_matter_sync.sh

# Verifizieren, dass er läuft
ps -ef | grep sync_matter_ota | grep -v grep
```

Erwartet eine Zeile wie:

```
root  1234  1  0 17:22 ? 00:00:00 /bin/bash /config/matter/ota/sync_matter_ota.sh daemon
```

## Autostart nach HA-Reboot

Im Add-on **Advanced SSH & Web Terminal** unter *Configuration* in den
`init_commands` ergänzen:

```yaml
init_commands:
  - /config/start_matter_sync.sh
```

Add-on einmal neu starten. Ab jetzt überlebt der Daemon jeden HA-Neustart.

## Was passiert ab jetzt automatisch

1. Daemon prüft jede Stunde (`INTERVAL_SEC=3600`), ob auf GitHub eine neue
   `icd_app.ota` als *Latest Release* liegt
2. Wenn ja: SHA-256 vergleichen → bei Änderung in den Matter-Server-Container
   kopieren, Add-on neu starten
3. Matter-Server scannt beim Boot das OTA-Verzeichnis, übernimmt die Datei
   intern und löscht sie aus dem Ordner (das ist das Erfolgssignal)
4. Beim nächsten Wake-up des ICD wird das Update angeboten


Um den Update Suchvorgang anzustoßen, unter Einstellungen->System->Updates den Refresh Button klicken.  
Das Skript startet den Matter-Server neu, falls eine neue Datei kopiert wurde.

# ICD bauen
```yaml
source ~/esp-idf/export.sh
source ~/esp-matter/export.sh
```
In CMakeLists.txt die Version hochzählen:
```yaml
set(PROJECT_VER         "1.0.4")
set(PROJECT_VER_NUMBER  4)
```
```yaml
./scripts/release_ota.sh --build
```
(Wenn schon gebaut wurde ohne --build)

<br>
<br>
<br>
<br>
<br>

---

<br>

# BASISPROJEKT: ICD_APP Example (Intermittently Connected Device)

This example creates a Matter ICD device using the ESP Matter data model. Currently it is available for ESP32-H2 and ESP32-C6.

See the [docs](https://docs.espressif.com/projects/esp-matter/en/latest/esp32/developing.html) for more information about building and flashing the firmware.

**Note**: Please use IDF v5.2.2 or later for this example.

## 1. Additional Environment Setup

No additional setup is required.

## 2. Post Commissioning Setup

No additional setup is required.

## 3. ICD configuration options

The device is configured as a Short Idle Time(SIT) ICD with the following parameters by the default sdkconfig files.

| Parameter                 | Value  |
|---------------------------|--------|
| ICD Fast Polling Interval | 500ms  |
| ICD Slow Polling Interval | 5000ms |
| ICD Active Mode Duration  | 1000ms |
| ICD Idle Mode Duration    | 60s    |
| ICD Active Mode Threshold | 1000ms |

It can also be configured as a Long Idle Time(LIT) ICD with the following parameters by the sdkconfig files `sdkconfig.defaults.esp32h2.lit` or `sdkconfig.defaults.esp32c6.lit`.

| Parameter                 | Value   |
|---------------------------|---------|
| ICD Fast Polling Interval | 500ms   |
| ICD Slow Polling Interval | 20000ms |
| ICD Active Mode Duration  | 1000ms  |
| ICD Idle Mode Duration    | 600s    |
| ICD Active Mode Threshold | 5000ms  |

- ESP32-H2:
```
idf.py -D SDKCONFIG_DEFAULTS="sdkconfig.defaults.esp32h2.lit" set-target esp32h2 build
```
- ESP32-C6:
```
idf.py -D SDKCONFIG_DEFAULTS="sdkconfig.defaults.esp32c6.lit" set-target esp32c6 build
```

**Note**: According to the Matter 1.4 specification, "A LIT ICD SHALL operate as a SIT ICD if it doesn’t have at least one registration with any client on any fabric in the ICD Management cluster." In such case, a LIT ICD shall not set its Slow Polling Interval higher than the maximum allowed for a SIT ICD.

## 4. Power usage

The power usage will be various for different configuration parameters of ICD server.

Below are example current wave figures for ESP32-H2 Devkit-C and ESP32-C6 Devkit-C under the default SIT or LIT configurations. The ICD configurations are listed in the two tables above.

Note that all the current wave figures are measured with 20dBm radio TX power.

Current Wave Figure for ESP32-H2(SIT):
![H2-sit-icd](image/H2-sit-icd.png)

Current Wave Figure for ESP32-C6(SIT):
![C6-sit-icd](image/C6-sit-icd.png)

Current Wave Figure for ESP32-H2(LIT):
![H2-lit-icd](image/H2-lit-icd.png)

Current Wave Figure for ESP32-C6(LIT):
![C6-lit-icd](image/C6-lit-icd.png)
