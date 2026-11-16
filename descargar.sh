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

# Extraer ID de la temporada más reciente
SEASON_ID=$(python3 -c "
import json
data = json.load(open('$OUT/seasons.json'))
seasons = data.get('data', data) if isinstance(data, dict) else data
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

# Solo los 30 torneos más recientes por fecha de inicio
T_IDS=$(python3 -c "
import json, glob
all_t = []
for f in sorted(glob.glob('$OUT/tournaments_*.json')):
    d = json.load(open(f))
    for t in d.get('data', []):
        all_t.append(t)
all_t.sort(key=lambda x: x.get('start_date',''), reverse=True)
ids = [str(t['id']) for t in all_t[:30]]
print(' '.join(ids))
")
echo "Torneos: $T_IDS"

# Partidos de cada torneo
for TID in $T_IDS; do
  page=1
  while true; do
    f="$OUT/t${TID}_matches_${page}.json"
    get "$BASE/tournaments/$TID/matches?page=$page" "$f"
    sleep $PAUSE
    LAST=$(python3 -c "import json; d=json.load(open('$f')); print(d.get('meta',{}).get('last_page',1))")
    [[ "$page" -ge "$LAST" ]] && break
    page=$((page+1))
  done
done

# ¿Hay más páginas? Usa meta.last_page si existe; si no, links.next. Para si la página viene vacía.
more_pages() {
  python3 -c "
import json, sys
d = json.load(open(sys.argv[1])); p = int(sys.argv[2])
m = d.get('meta') or {}; l = d.get('links') or {}
last = m.get('last_page') or (m.get('pagination') or {}).get('total_pages')
more = int(last) > p if last else bool(l.get('next'))
print(1 if more and d.get('data') else 0)" "$1" "$2"
}

# Ranking oficial: inscritos de los 3 torneos más recientes ya empezados (sin FIP), todas las páginas.
# build.py se queda, para cada jugador, con el dato del torneo más reciente.
RANK_TIDS=$(python3 -c "
import json, glob, datetime, sys
hoy = datetime.date.today().isoformat()
dl = set(int(x) for x in sys.argv[1].split())
ts = {}
for f in glob.glob('$OUT/tournaments_*.json'):
    for t in json.load(open(f)).get('data', []):
        ts[t['id']] = t
c = [t for t in ts.values() if t['id'] in dl and (t.get('start_date') or '') <= hoy
     and not str(t.get('level') or '').startswith('fip')]
c.sort(key=lambda t: t.get('start_date') or '', reverse=True)
print(' '.join(str(t['id']) for t in c[:3]))
" "$T_IDS")
echo "Torneos para el ranking: $RANK_TIDS"
for RTID in $RANK_TIDS; do
  page=1
  while true; do
    f="$OUT/t${RTID}_players_${page}.json"
    get "$BASE/tournaments/$RTID/players?page=$page" "$f"
    sleep $PAUSE
    [[ "$(more_pages "$f" "$page")" == "1" ]] || break
    page=$((page+1))
  done
  python3 -c "
import json, glob
fs = glob.glob('$OUT/t${RTID}_players_*.json'); n = r = 0; k = set()
for f in fs:
    for p in json.load(open(f)).get('data', []):
        n += 1; r += p.get('ranking') is not None; k |= set(p)
print('  torneo $RTID:', len(fs), 'páginas,', n, 'jugadores,', r, 'con ranking; campos:', sorted(k))"
done

echo "==> Descarga completa en $OUT/"
