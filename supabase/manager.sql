-- ============================================================================
-- Fantasy Víbora · MODO MÁNAGER (ligas con amigos, sobre, mercado y cláusulas)
-- Cómo instalarlo: Supabase → SQL Editor → New query → pegar TODO esto → Run.
-- Se puede volver a ejecutar sin perder datos. Necesita la tabla «perfiles»
-- del fantasy anterior (supabase/fantasy.sql), que ya está instalada.
--
-- Reglas:
--   · Ligas de hasta 58 mánagers: solo chicos (M), solo chicas (F) o mixta (X).
--   · Cada jugador solo puede ser de un mánager dentro de la liga.
--   · Al entrar, un sobre con 4 jugadores (2 de relleno, 1 bueno del 21 al 40
--     y 1 estrella; el top 6 sale muy poco) que vale entre 45 y 60 M, y 100 M para fichar.
--   · Plantilla de 6 como máximo; se alinean 4: 2 revés + 2 drive (y en mixta,
--     2 chicos + 2 chicas), con una Pala de Oro que puntúa doble.
--   · Mercado diario de 8 jugadores libres; cierra cada día a la hora en que se
--     creó la liga (hora de Madrid). Pujas ciegas; gana la más alta.
--   · Cláusulas (si la liga las tiene): se pueden pagar para quedarse un
--     jugador de otro al momento; el dueño puede blindarlas.
--   · Cuando empieza un torneo Premier se congelan las alineaciones (GitHub);
--     al acabar se cobran 0,2 M por punto. Si empiezas en negativo, 0 puntos.
--     Los Major puntúan doble.
--   · Lo que pongas en venta recibe cada día una oferta de la liga (valor ± 10 %).
-- Los valores, el bloqueo y los puntos los escribe GitHub con la clave
-- service_role; los usuarios solo actúan a través de las funciones m_*.
-- ============================================================================

-- --- Tablas ------------------------------------------------------------------
create table if not exists public.m_jugadores (
  id          int primary key,
  nombre      text not null,
  corto       text,
  genero      char(1) not null check (genero in ('M', 'F')),
  lado        char(1) check (lado in ('R', 'D')),
  rank        int,
  valor       numeric(5,1) not null check (valor > 0),
  actualizado timestamptz not null default now()
);

create table if not exists public.m_estado (
  id            int primary key default 1 check (id = 1),
  bloqueado     boolean not null default false,
  torneo        int,
  torneo_nombre text,
  actualizado   timestamptz not null default now()
);
insert into public.m_estado (id) values (1) on conflict do nothing;

create table if not exists public.m_torneos (
  id      int primary key,
  nombre  text not null,
  inicio  timestamptz not null default now(),
  pagado  boolean not null default false
);

create table if not exists public.m_puntos (
  torneo   int not null,
  jugador  int not null,
  puntos   numeric(5,1) not null,
  detalle  jsonb,
  primary key (torneo, jugador)
);

create table if not exists public.m_ligas (
  id         uuid primary key default gen_random_uuid(),
  nombre     text not null check (char_length(nombre) between 3 and 30),
  codigo     text not null unique,
  genero     char(1) not null check (genero in ('M', 'F', 'X')),
  clausulas  boolean not null default true,
  hora       time not null,
  cierre     timestamptz not null,
  mercado    int[] not null default '{}',
  creador    uuid references public.perfiles on delete set null,
  creada     timestamptz not null default now()
);

create table if not exists public.m_miembros (
  liga         uuid not null references public.m_ligas on delete cascade,
  user_id      uuid not null references public.perfiles on delete cascade,
  caja         numeric(6,1) not null,
  sobre        int[] not null default '{}',
  sobre_visto  boolean not null default false,
  clausulazo   date,
  unido        timestamptz not null default now(),
  primary key (liga, user_id)
);

create table if not exists public.m_plantilla (
  liga       uuid not null,
  jugador    int not null references public.m_jugadores,
  user_id    uuid not null,
  precio     numeric(6,1) not null,
  clausula   numeric(6,1) not null,
  protegido  timestamptz not null default now(),
  venta      numeric(6,1),
  desde      timestamptz not null default now(),
  primary key (liga, jugador),
  foreign key (liga, user_id) references public.m_miembros on delete cascade
);
create index if not exists m_plantilla_user on public.m_plantilla (liga, user_id);

create table if not exists public.m_alineacion (
  liga       uuid not null,
  user_id    uuid not null,
  jugadores  int[] not null default '{}',
  capitan    int,
  primary key (liga, user_id),
  foreign key (liga, user_id) references public.m_miembros on delete cascade
);

create table if not exists public.m_pujas (
  liga      uuid not null,
  user_id   uuid not null,
  jugador   int not null,
  cantidad  numeric(6,1) not null check (cantidad > 0),
  creada    timestamptz not null default now(),
  primary key (liga, user_id, jugador),
  foreign key (liga, user_id) references public.m_miembros on delete cascade
);

create table if not exists public.m_fotos (
  liga       uuid not null,
  user_id    uuid not null,
  torneo     int not null,
  jugadores  int[] not null,
  capitan    int,
  negativo   boolean not null default false,
  primary key (liga, user_id, torneo),
  foreign key (liga, user_id) references public.m_miembros on delete cascade
);

create table if not exists public.m_actividad (
  id        bigserial primary key,
  liga      uuid not null references public.m_ligas on delete cascade,
  cuando    timestamptz not null default now(),
  tipo      text not null,
  quien     uuid,
  otro      uuid,
  jugador   int,
  cantidad  numeric(6,1)
);
create index if not exists m_actividad_liga on public.m_actividad (liga, cuando desc);

-- Valor de referencia: el que tenía al acabar el último torneo (entre torneos cambia como mucho un 10 %)
alter table public.m_jugadores add column if not exists ref numeric(5,1);
alter table public.m_jugadores add column if not exists ref_torneo int;

-- Avisos al móvil (OneSignal): configuración y control para no repetir avisos
alter table public.m_ligas  add column if not exists aviso10 timestamptz;          -- último «cierra en 10 min» enviado
alter table public.m_ligas  add column if not exists publica boolean not null default false;   -- liga pública (sin dueño, entra cualquiera)
alter table public.m_miembros add column if not exists visto timestamptz;            -- última vez que abrió la liga
-- A quién ya se le ha recordado que no tiene liga (solo una vez)
create table if not exists public.m_recordado (
  user_id uuid primary key references public.perfiles on delete cascade,
  cuando  timestamptz not null default now()
);
alter table public.m_estado add column if not exists proximo int;                  -- próximo torneo Premier (lo pone GitHub)
alter table public.m_estado add column if not exists proximo_nombre text;
alter table public.m_estado add column if not exists proximo_bloqueo timestamptz;  -- cuándo se congelan las alineaciones
alter table public.m_estado add column if not exists aviso_bloqueo int;            -- torneo del que ya se avisó
alter table public.m_estado add column if not exists abierto_hasta timestamptz;    -- excepción: con el torneo empezado, se puede alinear y negociar hasta esta hora
create table if not exists public.m_config (clave text primary key, valor text);
create table if not exists public.m_avisos (user_id uuid primary key references public.perfiles on delete cascade, activo boolean not null default true);
insert into public.m_config values ('onesignal_app', '6f1f07fb-b432-4b84-9fb0-3367f1be7e51'),
  ('app_url', 'https://alfredomartinez12345d-rgb.github.io/vibora-padel/') on conflict (clave) do nothing;

create table if not exists public.m_ofertas (
  id        bigserial primary key,
  liga      uuid not null references public.m_ligas on delete cascade,
  de        uuid not null,
  para      uuid not null,
  jugador   int not null,
  cantidad  numeric(6,1) not null check (cantidad > 0),
  estado    text not null default 'pendiente' check (estado in ('pendiente', 'aceptada', 'rechazada', 'cancelada')),
  creada    timestamptz not null default now(),
  resuelta  timestamptz
);
create index if not exists m_ofertas_liga on public.m_ofertas (liga, estado);
-- Las ofertas de la propia liga (por lo que está en venta) no tienen «de»
alter table public.m_ofertas alter column de drop not null;

