#!/usr/bin/env bash
# Discord live status. Never print the webhook URL.
#
# Messages per server run:
#   1. one status embed, posted when the run starts and edited in place
#   2. one short message each time a player joins (yellow) or leaves (red)
#   3. at shutdown the status embed is edited into its final "offline" state
# The next run posts a fresh status embed.
# The status embed also shows the connection latency measured from probes in
# Iran (Globalping, falling back to check-host.net), refreshed every
# PING_INTERVAL seconds (default 300).
# If the public port is not 25565 and there is no SRV record, set SERVER_ADDRESS
# to host:port.
#
# Players are read from two independent sources and merged:
#   - the server logs (ANSI codes stripped), for exact join events
#   - the Minecraft status ping on localhost, which does not depend on log format
set +x
MODE="${1:-run}"
HOOK="$DISCORD_WEBHOOK"
[ -z "$HOOK" ] && exit 0
TMP="${RUNNER_TEMP:-/tmp}"
IDFILE="$TMP/discord_msg_id"
STARTFILE="$TMP/discord_start"
SEENFILE="$TMP/discord_seen"
LASTFILE="$TMP/discord_last.json"
INTERVAL="${STATUS_INTERVAL:-10}"
LIMIT=$(( ${LIMIT_MIN:-335} * 60 ))
LOG="${LOG:-server.log}"
LOGS=("$LOG" logs/latest.log)
ADDR="${SERVER_ADDRESS:-?}"
PORT=$(sed -nE 's/^server-port=([0-9]+).*/\1/p' server.properties 2>/dev/null | head -1)
PORT="${PORT:-25565}"
IRAN_FILE="$TMP/discord_iran.txt"
PING_INTERVAL="${PING_INTERVAL:-300}"   # seconds between Iran ping checks

# Prints the new message id. Failures go to stderr (the workflow keeps that log).
post() {
  local body id
  body=$(curl -s -m 10 -H 'Content-Type: application/json' -d "$1" "$HOOK?wait=true")
  id=$(jq -r '.id // empty' <<<"$body" 2>/dev/null)
  [ -z "$id" ] && echo "[$(date -u +%T)] discord post failed: ${body:-no response}" >&2
  echo "$id"
}
# prints the HTTP status code; retries once on rate limit
edit() {
  local code
  for _ in 1 2; do
    code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -X PATCH -H 'Content-Type: application/json' -d "$2" "$HOOK/messages/$1")
    [ "$code" = "429" ] && { sleep 5; continue; }
    break
  done
  echo "$code"
}
note() {
  post "$(jq -n --arg d "$1" --argjson c "$2" --arg ts "$(date -u +%FT%TZ)" \
    '{embeds:[{description:$d,color:$c,timestamp:$ts}]}')" >/dev/null
}
fmt() { printf '%02d:%02d:%02d' $(( $1/3600 )) $(( $1%3600/60 )) $(( $1%60 )); }

# Minecraft status ping. Prints the online count, then one sample name per line.
# Prints nothing if the server is not answering yet.
ping_server() {
  python3 - "$PORT" 2>/dev/null <<'PY'
import json, socket, struct, sys

def varint(n):
    out = b""
    while True:
        b = n & 0x7F
        n >>= 7
        out += bytes([b | 0x80 if n else b])
        if not n:
            return out

def read_varint(s):
    r = 0
    for i in range(5):
        b = s.recv(1)
        if not b:
            raise EOFError
        r |= (b[0] & 0x7F) << (7 * i)
        if not b[0] & 0x80:
            return r
    raise ValueError

port = int(sys.argv[1])
host = "127.0.0.1"
s = socket.create_connection((host, port), timeout=3)
pkt = b"\x00" + varint(767) + varint(len(host)) + host.encode() + struct.pack(">H", port) + varint(1)
s.sendall(varint(len(pkt)) + pkt)
s.sendall(b"\x01\x00")
read_varint(s)
read_varint(s)
n = read_varint(s)
buf = b""
while len(buf) < n:
    c = s.recv(n - len(buf))
    if not c:
        break
    buf += c
p = json.loads(buf)["players"]
print(p.get("online", 0))
for x in p.get("sample", []):
    print(x.get("name", ""))
PY
}

