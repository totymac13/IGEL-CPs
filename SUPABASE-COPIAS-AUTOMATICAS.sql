-- TOTY Planner: copias en la nube y backup diario a las 23:59 (Europe/Madrid)
-- Ejecuta este archivo completo en Supabase > SQL Editor, después de crear tu proyecto.
-- No pegues aquí claves secretas ni compartas las credenciales.

create extension if not exists pg_cron with schema pg_catalog;

-- Tabla principal que utiliza la sincronización de TOTY Planner.
create table if not exists public.planner_data (
  user_id uuid primary key references auth.users(id) on delete cascade,
  data jsonb not null default '{"days":{},"budgets":{},"appointments":[]}'::jsonb,
  updated_at timestamptz not null default now()
);

alter table public.planner_data enable row level security;
drop policy if exists "TOTY users manage own planner data" on public.planner_data;
create policy "TOTY users manage own planner data"
  on public.planner_data for all to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

-- Copias independientes de los datos sincronizados.
create table if not exists public.toty_backups (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  data jsonb not null,
  source text not null default 'manual' check (source in ('manual','scheduled')),
  backup_date date not null default (now() at time zone 'Europe/Madrid')::date,
  created_at timestamptz not null default now()
);
create index if not exists toty_backups_user_created_idx
  on public.toty_backups(user_id, created_at desc);
create unique index if not exists toty_backups_one_scheduled_per_day
  on public.toty_backups(user_id, backup_date) where source = 'scheduled';

alter table public.toty_backups enable row level security;
drop policy if exists "TOTY users read own backups" on public.toty_backups;
create policy "TOTY users read own backups"
  on public.toty_backups for select to authenticated
  using (auth.uid() = user_id);
drop policy if exists "TOTY users create own manual backups" on public.toty_backups;
create policy "TOTY users create own manual backups"
  on public.toty_backups for insert to authenticated
  with check (auth.uid() = user_id and source = 'manual');

-- Solo pg_cron ejecuta esta función. La función comprueba la hora de Madrid,
-- por lo que se adapta al horario de verano/invierno sin cambiar el cron.
create or replace function public.toty_create_daily_backups()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  madrid_now timestamp without time zone := now() at time zone 'Europe/Madrid';
begin
  if to_char(madrid_now, 'HH24:MI') <> '23:59' then
    return;
  end if;

  insert into public.toty_backups(user_id, data, source, backup_date, created_at)
  select p.user_id, p.data, 'scheduled', madrid_now::date, now()
  from public.planner_data p
  where not exists (
    select 1 from public.toty_backups b
    where b.user_id = p.user_id
      and b.backup_date = madrid_now::date
      and b.source = 'scheduled'
  )
  on conflict (user_id, backup_date) where source = 'scheduled' do nothing;
end;
$$;

revoke all on function public.toty_create_daily_backups() from public, anon, authenticated;

-- Evita crear un segundo job con el mismo nombre si se vuelve a ejecutar el SQL.
do $$
declare existing_job record;
begin
  for existing_job in select jobid from cron.job where jobname = 'toty-planner-daily-backup' loop
    perform cron.unschedule(existing_job.jobid);
  end loop;
end $$;

-- Se ejecuta cada minuto; la función solo crea copias cuando en Madrid son las 23:59.
select cron.schedule(
  'toty-planner-daily-backup',
  '* * * * *',
  'select public.toty_create_daily_backups();'
);

-- Comprobación posterior: muestra el job y su última ejecución.
select jobid, jobname, schedule, active from cron.job where jobname = 'toty-planner-daily-backup';