-- --- Reglas en un solo sitio ---------------------------------------------------
create or replace function public.m_cfg(k text) returns numeric
language sql immutable as $$
  select case k
    when 'patrimonio' then 150      -- (antiguo) valor del sobre + caja al entrar
    when 'caja_min'   then 10       -- (antiguo) caja mínima al entrar
    when 'caja_ini'   then 100      -- dinero para fichar al entrar
    when 'inactivo_dias' then 21    -- días sin entrar para salir de una liga pública
    when 'sobre_min'  then 45       -- valor mínimo del sobre inicial
    when 'sobre_max'  then 60       -- valor máximo del sobre inicial
    when 'liga_oferta' then 0.10    -- la liga ofrece por lo que está en venta: valor ± 10 %
    when 'plantilla'  then 6        -- jugadores como máximo
    when 'miembros'   then 58       -- mánagers por liga
    when 'mercado'    then 8        -- jugadores libres en el mercado diario
    when 'credito'    then 0.2      -- se puede pujar hasta caja + 20 % de la plantilla
    when 'clausula'   then 1.25     -- cláusula inicial = 1,25 × lo pagado
    when 'blindaje'   then 1.5      -- se puede blindar hasta 1,5 × el valor
    when 'proteccion' then 7        -- días sin poder pagar su cláusula tras ficharlo (o tras el sobre)
    when 'venganza'   then 7        -- días sin poder recuperar a quien te clausularon
    when 'por_punto'  then 0.2      -- millones por punto al acabar cada torneo
    when 'top'        then 100      -- solo se fichan jugadores del top 100 de su ranking
    when 'oferta_h'   then 48       -- horas que dura una oferta entre amigos
  end
$$;

-- --- Ayudantes -------------------------------------------------------------------
create or replace function public.m_bloqueado() returns boolean
language sql stable as $$
  select coalesce((select bloqueado and not coalesce(abierto_hasta > now(), false) from public.m_estado where id = 1), false) $$;

create or replace function public.m_soy(p_liga uuid) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Entra en el fantasy primero.'; end if;
  if not exists (select 1 from m_miembros where liga = p_liga and user_id = auth.uid()) then
    raise exception 'No estás en esta liga.';
  end if;
end $$;

create or replace function public.m_valor_plantilla(p_liga uuid, p_user uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(j.valor), 0) from m_plantilla p join m_jugadores j on j.id = p.jugador
  where p.liga = p_liga and p.user_id = p_user
$$;

create or replace function public.m_quitar_de_alineacion(p_liga uuid, p_user uuid, p_jugador int) returns void
language sql security definer set search_path = public as $$
  update m_alineacion set jugadores = array_remove(jugadores, p_jugador),
         capitan = case when capitan = p_jugador then null else capitan end
  where liga = p_liga and user_id = p_user
$$;

create or replace function public.m_log(p_liga uuid, p_tipo text, p_quien uuid, p_otro uuid, p_jugador int, p_cantidad numeric)
returns void language sql security definer set search_path = public as $$
  insert into m_actividad (liga, tipo, quien, otro, jugador, cantidad) values (p_liga, p_tipo, p_quien, p_otro, p_jugador, p_cantidad)
$$;

-- Aviso al móvil (OneSignal) a unos usuarios. Nunca rompe la acción que lo llama:
-- si falta la clave (Vault: onesignal_rest_key) o la extensión pg_net, no hace nada.
create or replace function public.m_push(p_users uuid[], p_titulo text, p_texto text) returns void
language plpgsql security definer set search_path = public as $$
declare v_app text; v_url text; v_key text;
begin
  -- solo a quien ha activado los avisos del fantasy en la app
  p_users := array(select x from unnest(p_users) x where exists (select 1 from m_avisos a where a.user_id = x and a.activo));
  if coalesce(array_length(p_users, 1), 0) = 0 then return; end if;
  select c.valor into v_app from m_config c where c.clave = 'onesignal_app';
  select c.valor into v_url from m_config c where c.clave = 'app_url';
  if v_app is null then return; end if;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1 limit 1' into v_key using 'onesignal_rest_key';
  if v_key is null or trim(v_key) = '' then return; end if;
  execute 'select net.http_post(url := $1, body := $2, headers := $3)'
    using 'https://api.onesignal.com/notifications?c=push',
          jsonb_build_object('app_id', v_app, 'target_channel', 'push',
            'include_aliases', jsonb_build_object('external_id', to_jsonb(p_users::text[])),
            'headings', jsonb_build_object('en', p_titulo, 'es', p_titulo),
            'contents', jsonb_build_object('en', p_texto, 'es', p_texto),
            'url', coalesce(v_url, '') || '#fantasy'),
          jsonb_build_object('Content-Type', 'application/json', 'Authorization', 'Key ' || trim(both E' \n\r\t' from v_key));
exception when others then
  null;   -- un aviso que falla nunca rompe la jugada
end $$;

create or replace function public.m_fmt(x numeric) returns text
language sql immutable as $$
  select case when round(x, 1) = trunc(round(x, 1)) then trunc(round(x, 1))::text else replace(round(x, 1)::text, '.', ',') end || ' M' $$;
create or replace function public.m_jn(p_jugador int) returns text
language sql stable security definer set search_path = public as $$ select coalesce(corto, nombre, 'un jugador') from m_jugadores where id = p_jugador $$;
create or replace function public.m_un(p_user uuid) returns text
language sql stable security definer set search_path = public as $$ select coalesce((select nombre from perfiles where id = p_user), 'Alguien') $$;

-- Jugadores que se pueden fichar en una liga (libres, del género de la liga y con lado)
create or replace function public.m_libres(p_liga uuid) returns setof public.m_jugadores
language sql stable security definer set search_path = public as $$
  select j.* from m_jugadores j, m_ligas l
  where l.id = p_liga and j.lado is not null and (l.genero = 'X' or j.genero = l.genero)
    -- solo el top 100 de cada ranking; en ligas de más de 16 mánagers entran todos para que haya jugadores para todos
    and (coalesce(j.rank, 999) <= m_cfg('top') or (select count(*) from m_miembros m where m.liga = p_liga) > 16)
    and not exists (select 1 from m_plantilla p where p.liga = p_liga and p.jugador = j.id)
$$;

-- Escoge un jugador libre al azar (con peso) según rango, género y lado
create or replace function public.m_escoger(p_liga uuid, p_rmin int, p_rmax int, p_genero char, p_lado char, p_excluir int[])
returns int language sql volatile security definer set search_path = public as $$
  select id from m_libres(p_liga)
  where coalesce(rank, 999) between p_rmin and p_rmax
    and (p_genero is null or genero = p_genero) and (p_lado is null or lado = p_lado)
    and not (id = any(coalesce(p_excluir, '{}')))
    and not (id = any(coalesce((select mercado from m_ligas where id = p_liga), '{}')))   -- los del mercado de hoy no salen en sobres
  order by -ln(greatest(random(), 1e-9)) /
           case when p_rmax <= 20 then case when rank <= 4 then 0.1 when rank <= 6 then 0.4 else 1 end else 1 end
  limit 1
$$;

-- Nuevo mercado: 8 jugadores libres al azar
create or replace function public.m_nuevo_mercado(p_liga uuid) returns void
language sql security definer set search_path = public as $$
  update m_ligas set mercado = coalesce((
    select array_agg(id) from (select id from m_libres(p_liga)
                               order by random() limit m_cfg('mercado')::int) x), '{}')
  where id = p_liga
$$;

create or replace function public.m_quitar_uno(a char[], x char) returns char[]
language plpgsql immutable as $$
declare i int;
begin
  for i in 1..coalesce(array_length(a, 1), 0) loop
    if a[i] = x then return a[1:i-1] || a[i+1:]; end if;
  end loop;
  return a;
end $$;

-- Sobre: 4 jugadores que forman una alineación válida
create or replace function public.m_dar_sobre(p_liga uuid, p_user uuid) returns int[]
language plpgsql security definer set search_path = public as $$
declare
  g char; est int; bue int; r1 int; r2 int; ge char; gb char; le char; lb char;
  lados char[]; generos char[]; elegidos int[]; v numeric; mejor int[]; mejor_d numeric := 1e9; d numeric; intento int;
  vmin numeric := m_cfg('sobre_min'); vmax numeric := m_cfg('sobre_max');
