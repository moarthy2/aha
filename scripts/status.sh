#!/usr/bin/env bash
# Discord live status. Never print the webhook URL.
#
# Messages per server run:
#   1. one status embed, posted when the run starts and edited in place
#   2. one short message each time a player joins
#   3. at shutdown the status embed is edited into its final "offline" state
# The next run posts a fresh status embed. Leaves only update the embed.
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
LASTFILE="$TMP/discord_last.json"
INTERVAL="${STATUS_INTERVAL:-10}"
LIMIT=$(( ${LIMIT_MIN:-335} * 60 ))
LOG="${LOG:-server.log}"
LOGS=("$LOG" logs/latest.log)
ADDR="${SERVER_ADDRESS:-?}"
PORT=$(sed -nE 's/^server-port=([0-9]+).*/\1/p' server.properties 2>/dev/null | head -1)
PORT="${PORT:-25565}"

post() {
  curl -s -m 10 -H 'Content-Type: application/json' -d "$1" "$HOOK?wait=true" | jq -r '.id // empty' 2>/dev/null
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

  if [ -s "$LASTFILE" ]; then
    # reuse the last status embed: keep address/region/uptime, drop live fields
    JSON=$(jq --arg t "🔴 Offline · Run #$RUN_NUMBER" --arg m "$MSG" --arg up "$UP" --arg ts "$(date -u +%FT%TZ)" '
      .embeds[0] |= (
        .title = $t | .color = 15548997 | .timestamp = $ts
        | .description = (.description + "\n\n" + $m)
        | .fields |= map(select(.name == "Uptime"))
        | .fields |= map(.value = $up))' "$LASTFILE")
  else
    JSON=$(jq -n --arg t "🔴 Offline · Run #$RUN_NUMBER" --arg d "$MSG" --arg ts "$(date -u +%FT%TZ)" \
      '{embeds:[{title:$t,description:$d,color:15548997,timestamp:$ts}]}')
  fi

  code=""
  [ -n "$ID" ] && code=$(edit "$ID" "$JSON")
  # no message to edit (or edit failed): post the final state as a new message
  [ "$code" != "200" ] && post "$JSON" >/dev/null
  exit 0
fi

# ---- run mode ----
rm -f "$IDFILE" "$LASTFILE"
START=$(date +%s)
echo "$START" > "$STARTFILE"
AZ=$(curl -sf -m 3 -H 'Metadata:true' 'http://169.254.169.254/metadata/instance/compute/location?api-version=2021-02-01&format=text')
GEO=$(curl -sf -m 5 https://ipinfo.io/json)
CITY=$(echo "$GEO" | jq -r '.city // empty' 2>/dev/null)
CC=$(echo "$GEO" | jq -r '.country // empty' 2>/dev/null)
REGION="${AZ:-?} (${CITY:-?}, ${CC:-?})"

PREV=""
ID=""
while true; do
  EL=$(( $(date +%s) - START ))
  LEFT=$(( LIMIT - EL )); [ "$LEFT" -lt 0 ] && LEFT=0
  CPU=$(vmstat 1 2 | tail -1 | awk '{print 100-$15}')
  JRAM=$(ps -C java -o rss= | awk '{s+=$1} END{printf "%d MB", s/1024}')

  # merge log-based and ping-based player lists
  PING=$(ping_server)
  PING_ON=$(echo "$PING" | head -1)
  CUR=$( { log_players; echo "$PING" | tail -n +2; } | grep . | sort -u)
  COUNT=$(echo -n "$CUR" | grep -c .)
  [[ "$PING_ON" =~ ^[0-9]+$ ]] && [ "$PING_ON" -gt "$COUNT" ] && COUNT="$PING_ON"

  # new message only for joins; leaves just update the status embed
  for p in $(comm -13 <(echo "$PREV") <(echo "$CUR")); do
    note "➕ **$p** joined · ${COUNT} online" 5763719
  done
  PREV="$CUR"

  state
  JSON=$(jq -n \
    --arg title "$STATE_TXT · Run #$RUN_NUMBER" --argjson color "$STATE_COLOR" \
    --arg desc "🌐 \`$ADDR\` · 📍 $REGION" \
    --arg up "$(fmt $EL)" --arg left "$(fmt $LEFT)" \
    --arg cpu "${CPU}%" --arg jram "$JRAM" \
    --arg cnt "$COUNT" --arg list "${CUR//$'\n'/, }" \
    --arg run "$RUN_URL" --arg ts "$(date -u +%FT%TZ)" \
    '{embeds:[{title:$title,url:$run,description:$desc,color:$color,timestamp:$ts,
      fields:[
        {name:"Uptime",value:$up,inline:true},
        {name:"Restart in",value:$left,inline:true},
        {name:"Resources",value:("CPU "+$cpu+" · Java "+$jram),inline:true},
        {name:("Players ("+$cnt+")"),value:(if $list=="" then "—" else $list end),inline:false}
      ]}]}')
  printf '%s' "$JSON" > "$LASTFILE"

  if [ -z "$ID" ]; then
    ID=$(post "$JSON")
    [ -n "$ID" ] && echo "$ID" > "$IDFILE"
  else
    edit "$ID" "$JSON" >/dev/null
  fi
  sleep "$INTERVAL"
done
