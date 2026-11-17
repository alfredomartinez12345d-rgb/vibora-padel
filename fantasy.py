"""Fantasy Víbora: precios, bloqueo de equipos y puntos (lo ejecuta GitHub en cada actualización).

Uso: python3 fantasy.py DATOS

1. Precio de cada jugador inscrito (5–30 M) según su puesto en el ranking FIP.
2. Si hay un torneo Premier en juego, bloquea los equipos y congela la foto con la
   que puntúa cada usuario; si no hay ninguno, los vuelve a abrir.
3. Puntos de cada jugador en cada torneo y de cada usuario (capitán x2).
4. Escribe DATOS/fantasy.json para que build.py meta precios y puntos en la app.

Puntos por partido: victoria hasta octavos +3, en cuartos +5, en semifinales +8,
en la final +12; +1 por cada set ganado (también si pierde).

Sin SUPABASE_URL y SUPABASE_SERVICE_KEY solo hace los pasos 1, 3 (jugadores) y 4.
"""
import datetime
import glob
import json
import math
import os
import re
import sys
import urllib.request

datos = sys.argv[1]
URL = os.environ.get('SUPABASE_URL', '').strip().rstrip('/')
KEY = os.environ.get('SUPABASE_SERVICE_KEY', '').strip()
remoto = bool(URL and KEY)


def leer(f):
    try:
        with open(f, encoding='utf-8') as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def api(metodo, ruta, cuerpo=None, prefer=None):
    h = {'apikey': KEY, 'Content-Type': 'application/json'}
    if KEY.startswith('eyJ'):  # clave antigua (JWT); las nuevas sb_secret_… van solo en apikey
        h['Authorization'] = f'Bearer {KEY}'
    if prefer:
        h['Prefer'] = prefer
    req = urllib.request.Request(f'{URL}/rest/v1/{ruta}', method=metodo, headers=h,
                                 data=json.dumps(cuerpo).encode() if cuerpo is not None else None)
    with urllib.request.urlopen(req, timeout=30) as r:
        txt = r.read().decode()
        return json.loads(txt) if txt else None


# --- Torneos de la temporada Premier ---------------------------------------------------
try:
    temporada = open(os.path.join(datos, 'season.txt')).read().strip()
except OSError:
    temporada = ''
torneos = {}
for f in glob.glob(os.path.join(datos, 'tournaments_*.json')):
    for t in leer(f).get('data', []):
        if (t.get('connections') or {}).get('season') == f'/api/seasons/{temporada}':
            torneos[t['id']] = t

# --- 1. Precios: ranking de los inscritos (el dato del torneo más reciente gana) -------------
jug = {}
for f in sorted(glob.glob(os.path.join(datos, 't*_players_*.json')),
                key=lambda f: (torneos.get(int(re.search(r't(\d+)_players', f).group(1))) or {}).get('start_date') or ''):
    for p in leer(f).get('data', []):
        r = p.get('ranking')
        r = r.get('position') if isinstance(r, dict) else r
        if isinstance(r, (int, float)) and r > 0:
            jug[p['id']] = {'nombre': p.get('name'), 'corto': p.get('short_name'), 'rank': int(r)}

# Categoría de cada jugador según sus partidos
cat = {}
partidos = []
for f in glob.glob(os.path.join(datos, 't*_matches_*.json')):
    tid = int(re.search(r't(\d+)_matches', f).group(1))
    for m in leer(f).get('data', []):
        m['_t'] = tid
        partidos.append(m)
        for lado in ('team_1', 'team_2'):
            for p in (m.get('players') or {}).get(lado) or []:
                cat[p['id']] = m.get('category')


def precio(rank):
    """N.º 1 → 30 M; n.º 200 o peor → 5 M (escala logarítmica, de medio en medio millón)."""
    v = 30 - 25 * math.log(min(rank, 200)) / math.log(200)
    return max(5.0, min(30.0, round(v * 2) / 2))


precios = {pid: {'player_id': pid, 'nombre': j['nombre'], 'corto': j['corto'], 'cat': cat[pid], 'precio': precio(j['rank'])}
           for pid, j in jug.items() if cat.get(pid) in ('men', 'women')}