begin
  select genero into g from m_ligas where id = p_liga;
  -- Se prueban varios sobres hasta que su valor quede entre 45 y 60 M (si no, el más cercano)
  for intento in 1..40 loop
    est := m_escoger(p_liga, 1, 20, case when g = 'X' then null else g end, null, null);
    -- en ligas grandes se acaban las estrellas: entonces el mejor del sobre sale del 21-40 o de más abajo
    if est is null then est := m_escoger(p_liga, 21, 40, case when g = 'X' then null else g end, null, null); end if;
    if est is null then est := m_escoger(p_liga, 41, 999, case when g = 'X' then null else g end, null, null); end if;
    exit when est is null;
    select genero, lado into ge, le from m_jugadores where id = est;
    bue := m_escoger(p_liga, 21, 40, case when g = 'X' then (case ge when 'M' then 'F' else 'M' end) else g end, null, array[est]);
    if bue is null then bue := m_escoger(p_liga, 21, 999, case when g = 'X' then (case ge when 'M' then 'F' else 'M' end) else g end, null, array[est]); end if;
    continue when bue is null;
    select genero, lado into gb, lb from m_jugadores where id = bue;
    -- Lados y géneros que faltan para 2 revés + 2 drive (y 2 + 2 en mixta)
    lados := m_quitar_uno(m_quitar_uno(array['R','R','D','D']::char[], le), lb);
    if g = 'X' then generos := array['M','F']; else generos := array[g, g]; end if;
    if random() < 0.5 then lados := array[lados[2], lados[1]]; end if;
    elegidos := array[est, bue];
    r1 := m_escoger(p_liga, 41, 100, generos[1], lados[1], elegidos);
    if r1 is null then r1 := m_escoger(p_liga, 21, 999, generos[1], lados[1], elegidos); end if;
    continue when r1 is null;
    elegidos := elegidos || r1;
    r2 := m_escoger(p_liga, 41, 100, generos[2], lados[2], elegidos);
    if r2 is null then r2 := m_escoger(p_liga, 21, 999, generos[2], lados[2], elegidos); end if;
    continue when r2 is null;
    select sum(valor) into v from m_jugadores where id = any(array[r1, r2, bue, est]);
    d := greatest(vmin - v, v - vmax, 0);
    if d < mejor_d then mejor_d := d; mejor := array[r1, r2, bue, est]; end if;   -- orden del sobre: de peor a mejor
    exit when d = 0;
  end loop;
  if mejor is null then raise exception 'Esta liga ya no tiene jugadores libres para repartir más sobres. Las ligas solo masculinas o solo femeninas tienen menos jugadores: para ligas muy grandes, crea una liga mixta.'; end if;
  elegidos := mejor;
  -- Si el sobre vale menos de 45 M (en ligas grandes se acaban los buenos), la diferencia va a la caja
  select sum(valor) into v from m_jugadores where id = any(elegidos);
  insert into m_plantilla (liga, jugador, user_id, precio, clausula, protegido)
    select p_liga, j.id, p_user, j.valor, round(j.valor * m_cfg('clausula'), 1), now() + make_interval(days => m_cfg('proteccion')::int)
    from m_jugadores j where j.id = any(elegidos);
  update m_miembros set caja = m_cfg('caja_ini') + greatest(vmin - coalesce(v, vmin), 0), sobre = elegidos
    where liga = p_liga and user_id = p_user;
  insert into m_alineacion (liga, user_id, jugadores, capitan) values (p_liga, p_user, elegidos, elegidos[4])
    on conflict (liga, user_id) do update set jugadores = excluded.jugadores, capitan = excluded.capitan;
  return elegidos;
end $$;


-- --- Mercado: cierre diario ---------------------------------------------------------
create or replace function public.m_procesar(p_liga uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  l m_ligas; b record; hechos int[] := '{}'; cnt int; v numeric; cred numeric; vend record; val numeric; ganadas text[] := '{}'; r record;
begin
  select * into l from m_ligas where id = p_liga for update;
  if l.id is null or now() < l.cierre then return; end if;
  -- Pujas de mayor a menor: cada jugador para la puja más alta que se pueda pagar
  for b in
    select pu.*, j.valor from m_pujas pu join m_jugadores j on j.id = pu.jugador
    where pu.liga = p_liga order by pu.cantidad desc, pu.creada
  loop
    continue when b.jugador = any(hechos);
    select * into vend from m_plantilla where liga = p_liga and jugador = b.jugador;
    if vend.jugador is not null then
      -- Solo si sigue en venta, no es suyo y llega al mínimo
      continue when vend.venta is null or vend.user_id = b.user_id or b.cantidad < vend.venta;
    else
      continue when not (b.jugador = any(l.mercado));
    end if;
    select count(*) into cnt from m_plantilla where liga = p_liga and user_id = b.user_id;
    continue when cnt >= m_cfg('plantilla');
    select caja into v from m_miembros where liga = p_liga and user_id = b.user_id;
    cred := v + m_cfg('credito') * m_valor_plantilla(p_liga, b.user_id);
    continue when b.cantidad > cred;
    if vend.jugador is not null then
      update m_miembros set caja = caja + b.cantidad where liga = p_liga and user_id = vend.user_id;
      perform m_quitar_de_alineacion(p_liga, vend.user_id, b.jugador);
      delete from m_plantilla where liga = p_liga and jugador = b.jugador;
      perform m_log(p_liga, 'vende', vend.user_id, b.user_id, b.jugador, b.cantidad);
      perform m_push(array[vend.user_id], '🏷️ Vendido', m_jn(b.jugador) || ' se va con ' || m_un(b.user_id) || ' por ' || m_fmt(b.cantidad) || ' en «' || l.nombre || '».');
    end if;
    insert into m_plantilla (liga, jugador, user_id, precio, clausula, protegido)
      values (p_liga, b.jugador, b.user_id, b.cantidad,
              round(greatest(b.cantidad, b.valor) * m_cfg('clausula'), 1), now() + make_interval(days => m_cfg('proteccion')::int));
    update m_miembros set caja = caja - b.cantidad where liga = p_liga and user_id = b.user_id;
    perform m_log(p_liga, 'ficha', b.user_id, vend.user_id, b.jugador, b.cantidad);
    perform m_push(array[b.user_id], '💰 ¡Puja ganada!', m_jn(b.jugador) || ' es tuyo por ' || m_fmt(b.cantidad) || ' en «' || l.nombre || '».');
    hechos := hechos || b.jugador;
    ganadas := ganadas || (b.user_id::text || ':' || b.jugador);
  end loop;
  -- Lo que sigue en venta recibe cada día una oferta de la propia liga: su valor ± 10 %.
  -- La de ayer caduca; el dueño la acepta o la rechaza desde el vestuario.
  update m_ofertas set estado = 'cancelada', resuelta = now() where liga = p_liga and de is null and estado = 'pendiente';
  for vend in select p.*, j.valor from m_plantilla p join m_jugadores j on j.id = p.jugador
              where p.liga = p_liga and p.venta is not null loop
    val := round(vend.valor * (1 - m_cfg('liga_oferta') + random()::numeric * 2 * m_cfg('liga_oferta')), 1);
    insert into m_ofertas (liga, de, para, jugador, cantidad) values (p_liga, null, vend.user_id, vend.jugador, greatest(val, 0.5));
    perform m_push(array[vend.user_id], '🏷️ Oferta de la liga', 'La liga te ofrece ' || m_fmt(greatest(val, 0.5)) || ' por ' || m_jn(vend.jugador) || ' en «' || l.nombre || '». Tienes hasta mañana para aceptarla.');
  end loop;
  -- Pujas perdidas: un aviso por mánager con todos los jugadores
  for r in select pu.user_id, string_agg(m_jn(pu.jugador), ', ') as js from m_pujas pu
           where pu.liga = p_liga and not ((pu.user_id::text || ':' || pu.jugador) = any(ganadas)) group by pu.user_id loop
    perform m_push(array[r.user_id], '😬 Puja perdida', 'No te has llevado a ' || r.js || ' en «' || l.nombre || '».');
  end loop;
  delete from m_pujas where liga = p_liga;
  perform m_nuevo_mercado(p_liga);
  -- Siguiente cierre: mañana a la misma hora (si se saltó algún día, el próximo futuro)
  update m_ligas set cierre = cierre + make_interval(days => greatest(1, ceil(extract(epoch from now() - cierre) / 86400)::int))
    where id = p_liga;
  update m_ligas set cierre = cierre + interval '1 day' where id = p_liga and cierre <= now();
  perform m_log(p_liga, 'mercado', null, null, null, null);
  -- Quien se ha quedado en negativo
  for r in select user_id, caja from m_miembros where liga = p_liga and caja < 0 loop
    perform m_push(array[r.user_id], '⚠️ Estás en negativo', 'Tienes ' || m_fmt(r.caja) || ' en «' || l.nombre || '». Vende antes del torneo o no puntuarás.');
  end loop;
end $$;

-- --- Crear, ver y unirse a ligas -------------------------------------------------------
create or replace function public.m_crear_liga(p_nombre text, p_genero char, p_clausulas boolean)
returns uuid language plpgsql security definer set search_path = public as $$
declare cod text; id_ uuid; ahora timestamptz := date_trunc('minute', now());
begin
  if auth.uid() is null or not exists (select 1 from perfiles where id = auth.uid()) then
    raise exception 'Elige antes tu nombre de mánager.';
  end if;
  if p_genero not in ('M', 'F', 'X') then raise exception 'Elige a quién se puede fichar.'; end if;
  if (select count(*) from m_ligas where creador = auth.uid() and creada > now() - interval '1 day') >= 5 then
    raise exception 'Has creado muchas ligas hoy. Prueba mañana.';
  end if;
  loop
    cod := (select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1), '')
            from generate_series(1, 6));
    exit when not exists (select 1 from m_ligas where codigo = cod);
  end loop;
  insert into m_ligas (nombre, codigo, genero, clausulas, hora, cierre, creador)
    values (upper(trim(p_nombre)), cod, p_genero, coalesce(p_clausulas, true),
            (ahora at time zone 'Europe/Madrid')::time, ahora + interval '1 day', auth.uid())
    returning id into id_;
  insert into m_miembros (liga, user_id, caja) values (id_, auth.uid(), 0);
  perform m_dar_sobre(id_, auth.uid());
  perform m_nuevo_mercado(id_);
  perform m_log(id_, 'crea', auth.uid(), null, null, null);
  return id_;
