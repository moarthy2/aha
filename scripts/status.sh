#!/usr/bin/env bash
# Discord live status. Never print the webhook URL.
#
# Messages per server run:
#   1. one status embed, posted when the run starts and edited in place
#   2. one short message each time a player joins
#   3. at shutdown the status embed is edited into its final "offline" state
# The next run posts a fresh status embed. Leaves only update the embed.
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
ADDR="${SERVER_ADDRESS:-?}"

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
players() {
  [ -f "$LOG" ] || return 0
  sed -nE 's/.*INFO\]: ([A-Za-z0-9_.]{2,17}) (joined|left) the game$/\2 \1/p' "$LOG" \
    | awk '$1=="joined"{p[$2]=1} $1=="left"{delete p[$2]} END{for(k in p) print k}' | sort
}
# sets STATE_TXT and STATE_COLOR
state() {
  if grep -qE 'Stopping (the )?server' "$LOG" 2>/dev/null; then STATE_TXT="🟠 در حال خاموش شدن"; STATE_COLOR=15105570
  elif grep -q 'Done (' "$LOG" 2>/dev/null; then STATE_TXT="🟢 آنلاین"; STATE_COLOR=5763719
  else STATE_TXT="🟡 در حال بالا آمدن"; STATE_COLOR=16705372; fi
}

if [ "$MODE" = "final" ]; then
  ID=$(cat "$IDFILE" 2>/dev/null)
  START=$(cat "$STARTFILE" 2>/dev/null)
  if [ "$HEALTHY" = "true" ] && [ "$JOB_STATUS" != "cancelled" ] && [ "$AUTO_RESTART" != "false" ]; then
    MSG="🔄 دنیا ذخیره شد. اجرای بعدی خودکار شروع می‌شود (حدود ۱ تا ۲ دقیقه قطعی) و پیام جدیدی ارسال می‌شود."
  else
    MSG="⛔ ری‌استارت خودکاری در کار نیست؛ برای روشن کردن، دستی Run workflow بزنید."
  fi
  UP="—"
  [ -n "$START" ] && UP=$(fmt $(( $(date +%s) - START )))

  if [ -s "$LASTFILE" ]; then
    # reuse the last status embed: keep address/region/uptime, drop live fields
    JSON=$(jq --arg t "🔴 خاموش · اجرای #$RUN_NUMBER" --arg m "$MSG" --arg up "$UP" --arg ts "$(date -u +%FT%TZ)" '
      .embeds[0] |= (
        .title = $t | .color = 15548997 | .timestamp = $ts
        | .description = (.description + "\n\n" + $m)
        | .fields |= map(select(.name == "آپ‌تایم"))
        | .fields |= map(.value = $up))' "$LASTFILE")
  else
    JSON=$(jq -n --arg t "🔴 خاموش · اجرای #$RUN_NUMBER" --arg d "$MSG" --arg ts "$(date -u +%FT%TZ)" \
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
  CUR=$(players)
  COUNT=$(echo -n "$CUR" | grep -c .)

  # new message only for joins; leaves just update the status embed
  for p in $(comm -13 <(echo "$PREV") <(echo "$CUR")); do
    note "➕ **$p** وارد شد · ${COUNT} آنلاین" 5763719
  done
  PREV="$CUR"

  state
  JSON=$(jq -n \
    --arg title "$STATE_TXT · اجرای #$RUN_NUMBER" --argjson color "$STATE_COLOR" \
    --arg desc "🌐 \`$ADDR\` · 📍 $REGION" \
    --arg up "$(fmt $EL)" --arg left "$(fmt $LEFT)" \
    --arg cpu "${CPU}%" --arg jram "$JRAM" \
    --arg cnt "$COUNT" --arg list "${CUR//$'\n'/, }" \
    --arg run "$RUN_URL" --arg ts "$(date -u +%FT%TZ)" \
    '{embeds:[{title:$title,url:$run,description:$desc,color:$color,timestamp:$ts,
      fields:[
        {name:"آپ‌تایم",value:$up,inline:true},
        {name:"تا ری‌استارت",value:$left,inline:true},
        {name:"منابع",value:("CPU "+$cpu+" · جاوا "+$jram),inline:true},
        {name:("بازیکنان ("+$cnt+")"),value:(if $list=="" then "—" else $list end),inline:false}
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
