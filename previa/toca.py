"""¿Hay que leer la previa de la web de Premier Padel? Sale con 0 (sí) si hay un torneo Premier (no FIP)
en sus primeros días (la previa se juega los 2-3 primeros; se mira hasta el 5.º para recoger los últimos
resultados). Si no, sale con 1 y no se abre el navegador.

Uso: python3 previa/toca.py DATOS
"""
import datetime
import glob
import json
import sys

datos = sys.argv[1] if len(sys.argv) > 1 else 'datos'
hoy = datetime.date.today()
for f in glob.glob(f'{datos}/tournaments_*.json'):
    try:
        ts = json.load(open(f, encoding='utf-8')).get('data', [])
    except Exception:
        continue
    for t in ts:
        if str(t.get('level') or '').startswith('fip') or not t.get('start_date'):
            continue
        try:
            d0 = datetime.date.fromisoformat(t['start_date'][:10])
        except ValueError:
            continue
        if d0 <= hoy <= d0 + datetime.timedelta(days=4):
            print('Previa: toca leerla para', t.get('name'))
            sys.exit(0)
print('Previa: ningún torneo Premier en sus primeros días')
sys.exit(1)
