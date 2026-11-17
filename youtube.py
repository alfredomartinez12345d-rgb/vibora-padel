"""Emisiones de YouTube del canal oficial (Premier Padel) para enlazar cada partido a su pista.

Uso: python3 youtube.py DATOS

Lee los últimos vídeos subidos al canal (los directos y los programados aparecen
ahí) y se queda con los que están en directo o programados. Guarda el resultado
en DATOS/youtube.json; build.py empareja cada partido con la emisión de su pista.

Gasta unas 3 unidades de la cuota de la API de YouTube por ejecución (de 10.000
gratis al día). Necesita YT_API_KEY; sin ella no hace nada. YT_CHANNEL elige el
canal (por defecto @PremierPadelOfficial). YT_API_BASE solo sirve para pruebas.
"""
import json
import os
import sys
import urllib.parse
import urllib.request

datos = sys.argv[1]
KEY = os.environ.get('YT_API_KEY', '').strip()
CANAL = os.environ.get('YT_CHANNEL', '').strip() or '@PremierPadelOfficial'
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

try:
    # El id del canal y su lista de subidas solo se piden la primera vez
    if previo.get('handle') == CANAL and previo.get('uploads'):
        uploads = previo['uploads']
    else:
        ch = api('channels', part='contentDetails', forHandle=CANAL).get('items') or []
        if not ch:
            print(f'YouTube: no encuentro el canal {CANAL}.')
            sys.exit(0)
        uploads = ch[0]['contentDetails']['relatedPlaylists']['uploads']
    items = api('playlistItems', part='contentDetails', playlistId=uploads, maxResults=50).get('items') or []
    ids = [i['contentDetails']['videoId'] for i in items]
    videos = []
    if ids:
        for v in api('videos', part='snippet,liveStreamingDetails', id=','.join(ids)).get('items') or []:
            estado = v['snippet'].get('liveBroadcastContent')  # live / upcoming / none
            if estado in ('live', 'upcoming'):
                d = v.get('liveStreamingDetails') or {}
                videos.append({'id': v['id'], 'title': v['snippet'].get('title', ''), 'status': estado,
                               'start': d.get('actualStartTime') or d.get('scheduledStartTime')})
except Exception as e:  # YouTube caído o clave mal puesta: se deja la última lista buena
    print('YouTube: error al consultar la API:', e)
    sys.exit(0)

json.dump({'handle': CANAL, 'uploads': uploads, 'videos': videos}, open(salida, 'w'), ensure_ascii=False)
print(f'YouTube: {len(videos)} emisiones en directo o programadas')
for v in videos:
    print('  ', v['status'], v['id'], v['title'])
