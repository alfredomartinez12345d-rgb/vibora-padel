-- ============================================================================
-- Fantasy Víbora: base de datos para Supabase.
-- Cómo instalarlo: Supabase → SQL Editor → New query → pegar TODO esto → Run.
-- Se puede volver a ejecutar sin perder datos (crea solo lo que falta).
--
-- Reglas (las mismas que explica la app):
--   · Equipo de 5 jugadores distintos con presupuesto de 100 M y un capitán.
--   · Cuando empieza un torneo Premier el equipo se bloquea (lo hace GitHub).
--   · Con el equipo desbloqueado se permiten como mucho 2 cambios respecto al
--     equipo con el que jugaste el último torneo (antes del primero, libres).
-- Los precios, el bloqueo y los puntos los escribe GitHub con la clave
-- service_role; los usuarios no pueden tocarlos.
-- ============================================================================

-- --- Tablas ------------------------------------------------------------------
create table if not exists public.precios (
  player_id  int primary key,
  nombre     text not null,
  corto      text,
  cat        text not null check (cat in ('men', 'women')),
  precio     numeric(4,1) not null check (precio > 0)
);

create table if not exists public.estado (
  id            int primary key default 1 check (id = 1),
  abierto       boolean not null default true,
  torneo        int,
  torneo_nombre text,
  actualizado   timestamptz not null default now()
);
insert into public.estado (id) values (1) on conflict do nothing;

create table if not exists public.perfiles (
  id      uuid primary key references auth.users on delete cascade,
  nombre  text not null unique
          check (char_length(nombre) between 3 and 20 and nombre ~ '^[A-Za-z0-9ÁÉÍÓÚÜÑáéíóúüñ _.-]+$'),
  creado  timestamptz not null default now()
);

create table if not exists public.equipos (
  user_id     uuid primary key references public.perfiles on delete cascade,
  jugadores   int[] not null,
  capitan     int not null,
  actualizado timestamptz not null default now()
);

-- Equipo congelado al empezar cada torneo (con este se puntúa)
create table if not exists public.fotos (
  user_id   uuid not null references public.perfiles on delete cascade,
  torneo    int not null,
  jugadores int[] not null,
  capitan   int not null,
  creada    timestamptz not null default now(),
  primary key (user_id, torneo)
);

create table if not exists public.puntos (
  user_id       uuid not null references public.perfiles on delete cascade,
  torneo        int not null,
  torneo_nombre text,
  puntos        int not null default 0,
  primary key (user_id, torneo)
);

create table if not exists public.ligas (
  id      uuid primary key default gen_random_uuid(),
  nombre  text not null check (char_length(nombre) between 3 and 30),
  codigo  text unique,
  publica boolean not null default false,
  creador uuid references public.perfiles on delete set null,
  creada  timestamptz not null default now()
);
insert into public.ligas (id, nombre, publica)
values ('00000000-0000-0000-0000-000000000001', 'Liga Víbora', true) on conflict do nothing;

create table if not exists public.miembros (
  liga_id uuid not null references public.ligas on delete cascade,
  user_id uuid not null references public.perfiles on delete cascade,
  unido   timestamptz not null default now(),
  primary key (liga_id, user_id)
);

-- --- Reglas del equipo ---------------------------------------------------------
create or replace function public.validar_equipo() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  n_precios int; total numeric; abierta boolean; ultima int[]; cambios int;
begin
  if coalesce(auth.role(), '') = 'service_role' then return new; end if;
  select abierto into abierta from estado where id = 1;
  if not coalesce(abierta, true) then
    raise exception 'El equipo está bloqueado mientras se juega el torneo.' using errcode = 'P0001';
  end if;
  if coalesce(array_length(new.jugadores, 1), 0) <> 5
     or (select count(distinct j) from unnest(new.jugadores) j) <> 5 then
    raise exception 'El equipo tiene que tener 5 jugadores distintos.' using errcode = 'P0001';
  end if;
  if not (new.capitan = any (new.jugadores)) then
    raise exception 'El capitán tiene que estar en el equipo.' using errcode = 'P0001';
  end if;
  select count(*), coalesce(sum(precio), 0) into n_precios, total
    from precios where player_id = any (new.jugadores);
  if n_precios <> 5 then
    raise exception 'Hay jugadores que no están disponibles en el fantasy.' using errcode = 'P0001';
  end if;
  if total > 100 then
    raise exception 'Te pasas del presupuesto: % M de 100 M.', total using errcode = 'P0001';
  end if;
  select f.jugadores into ultima from fotos f where f.user_id = new.user_id order by f.creada desc limit 1;
  if ultima is not null then
    select count(*) into cambios from unnest(new.jugadores) j where not (j = any (ultima));
    if cambios > 2 then
      raise exception 'Solo puedes hacer 2 cambios entre torneos (llevas %).', cambios using errcode = 'P0001';
    end if;
  end if;
  new.actualizado := now();
  return new;
end $$;

drop trigger if exists validar_equipo on public.equipos;
create trigger validar_equipo before insert or update on public.equipos
  for each row execute function public.validar_equipo();

-- Al crear el perfil, entra en la liga pública
create or replace function public.unir_publica() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into miembros (liga_id, user_id)
  values ('00000000-0000-0000-0000-000000000001', new.id) on conflict do nothing;
  return new;
end $$;

drop trigger if exists unir_publica on public.perfiles;
create trigger unir_publica after insert on public.perfiles
  for each row execute function public.unir_publica();

