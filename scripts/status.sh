#!/usr/bin/env bash
# Discord live status. Never print the webhook URL.
set +x
MODE="${1:-run}"
HOOK="$DISCORD_WEBHOOK"
[ -z "$HOOK" ] && exit 0
IDFILE="${RUNNER_TEMP:-/tmp}/discord_msg_id"
INTERVAL="${STATUS_INTERVAL:-10}"
LIMIT=$(( ${LIMIT_MIN:-335} * 60 ))
LOG="${LOG:-server.log}"
ADDR="${SERVER_ADDRESS:-?}"

post() {
  curl -s -m 10 -H 'Content-Type: application/json' -d "$1" "$HOOK?wait=true" | jq -r '.id // empty' 2>/dev/null
}
edit() {
  code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -X PATCH -H 'Content-Type: application/json' -d "$2" "$HOOK/messages/$1")
  [ "$code" = "429" ] && sleep 5
  return 0
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
state() {
  if grep -qE 'Stopping (the )?server' "$LOG" 2>/dev/null; then echo "🟠 در حال خاموش شدن"
  elif grep -q 'Done (' "$LOG" 2>/dev/null; then echo "🟢 آنلاین"
  else echo "🟡 در حال بالا آمدن"; fi
}

if [ "$MODE" = "final" ]; then
  ID=$(cat "$IDFILE" 2>/dev/null)
  if [ "$HEALTHY" = "true" ] && [ "$JOB_STATUS" != "cancelled" ] && [ "$AUTO_RESTART" != "false" ]; then
    TXT=$(printf '%s\n' "🔄 این اجرا تمام شد و دنیا ذخیره شد." "اجرای بعدی خودکار شروع می‌شود (حدود ۱ تا ۲ دقیقه قطعی).")
    COLOR=16705372
  else
    TXT=$(printf '%s\n' "⛔ سرور خاموش شد." "ری‌استارت خودکاری در کار نیست؛ برای روشن کردن، دستی Run workflow بزنید.")
    COLOR=15548997
  fi
  if [ -n "$ID" ]; then
    edit "$ID" "$(jq -n --arg n "$RUN_NUMBER" --arg ts "$(date -u +%FT%TZ)" \
      '{embeds:[{title:("⛔ اجرای #"+$n+" تمام شد"),color:15548997,timestamp:$ts}]}')"
  fi
  note "$TXT" "$COLOR"
  exit 0
fi

# ---- run mode ----
START=$(date +%s)
AZ=$(curl -s -m 3 -H 'Metadata:true' 'http://169.254.169.254/metadata/instance/compute/location?api-version=2021-02-01&format=text')
GEO=$(curl -s -m 5 https://ipinfo.io/json)
CITY=$(echo "$GEO" | jq -r '.city // empty' 2>/dev/null)
CC=$(echo "$GEO" | jq -r '.country // empty' 2>/dev/null)
REGION="${AZ:-?} (${CITY:-?}, ${CC:-?})"

note "$(printf '%s\n' "🚀 اجرای #${RUN_NUMBER} شروع شد" "📍 ریجن: ${REGION}" "🌐 آدرس: \`${ADDR}\`")" 5793266

PREV=""
ID=""
while true; do
  EL=$(( $(date +%s) - START ))
  LEFT=$(( LIMIT - EL )); [ "$LEFT" -lt 0 ] && LEFT=0
  CPU=$(vmstat 1 2 | tail -1 | awk '{print 100-$15}')
  RAM=$(free -m | awk '/Mem:/{printf "%d / %d MB",$3,$2}')
  JRAM=$(ps -C java -o rss= | awk '{s+=$1} END{printf "%d MB", s/1024}')
  CUR=$(players)

  for p in $(comm -13 <(echo "$PREV") <(echo "$CUR")); do note "➕ **$p** وارد شد" 5763719; done
  for p in $(comm -23 <(echo "$PREV") <(echo "$CUR")); do note "➖ **$p** خارج شد" 15548997; done
  PREV="$CUR"
  COUNT=$(echo -n "$CUR" | grep -c .)

  JSON=$(jq -n \
    --arg state "$(state)" --arg addr "$ADDR" --arg region "$REGION" \
    --arg up "$(fmt $EL)" --arg left "$(fmt $LEFT)" \
    --arg cpu "${CPU}%" --arg ram "$RAM" --arg jram "$JRAM" \
    --arg cnt "$COUNT" --arg list "${CUR//$'\n'/, }" \
    --arg run "$RUN_URL" --arg n "$RUN_NUMBER" --arg ts "$(date -u +%FT%TZ)" \
    '{embeds:[{title:("🖥️ وضعیت سرور (اجرای #"+$n+")"),url:$run,color:5763719,timestamp:$ts,
      fields:[
        {name:"وضعیت",value:$state,inline:true},
        {name:"آدرس",value:("`"+$addr+"`"),inline:true},
        {name:"ریجن",value:$region,inline:true},
        {name:"آپ‌تایم",value:$up,inline:true},
        {name:"تا ری‌استارت",value:$left,inline:true},
        {name:"CPU",value:$cpu,inline:true},
        {name:"RAM",value:($ram+" (جاوا: "+$jram+")"),inline:false},
        {name:("بازیکنان ("+$cnt+")"),value:(if $list=="" then "—" else $list end),inline:false}
      ]}]}')

  if [ -z "$ID" ]; then
    ID=$(post "$JSON")
    [ -n "$ID" ] && echo "$ID" > "$IDFILE"
  else
    edit "$ID" "$JSON"
  fi
  sleep "$INTERVAL"
done
