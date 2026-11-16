#!/usr/bin/env bash
# Script de descarga para GitHub Actions
# El token viene de la variable de entorno PADEL_API_TOKEN

set -euo pipefail

TOKEN="${PADEL_API_TOKEN:?Variable PADEL_API_TOKEN no definida}"
BASE="https://padelapi.org/api"
H="Authorization: Bearer $TOKEN"
OUT="datos"
PAUSE=7

mkdir -p "$OUT"

get() {
  local url="$1" dest="$2"
  while true; do
    CODE=$(curl -s -o "$dest.tmp" -w "%{http_code}" -H "$H" "$url")
    if [[ "$CODE" == "200" ]]; then
      mv "$dest.tmp" "$dest"
      return 0
    elif [[ "$CODE" == "429" ]]; then
      RA=$(grep -i "Retry-After" "$dest.tmp" 2>/dev/null | awk '{print $2}' | tr -d '\r' || echo 60)
      echo "429 en $url — espero ${RA}s"
      sleep "${RA:-60}"
    else
      echo "Error $CODE en $url" >&2
      rm -f "$dest.tmp"
      return 1
    fi
  done
}

echo "==> Descargando temporadas y torneos..."
get "$BASE/seasons" "$OUT/seasons.json"
sleep $PAUSE

# Extraer IDs de torneos de la temporada más reciente
SEASON_ID=$(python3 -c "
import json, sys
data = json.load(open('$OUT/seasons.json'))
seasons = data.get('data', data) if isinstance(data, dict) else data
# Coger la más reciente (mayor id)
s = max(seasons, key=lambda x: x['id'])
print(s['id'])
")
echo "Temporada activa: $SEASON_ID"

# Torneos de esa temporada (todas las páginas)
page=1
while true; do
  f="$OUT/tournaments_${page}.json"
  get "$BASE/tournaments?season_id=$SEASON_ID&page=$page" "$f"
  sleep $PAUSE
  LAST=$(python3 -c "import json; d=json.load(open('$f')); print(d.get('meta',{}).get('last_page',1))")
  [[ "$page" -ge "$LAST" ]] && break
  page=$((page+1))
done

# Extraer IDs de torneos
T_IDS=$(python3 -c "
import json, glob
ids = []
for f in sorted(glob.glob('$OUT/tournaments_*.json')):
    d = json.load(open(f))
    for t in d.get('data', []):
        ids.append(t['id'])
print(' '.join(map(str, ids)))
")
echo "Torneos: $T_IDS"

# Partidos de cada torneo
for TID in $T_IDS; do
  page=1
  while true; do
    f="$OUT/t${TID}_matches_${page}.json"
    [[ -f "$f" ]] && {
      LAST=$(python3 -c "import json; d=json.load(open('$f')); print(d.get('meta',{}).get('last_page',1))")
      [[ "$page" -ge "$LAST" ]] && break || { page=$((page+1)); continue; }
    }
    get "$BASE/tournaments/$TID/matches?page=$page" "$f"
    sleep $PAUSE
    LAST=$(python3 -c "import json; d=json.load(open('$f')); print(d.get('meta',{}).get('last_page',1))")
    [[ "$page" -ge "$LAST" ]] && break
    page=$((page+1))
  done
done

# Players del torneo más grande (ranking oficial)
MAIN_TID=$(python3 -c "
import json, glob
best, bestid = 0, 0
for f in glob.glob('$OUT/t*_matches_1.json'):
    import os
    tid = int(os.path.basename(f).split('_')[0][1:])
    d = json.load(open(f))
    n = d.get('meta', {}).get('total', 0)
    if n > best:
        best, bestid = n, tid
print(bestid)
")
echo "Torneo principal para ranking: $MAIN_TID"
page=1
while true; do
  f="$OUT/t${MAIN_TID}_players_${page}.json"
  get "$BASE/tournaments/$MAIN_TID/players?page=$page" "$f"
  sleep $PAUSE
  LAST=$(python3 -c "import json; d=json.load(open('$f')); print(d.get('meta',{}).get('last_page',1))")
  [[ "$page" -ge "$LAST" ]] && break
  page=$((page+1))
done

echo "==> Descarga completa en $OUT/"
