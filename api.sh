#!/usr/bin/env bash
# Funciones comunes para hablar con Padel API (las usan descargar.sh y directo.sh).
# El token viene de la variable de entorno PADEL_API_TOKEN.

TOKEN="${PADEL_API_TOKEN:?Variable PADEL_API_TOKEN no definida}"
BASE="${PADEL_API_BASE:-https://padelapi.org/api}"
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
