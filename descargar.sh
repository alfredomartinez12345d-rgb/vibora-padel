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
    CODE=$(curl -s -D "$dest.hdr" -o "$dest.tmp" -w "%{http_code}" -H "$H" "$url")
    if [[ "$CODE" == "200" ]]; then
      mv "$dest.tmp" "$dest"; rm -f "$dest.hdr"
      return 0
    elif [[ "$CODE" == "429" ]]; then
      RA=$(grep -i "^Retry-After:" "$dest.hdr" 2>/dev/null | awk '{print $2}' | tr -d '\r' || true)
      echo "429 en $url — espero ${RA:-60}s"
      sleep "${RA:-60}"
    else
      echo "Error $CODE en $url" >&2
      rm -f "$dest.tmp" "$dest.hdr"
      return 1
    fi
  done
}

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

# Descarga todas las páginas de un listado: get_all URL_BASE PREFIJO
get_all() {
  local base="$1" prefix="$2" page=1 sep='?'
  [[ "$base" == *\?* ]] && sep='&'
  while true; do
    get "${base}${sep}page=${page}" "${prefix}_${page}.json" || return 1
    sleep $PAUSE
    [[ "$(more_pages "${prefix}_${page}.json" "$page")" == "1" ]] || break
    page=$((page+1))
  done
}

echo "==> Descargando temporadas..."
get_all "$BASE/seasons" "$OUT/seasons"

# Temporada de Premier Padel activa (si no hay, la activa que empezó más tarde)
SEASON_ID=$(python3 -c "
import json, glob
ss = [s for f in glob.glob('$OUT/seasons_*.json') for s in json.load(open(f)).get('data', [])]
act = [s for s in ss if s.get('status') == 'active'] or ss
prem = [s for s in act if 'premier' in (s.get('name') or '').lower()] or act
s = max(prem, key=lambda x: x.get('start_date') or '')
print(s['id'])
")
echo "$SEASON_ID" > "$OUT/season.txt"
echo "Temporada: $SEASON_ID"

echo "==> Descargando torneos de la temporada..."
get_all "$BASE/seasons/$SEASON_ID/tournaments" "$OUT/tournaments" \
  || get_all "$BASE/tournaments?season_id=$SEASON_ID" "$OUT/tournaments"

# Torneos de la temporada que ya han empezado (los pendientes aún no tienen partidos)
T_IDS=$(python3 -c "
import json, glob, datetime
hoy = datetime.date.today().isoformat()
ts = {t['id']: t for f in glob.glob('$OUT/tournaments_*.json') for t in json.load(open(f)).get('data', [])}
ts = [t for t in ts.values() if (t.get('connections') or {}).get('season') == '/api/seasons/$SEASON_ID'
      and (t.get('start_date') or '') <= hoy]
ts.sort(key=lambda t: t.get('start_date') or '', reverse=True)
print(' '.join(str(t['id']) for t in ts))
")
echo "Torneos: $T_IDS"

# Partidos de cada torneo
for TID in $T_IDS; do
  get_all "$BASE/tournaments/$TID/matches" "$OUT/t${TID}_matches" || echo "  Sin partidos del torneo $TID, sigo"
done

# Ranking oficial: la API solo da inscritos de torneos en juego o por jugar.
# Se prueban (sin FIP) el que está en juego y los próximos, y después los últimos jugados.
RANK_TIDS=$(python3 -c "
import json, glob
ts = {t['id']: t for f in glob.glob('$OUT/tournaments_*.json') for t in json.load(open(f)).get('data', [])}
ts = [t for t in ts.values() if (t.get('connections') or {}).get('season') == '/api/seasons/$SEASON_ID'
      and not str(t.get('level') or '').startswith('fip')]
live = [t for t in ts if t.get('status') == 'live']
pend = sorted([t for t in ts if t.get('status') == 'pending'], key=lambda t: t.get('start_date') or '')
done = sorted([t for t in ts if t.get('status') not in ('live', 'pending')], key=lambda t: t.get('start_date') or '', reverse=True)
print(' '.join(str(t['id']) for t in (live + pend + done)[:5]))
")
echo "Torneos para el ranking: $RANK_TIDS"
for RTID in $RANK_TIDS; do
  get_all "$BASE/tournaments/$RTID/players" "$OUT/t${RTID}_players" || { echo "  Sin inscritos del torneo $RTID"; continue; }
  python3 -c "
import json, glob
fs = glob.glob('$OUT/t${RTID}_players_*.json'); n = r = 0; k = set()
for f in fs:
    for p in json.load(open(f)).get('data', []):
        n += 1; r += p.get('ranking') is not None; k |= set(p)
print('  torneo $RTID:', len(fs), 'páginas,', n, 'jugadores,', r, 'con ranking; campos:', sorted(k))"
done

echo "==> Descarga completa en $OUT/"
