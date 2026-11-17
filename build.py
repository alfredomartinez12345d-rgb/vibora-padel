import json, sys, glob, os, re, datetime

d_matches, d_meta, tpl, out = sys.argv[1:5]

# Torneos (metadatos de la primera descarga)
tmeta = {}
for f in sorted(glob.glob(os.path.join(d_meta, 'tournaments_*.json'))):
    try:
        for t in json.load(open(f)).get('data', []):
            tmeta[t['id']] = t
    except Exception:
        pass

# Solo la temporada elegida por descargar.sh (si se guardó)
sf = os.path.join(d_meta, 'season.txt')
if os.path.exists(sf):
    sid = open(sf).read().strip()
    tmeta = {i: t for i, t in tmeta.items() if (t.get('connections') or {}).get('season') == f'/api/seasons/{sid}'}

# Partidos
raw = {}
for f in sorted(glob.glob(os.path.join(d_matches, 't*_matches_*.json'))):
    t = int(re.search(r't(\d+)_matches', f).group(1))
    for m in json.load(open(f)).get('data', []):
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
        for p in json.load(open(f)).get('data', []):
            r = val(p.get('ranking'), 'position', 'ranking', 'rank')
            pts = val(p.get('points'), 'points', 'value')
            if r is not None:
                rk[p['id']] = (int(r), pts)
                n += 1
    if n and t in tmeta:
        rk_from.append(tmeta[t]['name'])

ST = {'finished': 0, 'retired': 1, 'walkover': 2, 'scheduled': 3}
other = {}
hidden_t = set()
P = {}
M = []


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
              m.get('scheduled_at'), 1 if str(m.get('schedule_label') or '').lower().startswith('estimated') else 0, m.get('court_order')])

tids = {m['_t'] for m in raw.values()} | set(tmeta)
T = []
for i in sorted(tids):
    t = tmeta.get(i)
    if not t:
        continue
    T.append([i, t['name'], t['level'], t['location'], t['country'], t['start_date'], t['end_date'], t['court_type'], t['status'], 1 if i in hidden_t else 0, t.get('photo_url')])

has={m[1] for m in M}
T=[t for t in T if t[0] in has or t[9] or t[8]=='pending']
data = {'snap': datetime.date.today().isoformat(), 'rk': rk_from[::-1], 'P': P, 'T': T, 'M': M}
js = json.dumps(data, ensure_ascii=False, separators=(',', ':'))
assert '</' not in js
html = open(tpl, encoding='utf-8').read().replace('/*DATA*/null', js)
open(out, 'w', encoding='utf-8').write(html)
print('ranking de', rk_from, 'jugadores con ranking', sum(1 for p in P.values() if p[5] is not None))
print('players', len(P), 'tournaments', len(T), 'matches', len(M), 'hidden tournaments', sorted(hidden_t), 'other statuses', other, 'bytes', len(html.encode()))
