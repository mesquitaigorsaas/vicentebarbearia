-- =====================================================================
-- Vicente Barbearia · Buritis (BH) — agendamento online (Supabase / Postgres)
-- Cole tudo no Supabase → SQL Editor → Run. Pode rodar de novo sem problema.
--
-- Vários barbeiros atendem ao mesmo tempo: cada agendamento é de um barbeiro,
-- e o banco impede dois clientes no mesmo horário com o MESMO barbeiro.
-- O site público não lê dados de clientes: só chama as funções abaixo.
-- =====================================================================

create extension if not exists btree_gist;

create table if not exists services (
  id           serial primary key,
  name         text not null,
  description  text not null default '',
  price        numeric(8,2),                 -- vazio = "Consulte" no site
  duration_min integer not null check (duration_min between 5 and 240),
  kind         text not null check (kind in ('main', 'extra')),
  active       boolean not null default true,
  sort         integer not null default 0
);

create table if not exists professionals (
  id     serial primary key,
  name   text not null,
  active boolean not null default true,
  sort   integer not null default 0
);

-- Expediente (0 = domingo … 6 = sábado), horário de Brasília.
create table if not exists hours (
  weekday  integer primary key check (weekday between 0 and 6),
  closed   boolean not null default false,
  opens    time not null default '09:00',
  closes   time not null default '20:00'
);

create table if not exists settings (
  id              integer primary key default 1 check (id = 1),
  buffer_min      integer not null default 10,
  slot_step_min   integer not null default 20,
  min_notice_min  integer not null default 30,
  max_days        integer not null default 30,
  max_active_per_phone integer not null default 2
);

create table if not exists bookings (
  id              uuid primary key default gen_random_uuid(),
  token           uuid not null unique default gen_random_uuid(),
  professional_id integer not null references professionals (id),
  customer_name   text not null,
  customer_phone  text not null,
  service_ids     integer[] not null,
  services_label  text not null,
  total           numeric(8,2),              -- vazio quando algum serviço está sem preço
  starts_at       timestamptz not null,
  ends_at         timestamptz not null,
  status          text not null default 'confirmed' check (status in ('confirmed', 'done', 'no_show', 'cancelled')),
  notes           text not null default '',
  cancelled_by    text,
  created_at      timestamptz not null default now(),
  check (ends_at > starts_at)
);
create index if not exists idx_bookings_start on bookings (starts_at);

do $$ begin
  alter table bookings add constraint bookings_no_overlap
    exclude using gist (professional_id with =, tstzrange(starts_at, ends_at) with &&)
    where (status in ('confirmed', 'done'));
exception when duplicate_object then null; end $$;

-- Bloqueios: professional_id vazio = a barbearia toda.
create table if not exists blocks (
  id              serial primary key,
  professional_id integer references professionals (id) on delete cascade,
  starts_at       timestamptz not null,
  ends_at         timestamptz not null,
  reason          text not null default '',
  created_at      timestamptz not null default now(),
  check (ends_at > starts_at)
);

create table if not exists admins (
  user_id uuid primary key references auth.users (id) on delete cascade
);

-- ---------------------------------------------------------------------
-- Dados iniciais (confira no painel: preços, durações e nomes dos barbeiros)
-- ---------------------------------------------------------------------
insert into settings (id) values (1) on conflict do nothing;

insert into hours (weekday, closed, opens, closes) values
  (0, true,  '09:00', '16:00'),
  (1, false, '09:00', '20:00'),
  (2, false, '09:00', '20:00'),
  (3, false, '09:00', '20:00'),
  (4, false, '09:00', '20:00'),
  (5, false, '09:00', '20:00'),
  (6, false, '09:00', '16:00')
on conflict do nothing;

insert into services (name, description, price, duration_min, kind, sort)
select * from (values
  ('Corte',          'Corte masculino',                                   null::numeric, 40, 'main', 1),
  ('Barba',          'Barba feita e alinhada',                            null::numeric, 30, 'main', 2),
  ('Corte e Barba',  'Corte masculino + barba',                           null::numeric, 70, 'main', 3),
  ('Barboterapia',   'Tratamento completo da barba',                 null::numeric, 40, 'main', 4),
  ('Ozonioterapia',  'Terapia com ozônio', null::numeric, 30, 'extra', 10)
) as v(name, description, price, duration_min, kind, sort)
where not exists (select 1 from services);

