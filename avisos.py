"""Avisos en el móvil (OneSignal) para quien sigue a un jugador.

Uso: python3 avisos.py DATOS URL_DE_LA_APP

- «Empieza pronto»: partido con las dos parejas decididas que empieza en los
  próximos 45 minutos.
- «Resultado»: partido que en la ejecución anterior estaba pendiente y ahora
  tiene ganador.

Cada usuario que pulsa 🔔 en la ficha de un jugador queda etiquetado en
OneSignal con p<id del jugador> = 1; el aviso se manda a esas etiquetas.
El estado (qué se ha avisado ya) se guarda en DATOS/avisos.json, que viaja en
la caché de GitHub junto al resto de datos.

Necesita ONESIGNAL_APP_ID y ONESIGNAL_REST_KEY en el entorno; si falta alguno,
no hace nada. Con AVISOS_PRUEBA=1 no envía: escribe en pantalla lo que mandaría.
"""
import datetime
import glob
import json
import os
import re
import sys
import urllib.request

datos, url_app = sys.argv[1], sys.argv[2].rstrip('/') + '/'
APP = os.environ.get('ONESIGNAL_APP_ID', '').strip()
KEY = os.environ.get('ONESIGNAL_REST_KEY', '').strip()
PRUEBA = os.environ.get('AVISOS_PRUEBA') == '1'
if not PRUEBA and not (APP and KEY):
    print('Avisos: falta ONESIGNAL_APP_ID u ONESIGNAL_REST_KEY, no se envía nada.')
    sys.exit(0)

ahora = datetime.datetime.now(datetime.timezone.utc)
VENTANA = datetime.timedelta(minutes=45)
RN = {1: 'Final', 2: 'Semifinal', 4: 'Cuartos', 8: 'Octavos', 16: 'Dieciseisavos', 32: 'Primera ronda'}

estado_f = os.path.join(datos, 'avisos.json')
try:
    estado = json.load(open(estado_f))
except Exception:
    estado = {}
primera_vez = not estado
avisados = set(estado.get('avisados', []))     # 'pre:ID' y 'res:ID'
pendientes_antes = set(estado.get('pendientes', []))

torneos = {}
for f in glob.glob(os.path.join(datos, 'tournaments_*.json')):
    for t in json.load(open(f)).get('data', []):
        torneos[t['id']] = t

partidos = []
for f in glob.glob(os.path.join(datos, 't*_matches_*.json')):
    tid = int(re.search(r't(\d+)_matches', f).group(1))
    for m in json.load(open(f)).get('data', []):
        m['_t'] = tid
        partidos.append(m)


def pareja(m, lado):
    return ' / '.join(p.get('short_name') or p.get('name', '') for p in (m.get('players') or {}).get(lado) or [])


def ids(m):
    return [p['id'] for lado in ('team_1', 'team_2') for p in (m.get('players') or {}).get(lado) or []]


def enviar(clave, jugadores, titulo, texto, partido_id):
    if clave in avisados or not jugadores:
        return
    avisados.add(clave)
    filtros = []
    for j in jugadores:
        if filtros:
            filtros.append({'operator': 'OR'})
        filtros.append({'field': 'tag', 'key': f'p{j}', 'relation': '=', 'value': '1'})
    cuerpo = {'app_id': APP, 'target_channel': 'push', 'filters': filtros,
              'headings': {'en': titulo, 'es': titulo}, 'contents': {'en': texto, 'es': texto},
              'url': f'{url_app}#partido-{partido_id}'}
    if PRUEBA:
        print('AVISO', clave, '|', titulo, '|', texto, '| a', [f'p{j}' for j in jugadores])
        return
    req = urllib.request.Request('https://api.onesignal.com/notifications', data=json.dumps(cuerpo).encode(),
                                 headers={'Content-Type': 'application/json', 'Authorization': f'Key {KEY}'})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            print('Aviso enviado', clave, r.status)
    except Exception as e:
        print('Aviso fallido', clave, e)


pendientes = set()
for m in partidos:
    mid = str(m['id'])
    t = torneos.get(m['_t'], {})
    a, b = pareja(m, 'team_1'), pareja(m, 'team_2')
    terminado = m.get('winner') in ('team_1', 'team_2') and m.get('status') in ('finished', 'retired', 'walkover')
    if not terminado:
        pendientes.add(mid)
    if primera_vez:
        continue
    # Empieza pronto
    if not terminado and a and b and m.get('scheduled_at'):
        try:
            hora = datetime.datetime.fromisoformat(m['scheduled_at'])
        except ValueError:
            hora = None
        if hora and ahora - datetime.timedelta(minutes=10) <= hora <= ahora + VENTANA:
            pista = f" · {m['court']}" if m.get('court') else ''
            enviar(f'pre:{mid}', ids(m), f"🎾 {a} vs {b}",
                   f"{RN.get(m.get('round'), '')} del {t.get('name', '')}: empieza pronto{pista}", mid)
    # Resultado
    if terminado and mid in pendientes_antes:
        gana, pierde = (a, b) if m['winner'] == 'team_1' else (b, a)
        lado = m['winner']
        sets = ', '.join(f"{s.get(lado)}-{s.get('team_2' if lado == 'team_1' else 'team_1')}" for s in (m.get('score') or [])
                         if isinstance(s, dict))
        enviar(f'res:{mid}', ids(m), f"🏆 Ganan {gana}",
               f"{RN.get(m.get('round'), '')} del {t.get('name', '')}: {gana} a {pierde}{' · ' + sets if sets else ''}", mid)

json.dump({'avisados': sorted(avisados)[-5000:], 'pendientes': sorted(pendientes)}, open(estado_f, 'w'))
print('Avisos:', 'estado inicial guardado' if primera_vez else f'{len(avisados)} avisos en total', '·', len(pendientes), 'partidos pendientes')
