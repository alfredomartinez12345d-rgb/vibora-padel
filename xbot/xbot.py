"""Bot de X (Twitter) de Víbora Pádel: publica solo, con imagen, a partir de los datos de la app.

Uso: python3 xbot/xbot.py DATOS ESTADO   (después de build.py, que deja DATOS/app.json)

Qué publica (solo torneos Premier, cuadro final):
- «Campeones»: cuando termina una final.
- «Sorpresa»: gana una pareja que tenía poco pronóstico según el Elo de Víbora.
- «Hoy en …»: los partidos más interesantes del día con su pronóstico (una vez al día).
- «Así queda el Elo»: top 5 masculino y femenino cuando acaba un torneo.
- «Cierre del fantasy»: la víspera del bloqueo de alineaciones (solo texto).

Límites para no hacer spam ni gastar: como mucho 3 posts por ejecución y 10 al día.
La primera vez solo guarda el estado (no publica lo que ya pasó).

Estado en ESTADO/xbot.json (viaja en la caché de GitHub).
Publica de verdad solo con X_PUBLICAR=1 y las cuatro claves (X_API_KEY, X_API_SECRET,
X_ACCESS_TOKEN, X_ACCESS_TOKEN_SECRET). Si no, modo prueba: escribe en pantalla lo que
publicaría y deja las imágenes en XBOT_SALIDA (por defecto ESTADO/salida).
XBOT_AHORA=2026-11-24T10:00:00+00:00 sirve para probar con otra fecha.
"""
import base64
import datetime
import hashlib
import hmac
import io
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from zoneinfo import ZoneInfo

from PIL import Image, ImageDraw, ImageFilter, ImageFont

datos, dir_estado = sys.argv[1], sys.argv[2]
os.makedirs(dir_estado, exist_ok=True)
AQUI = os.path.dirname(os.path.abspath(__file__))
RAIZ = os.path.dirname(AQUI)
MAD = ZoneInfo('Europe/Madrid')

CLAVES = [os.environ.get(k, '').strip() for k in ('X_API_KEY', 'X_API_SECRET', 'X_ACCESS_TOKEN', 'X_ACCESS_TOKEN_SECRET')]
PUBLICAR = os.environ.get('X_PUBLICAR', '').strip() == '1' and all(CLAVES)
SALIDA = os.environ.get('XBOT_SALIDA') or os.path.join(dir_estado, 'salida')
AHORA = datetime.datetime.fromisoformat(os.environ['XBOT_AHORA']) if os.environ.get('XBOT_AHORA') else datetime.datetime.now(datetime.timezone.utc)
HOY = AHORA.astimezone(MAD).date()
MAX_EJECUCION, MAX_DIA = 3, 10
print('Bot de X:', 'PUBLICA DE VERDAD' if PUBLICAR else 'modo prueba (no publica)', '·', AHORA.astimezone(MAD).strftime('%d/%m %H:%M'), 'hora España')

# ---------------------------------------------------------------- datos de la app
D = json.load(open(os.path.join(datos, 'app.json'), encoding='utf-8'))
# P: id → [nombre, corto, nacionalidad, lado, mujer, ranking, puntos, foto]
P = {int(k): v for k, v in D['P'].items()}
# T: [id, nombre, nivel, lugar, país, inicio, fin, pista, estado, oculto, cartel]
T = {t[0]: t for t in D['T']}
# M: [id, torneo, mujer, ronda, orden, fecha, pista, estado, a, b, cab_a, cab_b, sets, ganador, hora, tipo_hora, orden_pista]
M = [dict(id=m[0], t=m[1], mujer=m[2], ronda=m[3], fecha=m[5] or '', pista=m[6], st=m[7], a=m[8], b=m[9], sets=m[12] or [],
          w=m[13], hora=m[14] if len(m) > 14 else None) for m in D['M']]
RN = {1: 'Final', 2: 'Semifinal', 4: 'Cuartos', 8: 'Octavos', 16: 'Dieciseisavos', 32: 'Primera ronda'}