insert into professionals (name, sort)
select 'Equipe Vicente', 1 where not exists (select 1 from professionals);

-- ---------------------------------------------------------------------
-- Permissões (RLS)
-- ---------------------------------------------------------------------
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = '' as
$$ select exists (select 1 from public.admins where user_id = auth.uid()) $$;

alter table services      enable row level security;
alter table professionals enable row level security;
alter table hours         enable row level security;
alter table settings      enable row level security;
alter table bookings      enable row level security;
alter table blocks        enable row level security;
alter table admins        enable row level security;

do $$
declare t text;
begin
  foreach t in array array['services', 'professionals', 'hours', 'settings'] loop
    execute format('drop policy if exists "leitura pública" on %I', t);
    execute format('create policy "leitura pública" on %I for select using (true)', t);
    execute format('drop policy if exists "admin altera" on %I', t);
    execute format('create policy "admin altera" on %I for all to authenticated using (public.is_admin()) with check (public.is_admin())', t);
  end loop;
  foreach t in array array['bookings', 'blocks'] loop
    execute format('drop policy if exists "admin" on %I', t);
    execute format('create policy "admin" on %I for all to authenticated using (public.is_admin()) with check (public.is_admin())', t);
  end loop;
end $$;

drop policy if exists "vê o próprio" on admins;
create policy "vê o próprio" on admins for select to authenticated using (user_id = auth.uid());

-- ---------------------------------------------------------------------
-- Funções do site público
-- ---------------------------------------------------------------------

-- Intervalos ocupados do dia, por barbeiro (professional_id vazio = todos). Sem dados pessoais.
create or replace function public.busy_intervals(p_day date)
returns table (professional_id integer, starts_at timestamptz, ends_at timestamptz)
language sql stable security definer set search_path = '' as
$$
  with d as (
    select (p_day::timestamp at time zone 'America/Sao_Paulo') as d0,
           ((p_day + 1)::timestamp at time zone 'America/Sao_Paulo') as d1
  )
  select b.professional_id, b.starts_at, b.ends_at from public.bookings b, d
   where b.status in ('confirmed', 'done') and b.starts_at < d.d1 and b.ends_at > d.d0
  union all
  select k.professional_id, k.starts_at, k.ends_at from public.blocks k, d
   where k.starts_at < d.d1 and k.ends_at > d.d0
$$;

drop function if exists public.create_booking(integer[], timestamptz, integer, text, text, text);
create or replace function public.create_booking(
  p_service_ids integer[], p_start timestamptz, p_professional_id integer,
  p_name text, p_phone text, p_notes text default ''
) returns table (token uuid, starts_at timestamptz, services_label text, total numeric, professional_name text)
language plpgsql security definer set search_path = '' as
$$
#variable_conflict use_column
declare
  cfg     public.settings;
  h       public.hours;
  local_t timestamp := p_start at time zone 'America/Sao_Paulo';
  dur     integer;
  n_main  integer;
  n_found integer;
  n_price integer;
  lbl     text;
  tot     numeric;
  phone   text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  name    text := btrim(coalesce(p_name, ''));
  v_end   timestamptz;
  v_prof  public.professionals;
  v_token uuid;