# host:port that players actually connect to. A port in SERVER_ADDRESS wins,
# then a _minecraft._tcp SRV record (checked over DNS-over-HTTPS), then 25565.
resolve_target() {
  case "$ADDR" in *:*) echo "$ADDR"; return ;; esac
  local srv
  srv=$(curl -sf -m 5 -H 'Accept: application/dns-json' \
    "https://cloudflare-dns.com/dns-query?name=_minecraft._tcp.${ADDR}&type=SRV" \
    | jq -r '[.Answer[]? | select(.type == 33) | .data][0] // empty' 2>/dev/null \
    | awk 'NF >= 4 {sub(/\.$/, "", $4); print $4 ":" $3}')
  echo "${srv:-$ADDR:25565}"
}

UA='Mozilla/5.0 (compatible; mc-status/1.0)'

# curl wrapper: prints the body on HTTP 2xx. Otherwise prints nothing, returns 1
# and stores the reason in $IRAN_FILE.err.
http() {
  local out code
  out=$(curl -s -m 10 -A "$UA" -w '\n%{http_code}' "$@")
  code="${out##*$'\n'}"
  case "$code" in 2??) printf '%s' "${out%$'\n'*}"; return 0 ;; esac
  [ "$code" = "000" ] && code="no response"
  echo "HTTP $code" > "$IRAN_FILE.err"
  return 1
}
why() { cat "$IRAN_FILE.err" 2>/dev/null; }