def premier(tid):
    t = T.get(tid)
    return bool(t) and not str(t[2] or '').startswith('fip')


def corto(i):
    p = P.get(i)
    return (p[1] or p[0].split()[-1]) if p else '?'


def par(ids):
    return '/'.join(corto(i) for i in ids)


def marcador(m, lado):
    return ' '.join(f'{x[lado]}-{x[1 - lado]}' for x in m['sets'] if len(x) >= 2)


def nombre_t(tid):
    return T[tid][1] if tid in T else ''


# Elo como la app: 1500, K=32, media de la pareja, solo Premier; guarda el pronóstico previo de cada partido
elo, ultimo = {}, {}
for m in sorted([m for m in M if premier(m['t']) and len(m['a']) == 2 and len(m['b']) == 2],
                key=lambda m: (m['fecha'], -m['ronda'], m['id'])):
    ea = sum(elo.get(i, 1500) for i in m['a']) / 2
    eb = sum(elo.get(i, 1500) for i in m['b']) / 2
    m['pre'] = 1 / (1 + 10 ** ((eb - ea) / 400))
    if not (m['st'] < 2 and m['w'] is not None):
        continue
    d = 32 * ((1 if m['w'] == 0 else 0) - m['pre'])
    for i in m['a'] + m['b']:
        ultimo.setdefault(m['t'], {})
        ultimo[m['t']][i] = ultimo[m['t']].get(i, 0) + (d if i in m['a'] else -d)
        elo[i] = elo.get(i, 1500) + (d if i in m['a'] else -d)

# ---------------------------------------------------------------- estado
f_estado = os.path.join(dir_estado, 'xbot.json')
try:
    estado = json.load(open(f_estado))
except Exception:
    estado = {}
primera_vez = not estado
hechos = set(estado.get('hechos', []))
vistos = set(estado.get('vistos', []))          # partidos terminados ya revisados
fallos = estado.get('fallos', {})
por_dia = estado.get('por_dia', {})
terminado = lambda m: m['w'] is not None and m['st'] <= 2

# ---------------------------------------------------------------- imágenes
W, H = 1200, 675
F = lambda n, s: ImageFont.truetype(os.path.join(AQUI, 'fuentes', n), s)
TIT = lambda s: F('BarlowCondensed-ExtraBoldItalic.ttf', s)
NEG = lambda s: F('BarlowCondensed-Bold.ttf', s)
TXT = lambda s: F('Barlow-SemiBold.ttf', s)
AMA, ORO, GRIS, BLANCO = (217, 224, 33), (255, 197, 61), (154, 161, 199), (244, 245, 255)
_fotos = {}


def foto(i):
    """Foto recortada del jugador (RGBA) o None."""
    if i in _fotos:
        return _fotos[i]
    url, im = (P.get(i) or [None] * 8)[7], None
    try:
        if url and url.startswith('fotos/'):
            im = Image.open(os.path.join(RAIZ, url))
        elif url and url.startswith('https://'):
            req = urllib.request.Request(url, headers={'User-Agent': 'ViboraPadelBot/1.0'})
            with urllib.request.urlopen(req, timeout=20) as r:
                im = Image.open(io.BytesIO(r.read()))
        if im:
            im = im.convert('RGBA')
            caja = im.getchannel('A').getbbox()
            if caja:
                im = im.crop(caja)
    except Exception as e:
        print('  sin foto', i, e)
        im = None
    _fotos[i] = im
    return im


