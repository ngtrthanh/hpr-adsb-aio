#!/command/with-contenv bash

# ══════════════════════════════════════════════════════════════════════════════
# FEEDER REGISTRY — single source of truth for all aggregators
#
# To add a new aggregator:
#   1. Append one entry here
#   2. Write configure_<id>() and launch_<id>() below
#   3. Add any required env vars to compose.yaml + .env.example
#   That's it — status JSON and dashboard update automatically.
#
# Entry format: "id|Display Name|category|pgrep_pattern"
#   category:     community | commercial
#   pgrep_pattern: passed to `pgrep -f`; use __always__ for internally-driven feeds
# ══════════════════════════════════════════════════════════════════════════════
declare -a FEEDER_REGISTRY=(
  "fr24feed|flightradar24|commercial|fr24feed"
  "rbfeeder_1|RadarBox (EXTRPI014979)|commercial|rbfeeder --config /etc/rbfeeder_1.ini"
  "rbfeeder_2|RadarBox (PGANRB501179)|commercial|rbfeeder --config /etc/rbfeeder_2.ini"
  "piaware|FlightAware (PiAware)|commercial|piaware"
  "pfclient|PlaneFinder|commercial|pfclient"
  "adsbhub|ADSBHub Network|community|adsbhub.sh"
  "openskyd|OpenSky Network|community|openskyd"
  "hpradar|HPRadar Core|community|__always__"
)

# ── CONFIG GENERATORS ─────────────────────────────────────────────────────────

configure_fr24feed() {
  cat > /etc/fr24feed.ini << EOF
receiver="beast-tcp"
host="127.0.0.1:30005"
fr24key="${FD_FR24KEY}"
bs="no"
raw="no"
logmode="0"
mlat="yes"
mlat-pager="yes"
EOF
}

configure_rbfeeder_1() {
  cat > /etc/rbfeeder_1.ini << EOF
[client]
network_mode=true
key=${FD_RBFEEDER_SHARING_KEY_1}
lat=${FEEDER_LAT}
lon=${FEEDER_LONG}
alt=${FEEDER_ALT_M}
[network]
mode=beast
external_port=30005
external_host=127.0.0.1
[mlat]
host=mlat.rb24.com
port=40900
EOF
}

configure_rbfeeder_2() {
  cat > /etc/rbfeeder_2.ini << EOF
[client]
network_mode=true
key=${FD_RBFEEDER_SHARING_KEY_2}
lat=${FEEDER_LAT}
lon=${FEEDER_LONG}
alt=${FEEDER_ALT_M}
[network]
mode=beast
external_port=30005
external_host=127.0.0.1
[mlat]
host=mlat.rb24.com
port=40900
EOF
}

configure_piaware() {
  mkdir -p /run/piaware  # /run is tmpfs at runtime; must be created here, not in Dockerfile
  cat > /etc/piaware.conf << EOF
feeder-id ${FD_PIAWARE_FEEDER_ID}
receiver-type relay
receiver-host 127.0.0.1
receiver-port 30005
EOF
}

configure_pfclient() { :; }  # fully configured via CLI args at launch

configure_adsbhub()  { :; }  # args-only, no config file

configure_openskyd() {
  mkdir -p /var/lib/openskyd/conf.d
  cat > /var/lib/openskyd/conf.d/10-opensky.conf << EOF
[GPS]
Latitude=${FEEDER_LAT}
Longitude=${FEEDER_LONG}
Altitude=${FEEDER_ALT_M}

[DEVICE]
Type=dump1090

[IDENT]
Username=${FD_OPENSKY_USERNAME}

[INPUT]
Host=127.0.0.1
Port=30005
EOF
  cat > /var/lib/openskyd/conf.d/05-serial.conf << EOF
[Device]
serial = ${FD_OPENSKY_SERIAL}
EOF
}

configure_hpradar()  { :; }  # driven by ULTRAFEEDER_CONFIG env var

# ── LAUNCHERS ─────────────────────────────────────────────────────────────────

launch_fr24feed()   { /usr/bin/fr24feed --config-file=/etc/fr24feed.ini > /dev/null 2>&1 & }
launch_rbfeeder_1() { /usr/bin/rbfeeder --config /etc/rbfeeder_1.ini > /dev/null 2>&1 & }
launch_rbfeeder_2() { /usr/bin/rbfeeder --config /etc/rbfeeder_2.ini > /dev/null 2>&1 & }
launch_piaware()    { /usr/bin/piaware > /dev/null 2>&1 & }
launch_pfclient()   { /usr/bin/pfclient --sharecode="${FD_PFC_SHARECODE}" --address=127.0.0.1 --port=30005 --data_format=1 --connection_type=1 --lat="${FEEDER_LAT}" --lon="${FEEDER_LONG}" --pid_file=/run/pfclient.pid --log_path=/var/log/pfclient > /dev/null 2>&1 & }
launch_adsbhub()    { /usr/bin/adsbhub.sh -c 127.0.0.1 -p 30005 -k "${FD_AHUB_CLIENTKEY}" > /dev/null 2>&1 & }
launch_openskyd()   { /usr/bin/openskyd > /dev/null 2>&1 & }
launch_hpradar()    { :; }  # already running via ultrafeeder core

# ── BOOTSTRAP ─────────────────────────────────────────────────────────────────
echo "[HPR-AIO] Generating configs for all registered feeders..."
export PATH="/opt/tcl/bin:$PATH"

for entry in "${FEEDER_REGISTRY[@]}"; do
  IFS='|' read -r id _ _ _ <<< "$entry"
  "configure_${id}"
done

echo "[HPR-AIO] Waiting for beast port 30005 to be ready..."
for i in $(seq 1 30); do
  nc -z 127.0.0.1 30005 2>/dev/null && break
  sleep 1
done

echo "[HPR-AIO] Launching satellite feeders..."
for entry in "${FEEDER_REGISTRY[@]}"; do
  IFS='|' read -r id _ _ pgrep_pat <<< "$entry"
  [[ "$pgrep_pat" == "__always__" ]] && continue
  "launch_${id}"
done

# ── TELEMETRY STATUS LOOP ─────────────────────────────────────────────────────
echo "[HPR-AIO] Starting telemetry status loop..."
mkdir -p /var/www/html/api

_build_feeders_json() {
  local out=""
  for entry in "${FEEDER_REGISTRY[@]}"; do
    IFS='|' read -r id name category pgrep_pat <<< "$entry"
    if [[ "$pgrep_pat" == "__always__" ]]; then
      alive=true
    else
      pgrep -f "$pgrep_pat" >/dev/null 2>&1 && alive=true || alive=false
    fi
    out+="\"${id}\":{\"name\":\"${name}\",\"category\":\"${category}\",\"alive\":${alive}},"
  done
  printf '%s' "${out%,}"
}

while true; do
  cat > /var/www/html/api/hpr_status.json << EOF
{
  "updated_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "feeders": {$(_build_feeders_json)}
}
EOF
  sleep 5
done &
