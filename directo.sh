#!/usr/bin/env bash
# Actualización rápida durante los torneos: parte de los datos de la última descarga
# (restaurados de la caché) y solo vuelve a bajar el calendario y los partidos de los
# torneos que se están jugando hoy. Si no hay ninguno, no hace nada.
# Escribe hay_directo=1/0 en $GITHUB_OUTPUT para que el workflow sepa si publicar.

set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/api.sh"

salida() { echo "hay_directo=$1" >> "${GITHUB_OUTPUT:-/dev/null}"; }

if [[ ! -f "$OUT/season.txt" ]]; then
  echo "No hay datos previos en caché: hace falta una actualización completa."
  salida 0; exit 0
fi
SEASON_ID=$(cat "$OUT/season.txt")

en_juego() {
  python3 -c "
import json, glob, datetime
hoy = datetime.date.today().isoformat()
ts = {t['id']: t for f in glob.glob('$OUT/tournaments_*.json') for t in json.load(open(f)).get('data', [])}
ids = [t['id'] for t in ts.values() if (t.get('connections') or {}).get('season') == '/api/seasons/$SEASON_ID'
       and (t.get('status') == 'live' or (t.get('start_date') or '9') <= hoy <= (t.get('end_date') or ''))]
print(' '.join(map(str, sorted(ids))))"
}

# Mirada rápida con el calendario guardado: si hoy no hay torneo, no se gasta ninguna petición.
if [[ -z "$(en_juego)" ]]; then
  echo "Hoy no hay ningún torneo en juego. Nada que actualizar."
  salida 0; exit 0
fi

echo "==> Actualizando calendario de la temporada $SEASON_ID..."
mkdir -p "$OUT/nuevo"
if get_all "$BASE/seasons/$SEASON_ID/tournaments" "$OUT/nuevo/tournaments"; then
  rm -f "$OUT"/tournaments_*.json && mv "$OUT"/nuevo/tournaments_*.json "$OUT/"
fi
rm -rf "$OUT/nuevo"

LIVE=$(en_juego)
echo "Torneos en juego: ${LIVE:-ninguno}"
[[ -n "$LIVE" ]] || { salida 0; exit 0; }

for TID in $LIVE; do
  mkdir -p "$OUT/nuevo"
  if get_all "$BASE/tournaments/$TID/matches" "$OUT/nuevo/t${TID}_matches"; then
    rm -f "$OUT"/t"${TID}"_matches_*.json && mv "$OUT"/nuevo/t"${TID}"_matches_*.json "$OUT/"
    echo "  torneo $TID: partidos actualizados"
  else
    echo "  torneo $TID: no se pudo actualizar, se mantienen los partidos anteriores"
  fi
  rm -rf "$OUT/nuevo"
done
salida 1