end $$;

create or replace function public.m_ver_liga(p_codigo text)
returns table (nombre text, genero char, clausulas boolean, miembros bigint, lleno boolean)
language sql stable security definer set search_path = public as $$
  select l.nombre, l.genero, l.clausulas, count(m.user_id), count(m.user_id) >= m_cfg('miembros')
  from m_ligas l left join m_miembros m on m.liga = l.id
  where l.codigo = upper(trim(p_codigo)) group by l.id
$$;

create or replace function public.m_unirse(p_codigo text)
returns uuid language plpgsql security definer set search_path = public as $$
declare l m_ligas;
begin
  if auth.uid() is null or not exists (select 1 from perfiles where id = auth.uid()) then
    raise exception 'Elige antes tu nombre de mánager.';
  end if;
  select * into l from m_ligas where codigo = upper(trim(p_codigo)) for update;
  if l.id is null then raise exception 'No hay ninguna liga con ese código.'; end if;
  if exists (select 1 from m_miembros where liga = l.id and user_id = auth.uid()) then return l.id; end if;
  if (select count(*) from m_miembros where liga = l.id) >= m_cfg('miembros') then
    raise exception 'Esta liga ya está llena (% mánagers).', m_cfg('miembros');
  end if;
  insert into m_miembros (liga, user_id, caja) values (l.id, auth.uid(), 0);
  perform m_dar_sobre(l.id, auth.uid());
  perform m_log(l.id, 'entra', auth.uid(), null, null, null);
  return l.id;
end $$;

-- Liga pública: entra en la que tenga sitio (se llenan por orden); si están todas llenas, se crea otra
create or replace function public.m_unirse_publica()
returns uuid language plpgsql security definer set search_path = public as $$
declare id_ uuid; cod text; n int; ahora timestamptz := date_trunc('minute', now());
begin
  if auth.uid() is null or not exists (select 1 from perfiles where id = auth.uid()) then
    raise exception 'Elige antes tu nombre de mánager.';
  end if;
  -- si ya está en una pública, a esa
  select l.id into id_ from m_ligas l join m_miembros m on m.liga = l.id where l.publica and m.user_id = auth.uid() limit 1;
  if id_ is not null then return id_; end if;
  perform pg_advisory_xact_lock(hashtext('vibora-liga-publica'));   -- que dos a la vez no creen dos ligas
  select l.id into id_ from m_ligas l
    where l.publica and (select count(*) from m_miembros m where m.liga = l.id) < m_cfg('miembros')
    order by l.creada limit 1;
  if id_ is null then
    select count(*) + 1 into n from m_ligas where publica;
    loop
      cod := (select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + floor(random() * 32)::int, 1), '')
              from generate_series(1, 6));
      exit when not exists (select 1 from m_ligas where codigo = cod);
    end loop;
    insert into m_ligas (nombre, codigo, genero, clausulas, hora, cierre, creador, publica)
      values ('LIGA VÍBORA ' || n, cod, 'X', true, (ahora at time zone 'Europe/Madrid')::time, ahora + interval '1 day', null, true)
      returning id into id_;
    perform m_nuevo_mercado(id_);
  end if;
  insert into m_miembros (liga, user_id, caja, visto) values (id_, auth.uid(), 0, now());
  perform m_dar_sobre(id_, auth.uid());
  perform m_log(id_, 'entra', auth.uid(), null, null, null);
  return id_;
end $$;

create or replace function public.m_salir(p_liga uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform m_soy(p_liga);
  delete from m_pujas where liga = p_liga and user_id = auth.uid();
  delete from m_miembros where liga = p_liga and user_id = auth.uid();
  if not exists (select 1 from m_miembros where liga = p_liga) then delete from m_ligas where id = p_liga; return; end if;
  update m_ligas set creador = (select user_id from m_miembros where liga = p_liga order by unido limit 1)
    where id = p_liga and creador = auth.uid() and not publica;
  perform m_log(p_liga, 'sale', auth.uid(), null, null, null);
end $$;

-- El creador de la liga puede echar a un mánager (sus jugadores vuelven a quedar libres)
create or replace function public.m_echar(p_liga uuid, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform m_soy(p_liga);
  if (select creador from m_ligas where id = p_liga) is distinct from auth.uid() then
    raise exception 'Solo quien creó la liga puede echar a alguien.';
  end if;
  if p_user = auth.uid() then raise exception 'No te puedes echar a ti mismo.'; end if;
  if not exists (select 1 from m_miembros where liga = p_liga and user_id = p_user) then raise exception 'Ese mánager ya no está en la liga.'; end if;
  perform m_log(p_liga, 'echa', auth.uid(), p_user, null, null);
  perform m_push(array[p_user], '🚪 Fuera de la liga', 'Ya no estás en «' || (select nombre from m_ligas where id = p_liga) || '».');
  delete from m_pujas where liga = p_liga and user_id = p_user;
  delete from m_miembros where liga = p_liga and user_id = p_user;
end $$;

-- Puntos de un mánager en un torneo (Pala de Oro doble; en negativo, 0)
create or replace function public.m_pts_foto(f public.m_fotos) returns numeric
language sql stable security definer set search_path = public as $$
  select case when f.negativo then 0 else coalesce((
    select sum(p.puntos * case when p.jugador = f.capitan then 2 else 1 end)
    from m_puntos p where p.torneo = f.torneo and p.jugador = any(f.jugadores)), 0) end
$$;

drop function if exists public.m_mis_ligas();
create or replace function public.m_mis_ligas()
returns table (id uuid, nombre text, genero char, clausulas boolean, miembros bigint, puesto bigint, total numeric, sobre_visto boolean, publica boolean)
language sql stable security definer set search_path = public as $$
  with mias as (select liga, sobre_visto from m_miembros where user_id = auth.uid()),
  tot as (
    select m.liga, m.user_id, coalesce((select sum(m_pts_foto(f)) from m_fotos f where f.liga = m.liga and f.user_id = m.user_id), 0) as total
    from m_miembros m where m.liga in (select liga from mias)),
  pos as (select liga, user_id, total, rank() over (partition by liga order by total desc) as puesto, count(*) over (partition by liga) as n from tot)
  select l.id, l.nombre, l.genero, l.clausulas, p.n, p.puesto, p.total, mi.sobre_visto, l.publica
  from mias mi join m_ligas l on l.id = mi.liga join pos p on p.liga = l.id and p.user_id = auth.uid()
  order by l.creada
$$;

-- Todo lo que necesita la app para pintar una liga
create or replace function public.m_liga(p_liga uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare yo uuid := auth.uid(); bloq boolean := m_bloqueado(); r jsonb;
begin
  perform m_soy(p_liga);
  update m_miembros set visto = now() where liga = p_liga and user_id = yo and (visto is null or visto < now() - interval '1 hour');
  perform m_procesar(p_liga);
  select jsonb_build_object(
    'liga', (select jsonb_build_object('id', l.id, 'nombre', l.nombre, 'codigo', l.codigo, 'genero', l.genero,
              'clausulas', l.clausulas, 'cierre', l.cierre, 'mercado', l.mercado, 'creador', l.creador, 'publica', l.publica) from m_ligas l where l.id = p_liga),
    'ofertas', (select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'de', o.de, 'para', o.para,
                 'de_nombre', (select nombre from perfiles where id = o.de), 'para_nombre', (select nombre from perfiles where id = o.para), 'jugador', o.jugador, 'cantidad', o.cantidad,
                 'estado', case when o.estado = 'pendiente' and o.creada < now() - make_interval(hours => m_cfg('oferta_h')::int) then 'caducada' else o.estado end,
                 'creada', o.creada) order by o.creada desc), '[]')
                from m_ofertas o where o.liga = p_liga and (o.de = yo or o.para = yo) and o.creada > now() - interval '7 days'),
    'estado', (select to_jsonb(e) || jsonb_build_object('bloqueado', m_bloqueado()) from m_estado e where id = 1),
    'yo', (select jsonb_build_object('id', yo, 'avisos', coalesce((select activo from m_avisos where user_id = yo), false), 'caja', caja, 'sobre', sobre, 'sobre_visto', sobre_visto,
              'clausulazo_hoy', clausulazo = (now() at time zone 'Europe/Madrid')::date)
           from m_miembros where liga = p_liga and user_id = yo),
    'alineacion', (select jsonb_build_object('jugadores', jugadores, 'capitan', capitan) from m_alineacion where liga = p_liga and user_id = yo),
    'miembros', (select jsonb_agg(jsonb_build_object('id', m.user_id, 'nombre', pf.nombre,
                   'valor', m_valor_plantilla(p_liga, m.user_id),
                   'jugadores', (select coalesce(jsonb_agg(jsonb_build_object('id', p.jugador, 'clausula', p.clausula,
                                   'protegido', p.protegido, 'venta', p.venta, 'precio', case when m.user_id = yo then p.precio end) order by j.valor desc), '[]')
                                 from m_plantilla p join m_jugadores j on j.id = p.jugador where p.liga = p_liga and p.user_id = m.user_id))
                 order by m.unido)
                 from m_miembros m join perfiles pf on pf.id = m.user_id where m.liga = p_liga),
    'pujas', (select coalesce(jsonb_agg(jsonb_build_object('jugador', jugador, 'cantidad', cantidad)), '[]') from m_pujas where liga = p_liga and user_id = yo),
    -- cuántas pujas tiene cada jugador (de todos los mánagers); las cantidades siguen siendo secretas
    'npujas', (select coalesce(jsonb_object_agg(jugador, n), '{}') from (select jugador, count(*) n from m_pujas where liga = p_liga group by jugador) x),
    'fotos', (select coalesce(jsonb_agg(jsonb_build_object('user', f.user_id, 'torneo', f.torneo, 'jugadores', f.jugadores,
                 'capitan', f.capitan, 'negativo', f.negativo, 'puntos', m_pts_foto(f))), '[]') from m_fotos f where f.liga = p_liga),
    'torneos', (select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'nombre', t.nombre, 'inicio', t.inicio) order by t.inicio), '[]')
                from m_torneos t where exists (select 1 from m_fotos f where f.liga = p_liga and f.torneo = t.id)),
    'venganza', (select coalesce(jsonb_agg(distinct a.jugador), '[]') from m_actividad a
                 where a.liga = p_liga and a.tipo = 'clausula' and a.otro = yo and a.cuando > now() - make_interval(days => m_cfg('venganza')::int)),
    'actividad', (select coalesce(jsonb_agg(x order by x.cuando desc), '[]') from (
                   select a.cuando, a.tipo, a.jugador, a.cantidad, q.nombre as quien, o.nombre as otro
                   from m_actividad a left join perfiles q on q.id = a.quien left join perfiles o on o.id = a.otro
                   where a.liga = p_liga and a.tipo <> 'mercado' order by a.cuando desc limit 40) x)
  ) into r;
  return r;
