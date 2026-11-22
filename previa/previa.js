// Previa de los torneos Premier desde la web oficial (premierpadel.com).
// Padel API solo da la previa en sus planes de pago, así que la leemos de la página pública del torneo:
// un navegador la abre como lo haría una persona, pulsa cada día y cada categoría, y nos quedamos con
// los partidos de previa que la propia página descarga para enseñarlos. Una visita por ejecución.
//
// Uso: node previa/previa.js DATOS   → actualiza DATOS/pp_previa.json (no rompe nada si falla)
const {chromium} = require('playwright');
const fs = require('fs'), path = require('path');

const datos = process.argv[2] || 'datos';
const salida = path.join(datos, 'pp_previa.json');
const WEB = 'https://premierpadel.com/es';

function leer() { try { return JSON.parse(fs.readFileSync(salida, 'utf8')) } catch (e) { return {} } }

(async () => {
  const guardado = leer();
  const b = await chromium.launch();
  try {
    const p = await (await b.newContext({viewport: {width: 1280, height: 900}, locale: 'es-ES'})).newPage();
    // 1) El torneo en juego: la propia web lo anuncia en la cabecera de todas sus páginas
    await p.goto(WEB, {waitUntil: 'domcontentloaded', timeout: 60000});
    const html = await p.content();
    const m = html.match(/initialTournamentStrip\\?":\{\\?"id\\?":\\?"(\d+)\\?",\\?"slug\\?":\\?"([a-z0-9-]+)\\?"/);
    const ini = m && html.slice(m.index, m.index + 3000).match(/start_date_utc\\?":\\?"(\d{4}-\d\d-\d\d)/);
    if (!m || !ini) { console.log('Previa: no hay torneo en la cabecera de premierpadel.com'); return }
    const slug = m[2], start = ini[1];
    console.log('Previa: torneo', slug, 'desde', start);

    // 2) Página del torneo: cada día y cada categoría (la página pide sus partidos al pulsar)
    const ms = new Map();
    p.on('response', async r => {
      if (!r.url().endsWith('/tournament/getTournamentMatches')) return;
      try {
        const d = await r.json();
        for (const ct of (d.data && d.data.courts) || [])
          for (const x of ct.matches || []) ms.set(String(x.match_id), {...x, court: ct.court_name});
      } catch (e) {}
    });
    await p.goto(`${WEB}/tournaments-detail/${slug}`, {waitUntil: 'domcontentloaded', timeout: 60000});
    await p.locator('button').filter({hasText: /^\s*\d+\s*[A-Z]{3}\s*$/}).first().waitFor({timeout: 45000});
    await p.waitForTimeout(2000);
    // pulsa el botón con ese texto (la web abre a los pocos segundos una ventana de registro que tapa la página)
    const pulsa = t => p.evaluate(t => {
      const x = [...document.querySelectorAll('button')].find(b => b.innerText.replace(/\s+/g, ' ').trim().toUpperCase() === t);
      if (x) { x.click(); return true } return false
    }, t);
    const dias = await p.$$eval('button', bs => bs.map(b => b.innerText.replace(/\s+/g, ' ').trim().toUpperCase()).filter(t => /^\d+ [A-Z]{3}$/.test(t)));
    for (const g of ['MASCULINO', 'FEMENINO']) {
      await pulsa(g); await p.waitForTimeout(1500);
      for (const d of dias) { await pulsa(d); await p.waitForTimeout(1800) }
    }

    // 3) Solo la previa, con lo justo
    const previa = [...ms.values()].filter(x => /Q$/.test(x.draw_type || '') || /^Q\d/.test(x.round_name || ''));
    const nuevo = {};
    for (const x of previa) {
      nuevo[x.match_id] = {
        id: String(x.match_id), ronda: x.round_name, fecha: x.date, estado: x.status, ganador: x.winner_id, pista: x.court,
        hora: x.start_date_time,
        equipos: (x.teams || []).map(t => ({
          sets: [1, 2, 3].map(k => [t.score && t.score['set' + k], t.score && t.score['tie' + k]]),
          jugadores: (t.players || []).map(j => ({id: j.player_id, nombre: j.first_name, apellido: j.last_name,
            genero: j.gender, pais: j.country_code, ranking: j.doubles_rank}))
        }))
      };
    }
    const prev = guardado[slug] && guardado[slug].start === start ? guardado[slug].partidos : {};
    guardado[slug] = {slug, start, leido: new Date().toISOString(), partidos: {...prev, ...nuevo}};
    // solo los 4 torneos más recientes
    const ks = Object.keys(guardado).sort((a, z) => (guardado[z].start || '').localeCompare(guardado[a].start || ''));
    ks.slice(4).forEach(k => delete guardado[k]);
    fs.mkdirSync(datos, {recursive: true});
    fs.writeFileSync(salida, JSON.stringify(guardado));
    console.log('Previa:', previa.length, 'partidos leídos ahora,', Object.keys(guardado[slug].partidos).length, 'guardados de', slug);
  } catch (e) {
    console.log('Previa: no se ha podido leer (', String(e.message).split('\n')[0], '); sigo con lo guardado');
  } finally { await b.close() }
})();