# --- 3. Puntos de cada jugador por torneo (solo Premier) ---------------------------------
RONDA = {1: 12, 2: 8, 4: 5}
pts_jug = {}
for m in partidos:
    if m['_t'] not in torneos or m.get('status') not in ('finished', 'retired', 'walkover'):
        continue
    gana = m.get('winner')
    if gana not in ('team_1', 'team_2'):
        continue
    sets = m.get('score') if isinstance(m.get('score'), list) else []
    for lado in ('team_1', 'team_2'):
        otro = 'team_2' if lado == 'team_1' else 'team_1'
        ganados = 0
        for s in sets:
            try:
                a = int(re.match(r'\d+', str(s.get(lado))).group())
                b = int(re.match(r'\d+', str(s.get(otro))).group())
                ganados += a > b
            except (AttributeError, TypeError, ValueError):
                pass
        p_ = ganados + (RONDA.get(m.get('round'), 3) if lado == gana else 0)
        for p in (m.get('players') or {}).get(lado) or []:
            d = pts_jug.setdefault(m['_t'], {})
            d[p['id']] = d.get(p['id'], 0) + p_

# --- 2. Bloqueo según el torneo en juego ---------------------------------------------------
hoy = datetime.date.today().isoformat()
en_juego = [t for t in torneos.values()
            if t.get('status') == 'live' or (t.get('start_date') or '9') <= hoy <= (t.get('end_date') or '')]
en_juego.sort(key=lambda t: t.get('start_date') or '')

if remoto:
    try:
        for i in range(0, len(precios), 200):
            api('POST', 'precios?on_conflict=player_id', list(precios.values())[i:i + 200], 'resolution=merge-duplicates')
        estado = (api('GET', 'estado?id=eq.1&select=*') or [{}])[0]
        if en_juego and estado.get('abierto', True):
            t = en_juego[0]
            n = api('POST', 'rpc/bloquear', {'p_torneo': t['id'], 'p_nombre': t['name']})
            print(f"Fantasy: equipos bloqueados para {t['name']} ({n} equipos congelados)")
        elif not en_juego and not estado.get('abierto', True):
            api('POST', 'rpc/abrir', {})
            print('Fantasy: equipos abiertos (no hay torneo en juego)')
        # Puntos de cada usuario en los torneos con equipos congelados
        for tid in sorted({f['torneo'] for f in api('GET', 'fotos?select=torneo') or []}):
            if tid not in pts_jug:
                continue
            filas = []
            for f in api('GET', f'fotos?torneo=eq.{tid}&select=user_id,jugadores,capitan') or []:
                total = sum(pts_jug[tid].get(j, 0) * (2 if j == f['capitan'] else 1) for j in f['jugadores'])
                filas.append({'user_id': f['user_id'], 'torneo': tid, 'torneo_nombre': torneos[tid]['name'], 'puntos': total})
            for i in range(0, len(filas), 500):
                api('POST', 'puntos?on_conflict=user_id,torneo', filas[i:i + 500], 'resolution=merge-duplicates')
            print(f"Fantasy: puntos de {len(filas)} equipos en {torneos[tid]['name']}")
    except Exception as e:
        print('Fantasy: error con Supabase:', e)
else:
    print('Fantasy: sin SUPABASE_URL / SUPABASE_SERVICE_KEY, solo se calculan precios y puntos de jugadores.')

# --- 4. Para la app -------------------------------------------------------------------------
ult = max((t for t in pts_jug if t in torneos), key=lambda t: torneos[t].get('start_date') or '', default=None)
json.dump({'precios': {str(k): v['precio'] for k, v in precios.items()},
           'ultimo': {'torneo': ult, 'nombre': torneos[ult]['name'] if ult else None,
                      'puntos': {str(k): v for k, v in (pts_jug.get(ult) or {}).items()}},
           'en_juego': en_juego[0]['name'] if en_juego else None},
          open(os.path.join(datos, 'fantasy.json'), 'w'), ensure_ascii=False)
print(f'Fantasy: {len(precios)} jugadores con precio; último torneo con puntos: {torneos[ult]["name"] if ult else "ninguno"}')