-- --- Funciones que llama la app --------------------------------------------------
create or replace function public.crear_liga(p_nombre text) returns text
language plpgsql security definer set search_path = public as $$
declare cod text; lid uuid; letras text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  if auth.uid() is null or not exists (select 1 from perfiles where id = auth.uid()) then
    raise exception 'Primero crea tu perfil.' using errcode = 'P0001';
  end if;
  if (select count(*) from ligas where creador = auth.uid()) >= 10 then
    raise exception 'Como mucho puedes crear 10 ligas.' using errcode = 'P0001';
  end if;
  loop
    cod := '';
    for i in 1..6 loop cod := cod || substr(letras, 1 + floor(random() * length(letras))::int, 1); end loop;
    exit when not exists (select 1 from ligas where codigo = cod);
  end loop;
  insert into ligas (nombre, codigo, creador) values (trim(p_nombre), cod, auth.uid()) returning id into lid;
  insert into miembros (liga_id, user_id) values (lid, auth.uid());
  return cod;
end $$;

create or replace function public.unirse_liga(p_codigo text) returns uuid
language plpgsql security definer set search_path = public as $$
declare lid uuid;
begin
  if auth.uid() is null or not exists (select 1 from perfiles where id = auth.uid()) then
    raise exception 'Primero crea tu perfil.' using errcode = 'P0001';
  end if;
  select id into lid from ligas where codigo = upper(trim(p_codigo));
  if lid is null then raise exception 'No existe ninguna liga con ese código.' using errcode = 'P0001'; end if;
  insert into miembros (liga_id, user_id) values (lid, auth.uid()) on conflict do nothing;
  return lid;
end $$;

create or replace function public.salir_liga(p_liga uuid) returns void
language sql security definer set search_path = public as $$
  delete from miembros
  where liga_id = p_liga and user_id = auth.uid() and p_liga <> '00000000-0000-0000-0000-000000000001';
$$;

create or replace function public.mis_ligas()
returns table (id uuid, nombre text, codigo text, publica boolean, miembros bigint, mia boolean)
language sql stable security definer set search_path = public as $$
  select l.id, l.nombre, l.codigo, l.publica, (select count(*) from miembros x where x.liga_id = l.id), l.creador = auth.uid()
  from ligas l join miembros m on m.liga_id = l.id and m.user_id = auth.uid()
  order by l.publica desc, l.creada;
$$;

create or replace function public.clasificacion(p_liga uuid)
returns table (posicion bigint, nombre text, total bigint, ultimo int, soy_yo boolean)
language sql stable security definer set search_path = public as $$
  with ult as (select max(torneo) t from puntos),
  tabla as (
    select p.nombre, coalesce(sum(pt.puntos), 0) total,
           coalesce(max(pt.puntos) filter (where pt.torneo = (select t from ult)), 0)::int ultimo,
           p.id = auth.uid() soy_yo
    from miembros m join perfiles p on p.id = m.user_id
    left join puntos pt on pt.user_id = p.id
    where m.liga_id = p_liga
      and (exists (select 1 from ligas where id = p_liga and publica)
           or exists (select 1 from miembros y where y.liga_id = p_liga and y.user_id = auth.uid()))
    group by p.id, p.nombre)
  select rank() over (order by total desc), nombre, total, ultimo, soy_yo from tabla
  order by total desc, nombre limit 500;
$$;

-- Solo para GitHub (service_role): bloquear y abrir los equipos
create or replace function public.bloquear(p_torneo int, p_nombre text) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'No permitido'; end if;
  update estado set abierto = false, torneo = p_torneo, torneo_nombre = p_nombre, actualizado = now() where id = 1;
  insert into fotos (user_id, torneo, jugadores, capitan)
    select user_id, p_torneo, jugadores, capitan from equipos
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.abrir() returns void
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(auth.role(), '') <> 'service_role' then raise exception 'No permitido'; end if;
  update estado set abierto = true, actualizado = now() where id = 1;
end $$;

-- --- Seguridad: cada usuario solo toca lo suyo -------------------------------------
alter table public.precios  enable row level security;
alter table public.estado   enable row level security;
alter table public.perfiles enable row level security;
alter table public.equipos  enable row level security;
alter table public.fotos    enable row level security;
alter table public.puntos   enable row level security;
alter table public.ligas    enable row level security;
alter table public.miembros enable row level security;

drop policy if exists leer on public.precios;  create policy leer on public.precios  for select using (true);
drop policy if exists leer on public.estado;   create policy leer on public.estado   for select using (true);
drop policy if exists leer on public.puntos;   create policy leer on public.puntos   for select using (true);
drop policy if exists leer on public.fotos;    create policy leer on public.fotos    for select using (true);
drop policy if exists leer on public.perfiles; create policy leer on public.perfiles for select using (true);
drop policy if exists crear on public.perfiles;
create policy crear on public.perfiles for insert with check (id = auth.uid());
drop policy if exists cambiar on public.perfiles;
create policy cambiar on public.perfiles for update using (id = auth.uid()) with check (id = auth.uid());
drop policy if exists mio on public.equipos;
create policy mio on public.equipos for all using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists mias on public.miembros;
create policy mias on public.miembros for select using (user_id = auth.uid());
drop policy if exists visibles on public.ligas;
create policy visibles on public.ligas for select
  using (publica or exists (select 1 from public.miembros m where m.liga_id = id and m.user_id = auth.uid()));

revoke execute on function public.bloquear(int, text) from public, anon, authenticated;
revoke execute on function public.abrir() from public, anon, authenticated;
grant execute on function public.bloquear(int, text) to service_role;
grant execute on function public.abrir() to service_role;
