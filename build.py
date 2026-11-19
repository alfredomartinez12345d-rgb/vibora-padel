import json, sys, glob, os, re, datetime


def leer(f):
    """Lee un JSON descargado; si está roto, avisa y devuelve vacío en vez de romperse."""
    try:
        with open(f, encoding='utf-8') as fh:
            return json.load(fh)
    except (OSError, ValueError) as e:
        print(f'Aviso: no se puede leer {os.path.basename(f)} ({e}); se ignora.')
        return {}

d_matches, d_meta, tpl, out = sys.argv[1:5]

# Torneos (metadatos de la primera descarga)
tmeta = {}
for f in sorted(glob.glob(os.path.join(d_meta, 'tournaments_*.json'))):
    try:
        for t in leer(f).get('data', []):
            tmeta[t['id']] = t
    except Exception:
        pass

# Solo la temporada elegida por descargar.sh (si se guardó)
sf = os.path.join(d_meta, 'season.txt')
if os.path.exists(sf):
    sid = open(sf).read().strip()
    ff = os.path.join(d_meta, 'fip_ids.txt')
    fip_ids = set(int(x) for x in open(ff).read().split()) if os.path.exists(ff) else set()
    tmeta = {i: t for i, t in tmeta.items() if (t.get('connections') or {}).get('season') == f'/api/seasons/{sid}' or i in fip_ids}

# Partidos
raw = {}
for f in sorted(glob.glob(os.path.join(d_matches, 't*_matches_*.json'))):
    t = int(re.search(r't(\d+)_matches', f).group(1))
    for m in leer(f).get('data', []):
        m['_t'] = t
        raw[m['id']] = m

# Ranking y puntos: inscritos de los últimos torneos; gana el dato del torneo más reciente
def val(x, *keys):
    if isinstance(x, dict):
        for k in keys:
            if x.get(k) is not None:
                return x[k]
        return None
    return x


rk = {}
rk_from = []
pf = {}
for f in glob.glob(os.path.join(d_matches, 't*_players_*.json')):
    pf.setdefault(int(re.search(r't(\d+)_players', f).group(1)), []).append(f)
for t in sorted(pf, key=lambda i: (tmeta.get(i) or {}).get('start_date') or ''):
    n = 0
    for f in pf[t]:
        for p in leer(f).get('data', []):
            r = val(p.get('ranking'), 'position', 'ranking', 'rank')
            pts = val(p.get('points'), 'points', 'value')
            if r is not None:
                rk[p['id']] = (int(r), pts)
                n += 1
    if n and t in tmeta:
        rk_from.append(tmeta[t]['name'])

ST = {'finished': 0, 'retired': 1, 'walkover': 2, 'scheduled': 3,
      # en juego: se trata como pendiente (si no, el partido desaparecería mientras se juega)
      'live': 3, 'in_progress': 3, 'playing': 3, 'started': 3, 'ongoing': 3}
other = {}
hidden_t = set()
P = {}
M = []


def tipo_hora(label):
    """0: empieza a una hora · 1: hora aproximada · 2: no antes de · 3: a continuación"""
    s = str(label or '').lower()
    if s.startswith('estimated'):
        return 1
    if s.startswith('not before'):
        return 2
    if s.startswith('followed') or 'after' in s:
        return 3
    return 0


def num(s):
    mm = re.match(r'\s*(\d+)(?:\((\d+)\))?', str(s))
    return (int(mm.group(1)), int(mm.group(2)) if mm.group(2) else None) if mm else (0, None)