# Provider 1: Globalping (api.globalping.io). TCP ping from probes in Iran.
# Prints "<avg ms or ->" then one line per probe. On provider failure prints
# one error line and returns 1. A GLOBALPING_TOKEN (optional) raises its limits.
gp_ping() {
  local host port body resp id res t0 out auth=()
  rm -f "$IRAN_FILE.err"
  host="${TARGET%:*}"; port="${TARGET##*:}"
  [ -n "$GLOBALPING_TOKEN" ] && auth=(-H "Authorization: Bearer $GLOBALPING_TOKEN")
  body=$(jq -n --arg t "$host" --argjson p "$port" \
    '{type:"ping",target:$t,locations:[{country:"IR"}],limit:4,
      measurementOptions:{protocol:"TCP",port:$p,packets:3}}')
  resp=$(http -X POST -H 'Content-Type: application/json' "${auth[@]}" -d "$body" \
    https://api.globalping.io/v1/measurements) \
    || { echo "globalping: request failed ($(why))"; return 1; }
  id=$(jq -r '.id // empty' <<<"$resp" 2>/dev/null)
  [ -z "$id" ] && { echo "globalping: no measurement id"; return 1; }
  t0=$SECONDS
  while [ $(( SECONDS - t0 )) -lt 45 ]; do
    sleep 1
    res=$(http "${auth[@]}" "https://api.globalping.io/v1/measurements/$id") || continue
    [ "$(jq -r '.status' <<<"$res" 2>/dev/null)" != "in-progress" ] && break
  done
  [ -z "$res" ] && { echo "globalping: no result ($(why))"; return 1; }
  out=$(jq -r '
    .results as $r
    | if ($r | length) == 0 then empty else
        ([$r[] | select(.result.status == "finished" and .result.stats.avg != null) | .result.stats.avg]) as $t
        | (if ($t | length) == 0 then "-" else (($t | add / length) | round | tostring) end),
          ($r[] | ((.probe.city // .probe.country) + (if .probe.network then " (" + .probe.network[:20] + ")" else "" end)) as $n
            | if .result.status == "finished" and .result.stats.avg != null then "\($n): \(.result.stats.avg | round) ms"
              elif .result.status == "in-progress" then "\($n): …"
              else "\($n): ✖ \(if .result.stats.loss == 100 then "no reply" else "failed" end)" end)
      end' <<<"$res" 2>/dev/null)
  [ -z "$out" ] && { echo "globalping: no Iranian probes available"; return 1; }
  echo "$out"
}

# Provider 2 (fallback): check-host.net TCP check from its Iranian nodes.
ch_ping() {
  local nodes args=() resp id res n t0 H=(-H 'Accept: application/json')
  rm -f "$IRAN_FILE.err"
  nodes=$(http "${H[@]}" https://check-host.net/nodes/hosts \
    | jq -r '([.nodes | to_entries[] | select(.value.location[0] | ascii_downcase == "ir") | .key])[:4][]' 2>/dev/null)
  [ -z "$nodes" ] && { echo "check-host: no Iran nodes ($(why))"; return 1; }
  for n in $nodes; do args+=(--data-urlencode "node=$n"); done
  resp=$(http "${H[@]}" -G --data-urlencode "host=$TARGET" "${args[@]}" https://check-host.net/check-tcp) \
    || { echo "check-host: request failed ($(why))"; return 1; }
  id=$(jq -r '.request_id // empty' <<<"$resp" 2>/dev/null)
  [ -z "$id" ] && { echo "check-host: no request id"; return 1; }
  t0=$SECONDS
  while [ $(( SECONDS - t0 )) -lt 40 ]; do
    sleep 3
    res=$(http "${H[@]}" "https://check-host.net/check-result/$id")
    jq -e 'length > 0 and all(.[]; . != null)' <<<"$res" >/dev/null 2>&1 && break
  done
  [ -z "$res" ] && { echo "check-host: no result ($(why))"; return 1; }
  jq -r --argjson nodes "$(jq '.nodes' <<<"$resp")" '
    to_entries
    | map({city: ($nodes[.key][2] // .key),
           r: (if .value == null then null else (.value | flatten[0]) end)})
    | ([.[] | select(.r.time != null) | .r.time * 1000] ) as $t
    | (if ($t | length) == 0 then "-" else (($t | add / length) | round | tostring) end),
      (.[] | if .r == null then "\(.city): …"
             elif .r.time != null then "\(.city): \((.r.time * 1000) | round) ms"
             else "\(.city): ✖ \(.r.error // "failed")" end)' <<<"$res"
}

# Latency to the server as seen from Iran (no Iranian server needed): tries
# Globalping first, then check-host.net. Output: first line = average ms ("-" if
# there is no usable data), then one line per probe or per provider error.
iran_ping() {
  local out e1 e2
  TARGET=$(resolve_target)
  if out=$(gp_ping); then echo "$out"; return; fi
  e1="$out"
  if out=$(ch_ping); then echo "$out"; return; fi
  e2="$out"
  printf '%s\n%s\n%s\n' "-" "$e1" "$e2"
}

# Players currently online according to the logs (ANSI codes and CRs stripped).
log_players() {
  cat "${LOGS[@]}" 2>/dev/null \
    | sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\r//g' \
    | sed -nE 's/.*\]: ([A-Za-z0-9_.]{2,17}) (joined|left) the game[[:space:]]*$/\2 \1/p' \
    | awk '$1=="joined"{p[$2]=1} $1=="left"{delete p[$2]} END{for(k in p) print k}'
}

# sets STATE_TXT and STATE_COLOR
state() {
  if grep -qhE 'Stopping (the )?server' "${LOGS[@]}" 2>/dev/null; then STATE_TXT="🟠 Stopping"; STATE_COLOR=15105570
  elif grep -qh 'Done (' "${LOGS[@]}" 2>/dev/null; then STATE_TXT="🟢 Online"; STATE_COLOR=5763719
  else STATE_TXT="🟡 Starting"; STATE_COLOR=16705372; fi
}

if [ "$MODE" = "final" ]; then
  ID=$(cat "$IDFILE" 2>/dev/null)
  START=$(cat "$STARTFILE" 2>/dev/null)
  if [ "$HEALTHY" = "true" ] && [ "$JOB_STATUS" != "cancelled" ] && [ "$AUTO_RESTART" != "false" ]; then
    MSG="🔄 World saved. The next run starts automatically (about 1–2 min of downtime) and will post a new message."
  else
    MSG="⛔ No automatic restart. Run the workflow manually to start the server."
  fi
  UP="—"
  [ -n "$START" ] && UP=$(fmt $(( $(date +%s) - START )))
  # everyone who joined during this run
  SEEN=$(sort -u "$SEENFILE" 2>/dev/null | grep . | paste -sd, - | sed 's/,/, /g')
  SEEN_N=$(sort -u "$SEENFILE" 2>/dev/null | grep -c .)

  if [ -s "$LASTFILE" ]; then
    # reuse the last status embed: keep address/region, replace live fields by a summary
    JSON=$(jq --arg t "🔴 Offline · Run #$RUN_NUMBER" --arg m "$MSG" --arg up "$UP" \
      --arg seen "${SEEN:-—}" --arg n "$SEEN_N" --arg ts "$(date -u +%FT%TZ)" '
      .embeds[0] |= (
        .title = $t | .color = 15548997 | .timestamp = $ts
        | .description = (.description + "\n\n" + $m)
        | .fields = [{name:"Uptime",value:$up,inline:true},
                     {name:("Players this run ("+$n+")"),value:$seen,inline:false}])' "$LASTFILE")
  else
    JSON=$(jq -n --arg t "🔴 Offline · Run #$RUN_NUMBER" --arg d "$MSG" --arg up "$UP" \
      --arg seen "${SEEN:-—}" --arg n "$SEEN_N" --arg ts "$(date -u +%FT%TZ)" \
      '{embeds:[{title:$t,description:$d,color:15548997,timestamp:$ts,
        fields:[{name:"Uptime",value:$up,inline:true},
                {name:("Players this run ("+$n+")"),value:$seen,inline:false}]}]}')
  fi

  code=""
  [ -n "$ID" ] && code=$(edit "$ID" "$JSON")
  # no message to edit (or edit failed): post the final state as a new message
  [ "$code" != "200" ] && post "$JSON" >/dev/null
  exit 0
fi

# ---- run mode ----
rm -f "$IDFILE" "$LASTFILE" "$SEENFILE"
START=$(date +%s)
echo "$START" > "$STARTFILE"
echo "[$(date -u +%T)] monitor started (run #$RUN_NUMBER, log=$LOG, port=$PORT)" >&2
trap 'echo "[$(date -u +%T)] monitor exited" >&2' EXIT

# The first status message is posted right away; the region lookup (slow) happens
# after it so a quick crash still leaves a status message to edit.
REGION="…"
GEO_DONE=""

PREV=""
ID=""
IRAN_PID=""
IRAN_LAST=0
rm -f "$IRAN_FILE" "$IRAN_FILE.tmp"
while true; do
  EL=$(( $(date +%s) - START ))
  LEFT=$(( LIMIT - EL )); [ "$LEFT" -lt 0 ] && LEFT=0
  CPU=$(vmstat 1 2 | tail -1 | awk '{print 100-$15}')
  RAM=$(free -m | awk '/Mem:/{printf "%d/%d MB",$3,$2}')   # used/total, whole machine

  # merge log-based and ping-based player lists
  PING=$(ping_server)
  PING_ON=$(echo "$PING" | head -1)
  CUR=$( { log_players; echo "$PING" | tail -n +2; } | grep . | sort -u)
  COUNT=$(echo -n "$CUR" | grep -c .)
  [[ "$PING_ON" =~ ^[0-9]+$ ]] && [ "$PING_ON" -gt "$COUNT" ] && COUNT="$PING_ON"

  # new message for each join (Minecraft yellow) and leave (Minecraft red)
  for p in $(comm -13 <(echo "$PREV") <(echo "$CUR")); do
    note "➕ **$p** joined · ${COUNT} online" 16777045
    echo "$p" >> "$SEENFILE"
  done
  for p in $(comm -23 <(echo "$PREV") <(echo "$CUR")); do
    note "➖ **$p** left · ${COUNT} online" 16733525
  done
  PREV="$CUR"

  state

  # Iran ping runs in the background (takes ~10 s) and is refreshed every
  # PING_INTERVAL seconds once the server is online; retried after 120 s on failure.
  if [ "$STATE_TXT" = "🟢 Online" ]; then
    NOW=$(date +%s)
    FIRST=$(head -1 "$IRAN_FILE" 2>/dev/null)
    WAIT="$PING_INTERVAL"; { [ -z "$FIRST" ] || [ "$FIRST" = "-" ]; } && WAIT=120
    if { [ -z "$IRAN_PID" ] || ! kill -0 "$IRAN_PID" 2>/dev/null; } && [ $(( NOW - IRAN_LAST )) -ge "$WAIT" ]; then
      IRAN_LAST=$NOW
      ( iran_ping > "$IRAN_FILE.tmp" 2>/dev/null; mv -f "$IRAN_FILE.tmp" "$IRAN_FILE" ) &
      IRAN_PID=$!
    fi
  fi
  IRAN_NAME="🇮🇷 Ping from Iran"; IRAN_VAL="—"
  [ "$STATE_TXT" = "🟢 Online" ] && IRAN_VAL="Measuring…"
  if [ -s "$IRAN_FILE" ]; then
    FIRST=$(head -1 "$IRAN_FILE")
    if [ "$FIRST" = "-" ]; then IRAN_NAME="$IRAN_NAME · no data"; else IRAN_NAME="$IRAN_NAME · avg ${FIRST} ms"; fi
    IRAN_VAL=$(tail -n +2 "$IRAN_FILE")
    [ -z "$IRAN_VAL" ] && IRAN_VAL="—"
  fi

  JSON=$(jq -n \
    --arg title "$STATE_TXT · Run #$RUN_NUMBER" --argjson color "$STATE_COLOR" \
    --arg desc "🌐 \`$ADDR\` · 📍 $REGION" \
    --arg up "$(fmt $EL)" --arg left "$(fmt $LEFT)" \
    --arg cpu "${CPU}%" --arg ram "$RAM" \
    --arg cnt "$COUNT" --arg list "${CUR//$'\n'/, }" \
    --arg iname "$IRAN_NAME" --arg ival "$IRAN_VAL" \
    --arg run "$RUN_URL" --arg ts "$(date -u +%FT%TZ)" \
    '{embeds:[{title:$title,url:$run,description:$desc,color:$color,timestamp:$ts,
      fields:[
        {name:"Uptime",value:$up,inline:true},
        {name:"Restart in",value:$left,inline:true},
        {name:"Resources",value:("CPU "+$cpu+" · "+$ram),inline:true},
        {name:("Players ("+$cnt+")"),value:(if $list=="" then "—" else $list end),inline:false},
        {name:$iname,value:$ival,inline:false}
      ]}]}')
  printf '%s' "$JSON" > "$LASTFILE"

  if [ -z "$ID" ]; then
    ID=$(post "$JSON")
    [ -n "$ID" ] && echo "$ID" > "$IDFILE"
  else
    code=$(edit "$ID" "$JSON")
    if [ "$code" != "200" ]; then
      echo "[$(date -u +%T)] discord edit failed: HTTP $code" >&2
      [ "$code" = "404" ] && ID=""   # message was deleted: post a new one
    fi
  fi

  if [ -z "$GEO_DONE" ]; then
    GEO_DONE=1
    AZ=$(curl -sf -m 3 -H 'Metadata:true' 'http://169.254.169.254/metadata/instance/compute/location?api-version=2021-02-01&format=text')
    GEO=$(curl -sf -m 5 https://ipinfo.io/json)
    CITY=$(echo "$GEO" | jq -r '.city // empty' 2>/dev/null)
    CC=$(echo "$GEO" | jq -r '.country // empty' 2>/dev/null)
    REGION="${AZ:-?} (${CITY:-?}, ${CC:-?})"
  fi
  sleep "$INTERVAL"
done
