"""Fantasy Víbora · modo mánager: valores, bloqueo, puntos y mercados (lo ejecuta GitHub).

Uso: python3 manager.py DATOS   (después de build.py, que deja DATOS/app.json)

1. Valor de cada jugador con lado conocido: sale de su ranking (o de su Elo si no
   tiene) y sube o baja hasta un 15 % según sus puntos en los 2 últimos torneos
   Premier; de un torneo al siguiente cambia como mucho un 10 % (respecto a su
   valor al acabar el último torneo); de 3 a 90 M.
2. Si hay un torneo Premier en juego, congela las alineaciones; si no, las abre y
   paga 0,2 M por punto del torneo que acaba de terminar.
3. Puntos de cada jugador en los torneos con alineaciones congeladas.
4. Cierra los mercados que tocan (por si nadie ha entrado en esas ligas).

La previa de los torneos Premier también puntúa (victoria +2; lo demás igual, sin
campeón) y el «cae en su primer partido» cuenta desde la previa.
Las reglas de puntos son las mismas que enseña la app (template.html, función mxPartido).
Sin SUPABASE_URL y SUPABASE_SERVICE_KEY solo calcula y muestra un resumen.
"""
import datetime
import json
import math
import os
import sys
import urllib.request

datos = sys.argv[1]
URL = os.environ.get('SUPABASE_URL', '').strip().rstrip('/')
KEY = os.environ.get('SUPABASE_SERVICE_KEY', '').strip()
remoto = bool(URL and KEY)


def api(metodo, ruta, cuerpo=None, prefer=None):
    h = {'apikey': KEY, 'Content-Type': 'application/json'}
    if KEY.startswith('eyJ'):  # clave antigua (JWT); las nuevas sb_secret_… van solo en apikey
        h['Authorization'] = f'Bearer {KEY}'
    if prefer:
        h['Prefer'] = prefer
    req = urllib.request.Request(f'{URL}/rest/v1/{ruta}', method=metodo, headers=h,
                                 data=json.dumps(cuerpo).encode() if cuerpo is not None else None)
    with urllib.request.urlopen(req, timeout=60) as r:
        txt = r.read().decode()
        return json.loads(txt) if txt else None


D = json.load(open(os.path.join(datos, 'app.json'), encoding='utf-8'))
# P: id → [nombre, corto, nacionalidad, lado, mujer, ranking, puntos, foto]
P = {int(k): v for k, v in D['P'].items()}
# T: [id, nombre, nivel, lugar, país, inicio, fin, pista, estado, oculto, cartel]
T = {t[0]: t for t in D['T']}
# M: [id, torneo, mujer, ronda, orden, fecha, pista, estado, a, b, cab_a, cab_b, sets, ganador, …]
M = [dict(id=m[0], t=m[1], ronda=m[3], fecha=m[5] or '', st=m[7], a=m[8], b=m[9], sets=m[12] or [], w=m[13]) for m in D['M']]
# Q (previas, solo fantasy): [id, torneo, mujer, ronda, fecha, estado, a, b, sets, ganador]
Q = [dict(id=m[0], t=m[1], ronda=m[3], fecha=m[4] or '', st=m[5], a=m[6], b=m[7], sets=m[8] or [], w=m[9], q=True) for m in D.get('Q') or []]


def premier(tid):
    t = T.get(tid)
    return bool(t) and not str(t[2] or '').startswith('fip')


# --- Elo propio, igual que la app: 1500, K=32, media de la pareja, solo Premier -----------
elo = {}
orden = lambda m: (m['fecha'], 0 if m.get('q') else 1, -m['ronda'], m['id'])
ms = sorted([m for m in M + Q if premier(m['t']) and len(m['a']) == 2 and len(m['b']) == 2], key=orden)
jugados = {}
for m in ms:
    if not m.get('q'):
        for i in m['a'] + m['b']:
            jugados.setdefault(i, 0)
    if not (m['st'] < 2 and m['w'] is not None):
        continue
    ea = sum(elo.get(i, 1500) for i in m['a']) / 2
    eb = sum(elo.get(i, 1500) for i in m['b']) / 2
    m['pre'] = 1 / (1 + 10 ** ((eb - ea) / 400))
    if m.get('q'):   # la previa no mueve el Elo (como en la app); solo sirve para la sorpresa
        continue
    d = 32 * ((1 if m['w'] == 0 else 0) - m['pre'])
    for i in m['a']:
        elo[i] = elo.get(i, 1500) + d
        jugados[i] += 1
    for i in m['b']:
        elo[i] = elo.get(i, 1500) - d
        jugados[i] += 1

