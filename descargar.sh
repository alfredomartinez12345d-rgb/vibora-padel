#!/usr/bin/env bash
# Script de descarga para GitHub Actions
# El token viene de la variable de entorno PADEL_API_TOKEN

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/api.sh"

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