begin
  select * into cfg from public.settings where id = 1;

  if length(name) < 2 or length(name) > 60 then raise exception 'Informe seu nome.' using errcode = 'P0001'; end if;
  if length(phone) < 10 or length(phone) > 13 then raise exception 'Informe um WhatsApp válido com DDD.' using errcode = 'P0001'; end if;

  select count(*), count(*) filter (where s.kind = 'main'), count(s.price), coalesce(sum(s.duration_min), 0),
         string_agg(s.name, ' + ' order by s.sort), sum(s.price)
    into n_found, n_main, n_price, dur, lbl, tot
    from public.services s where s.id = any (p_service_ids) and s.active;
  if n_main <> 1 or n_found <> cardinality(p_service_ids) then
    raise exception 'Escolha um serviço principal.' using errcode = 'P0001';
  end if;
  if n_price < n_found then tot := null; end if;

  if p_start < now() + make_interval(mins => cfg.min_notice_min) then
    raise exception 'Esse horário já passou ou está muito em cima. Escolha outro.' using errcode = 'P0001';
  end if;
  if p_start > now() + make_interval(days => cfg.max_days) then
    raise exception 'Agendamentos só até % dias à frente.', cfg.max_days using errcode = 'P0001';
  end if;

  select * into h from public.hours where weekday = extract(dow from local_t)::int;
  if h.closed or local_t::time < h.opens or (local_t + make_interval(mins => dur))::time > h.closes
     or (local_t + make_interval(mins => dur))::date <> local_t::date then
    raise exception 'Fora do horário de atendimento.' using errcode = 'P0001';
  end if;

  if (select count(*) from public.bookings b where b.customer_phone = phone and b.status = 'confirmed' and b.starts_at > now())
     >= cfg.max_active_per_phone then
    raise exception 'Você já tem agendamentos marcados. Fale com a barbearia no WhatsApp para marcar mais.' using errcode = 'P0001';
  end if;

  v_end := p_start + make_interval(mins => dur + cfg.buffer_min);

  -- Barbeiro escolhido, ou o primeiro livre ("sem preferência").
  select p.* into v_prof from public.professionals p
   where p.active and (p_professional_id is null or p.id = p_professional_id)
     and not exists (select 1 from public.bookings b where b.professional_id = p.id and b.status in ('confirmed', 'done')
                      and b.starts_at < v_end and b.ends_at > p_start)
     and not exists (select 1 from public.blocks k where (k.professional_id is null or k.professional_id = p.id)
                      and k.starts_at < v_end and k.ends_at > p_start)
   order by (select count(*) from public.bookings b where b.professional_id = p.id and b.status = 'confirmed'
              and b.starts_at::date = p_start::date), p.sort
   limit 1;
  if v_prof.id is null then
    raise exception 'Esse horário acabou de ser ocupado. Escolha outro.' using errcode = 'P0001';
  end if;

  begin
    insert into public.bookings (professional_id, customer_name, customer_phone, service_ids, services_label, total, starts_at, ends_at, notes)
    values (v_prof.id, name, phone, p_service_ids, lbl, tot, p_start, v_end, left(btrim(coalesce(p_notes, '')), 300))
    returning bookings.token into v_token;
  exception when exclusion_violation then
    raise exception 'Esse horário acabou de ser ocupado. Escolha outro.' using errcode = 'P0001';
  end;

  return query select v_token, p_start, lbl, tot, v_prof.name;
end
$$;

create or replace function public.get_booking(p_token uuid)
returns table (customer_name text, services_label text, total numeric, starts_at timestamptz, status text, professional_name text)
language sql stable security definer set search_path = '' as
$$ select b.customer_name, b.services_label, b.total, b.starts_at, b.status, p.name
     from public.bookings b join public.professionals p on p.id = b.professional_id where b.token = p_token $$;

create or replace function public.cancel_booking(p_token uuid) returns boolean
language plpgsql security definer set search_path = '' as
$$
begin
  update public.bookings set status = 'cancelled', cancelled_by = 'cliente'
   where token = p_token and status = 'confirmed' and starts_at > now();
  return found;
end
$$;

revoke all on function public.busy_intervals(date) from public;
revoke all on function public.create_booking(integer[], timestamptz, integer, text, text, text) from public;
revoke all on function public.get_booking(uuid) from public;
revoke all on function public.cancel_booking(uuid) from public;
grant execute on function public.busy_intervals(date) to anon, authenticated;
grant execute on function public.create_booking(integer[], timestamptz, integer, text, text, text) to anon, authenticated;
grant execute on function public.get_booking(uuid) to anon, authenticated;
grant execute on function public.cancel_booking(uuid) to anon, authenticated;