end $$;

create or replace function public.m_sobre_visto(p_liga uuid) returns void
language sql security definer set search_path = public as $$
  update m_miembros set sobre_visto = true where liga = p_liga and user_id = auth.uid()
$$;

-- --- Acciones del mánager --------------------------------------------------------------
create or replace function public.m_alinear(p_liga uuid, p_jugadores int[], p_capitan int)
returns void language plpgsql security definer set search_path = public as $$
declare g char; n int; r int; d int; hm int; mu int;
begin
  perform m_soy(p_liga);
  if m_bloqueado() then raise exception 'Se está jugando un torneo: las alineaciones están bloqueadas.'; end if;
  select genero into g from m_ligas where id = p_liga;
  n := coalesce(array_length(p_jugadores, 1), 0);
  if n <> 4 or (select count(distinct x) from unnest(p_jugadores) x) <> 4 then raise exception 'La alineación tiene que tener 4 jugadores distintos.'; end if;
  if (select count(*) from m_plantilla where liga = p_liga and user_id = auth.uid() and jugador = any(p_jugadores)) <> 4 then
    raise exception 'Solo puedes alinear jugadores de tu plantilla.';
  end if;
  select count(*) filter (where lado = 'R'), count(*) filter (where lado = 'D'),
         count(*) filter (where genero = 'M'), count(*) filter (where genero = 'F')
    into r, d, hm, mu from m_jugadores where id = any(p_jugadores);
  if r <> 2 or d <> 2 then raise exception 'Necesitas 2 jugadores de revés y 2 de drive.'; end if;
  if g = 'X' and (hm <> 2 or mu <> 2) then raise exception 'En esta liga tienes que alinear 2 chicos y 2 chicas.'; end if;
  if p_capitan is null or not (p_capitan = any(p_jugadores)) then raise exception 'Elige tu Pala de Oro entre los 4 titulares.'; end if;
  insert into m_alineacion (liga, user_id, jugadores, capitan) values (p_liga, auth.uid(), p_jugadores, p_capitan)
    on conflict (liga, user_id) do update set jugadores = excluded.jugadores, capitan = excluded.capitan;
end $$;

create or replace function public.m_pujar(p_liga uuid, p_jugador int, p_cantidad numeric)
returns void language plpgsql security definer set search_path = public as $$
declare l m_ligas; v numeric; caja_ numeric; cnt int; venta_ record; tope numeric;
begin
  perform m_soy(p_liga);
  perform m_procesar(p_liga);
  select * into l from m_ligas where id = p_liga;
  select valor into v from m_jugadores where id = p_jugador;
  select * into venta_ from m_plantilla where liga = p_liga and jugador = p_jugador;
  if venta_.jugador is not null then
    if venta_.venta is null then raise exception 'Ese jugador ya tiene dueño.'; end if;
    if venta_.user_id = auth.uid() then raise exception 'Es tuyo.'; end if;
    v := greatest(v, venta_.venta);
  elsif not (p_jugador = any(l.mercado)) then
    raise exception 'Ese jugador no está hoy en el mercado.';
  end if;
  select count(*) into cnt from m_plantilla where liga = p_liga and user_id = auth.uid();
  if cnt >= m_cfg('plantilla') then raise exception 'Tienes la plantilla llena: vende antes a alguien para tener un hueco.'; end if;
  p_cantidad := round(p_cantidad, 1);
  if p_cantidad < v then raise exception 'La puja mínima es %', to_char(v, 'FM990.0') || ' M.'; end if;
  select caja into caja_ from m_miembros where liga = p_liga and user_id = auth.uid();
  tope := caja_ + m_cfg('credito') * m_valor_plantilla(p_liga, auth.uid());
  if p_cantidad > tope then raise exception 'Como mucho puedes pujar %', to_char(tope, 'FM990.0') || ' M.'; end if;
  insert into m_pujas (liga, user_id, jugador, cantidad) values (p_liga, auth.uid(), p_jugador, p_cantidad)
    on conflict (liga, user_id, jugador) do update set cantidad = excluded.cantidad, creada = now();
end $$;

create or replace function public.m_retirar_puja(p_liga uuid, p_jugador int) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform m_soy(p_liga);
  delete from m_pujas where liga = p_liga and user_id = auth.uid() and jugador = p_jugador;
end $$;

create or replace function public.m_vender_ya(p_liga uuid, p_jugador int) returns numeric
language plpgsql security definer set search_path = public as $$
declare v numeric;
begin
  perform m_soy(p_liga);
  if not exists (select 1 from m_plantilla where liga = p_liga and jugador = p_jugador and user_id = auth.uid()) then
    raise exception 'Ese jugador no es tuyo.';
  end if;
  select valor into v from m_jugadores where id = p_jugador;
  perform m_quitar_de_alineacion(p_liga, auth.uid(), p_jugador);
  delete from m_plantilla where liga = p_liga and jugador = p_jugador;
  update m_miembros set caja = caja + v where liga = p_liga and user_id = auth.uid();
  perform m_log(p_liga, 'vende', auth.uid(), null, p_jugador, v);
  return v;
end $$;

create or replace function public.m_poner_venta(p_liga uuid, p_jugador int, p_minimo numeric) returns void
language plpgsql security definer set search_path = public as $$
declare v numeric;
begin
  perform m_soy(p_liga);
  select valor into v from m_jugadores where id = p_jugador;
  if p_minimo is not null and p_minimo < v then raise exception 'El precio mínimo no puede ser menor que su valor (%).', to_char(v, 'FM990.0') || ' M'; end if;
  update m_plantilla set venta = round(p_minimo, 1) where liga = p_liga and jugador = p_jugador and user_id = auth.uid();
  if not found then raise exception 'Ese jugador no es tuyo.'; end if;
end $$;

