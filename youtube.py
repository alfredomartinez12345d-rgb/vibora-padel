"""Emisiones de YouTube del canal oficial (Premier Padel) para enlazar cada partido a su pista.

Uso: python3 youtube.py DATOS

Lee los últimos vídeos subidos al canal (los directos y los programados aparecen
ahí) y se queda con los que están en directo o programados. Guarda el resultado
en DATOS/youtube.json; build.py empareja cada partido con la emisión de su pista.

Mira dos canales: el de Premier Padel (YT_CHANNEL, por defecto @PremierPadelOfficial)
y el de la FIP (YT_CHANNEL_FIP, por defecto @padelfip). Gasta unas 2-3 unidades de la
cuota de la API de YouTube por canal y ejecución (de 10.000 gratis al día).
Necesita YT_API_KEY; sin ella no hace nada. YT_API_BASE solo sirve para pruebas.
"""
import json
import os
import sys
import urllib.parse
import urllib.request

datos = sys.argv[1]
KEY = os.environ.get('YT_API_KEY', '').strip()
CANALES = {'premier': os.environ.get('YT_CHANNEL', '').strip() or '@PremierPadelOfficial',
           'fip': os.environ.get('YT_CHANNEL_FIP', '').strip() or '@padelfip'}
BASE = os.environ.get('YT_API_BASE', 'https://www.googleapis.com/youtube/v3')
salida = os.path.join(datos, 'youtube.json')

if not KEY:
    print('YouTube: falta YT_API_KEY, no se buscan emisiones.')
    sys.exit(0)


def api(recurso, **params):
    params['key'] = KEY
    url = f'{BASE}/{recurso}?{urllib.parse.urlencode(params)}'
    with urllib.request.urlopen(url, timeout=20) as r:
        return json.load(r)


try:
    previo = json.load(open(salida))
except Exception:
    previo = {}
subidas = previo.get('uploads') if isinstance(previo.get('uploads'), dict) else {}

resultado = {'channels': CANALES, 'uploads': {}, 'videos': []}
for circuito, canal in CANALES.items():
    try:
        # El id del canal y su lista de subidas solo se piden la primera vez
        up = subidas.get(canal)
        if not up:
            ch = api('channels', part='contentDetails', forHandle=canal).get('items') or []
            if not ch:
                print(f'YouTube: no encuentro el canal {canal}.')
                continue
            up = ch[0]['contentDetails']['relatedPlaylists']['uploads']
        resultado['uploads'][canal] = up
        items = api('playlistItems', part='contentDetails', playlistId=up, maxResults=50).get('items') or []
        ids = [i['contentDetails']['videoId'] for i in items]
        if not ids:
            continue
        for v in api('videos', part='snippet,liveStreamingDetails', id=','.join(ids)).get('items') or []:
            estado = v['snippet'].get('liveBroadcastContent')  # live / upcoming / none
            if estado in ('live', 'upcoming'):
                d = v.get('liveStreamingDetails') or {}
                resultado['videos'].append({'id': v['id'], 'title': v['snippet'].get('title', ''), 'status': estado,
                                            'circuit': circuito,
                                            'start': d.get('actualStartTime') or d.get('scheduledStartTime')})
    except Exception as e:  # YouTube caído o clave mal puesta: se mantiene lo anterior de ese canal
        print(f'YouTube: error con {canal}:', e)
        resultado['videos'] += [v for v in previo.get('videos') or [] if v.get('circuit') == circuito]

json.dump(resultado, open(salida, 'w'), ensure_ascii=False)
print(f"YouTube: {len(resultado['videos'])} emisiones en directo o programadas")
for v in resultado['videos']:
    print('  ', v['circuit'], v['status'], v['id'], v['title'])