for m in raw.values():
    if m['score'] == 'hidden_free_plan' or m['winner'] == 'hidden_free_plan':
        hidden_t.add(m['_t'])
        continue
    if m['status'] == 'bye':
        continue
    if m['status'] not in ST:
        other[m['status']] = other.get(m['status'], 0) + 1
        continue
    teams = []
    for tm in ('team_1', 'team_2'):
        ids = []
        for p in m['players'][tm]:
            ids.append(p['id'])
            if p['id'] not in P:
                r = rk.get(p['id'], (None, None))
                P[p['id']] = [p['name'], p['short_name'], p['nationality'], p['side'], 1 if m['category'] == 'women' else 0, r[0], r[1], p.get('photo_url')]
        teams.append(ids)
    sets = []
    for s in (m['score'] or []):
        a, ta = num(s['team_1'])
        b, tb = num(s['team_2'])
        sets.append([a, b] + ([ta if ta is not None else tb] if (ta is not None or tb is not None) else []))
    w = {'team_1': 0, 'team_2': 1}.get(m['winner'])
    M.append([m['id'], m['_t'], 1 if m['category'] == 'women' else 0, m['round'], m['index'], m['played_at'],
              (m['court'] or '').strip() or None, ST[m['status']], teams[0], teams[1],
              m['seeds']['team_1'], m['seeds']['team_2'], sets, w,
              m.get('scheduled_at'), tipo_hora(m.get('schedule_label')), m.get('court_order')])

# Previas de los torneos Premier: solo para el fantasy (no entran en cuadros, Elo ni estadísticas)
Q = []
for f in sorted(glob.glob(os.path.join(d_matches, 't*_qualy_*.json'))):
    t = int(re.search(r't(\d+)_qualy', f).group(1))
    if t not in tmeta or str(tmeta[t].get('level') or '').startswith('fip'):
        continue
    for m in leer(f).get('data', []):
        if m.get('draw', 'qualy') != 'qualy' or m.get('status') not in ST or m.get('score') == 'hidden_free_plan' or m.get('winner') == 'hidden_free_plan':
            continue
        teams = []
        for tm in ('team_1', 'team_2'):
            ids = []
            for p in (m.get('players') or {}).get(tm) or []:
                ids.append(p['id'])
                if p['id'] not in P:
                    r = rk.get(p['id'], (None, None))
                    P[p['id']] = [p['name'], p['short_name'], p['nationality'], p['side'], 1 if m['category'] == 'women' else 0, r[0], r[1], p.get('photo_url')]
            teams.append(ids)
        sets = []
        for x in (m.get('score') or []):
            a_, ta = num(x['team_1'])
            b_, tb = num(x['team_2'])
            sets.append([a_, b_])
        Q.append([m['id'], t, 1 if m['category'] == 'women' else 0, m['round'], m.get('played_at'), ST[m['status']], teams[0], teams[1], sets,
                  {'team_1': 0, 'team_2': 1}.get(m.get('winner'))])
print('previas', len(Q), 'partidos')

tids = {m['_t'] for m in raw.values()} | set(tmeta)
T = []
for i in sorted(tids):
    t = tmeta.get(i)
    if not t:
        continue
    T.append([i, t['name'], t['level'], t['location'], t['country'], t['start_date'], t['end_date'], t['court_type'], t['status'], 1 if i in hidden_t else 0, t.get('photo_url')])

# Emisiones de YouTube (youtube.py): cada partido pendiente hasta cuartos se enlaza con la de su pista
import unicodedata


def nrm(x):
    x = unicodedata.normalize('NFD', str(x or '').lower())
    return ' ' + re.sub(r'[^a-z0-9]+', ' ', ''.join(c for c in x if unicodedata.category(c) != 'Mn')).strip() + ' '


def pista(x):
    x = nrm(x)
    if re.search(r' (center|centre|central|centro|main) ', x):
        return 'central'
    n = re.search(r' (?:court|pista|cancha|campo|pist) (\d+) ', x) or re.search(r' (\d+) (?:court|pista) ', x)
    return 'n' + n.group(1) if n else None


GENERIC = {'premier', 'padel', 'major', 'finals', 'final', 'p1', 'p2', 'open', 'fip', 'tour', 'world', 'cup'}
yt = {}
try:
    yt = json.load(open(os.path.join(d_meta, 'youtube.json')))
except Exception:
    pass
yt_videos = yt.get('videos') or []
canales = yt.get('channels') if isinstance(yt.get('channels'), dict) else {}
yt_handles = {'premier': re.sub(r'[^@A-Za-z0-9_.-]', '', canales.get('premier') or '@PremierPadelOfficial'),
              'fip': re.sub(r'[^@A-Za-z0-9_.-]', '', canales.get('fip') or '@padelfip')}