def lienzo(color=(30, 36, 102)):
    im = Image.new('RGB', (W, H), (10, 12, 28))
    capa = Image.new('RGBA', (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(capa)
    d.ellipse((W / 2 - 700, -500, W / 2 + 700, 500), fill=color + (190,))
    capa = capa.filter(ImageFilter.GaussianBlur(120))
    im.paste(capa, (0, 0), capa)
    d = ImageDraw.Draw(im)
    for k in range(-6, 7):   # líneas de pista en perspectiva
        d.line((W / 2 + k * 60, H - 230, W / 2 + k * 260, H + 40), fill=(40, 52, 120), width=2)
    d.line((0, H - 140, W, H - 140), fill=(40, 52, 120), width=2)
    # marca
    d.ellipse((40, 36, 66, 62), fill=AMA)
    d.text((78, 30), 'VÍBORA', font=TIT(34), fill=BLANCO)
    d.text((W - 40, 34), 'Datos y fantasy de pádel', font=TXT(20), fill=GRIS, anchor='ra')
    return im, d


def poner(im, i, x, y, alto, sombra=True, gris=False):
    """Pega la foto del jugador con la base en (x, y) centrada en x."""
    f = foto(i)
    if f is None:
        d = ImageDraw.Draw(im)
        r = min(alto // 4, 90)
        d.ellipse((x - r, y - 2 * r - 10, x + r, y - 10), fill=(40, 46, 90), outline=(80, 90, 150), width=3)
        ini = ''.join(w[0] for w in (P.get(i) or ['?'])[0].split()[:2]).upper()
        d.text((x, y - r - 10), ini, font=NEG(int(r * .9)), fill=BLANCO, anchor='mm')
        return
    f = f.resize((max(1, int(f.width * alto / f.height)), alto), Image.LANCZOS)
    if gris:
        a = f.getchannel('A')
        f = f.convert('L').convert('RGBA')
        f.putalpha(a.point(lambda v: v * 0.55))
    if sombra:
        s = Image.new('RGBA', f.size, (0, 0, 0, 0))
        s.putalpha(f.getchannel('A').point(lambda v: v * 0.6))
        s = s.filter(ImageFilter.GaussianBlur(10))
        im.paste(s, (x - f.width // 2 + 8, y - f.height + 10), s)
    im.paste(f, (x - f.width // 2, y - f.height), f)


def pareja_fotos(im, ids, cx, base, alto, gris=False):
    """Pega las dos fotos; si a alguno le falta, no pega nada y devuelve False."""
    if any(foto(i) is None for i in ids):
        return False
    sep = int(alto * 0.36)
    poner(im, ids[1], cx + sep, base, alto, gris=gris)
    poner(im, ids[0], cx - sep, base, alto, gris=gris)
    return True


def nombres_grandes(d, ids, cx, cy, ancho, color=BLANCO):
    """Si no hay fotos: los apellidos en grande."""
    for k, i in enumerate(ids):
        caja_texto(d, (cx, cy + (k - .5) * 120), corto(i).upper(), TIT(130), color, 'mm', ancho)


def caja_texto(d, xy, txt, font, fill, anchor='la', max_w=None):
    if max_w:
        while d.textlength(txt, font=font) > max_w and font.size > 16:
            font = font.font_variant(size=font.size - 2)
    d.text(xy, txt, font=font, fill=fill, anchor=anchor)


def guardar(im, nombre):
    os.makedirs(SALIDA, exist_ok=True)
    ruta = os.path.join(SALIDA, nombre + '.png')
    im.save(ruta, optimize=True)
    return ruta


def img_campeones(m):
    g = m['w']
    ids = m['a'] if g == 0 else m['b']
    im, d = lienzo((90, 70, 10))
    d.text((W / 2, 70), 'CAMPEONES', font=TIT(100), fill=ORO, anchor='mt')
    caja_texto(d, (W / 2, 180), nombre_t(m['t']).upper() + (' · FEMENINO' if m['mujer'] else ' · MASCULINO'), TXT(28), GRIS, 'mt', 1000)
    if not pareja_fotos(im, ids, W // 2, H - 118, 320):
        nombres_grandes(d, ids, W / 2, 380, 1000, BLANCO)
    d = ImageDraw.Draw(im)
    d.rectangle((0, H - 120, W, H), fill=(10, 12, 28))
    caja_texto(d, (W / 2, H - 100), ' / '.join((P[i][0] for i in ids)).upper(), NEG(48), BLANCO, 'mt', 1100)
    d.text((W / 2, H - 42), marcador(m, g), font=TXT(26), fill=ORO, anchor='mt')
    return im


def img_sorpresa(m):
    g = m['w']
    win, lose = (m['a'], m['b']) if g == 0 else (m['b'], m['a'])
    pct = round((m['pre'] if g == 0 else 1 - m['pre']) * 100)
    im, d = lienzo((110, 20, 40))
    d.text((60, 100), 'SORPRESA', font=TIT(104), fill=AMA)
    caja_texto(d, (64, 222), f"{RN.get(m['ronda'], '')} · {nombre_t(m['t'])}".upper(), TXT(26), GRIS, 'la', 560)
    d.text((64, 290), 'Tenían solo un', font=TXT(30), fill=BLANCO)
    d.text((60, 322), f'{pct}%', font=TIT(150), fill=AMA)
    d.text((64, 492), 'de pronóstico', font=TXT(30), fill=BLANCO)
    if not pareja_fotos(im, win, 870, H - 118, 400):
        nombres_grandes(d, win, 880, 330, 560, BLANCO)
    d = ImageDraw.Draw(im)
    d.rectangle((0, H - 120, W, H), fill=(10, 12, 28))
    caja_texto(d, (60, H - 100), f'{par(win).upper()}  GANAN A  {par(lose).upper()}', NEG(44), BLANCO, 'la', 1080)
    d.text((60, H - 46), marcador(m, g), font=TXT(26), fill=AMA)
    return im


def img_previa(tid, ms):
    im, d = lienzo()
    d.text((60, 92), 'HOY EN', font=TIT(56), fill=GRIS)
    caja_texto(d, (60, 140), nombre_t(tid).upper(), TIT(80), AMA, 'la', 760)
    d.text((W - 40, 210), 'Pronóstico según el Elo de Víbora', font=TXT(20), fill=GRIS, anchor='rs')
    y0, alto = 240, 96
    for k, m in enumerate(ms[:4]):
        y = y0 + k * (alto + 10)
        d.rounded_rectangle((40, y, W - 40, y + alto), 22, fill=(20, 23, 46), outline=(42, 47, 87), width=2)
        pa = round(m['pre'] * 100)
        # barra de pronóstico
        x0, x1 = 360, W - 360
        d.rounded_rectangle((x0, y + 62, x1, y + 76), 7, fill=(255, 93, 108))
        d.rounded_rectangle((x0, y + 62, x0 + (x1 - x0) * pa / 100, y + 76), 7, fill=(79, 124, 255))
        caja_texto(d, (x0, y + 16), f'{pa}%', NEG(36), (130, 160, 255), 'la')
        caja_texto(d, (x1, y + 16), f'{100 - pa}%', NEG(36), (255, 130, 140), 'ra')
        caja_texto(d, (W / 2, y + 26), (RN.get(m['ronda'], '') + (' F' if m['mujer'] else ' M')).upper(), TXT(18), GRIS, 'mm')
        caja_texto(d, (190, y + alto / 2), par(m['a']).upper(), NEG(32), BLANCO, 'lm', 165)
        caja_texto(d, (W - 190, y + alto / 2), par(m['b']).upper(), NEG(32), BLANCO, 'rm', 165)
        for j, i in enumerate(m['a']):
            poner(im, i, 80 + j * 52, y + alto - 2, 88, sombra=False)
        for j, i in enumerate(m['b']):
            poner(im, i, W - 132 + j * 52, y + alto - 2, 88, sombra=False)
        d = ImageDraw.Draw(im)
    return im


def img_podio(tid, tops):
    im, d = lienzo((50, 30, 110))
    d.text((60, 92), 'ASÍ QUEDA EL ELO', font=TIT(76), fill=AMA)
    caja_texto(d, (62, 180), 'Tras el ' + nombre_t(tid), TXT(26), GRIS, 'la', 1000)
    for c, (titulo, lista) in enumerate(tops):
        x = 60 + c * 560
        d.text((x, 232), titulo, font=NEG(32), fill=BLANCO)
        for k, (i, e, dlt) in enumerate(lista):
            pos = 1 + len({round(x[1]) for x in lista if round(x[1]) > round(e)})
            y = 280 + k * 74
            d.rounded_rectangle((x, y, x + 520, y + 64), 16, fill=(20, 23, 46), outline=(255, 197, 61) if pos == 1 else (42, 47, 87), width=2)
            d.text((x + 24, y + 32), str(pos), font=TIT(40), fill=ORO if pos == 1 else GRIS, anchor='mm')
            poner(im, i, x + 82, y + 63, 64, sombra=False)
            d = ImageDraw.Draw(im)
            caja_texto(d, (x + 124, y + 32), P[i][0], TXT(24), BLANCO, 'lm', 250)
            d.text((x + 430, y + 32), str(round(e)), font=NEG(34), fill=BLANCO, anchor='rm')
            col = (61, 220, 151) if dlt > 0 else (255, 93, 108) if dlt < 0 else GRIS
            d.text((x + 500, y + 32), f'{"+" if dlt > 0 else ""}{round(dlt)}' if round(dlt) else '–', font=TXT(20), fill=col, anchor='rm')
    return im


# ---------------------------------------------------------------- candidatos
cands = []   # (prioridad, clave, texto, imagen o None)
TAGS = '#padel #PremierPadel'

nuevos = [m for m in M if premier(m['t']) and terminado(m) and str(m['id']) not in vistos and len(m['a']) == 2 and len(m['b']) == 2]
if not primera_vez:
    for m in nuevos:
        g = m['w']
        win, lose = (m['a'], m['b']) if g == 0 else (m['b'], m['a'])
        pct = round((m['pre'] if g == 0 else 1 - m['pre']) * 100)
        if m['ronda'] == 1:
            cat = 'femenino' if m['mujer'] else 'masculino'
            txt = (f"🏆 ¡{par(win)} campeones del {nombre_t(m['t'])}! ({cat})\n\n"
                   f"Final: {marcador(m, g)} a {par(lose)}.\n\n{TAGS}")
            cands.append((0, f"camp:{m['id']}", txt, lambda m=m: img_campeones(m)))
        elif m['st'] == 0 and (pct <= 25 or (m['ronda'] <= 8 and pct <= 35)):
            txt = (f"💥 SORPRESA en {RN.get(m['ronda'], '').lower()} del {nombre_t(m['t'])}\n\n"
                   f"{par(win)} ganan a {par(lose)} ({marcador(m, g)}) con solo un {pct}% de pronóstico según el Elo de Víbora.\n\n{TAGS}")
            cands.append((1, f"sorp:{m['id']}", txt, lambda m=m: img_sorpresa(m)))

# Elo final de torneo: cuando ya se han jugado las dos finales
for tid in {m['t'] for m in M if premier(m['t'])}:
    finales = [m for m in M if m['t'] == tid and m['ronda'] == 1]
    if len(finales) < 2 or not all(terminado(m) for m in finales) or f'podio:{tid}' in hechos:
        continue
    fin = max(m['fecha'] for m in finales)[:10]
    if primera_vez or (HOY - datetime.date.fromisoformat(fin)).days > 2:
        hechos.add(f'podio:{tid}')
        continue
    tops = []
    for muj, tit in ((0, 'MASCULINO'), (1, 'FEMENINO')):
        l = sorted([i for i in elo if P.get(i) and P[i][4] == muj], key=lambda i: -elo[i])[:5]
        tops.append((tit, [(i, elo[i], ultimo.get(tid, {}).get(i, 0)) for i in l]))
    txt = (f"📊 Así queda el Elo de Víbora tras el {nombre_t(tid)}\n\n"
           + ''.join(f"👑 {tit.capitalize()}: {' y '.join(corto(i) for i, e, _ in l if round(e) == round(l[0][1]))} ({round(l[0][1])})\n" for tit, l in tops) + "\n"
           f"El ranking completo y el de parejas, en la app (link en la bio). {TAGS}")
    cands.append((2, f'podio:{tid}', txt, lambda tid=tid, tops=tops: img_podio(tid, tops)))

# Partidos de hoy (hora España), una vez al día por torneo, desde las 8:00
if AHORA.astimezone(MAD).hour >= 8:
    hoy = {}
    for m in M:
        if not premier(m['t']) or terminado(m) or len(m['a']) != 2 or len(m['b']) != 2 or not m['hora']:
            continue
        try:
            h = datetime.datetime.fromisoformat(m['hora'])
        except ValueError:
            continue
        dia_local = AHORA.astimezone(h.tzinfo).date()   # «hoy» en la hora del torneo
        if h.date() == dia_local and h > AHORA:
            hoy.setdefault((m['t'], str(dia_local)), []).append(m)
    for (tid, dia_local), ms in hoy.items():
        clave = f'hoy:{tid}:{dia_local}'
        if clave in hechos:
            continue
        # los más interesantes: rondas altas y parejas con más Elo
        ms.sort(key=lambda m: (m['ronda'], -(sum(elo.get(i, 1500) for i in m['a'] + m['b']))))
        top = ms[:4]
        fav = max(top, key=lambda m: abs(m['pre'] - .5))
        igual = min(top, key=lambda m: abs(m['pre'] - .5))
        txt = (f"🎾 Hoy en el {nombre_t(tid)}: {len(ms)} partido{'s' if len(ms) != 1 else ''}\n\n"
               f"⚖️ El más igualado: {par(igual['a'])} vs {par(igual['b'])} ({round(igual['pre'] * 100)}%-{round((1 - igual['pre']) * 100)}%)\n"
               f"🔒 El más claro: {par(fav['a'] if fav['pre'] >= .5 else fav['b'])} ({round(max(fav['pre'], 1 - fav['pre']) * 100)}%)\n\n"
               f"¿Quién da la sorpresa? 👇 {TAGS}")
        cands.append((3, clave, txt, lambda tid=tid, top=top: img_previa(tid, top)))

# Cierre de alineaciones del fantasy: 01:30 UTC del día que empieza el próximo torneo Premier
prox = sorted([t for t in T.values() if not str(t[2] or '').startswith('fip') and t[8] != 'finished' and t[5] and t[5] >= str(AHORA.date())],
              key=lambda t: t[5])
if prox:
    t = prox[0]
    cierre = datetime.datetime.fromisoformat(t[5] + 'T01:30:00+00:00')
    falta = (cierre - AHORA).total_seconds() / 3600
    clave = f'cierre:{t[0]}'
    if 2 < falta <= 30 and clave not in hechos:
        hl = cierre.astimezone(MAD)
        DIAS = ['lunes', 'martes', 'miércoles', 'jueves', 'viernes', 'sábado', 'domingo']
        txt = (f"⏰ Fantasy Víbora: las alineaciones del {t[1]} se cierran en {round(falta)} horas "
               f"(el {DIAS[hl.weekday()]} {hl.strftime('%d/%m')} a las {hl.strftime('%H:%M')}, hora España).\n\n"
               f"Elige tu capitán, mira el mercado y no te quedes sin puntos. Link en la bio 🐍 #padel #fantasy")
        cands.append((4, clave, txt, None))


# ---------------------------------------------------------------- publicar
enc = lambda s: urllib.parse.quote(str(s), safe='~-._')


def firma(metodo, url, params=None):
    ck, cs, at, ats = CLAVES
    o = {'oauth_consumer_key': ck, 'oauth_nonce': uuid.uuid4().hex, 'oauth_signature_method': 'HMAC-SHA1',
         'oauth_timestamp': str(int(time.time())), 'oauth_token': at, 'oauth_version': '1.0'}
    todos = sorted((enc(k), enc(v)) for k, v in {**(params or {}), **o}.items())
    base = '&'.join([metodo, enc(url), enc('&'.join(f'{k}={v}' for k, v in todos))])
    o['oauth_signature'] = base64.b64encode(hmac.new(f'{enc(cs)}&{enc(ats)}'.encode(), base.encode(), hashlib.sha1).digest()).decode()
    return 'OAuth ' + ', '.join(f'{enc(k)}="{enc(v)}"' for k, v in sorted(o.items()))


def pedir(metodo, url, cuerpo, tipo):
    req = urllib.request.Request(url, data=cuerpo, method=metodo,
                                 headers={'Authorization': firma(metodo, url), 'Content-Type': tipo, 'User-Agent': 'ViboraPadelBot/1.0'})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, json.loads(r.read().decode() or '{}')
    except urllib.error.HTTPError as e:
        return e.code, (e.read().decode(errors='replace')[:500])


def subir_imagen(ruta):
    lim = '----vibora' + uuid.uuid4().hex
    datos_img = open(ruta, 'rb').read()
    partes = [f'--{lim}\r\nContent-Disposition: form-data; name="media_category"\r\n\r\ntweet_image\r\n'.encode(),
              f'--{lim}\r\nContent-Disposition: form-data; name="media_type"\r\n\r\nimage/png\r\n'.encode(),
              f'--{lim}\r\nContent-Disposition: form-data; name="media"; filename="post.png"\r\nContent-Type: image/png\r\n\r\n'.encode(),
              datos_img, f'\r\n--{lim}--\r\n'.encode()]
    st, r = pedir('POST', 'https://api.x.com/2/media/upload', b''.join(partes), f'multipart/form-data; boundary={lim}')
    if st < 300 and isinstance(r, dict):
        return (r.get('data') or {}).get('id') or r.get('media_id_string')
    print('  no se pudo subir la imagen:', st, r)
    return None


def publicar(texto, ruta):
    cuerpo = {'text': texto}
    if ruta:
        mid = subir_imagen(ruta)
        if mid:
            cuerpo['media'] = {'media_ids': [str(mid)]}
    st, r = pedir('POST', 'https://api.x.com/2/tweets', json.dumps(cuerpo).encode(), 'application/json')
    if st < 300:
        print('  publicado:', (r.get('data') or {}).get('id'))
        return True
    print('  error al publicar:', st, r)
    return False


dia = str(HOY)
hechos_hoy = por_dia.get(dia, 0)
n = 0
for prio, clave, texto, hacer in sorted(cands, key=lambda c: c[0]):
    if clave in hechos:
        continue
    if n >= MAX_EJECUCION or hechos_hoy >= MAX_DIA:
        print('Límite alcanzado; queda para otra ejecución:', clave)
        continue
    ruta = None
    if hacer:
        try:
            ruta = guardar(hacer(), clave.replace(':', '_'))
        except Exception as e:
            print('  no se pudo crear la imagen de', clave, e)
    print(f'\n=== {clave} ===\n{texto}\n[{len(texto)} caracteres] imagen: {ruta}')
    ok = publicar(texto, ruta) if PUBLICAR else True
    if ok:
        hechos.add(clave)
        n += 1
        hechos_hoy += 1
    else:
        fallos[clave] = fallos.get(clave, 0) + 1
        if fallos[clave] >= 2:   # no insistir: cada intento puede costar
            hechos.add(clave)
pend = {c[1] for c in cands if c[1] not in hechos}
for m in nuevos:
    if f"sorp:{m['id']}" not in pend and f"camp:{m['id']}" not in pend:
        vistos.add(str(m['id']))
por_dia = {k: v for k, v in por_dia.items() if k >= str(HOY - datetime.timedelta(days=7))}
por_dia[dia] = hechos_hoy
json.dump({'hechos': sorted(hechos)[-3000:], 'vistos': sorted(vistos), 'fallos': fallos, 'por_dia': por_dia}, open(f_estado, 'w'))
print('\nBot de X:', 'estado inicial guardado, no publica lo que ya pasó' if primera_vez else f'{n} post(s) en esta ejecución')
