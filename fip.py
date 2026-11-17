"""Elige los torneos FIP que entran en la app: Platinum y Gold de la temporada FIP
que estén en juego, por jugar o que empezaran hace como mucho 45 días.

Uso: python3 fip.py DATOS ID_TEMPORADA_FIP  (escribe los ids separados por espacios)
"""
import datetime
import glob
import json
import os
import sys

datos, temporada = sys.argv[1], sys.argv[2]
hoy = datetime.date.today()
desde = (hoy - datetime.timedelta(days=45)).isoformat()
ts = {}
for f in glob.glob(os.path.join(datos, 'tournaments_*.json')):
    for t in json.load(open(f)).get('data', []):
        ts[t['id']] = t
ids = [t['id'] for t in ts.values()
       if (t.get('connections') or {}).get('season') == f'/api/seasons/{temporada}'
       and t.get('level') in ('fip_platinum', 'fip_gold')
       and (t.get('status') in ('live', 'pending') or (t.get('start_date') or '') >= desde)]
print(' '.join(map(str, sorted(ids))))
