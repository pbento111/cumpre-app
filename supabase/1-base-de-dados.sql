-- Cumpre — base de dados (Supabase)
-- Cola tudo no SQL Editor do Supabase e carrega em "Run". Pode correr-se mais do que uma vez.

-- 1. O estado de cada aluno: perfil, disciplinas, resumos, datas, pontos. Um registo por pessoa.
create table if not exists public.estado (
  user_id uuid primary key references auth.users (id) on delete cascade,
  dados jsonb not null default '{}'::jsonb,
  atualizado timestamptz not null default now()
);

alter table public.estado enable row level security;

grant select, insert, update, delete on public.estado to authenticated;
revoke all on public.estado from anon;

-- Cada aluno só vê e muda o seu próprio registo.
drop policy if exists "ver o meu estado" on public.estado;
create policy "ver o meu estado" on public.estado
  for select to authenticated using ((select auth.uid()) = user_id);

drop policy if exists "criar o meu estado" on public.estado;
create policy "criar o meu estado" on public.estado
  for insert to authenticated with check ((select auth.uid()) = user_id);

drop policy if exists "mudar o meu estado" on public.estado;
create policy "mudar o meu estado" on public.estado
  for update to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

drop policy if exists "apagar o meu estado" on public.estado;
create policy "apagar o meu estado" on public.estado
  for delete to authenticated using ((select auth.uid()) = user_id);

-- Mudanças aparecem logo nos outros aparelhos do mesmo aluno (telemóvel e computador).
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'estado'
  ) then
    alter publication supabase_realtime add table public.estado;
  end if;
end $$;

-- 2. Ficheiros (anexos dos resumos e fotos de perfil): pasta privada, até 20 MB por ficheiro.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('anexos', 'anexos', false, 20971520,
        array['image/jpeg', 'image/png', 'image/gif', 'image/webp', 'application/pdf'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Cada aluno só mexe na pasta com o seu id: anexos/<id do aluno>/...
drop policy if exists "ver os meus ficheiros" on storage.objects;
create policy "ver os meus ficheiros" on storage.objects
  for select to authenticated
  using (bucket_id = 'anexos' and (storage.foldername(name))[1] = (select auth.uid())::text);

drop policy if exists "enviar para a minha pasta" on storage.objects;
create policy "enviar para a minha pasta" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'anexos' and (storage.foldername(name))[1] = (select auth.uid())::text);

drop policy if exists "mudar os meus ficheiros" on storage.objects;
create policy "mudar os meus ficheiros" on storage.objects
  for update to authenticated
  using (bucket_id = 'anexos' and (storage.foldername(name))[1] = (select auth.uid())::text);

drop policy if exists "apagar os meus ficheiros" on storage.objects;
create policy "apagar os meus ficheiros" on storage.objects
  for delete to authenticated
  using (bucket_id = 'anexos' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- 3. Contador das leituras de horários por IA: cada aluno tem um limite por dia (para não gastar demais).
create table if not exists public.uso_ia (
  user_id uuid not null references auth.users (id) on delete cascade,
  dia date not null default current_date,
  n integer not null default 0,
  primary key (user_id, dia)
);
alter table public.uso_ia enable row level security;
revoke all on public.uso_ia from anon, authenticated;

-- Só o servidor da Cumpre (função "cumpre") pode contar.
create or replace function public.usar_ia(p_user uuid)
returns integer
language sql
security definer
set search_path = public
as $$
  insert into public.uso_ia as u (user_id, dia, n) values (p_user, current_date, 1)
  on conflict (user_id, dia) do update set n = u.n + 1
  returning n;
$$;
revoke all on function public.usar_ia(uuid) from public, anon, authenticated;
grant execute on function public.usar_ia(uuid) to service_role;

-- 4. Lembretes no telemóvel: os aparelhos de cada aluno e os avisos marcados (7 dias, 3 dias e véspera de cada teste).
create table if not exists public.push_subs (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  endpoint text not null,
  p256dh text not null,
  auth text not null,
  criado timestamptz not null default now(),
  unique (user_id, endpoint)
);
create table if not exists public.lembretes (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  chave text not null,
  quando timestamptz not null,
  titulo text not null,
  corpo text not null default '',
  enviado boolean not null default false,
  unique (user_id, chave)
);
create index if not exists lembretes_por_enviar on public.lembretes (quando) where not enviado;

-- 5. Pedidos de explicação grátis (trocados por pontos). Vês e mudas o estado em Table Editor → pedidos_explicacao.
create table if not exists public.pedidos_explicacao (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  pid text not null,
  dados jsonb not null,
  estado text not null default 'à procura',
  criado timestamptz not null default now(),
  unique (user_id, pid)
);

alter table public.push_subs enable row level security;
alter table public.lembretes enable row level security;
alter table public.pedidos_explicacao enable row level security;
grant select, insert, update, delete on public.push_subs, public.lembretes, public.pedidos_explicacao to authenticated;
revoke all on public.push_subs, public.lembretes, public.pedidos_explicacao from anon;

-- Cada aluno só vê e mexe nos seus.
do $$
declare t text;
begin
  foreach t in array array['push_subs', 'lembretes', 'pedidos_explicacao'] loop
    execute format('drop policy if exists "os meus" on public.%I', t);
    execute format('create policy "os meus" on public.%I for all to authenticated using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id)', t);
  end loop;
end $$;

-- 6. Configuração que só o servidor lê (chaves das notificações e o segredo do agendador).
create table if not exists public.config_privada (
  chave text primary key,
  valor jsonb not null
);
alter table public.config_privada enable row level security;
revoke all on public.config_privada from anon, authenticated;
insert into public.config_privada (chave, valor)
values ('cron', to_jsonb(replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '')))
on conflict (chave) do nothing;

-- 7. Agendador: de 10 em 10 minutos pede à função "cumpre" que envie os lembretes que chegaram à hora.
create extension if not exists pg_cron;
create extension if not exists pg_net;
select cron.unschedule(jobid) from cron.job where jobname = 'cumpre-lembretes';
select cron.schedule('cumpre-lembretes', '*/10 * * * *', $cron$
  select net.http_post(
    url := 'https://zvyhytddpqultyilcqsn.supabase.co/functions/v1/cumpre',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cumpre-cron', (select valor #>> '{}' from public.config_privada where chave = 'cron')),
    body := '{"acao": "enviar-lembretes"}'::jsonb,
    timeout_milliseconds := 30000
  );
$cron$);