create or replace function public.m_pagar_clausula(p_liga uuid, p_jugador int) returns numeric
language plpgsql security definer set search_path = public as $$
declare l m_ligas; pl m_plantilla; caja_ numeric; cnt int; hoy date := (now() at time zone 'Europe/Madrid')::date; v numeric;
begin
  perform m_soy(p_liga);
  select * into l from m_ligas where id = p_liga;
  if not l.clausulas then raise exception 'Esta liga no tiene clausulazos.'; end if;
  if m_bloqueado() then raise exception 'Durante el torneo no se pueden pagar cláusulas.'; end if;
  select * into pl from m_plantilla where liga = p_liga and jugador = p_jugador for update;
  if pl.jugador is null then raise exception 'Ese jugador no tiene dueño: búscalo en el mercado.'; end if;
  if pl.user_id = auth.uid() then raise exception 'Ese jugador ya es tuyo.'; end if;
  if pl.protegido > now() then raise exception 'Está protegido hasta el %.', to_char(pl.protegido at time zone 'Europe/Madrid', 'DD/MM HH24:MI'); end if;
  if (select clausulazo from m_miembros where liga = p_liga and user_id = auth.uid()) = hoy then
    raise exception 'Ya has hecho un clausulazo hoy.';
  end if;
  if exists (select 1 from m_actividad where liga = p_liga and tipo = 'clausula' and jugador = p_jugador and otro = auth.uid()
             and cuando > now() - make_interval(days => m_cfg('venganza')::int)) then
    raise exception 'Te lo quitaron hace poco: hasta dentro de 7 días no puedes recuperarlo.';
  end if;
  select count(*) into cnt from m_plantilla where liga = p_liga and user_id = auth.uid();
  if cnt >= m_cfg('plantilla') then raise exception 'Tienes la plantilla llena: vende antes a alguien.'; end if;
  select caja into caja_ from m_miembros where liga = p_liga and user_id = auth.uid();
  if caja_ < pl.clausula then raise exception 'Te faltan %', to_char(pl.clausula - caja_, 'FM990.0') || ' M.'; end if;
  select valor into v from m_jugadores where id = p_jugador;
  update m_miembros set caja = caja + pl.clausula where liga = p_liga and user_id = pl.user_id;
  update m_miembros set caja = caja - pl.clausula, clausulazo = hoy where liga = p_liga and user_id = auth.uid();
  perform m_quitar_de_alineacion(p_liga, pl.user_id, p_jugador);
  update m_plantilla set user_id = auth.uid(), precio = pl.clausula, venta = null, desde = now(),
         clausula = round(greatest(pl.clausula, v) * m_cfg('clausula'), 1),
         protegido = now() + make_interval(days => m_cfg('proteccion')::int)
    where liga = p_liga and jugador = p_jugador;
  delete from m_pujas where liga = p_liga and jugador = p_jugador;
  perform m_log(p_liga, 'clausula', auth.uid(), pl.user_id, p_jugador, pl.clausula);
  perform m_push(array[pl.user_id], '💥 ¡Clausulazo!', m_un(auth.uid()) || ' ha pagado la cláusula de ' || m_jn(p_jugador) || ': recibes ' || m_fmt(pl.clausula) || '.');
  return pl.clausula;
end $$;

create or replace function public.m_blindar(p_liga uuid, p_jugador int, p_cantidad numeric) returns numeric
language plpgsql security definer set search_path = public as $$
declare pl m_plantilla; v numeric; tope numeric; caja_ numeric; nueva numeric;
begin
  perform m_soy(p_liga);
  if not (select clausulas from m_ligas where id = p_liga) then raise exception 'Esta liga no tiene clausulazos.'; end if;
  select * into pl from m_plantilla where liga = p_liga and jugador = p_jugador and user_id = auth.uid() for update;
  if pl.jugador is null then raise exception 'Ese jugador no es tuyo.'; end if;
  select valor into v from m_jugadores where id = p_jugador;
  tope := round(v * m_cfg('blindaje'), 1);
  if pl.clausula >= tope then raise exception 'Su cláusula ya está en el máximo (%).', to_char(tope, 'FM990.0') || ' M'; end if;
  p_cantidad := round(least(p_cantidad, (tope - pl.clausula) / 2), 1);
  if p_cantidad <= 0 then raise exception 'Pon una cantidad mayor que 0.'; end if;
  select caja into caja_ from m_miembros where liga = p_liga and user_id = auth.uid();
  if p_cantidad > caja_ then raise exception 'No tienes tanto dinero en caja.'; end if;
  nueva := least(tope, pl.clausula + 2 * p_cantidad);
  update m_plantilla set clausula = nueva where liga = p_liga and jugador = p_jugador;
  update m_miembros set caja = caja - p_cantidad where liga = p_liga and user_id = auth.uid();
  perform m_log(p_liga, 'blinda', auth.uid(), null, p_jugador, nueva);
  return nueva;
end $$;

-- --- Ofertas entre amigos (se pueden hacer aunque el jugador esté protegido) -------------------
create or replace function public.m_ofertar(p_liga uuid, p_jugador int, p_cantidad numeric) returns bigint
language plpgsql security definer set search_path = public as $$
declare pl m_plantilla; id_ bigint;
begin
  perform m_soy(p_liga);
  if m_bloqueado() then raise exception 'Durante el torneo no se pueden hacer ofertas.'; end if;
  select * into pl from m_plantilla where liga = p_liga and jugador = p_jugador;
  if pl.jugador is null then raise exception 'Ese jugador no tiene dueño: búscalo en el mercado.'; end if;
  if pl.user_id = auth.uid() then raise exception 'Ese jugador ya es tuyo.'; end if;
  p_cantidad := round(p_cantidad, 1);
  if p_cantidad is null or p_cantidad <= 0 then raise exception 'Escribe cuántos millones ofreces.'; end if;
  if p_cantidad > (select caja from m_miembros where liga = p_liga and user_id = auth.uid()) then
    raise exception 'No tienes tanto dinero en caja.';
  end if;
  update m_ofertas set estado = 'cancelada', resuelta = now()
    where liga = p_liga and de = auth.uid() and jugador = p_jugador and estado = 'pendiente';
  insert into m_ofertas (liga, de, para, jugador, cantidad) values (p_liga, auth.uid(), pl.user_id, p_jugador, p_cantidad)
    returning id into id_;
  perform m_push(array[pl.user_id], '📩 Te han hecho una oferta', m_un(auth.uid()) || ' te ofrece ' || m_fmt(p_cantidad) || ' por ' || m_jn(p_jugador) || '. Tienes 48 h para responder.');
  return id_;
end $$;

create or replace function public.m_responder_oferta(p_oferta bigint, p_aceptar boolean) returns void
language plpgsql security definer set search_path = public as $$
declare o m_ofertas; cnt int; caja_ numeric; v numeric;
begin
  select * into o from m_ofertas where id = p_oferta for update;
  if o.id is null or o.para is distinct from auth.uid() then raise exception 'Esa oferta no es para ti.'; end if;
  if o.estado <> 'pendiente' then raise exception 'Esa oferta ya no está pendiente.'; end if;
  if o.creada < now() - make_interval(hours => m_cfg('oferta_h')::int) then raise exception 'Esa oferta ha caducado.'; end if;
  if o.de is null then   -- oferta de la propia liga: se vende y el jugador vuelve a quedar libre
    if not p_aceptar then update m_ofertas set estado = 'rechazada', resuelta = now() where id = o.id; return; end if;
    if not exists (select 1 from m_plantilla where liga = o.liga and jugador = o.jugador and user_id = auth.uid()) then
      raise exception 'Ese jugador ya no es tuyo.';
    end if;
    update m_miembros set caja = caja + o.cantidad where liga = o.liga and user_id = auth.uid();
    perform m_quitar_de_alineacion(o.liga, auth.uid(), o.jugador);
    delete from m_plantilla where liga = o.liga and jugador = o.jugador;
    update m_ofertas set estado = 'aceptada', resuelta = now() where id = o.id;
    update m_ofertas set estado = 'cancelada', resuelta = now() where liga = o.liga and jugador = o.jugador and estado = 'pendiente';
    delete from m_pujas where liga = o.liga and jugador = o.jugador;
    perform m_log(o.liga, 'vende', auth.uid(), null, o.jugador, o.cantidad);
    return;
  end if;
  if not p_aceptar then
    update m_ofertas set estado = 'rechazada', resuelta = now() where id = o.id;
    perform m_push(array[o.de], '❌ Oferta rechazada', m_un(o.para) || ' no acepta tu oferta por ' || m_jn(o.jugador) || '.');
    return;
  end if;
  if m_bloqueado() then raise exception 'Durante el torneo no se pueden cerrar traspasos.'; end if;
  if not exists (select 1 from m_plantilla where liga = o.liga and jugador = o.jugador and user_id = auth.uid()) then
    raise exception 'Ese jugador ya no es tuyo.';
  end if;
  if not exists (select 1 from m_miembros where liga = o.liga and user_id = o.de) then raise exception 'Ese mánager ya no está en la liga.'; end if;
  select count(*) into cnt from m_plantilla where liga = o.liga and user_id = o.de;
  if cnt >= m_cfg('plantilla') then raise exception 'Quien te hace la oferta tiene la plantilla llena.'; end if;
  select caja into caja_ from m_miembros where liga = o.liga and user_id = o.de;
  if caja_ < o.cantidad then raise exception 'Quien te hace la oferta ya no tiene ese dinero.'; end if;
  select valor into v from m_jugadores where id = o.jugador;
  update m_miembros set caja = caja + o.cantidad where liga = o.liga and user_id = auth.uid();
  update m_miembros set caja = caja - o.cantidad where liga = o.liga and user_id = o.de;
  perform m_quitar_de_alineacion(o.liga, auth.uid(), o.jugador);
  update m_plantilla set user_id = o.de, precio = o.cantidad, venta = null, desde = now(),
         clausula = round(greatest(o.cantidad, v) * m_cfg('clausula'), 1),
         protegido = now() + make_interval(days => m_cfg('proteccion')::int)
    where liga = o.liga and jugador = o.jugador;
  update m_ofertas set estado = 'aceptada', resuelta = now() where id = o.id;
  update m_ofertas set estado = 'cancelada', resuelta = now() where liga = o.liga and jugador = o.jugador and estado = 'pendiente';
  delete from m_pujas where liga = o.liga and jugador = o.jugador;
  perform m_log(o.liga, 'traspaso', auth.uid(), o.de, o.jugador, o.cantidad);
  perform m_push(array[o.de], '🤝 ¡Oferta aceptada!', m_jn(o.jugador) || ' es tuyo por ' || m_fmt(o.cantidad) || '.');