# --- Puntos de un partido para una pareja (lado 0 = a, 1 = b) ------------------------------
SORPRESA_GRANDE = 1 / (1 + 10 ** (100 / 400))   # 100 puntos de Elo menos que el rival


def pts_partido(m, s, primero):
    if m['w'] is None or m['st'] > 2:
        return None
    gana = m['w'] == s
    previa = bool(m.get('q'))
    vict = 2 if previa else {1: 12, 2: 8, 4: 5}.get(m['ronda'], 3)
    camp = 5 if m['ronda'] == 1 and not previa else 0
    if m['st'] in (1, 2):   # abandono o no presentado: solo cuenta ganar
        return (vict + camp) if gana else 0
    p = 0
    sets = [(x[s], x[1 - s]) for x in m['sets'] if len(x) >= 2]
    p += sum(1 for a, b in sets if a > b)                       # sets ganados
    p += 2 * sum(1 for a, b in sets if a == 6 and b == 0)       # roscos a favor
    p -= sum(1 for a, b in sets if a == 0 and b == 6)           # roscos en contra
    if gana:
        p += vict + camp
        if all(a > b for a, b in sets):
            p += 1                                              # sin ceder set
        pre = m.get('pre')
        if pre is not None:
            mio = pre if s == 0 else 1 - pre
            p += 4 if mio < SORPRESA_GRANDE else 2 if mio < 0.5 else 0
    elif primero:
        p -= 2                                                  # cae en su primer partido
    return p


puntos = {}      # torneo → jugador → puntos
for m in ms:
    for s, pareja in ((0, m['a']), (1, m['b'])):
        for j in pareja:
            d = puntos.setdefault(m['t'], {})
            primero = j not in d
            p = pts_partido(m, s, primero)
            if p is not None:
                d[j] = d.get(j, 0) + p

# Los Major puntúan doble (también lo que se resta)
MULT = {'major': 2}
for t, d in puntos.items():
    f = MULT.get(str(T[t][2] or '') if t in T else '', 1)
    if f != 1:
        for j in d:
            d[j] *= f

# --- Valores -----------------------------------------------------------------------------------
CURVA = [(1, 90), (3, 70), (5, 56), (7, 48), (10, 40), (15, 30), (20, 24), (30, 16), (40, 10), (60, 5), (100, 3)]


def curva(r):
    if not r or r >= 100:
        return 3.0
    for (r0, p0), (r1, p1) in zip(CURVA, CURVA[1:]):
        if r0 <= r <= r1:
            t = (math.log(r) - math.log(r0)) / (math.log(r1) - math.log(r0)) if r1 > r0 else 0
            return math.exp(math.log(p0) + t * (math.log(p1) - math.log(p0)))
    return 3.0


hoy = datetime.date.today().isoformat()
terminados = sorted([t for t in T.values() if premier(t[0]) and t[8] == 'finished' and t[0] in puntos], key=lambda t: t[5])
ultimos2 = [t[0] for t in terminados[-2:]]
objetivo = {}
for genero in (0, 1):
    gente = [i for i, p in P.items() if p[4] == genero and p[3] in ('backhand', 'drive')]
    por_elo = sorted([i for i in gente if jugados.get(i, 0) >= 5], key=lambda i: -elo.get(i, 1500))
    r_elo = {i: n + 1 for n, i in enumerate(por_elo)}
    forma = {i: sum(puntos.get(t, {}).get(i, 0) for t in ultimos2) for i in gente}
    por_forma = sorted([i for i in gente if forma[i] > 0], key=lambda i: -forma[i])
    r_forma = {i: n + 1 for n, i in enumerate(por_forma)}
    for i in gente:
        base = curva(P[i][5] or r_elo.get(i))
        racha = max(0.85, min(1.15, (curva(r_forma.get(i)) / base) ** 0.25))
        objetivo[i] = max(3.0, min(90.0, base * racha))

