import json, sys, glob, os, re

d_matches, d_meta, tpl, out = sys.argv[1:5]

# Torneos (metadatos de la primera descarga)
tmeta = {}
for f in sorted(glob.glob(os.path.join(d_meta, 'tournaments_*.json'))):
    try:
        for t in json.load(open(f)).get('data', []):
            tmeta[t['id']] = t
    except Exception:
        pass

# Partidos
raw = {}
for f in sorted(glob.glob(os.path.join(d_matches, 't*_matches_*.json'))):
    t = int(re.search(r't(\d+)_matches', f).group(1))
    for m in json.load(open(f)).get('data', []):
        m['_t'] = t
        raw[m['id']] = m

# Ranking y puntos (inscritos en Dubai P1)
rk = {}
for f in sorted(glob.glob(os.path.join(d_matches, 't*_players_*.json'))):
    for p in json.load(open(f)).get('data', []):
        rk[p['id']] = (p.get('ranking'), p.get('points'))

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
                P[p['id']] = [p['name'], p['short_name'], p['nationality'], p['side'], 1 if m['category'] == 'women' else 0, r[0], r[1]]
        teams.append(ids)
    sets = []
    for s in (m['score'] or []):
        a, ta = num(s['team_1'])
        b, tb = num(s['team_2'])
        sets.append([a, b] + ([ta if ta is not None else tb] if (ta is not None or tb is not None) else []))
    w = {'team_1': 0, 'team_2': 1}.get(m['winner'])
    M.append([m['id'], m['_t'], 1 if m['category'] == 'women' else 0, m['round'], m['index'], m['played_at'],
              (m['court'] or '').strip() or None, ST[m['status']], teams[0], teams[1],
              m['seeds']['team_1'], m['seeds']['team_2'], sets, w])

tids = {m['_t'] for m in raw.values()} | {i for i, t in tmeta.items() if t['connections']['season'] == '/api/seasons/5'}
T = []
for i in sorted(tids):
    t = tmeta.get(i)
    if not t:
        continue
    T.append([i, t['name'], t['level'], t['location'], t['country'], t['start_date'], t['end_date'], t['court_type'], t['status'], 1 if i in hidden_t else 0])

has={m[1] for m in M}
T=[t for t in T if t[0] in has or t[9] or t[8]=='pending']
data = {'snap': '2026-11-16', 'P': P, 'T': T, 'M': M}
js = json.dumps(data, ensure_ascii=False, separators=(',', ':'))
assert '</' not in js
html = open(tpl, encoding='utf-8').read().replace('/*DATA*/null', js)
open(out, 'w', encoding='utf-8').write(html)
print('players', len(P), 'tournaments', len(T), 'matches', len(M), 'hidden tournaments', sorted(hidden_t), 'other statuses', other, 'bytes', len(html.encode()))