end $$;

create or replace function public.m_cancelar_oferta(p_oferta bigint) returns void
language plpgsql security definer set search_path = public as $$
begin
  update m_ofertas set estado = 'cancelada', resuelta = now() where id = p_oferta and de = auth.uid() and estado = 'pendiente';
  if not found then raise exception 'Esa oferta ya no está pendiente.'; end if;
end $$;

-- Cambia los jugadores que ya no están en el top 100 por otros del 41 al 100 (mismo lado y género), gratis (solo en ligas de hasta 16)
create or replace function public.m_reemplazar_fuera() returns int
language plpgsql security definer set search_path = public as $$
declare r record; nuevo int; n int := 0;
begin
  for r in select p.liga, p.user_id, p.jugador, j.genero, j.lado from m_plantilla p join m_jugadores j on j.id = p.jugador
           where coalesce(j.rank, 999) > m_cfg('top')
             -- en ligas de más de 16 mánagers se permiten jugadores fuera del top 100: no se tocan
             and (select count(*) from m_miembros m where m.liga = p.liga) <= 16 loop
    nuevo := m_escoger(r.liga, 41, 100, r.genero, r.lado, null);
    if nuevo is null then nuevo := m_escoger(r.liga, 1, 100, r.genero, r.lado, null); end if;
    continue when nuevo is null;
    delete from m_pujas where liga = r.liga and jugador = r.jugador;
    update m_plantilla set jugador = nuevo, precio = (select valor from m_jugadores where id = nuevo),
           clausula = round((select valor from m_jugadores where id = nuevo) * m_cfg('clausula'), 1),
           protegido = now() + make_interval(days => m_cfg('proteccion')::int), venta = null
      where liga = r.liga and jugador = r.jugador;
    update m_alineacion set jugadores = array_replace(jugadores, r.jugador, nuevo),
           capitan = case when capitan = r.jugador then nuevo else capitan end
      where liga = r.liga and user_id = r.user_id;
    update m_miembros set sobre = array_replace(sobre, r.jugador, nuevo) where liga = r.liga and user_id = r.user_id;
    perform m_log(r.liga, 'cambio', r.user_id, null, nuevo, null);
    n := n + 1;
  end loop;
  return n;
end $$;

-- --- Lo que hace GitHub (clave service_role) ------------------------------------------------
-- Foto de las alineaciones de todos para un torneo (con p_rehacer, sustituye la que hubiera)
create or replace function public.m_foto(p_torneo int, p_rehacer boolean) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if p_rehacer then delete from m_fotos where torneo = p_torneo; end if;
  insert into m_fotos (liga, user_id, torneo, jugadores, capitan, negativo)
    select a.liga, a.user_id, p_torneo,
           coalesce((select array_agg(x) from unnest(a.jugadores) x
                     where exists (select 1 from m_plantilla p where p.liga = a.liga and p.user_id = a.user_id and p.jugador = x)), '{}'),
           a.capitan, m.caja < 0
    from m_alineacion a join m_miembros m on m.liga = a.liga and m.user_id = a.user_id
  on conflict (liga, user_id, torneo) do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- Excepción: con el torneo ya empezado, dejar alinear, ofertar y traspasar hasta p_hasta. Al llegar esa hora
-- (lo mira m_procesar_todas cada minuto) se rehace la foto de las alineaciones y vuelve el bloqueo.
-- Uso en el SQL Editor: select m_excepcion('2026-11-22 23:59 Europe/Madrid');
create or replace function public.m_excepcion(p_hasta timestamptz) returns text
language plpgsql security definer set search_path = public as $$
declare e m_estado;
begin
  select * into e from m_estado where id = 1;
  if not e.bloqueado then return 'No hay ningún torneo bloqueado: no hace falta excepción.'; end if;
  if p_hasta <= now() then raise exception 'La hora tiene que ser futura.'; end if;
  update m_estado set abierto_hasta = p_hasta where id = 1;
  perform m_push((select array_agg(distinct user_id) from m_miembros), '🔓 Alineaciones abiertas',
    'Excepción en el ' || coalesce(e.torneo_nombre, 'torneo') || ': puedes cambiar tu alineación y hacer ofertas hasta las '
    || to_char(p_hasta at time zone 'Europe/Madrid', 'HH24:MI') || ' (hora de España).');
  return 'Abierto hasta ' || to_char(p_hasta at time zone 'Europe/Madrid', 'DD/MM HH24:MI') || ' (hora de España)';
end $$;

-- Al acabar la excepción: nueva foto de las alineaciones y otra vez bloqueado
create or replace function public.m_cerrar_excepcion() returns void
language plpgsql security definer set search_path = public as $$
declare e m_estado;
begin
  select * into e from m_estado where id = 1 for update;
  if e.abierto_hasta is null or e.abierto_hasta > now() then return; end if;
  update m_estado set abierto_hasta = null where id = 1;
  if e.bloqueado and e.torneo is not null then
    perform m_foto(e.torneo, true);
    perform m_push((select array_agg(distinct user_id) from m_fotos where torneo = e.torneo),
                   '🔒 Alineaciones cerradas', 'Tu equipo para el ' || coalesce(e.torneo_nombre, 'torneo') || ' queda bloqueado. ¡Suerte!');
  end if;
end $$;

create or replace function public.m_bloquear(p_torneo int, p_nombre text) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update m_estado set bloqueado = true, torneo = p_torneo, torneo_nombre = p_nombre, actualizado = now() where id = 1;
  insert into m_torneos (id, nombre) values (p_torneo, p_nombre) on conflict (id) do nothing;
  n := m_foto(p_torneo, false);
  perform m_push((select array_agg(distinct user_id) from m_fotos where torneo = p_torneo and not negativo),
                 '🔒 Empieza el ' || p_nombre, 'Tu equipo queda bloqueado. ¡Suerte!');
  perform m_push((select array_agg(distinct user_id) from m_fotos where torneo = p_torneo and negativo),
                 '⚠️ Empieza el ' || p_nombre, 'Empiezas en negativo: en este torneo no puntúas.');
  return n;
end $$;

create or replace function public.m_abrir() returns int
language plpgsql security definer set search_path = public as $$
declare t int; n int := 0;
begin
  select torneo into t from m_estado where id = 1;
  update m_estado set bloqueado = false, actualizado = now() where id = 1;
  if t is not null and exists (select 1 from m_torneos where id = t and not pagado) then
    update m_miembros m set caja = m.caja + round(m_cfg('por_punto') * m_pts_foto(f), 1)
      from m_fotos f where f.torneo = t and f.liga = m.liga and f.user_id = m.user_id and not f.negativo;
    get diagnostics n = row_count;
    update m_torneos set pagado = true where id = t;
    declare r record; nom text := (select nombre from m_torneos where id = t);
    begin
      for r in select f.user_id, string_agg('«' || l.nombre || '» ' || round(m_pts_foto(f))::text || ' pts', ' · ') as txt
               from m_fotos f join m_ligas l on l.id = f.liga where f.torneo = t group by f.user_id loop
        perform m_push(array[r.user_id], '🏁 Termina el ' || nom, r.txt || '. Cobras 0,2 M por punto.');
      end loop;
    end;
  end if;
  return n;