# --- Torneo en juego -----------------------------------------------------------------------------
en_juego = sorted([t for t in T.values() if premier(t[0]) and (t[8] == 'live' or (t[5] or '9') <= hoy <= (t[6] or ''))],
                  key=lambda t: t[5])

if not remoto:
    top = sorted(objetivo, key=lambda i: -objetivo[i])[:12]
    print('Mánager (sin Supabase):', ', '.join(f'{P[i][1]} {objetivo[i]:.1f}' for i in top))
    print('En juego:', en_juego[0][1] if en_juego else 'ninguno', '· últimos para la forma:', [T[t][1] for t in ultimos2])
    sys.exit(0)

try:
    # Referencia: el valor que tenía al acabar el último torneo Premier
    ult = terminados[-1][0] if terminados else None
    antes = {r['id']: r for r in api('GET', 'm_jugadores?select=id,valor,ref,ref_torneo') or []}
    filas = []
    for i, v in objetivo.items():
        a = antes.get(i)
        if a and a.get('ref') is not None and a.get('ref_torneo') == ult:
            ref = float(a['ref'])
        else:   # ha acabado otro torneo (o es nuevo): la referencia pasa a ser su valor actual
            ref = float(a['valor']) if a else v
        v = min(ref * 1.1, max(ref * 0.9, v))   # entre torneos, como mucho ±10 %
        p = P[i]
        filas.append({'id': i, 'nombre': p[0], 'corto': p[1], 'genero': 'F' if p[4] else 'M',
                      'lado': 'R' if p[3] == 'backhand' else 'D', 'rank': p[5],
                      'valor': max(3.0, min(90.0, round(v * 2) / 2)), 'ref': round(ref, 1), 'ref_torneo': ult, 'actualizado': datetime.datetime.utcnow().isoformat() + 'Z'})
    for k in range(0, len(filas), 300):
        api('POST', 'm_jugadores?on_conflict=id', filas[k:k + 300], 'resolution=merge-duplicates')
    print(f'Mánager: {len(filas)} valores actualizados')

    estado = (api('GET', 'm_estado?id=eq.1&select=*') or [{}])[0]
    # Próximo torneo Premier: para el recordatorio de unas horas antes del bloqueo (01:30 UTC del primer día)
    prox = sorted([t for t in T.values() if premier(t[0]) and t[8] == 'pending' and (t[5] or '') > hoy], key=lambda t: t[5])
    if prox and estado.get('proximo') != prox[0][0]:
        api('PATCH', 'm_estado?id=eq.1', {'proximo': prox[0][0], 'proximo_nombre': prox[0][1], 'proximo_bloqueo': prox[0][5] + 'T01:30:00Z'})
        print(f'Mánager: próximo torneo {prox[0][1]} (se bloquea el {prox[0][5]} a las 01:30 UTC)')
    if en_juego and not estado.get('bloqueado'):
        t = en_juego[0]
        n = api('POST', 'rpc/m_bloquear', {'p_torneo': t[0], 'p_nombre': t[1]})
        print(f'Mánager: alineaciones congeladas para {t[1]} ({n})')
    elif not en_juego and estado.get('bloqueado'):
        n = api('POST', 'rpc/m_abrir', {})
        print(f'Mánager: alineaciones abiertas y {n} mánagers cobran sus puntos')

    for t in api('GET', 'm_torneos?select=id,nombre') or []:
        d = puntos.get(t['id'], {})
        filas = [{'torneo': t['id'], 'jugador': j, 'puntos': p} for j, p in d.items()]
        for k in range(0, len(filas), 500):
            api('POST', 'm_puntos?on_conflict=torneo,jugador', filas[k:k + 500], 'resolution=merge-duplicates')
        print(f"Mánager: puntos de {len(filas)} jugadores en {t['nombre']}")
    print('Mánager: mercados cerrados:', api('POST', 'rpc/m_procesar_todas', {}))
except Exception as e:
    print('Mánager: error con Supabase:', e)