enlazados = 0
if yt_videos:
    for m in M:
        t = tmeta.get(m[1]) or {}
        if m[7] != 3 or m[3] < 4 or not m[6]:   # solo pendientes, hasta cuartos y con pista
            continue
        pk = pista(m[6])
        if not pk:
            continue
        circuito = 'fip' if str(t.get('level') or '').startswith('fip') else 'premier'
        claves = {w for w in (nrm(t.get('name')) + nrm(t.get('location'))).split() if len(w) > 3 and w not in GENERIC and not w.isdigit()}
        mejor = None
        for v in yt_videos:
            tt = nrm(v.get('title'))
            if v.get('circuit', 'premier') != circuito or pista(v.get('title')) != pk or (claves and not any(f' {c} ' in tt for c in claves)):
                continue
            # Preferencia: en directo antes que programada, y en español antes que en inglés
            nota = (v.get('status') == 'live', ' esp ' in tt or ' espanol ' in tt)
            if mejor is None or nota > mejor[0]:
                mejor = (nota, v)
        mejor = mejor and mejor[1]
        if mejor and re.fullmatch(r'[A-Za-z0-9_-]{6,20}', mejor['id']):
            m.append(mejor['id'])
            enlazados += 1
print('youtube', len(yt_videos), 'emisiones,', enlazados, 'partidos enlazados')

has={m[1] for m in M}
T=[t for t in T if t[0] in has or t[9] or t[8]=='pending']
# Fotos propias (fotos/jugadores/<id>.webp|png|jpg) para quien no tiene foto en la API o la tiene peor
propias = 0
for pid, p in P.items():
    for ext in ('webp', 'png', 'jpg'):
        ruta = f'fotos/jugadores/{pid}.{ext}'
        if os.path.exists(ruta):
            p[7] = ruta
            propias += 1
            break
sin_foto = sorted((p[5], p[0], pid) for pid, p in P.items() if not p[7] and p[5] and p[5] <= 100)
print('fotos propias', propias, '· top 100 sin foto:', ', '.join(f'{n} (id {i}, n.º {r})' for r, n, i in sin_foto) or 'ninguno')

data = {'otp': os.environ.get('FANTASY_CODIGO') == '1', 'snap': datetime.date.today().isoformat(), 'rk': rk_from[::-1], 'yt': yt_handles, 'P': P, 'T': T, 'M': M, 'Q': Q}
# Copia de los datos de la app para manager.py (valores y puntos del fantasy)
json.dump(data, open(os.path.join(d_meta, 'app.json'), 'w', encoding='utf-8'), ensure_ascii=False, separators=(',', ':'))
js = json.dumps(data, ensure_ascii=False, separators=(',', ':'))
assert '</' not in js
push = re.sub(r'[^0-9a-fA-F-]', '', os.environ.get('ONESIGNAL_APP_ID', ''))
# Supabase (fantasy): solo la dirección y la clave pública «anon», que pueden ir en la página
s_url = os.environ.get('SUPABASE_URL', '').strip().rstrip('/')
s_key = os.environ.get('SUPABASE_ANON_KEY', '').strip()
supa = {'url': s_url, 'key': s_key} if re.fullmatch(r'https://[a-z0-9-]+\.supabase\.co', s_url) and re.fullmatch(r'[A-Za-z0-9._-]{20,}', s_key) else None
html = open(tpl, encoding='utf-8').read().replace('/*DATA*/null', js).replace('/*PUSH*/""', json.dumps(push)).replace('/*SUPA*/null', json.dumps(supa))
open(out, 'w', encoding='utf-8').write(html)
print('ranking de', rk_from, 'jugadores con ranking', sum(1 for p in P.values() if p[5] is not None))
print('players', len(P), 'tournaments', len(T), 'matches', len(M), 'hidden tournaments', sorted(hidden_t), 'other statuses', other, 'bytes', len(html.encode()))