end $$;

create or replace function public.m_procesar_todas() returns int
language plpgsql security definer set search_path = public as $$
declare l uuid; n int := 0;
begin
  perform m_cerrar_excepcion();
  for l in select id from m_ligas where cierre <= now() loop
    perform m_procesar(l); n := n + 1;
  end loop;
  return n;
end $$;

-- El mánager activa o desactiva sus avisos del fantasy
create or replace function public.m_avisos_set(p_activo boolean) returns void
language sql security definer set search_path = public as $$
  insert into m_avisos (user_id, activo) values (auth.uid(), p_activo)
  on conflict (user_id) do update set activo = excluded.activo
$$;

-- Reloj: lo llama pg_cron cada minuto. Cierra los mercados a su hora y manda los avisos con hora.
create or replace function public.m_tick() returns void
language plpgsql security definer set search_path = public as $$
declare l record; e m_estado; r record;
begin
  perform m_procesar_todas();
  -- «El mercado cierra en 10 minutos»
  for l in select * from m_ligas where cierre > now() and cierre <= now() + interval '10 minutes' and aviso10 is distinct from cierre loop
    update m_ligas set aviso10 = l.cierre where id = l.id;
    perform m_push((select array_agg(user_id) from m_miembros where liga = l.id), '⏰ El mercado cierra en 10 minutos',
                   'Últimos minutos para pujar en «' || l.nombre || '».');
  end loop;
  -- Ligas públicas: quien lleva 3 semanas sin abrirla sale (sus jugadores vuelven a quedar libres)
  for r in select m.liga, m.user_id, lg.nombre from m_miembros m join m_ligas lg on lg.id = m.liga
           where lg.publica and coalesce(m.visto, m.unido) < now() - make_interval(days => m_cfg('inactivo_dias')::int) limit 50 loop
    delete from m_pujas where liga = r.liga and user_id = r.user_id;
    delete from m_miembros where liga = r.liga and user_id = r.user_id;
    perform m_log(r.liga, 'sale', r.user_id, null, null, null);
    perform m_push(array[r.user_id], '👋 Has salido de «' || r.nombre || '»',
                   'Llevabas 3 semanas sin entrar y hemos dejado tu plaza a otro. Puedes volver a una liga pública cuando quieras.');
  end loop;
  -- Quien tiene nombre de mánager desde hace un día y no está en ninguna liga: un aviso (solo una vez)
  for r in select p.id from perfiles p
           where p.creado < now() - interval '1 day'
             and not exists (select 1 from m_miembros m where m.user_id = p.id)
             and not exists (select 1 from m_recordado x where x.user_id = p.id) limit 200 loop
    insert into m_recordado (user_id) values (r.id) on conflict do nothing;
    perform m_push(array[r.id], '🐍 Aún no tienes equipo',
                   'Entra en una liga pública con un toque, abre tu sobre y juega el próximo torneo.');
  end loop;
  -- Recordatorio unas horas antes de que se bloqueen las alineaciones
  select * into e from m_estado where id = 1;
  if e.proximo is not null and not e.bloqueado and e.aviso_bloqueo is distinct from e.proximo
     and now() between e.proximo_bloqueo - interval '7 hours' and e.proximo_bloqueo then
    update m_estado set aviso_bloqueo = e.proximo where id = 1;
    for r in select m.user_id,
                    bool_or(coalesce((select count(*) from unnest(a.jugadores) x
                                      where exists (select 1 from m_plantilla p where p.liga = m.liga and p.user_id = m.user_id and p.jugador = x)), 0) < 4) as incompleta,
                    bool_or(m.caja < 0) as negativo
             from m_miembros m left join m_alineacion a on a.liga = m.liga and a.user_id = m.user_id group by m.user_id loop
      perform m_push(array[r.user_id], '⏳ En unas horas empieza el ' || e.proximo_nombre,
        case when r.incompleta then 'Tu alineación está incompleta: complétala antes de que se bloquee.'
             when r.negativo then 'Estás en negativo: vende antes de que se bloquee o no puntuarás.'
             else 'Revisa tu alineación y tu Pala de Oro antes de que se bloquee.' end);
    end loop;
  end if;
end $$;

-- --- Permisos -------------------------------------------------------------------------------
alter table public.m_jugadores  enable row level security;
alter table public.m_estado     enable row level security;
alter table public.m_torneos    enable row level security;
alter table public.m_puntos     enable row level security;
alter table public.m_ligas      enable row level security;
alter table public.m_miembros   enable row level security;
alter table public.m_plantilla  enable row level security;
alter table public.m_alineacion enable row level security;
alter table public.m_pujas      enable row level security;
alter table public.m_fotos      enable row level security;
alter table public.m_actividad  enable row level security;
alter table public.m_ofertas    enable row level security;
alter table public.m_config     enable row level security;
alter table public.m_avisos     enable row level security;
alter table public.m_recordado  enable row level security;
-- Lectura libre de lo que es público; el resto, solo a través de las funciones
drop policy if exists leer on public.m_jugadores; create policy leer on public.m_jugadores for select using (true);
drop policy if exists leer on public.m_estado;    create policy leer on public.m_estado    for select using (true);
drop policy if exists leer on public.m_torneos;   create policy leer on public.m_torneos   for select using (true);
drop policy if exists leer on public.m_puntos;    create policy leer on public.m_puntos    for select using (true);

-- Las funciones internas y las de GitHub no las puede llamar nadie más
revoke execute on function public.m_soy(uuid), public.m_valor_plantilla(uuid, uuid), public.m_quitar_de_alineacion(uuid, uuid, int),
  public.m_log(uuid, text, uuid, uuid, int, numeric), public.m_libres(uuid), public.m_escoger(uuid, int, int, char, char, int[]),
  public.m_nuevo_mercado(uuid), public.m_dar_sobre(uuid, uuid), public.m_procesar(uuid), public.m_pts_foto(public.m_fotos),
  public.m_bloquear(int, text), public.m_foto(int, boolean), public.m_excepcion(timestamptz), public.m_cerrar_excepcion(),
  public.m_abrir(), public.m_procesar_todas(), public.m_reemplazar_fuera(),
  public.m_push(uuid[], text, text), public.m_tick() from public, anon, authenticated;
grant execute on function public.m_bloquear(int, text), public.m_foto(int, boolean), public.m_excepcion(timestamptz), public.m_cerrar_excepcion(), public.m_abrir(), public.m_procesar_todas(), public.m_reemplazar_fuera(), public.m_tick() to service_role;
revoke execute on function public.m_crear_liga(text, char, boolean), public.m_ver_liga(text), public.m_unirse(text), public.m_unirse_publica(), public.m_salir(uuid),
  public.m_mis_ligas(), public.m_liga(uuid), public.m_sobre_visto(uuid), public.m_alinear(uuid, int[], int), public.m_pujar(uuid, int, numeric),
  public.m_retirar_puja(uuid, int), public.m_vender_ya(uuid, int), public.m_poner_venta(uuid, int, numeric),
  public.m_pagar_clausula(uuid, int), public.m_blindar(uuid, int, numeric),
  public.m_echar(uuid, uuid), public.m_ofertar(uuid, int, numeric), public.m_responder_oferta(bigint, boolean), public.m_cancelar_oferta(bigint), public.m_avisos_set(boolean) from public, anon;
grant execute on function public.m_crear_liga(text, char, boolean), public.m_ver_liga(text), public.m_unirse(text), public.m_unirse_publica(), public.m_salir(uuid),
  public.m_mis_ligas(), public.m_liga(uuid), public.m_sobre_visto(uuid), public.m_alinear(uuid, int[], int), public.m_pujar(uuid, int, numeric),
  public.m_retirar_puja(uuid, int), public.m_vender_ya(uuid, int), public.m_poner_venta(uuid, int, numeric),
  public.m_pagar_clausula(uuid, int), public.m_blindar(uuid, int, numeric),
  public.m_echar(uuid, uuid), public.m_ofertar(uuid, int, numeric), public.m_responder_oferta(bigint, boolean), public.m_cancelar_oferta(bigint), public.m_avisos_set(boolean) to authenticated;


-- Reloj de cada minuto (solo si la extensión pg_cron está activada: Database → Extensions)
do $$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('vibora-fantasy', '* * * * *', 'select public.m_tick()');
  end if;
end $$;
