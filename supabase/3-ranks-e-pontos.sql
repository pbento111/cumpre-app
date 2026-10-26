-- Cumpre — ranks, pontos e horas de foco contados no servidor (fase 1)
-- Corre depois de 1-base-de-dados.sql. Pode correr-se mais do que uma vez.
--
-- Ideia: os pontos, as horas de foco, os objetivos e o rank deixam de viver só no telemóvel.
-- A app pede ao servidor (funções abaixo) e o servidor decide quanto dá, com os limites das regras.
-- Os alunos só conseguem LER as suas linhas; escrever, só através destas funções.

-- Relógio do servidor (os testes trocam esta função para simular dias a passar).
create or replace function public.cumpre_agora() returns timestamptz language sql stable set search_path = '' as $$ select now() $$;
create or replace function public.cumpre_dia(t timestamptz) returns date language sql stable set search_path = '' as $$ select (t at time zone 'Europe/Lisbon')::date $$;

-- 1. Os ranks e o que cada um pede. Os números mudam-se aqui, sem atualizar a app.
create table if not exists public.ranks (
  id smallint primary key,
  nome text not null,
  horas int not null,
  objetivos int not null,
  dias_conta int not null default 0,
  seq int not null default 0,
  verificado boolean not null default false,
  custo int not null,
  forte text not null,
  clara text not null
);
insert into public.ranks (id, nome, horas, objetivos, dias_conta, seq, verificado, custo, forte, clara) values
  (0, 'Grafite', 0, 0, 0, 0, false, 0, '#3F3F46', '#D4D4D8'),
  (1, 'Bronze', 5, 3, 0, 0, false, 200, '#8C4A22', '#D9A27A'),
  (2, 'Prata', 20, 10, 14, 0, false, 600, '#5E6B78', '#C9D2DB'),
  (3, 'Ouro', 50, 25, 0, 7, false, 1200, '#B8860B', '#F2D372'),
  (4, 'Platina', 100, 50, 90, 0, false, 2000, '#2E6F73', '#A7D8D6'),
  (5, 'Diamante', 180, 90, 180, 0, true, 3000, '#2F5BEA', '#A9C2FF'),
  (6, 'Mentor', 300, 150, 270, 0, true, 4500, '#6D28D9', '#C4B5FD')
on conflict (id) do update set nome = excluded.nome, horas = excluded.horas, objetivos = excluded.objetivos, dias_conta = excluded.dias_conta,
  seq = excluded.seq, verificado = excluded.verificado, custo = excluded.custo, forte = excluded.forte, clara = excluded.clara;

-- 2. Quanto vale cada ação. regra: 'uma' (uma vez na vida), 'ref' (uma vez por item), 'dia' (uma vez por dia), 'refsub' (uma vez por subitem de um item).
--    limite = conta para o máximo de 200 pontos por dia.
create table if not exists public.ganhos (
  tipo text primary key,
  n int not null,
  regra text not null check (regra in ('uma', 'ref', 'dia', 'refsub')),
  limite boolean not null default true,
  max_dia int,
  max_grupo int,
  max_total int,
  objetivo boolean not null default false
);
insert into public.ganhos (tipo, n, regra, limite, max_dia, max_grupo, max_total, objetivo) values
  ('boas-vindas', 150, 'uma', false, null, null, null, false),
  ('horario', 30, 'uma', false, null, null, null, false),
  ('calendario', 30, 'uma', false, null, null, null, false),
  ('lembretes', 20, 'uma', false, null, null, null, false),
  ('foto', 10, 'uma', false, null, null, null, false),
  ('tarefa', 5, 'ref', true, 10, null, null, true),
  ('tema', 10, 'ref', true, 15, null, null, true),
  ('temas-teste', 5, 'refsub', true, 20, 5, null, false),
  ('teste', 30, 'ref', true, 3, null, null, true),
  ('plano', 15, 'dia', true, null, null, null, false),
  ('media', 20, 'ref', true, null, null, 6, false),
  ('ler', 10, 'ref', true, 3, null, null, false)
on conflict (tipo) do update set n = excluded.n, regra = excluded.regra, limite = excluded.limite, max_dia = excluded.max_dia,
  max_grupo = excluded.max_grupo, max_total = excluded.max_total, objetivo = excluded.objetivo;

-- 3. O que se troca na loja (os preços ficam aqui para ninguém trocar mais barato).
create table if not exists public.loja_itens (id text primary key, custo int not null);
insert into public.loja_itens (id, custo) values
  ('guia-resumo', 0), ('guia-7dias', 100), ('tabuada', 100), ('verbos', 150), ('tabela', 150), ('lusiadas', 200),
  ('derivadas', 250), ('probabilidades', 250), ('contabilidade', 250), ('protecao', 150), ('explicacao', 3000)
on conflict (id) do update set custo = excluded.custo;

-- 4. A conta de cada aluno: pontos, horas, rank, ID público.
create table if not exists public.conta (
  user_id uuid primary key references auth.users (id) on delete cascade,
  nome text check (nome ~ '^[a-z0-9_.]{3,16}$'),
  num int check (num between 1 and 99999),
  nome_mudou timestamptz,
  rank smallint not null default 0 references public.ranks (id),
  cor smallint references public.ranks (id),
  saldo int not null default 0 check (saldo >= 0),
  ganho int not null default 0,
  foco_seg int not null default 0,
  objetivos int not null default 0,
  seq int not null default 0,
  seq_max int not null default 0,
  ultimo_dia date,
  protecoes int not null default 0,
  verificado boolean not null default false,
  criado timestamptz not null default now(),
  unique (nome, num)
);

-- 5. Extrato dos pontos (cada ganho e cada gasto).
create table if not exists public.movimentos (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  n int not null,
  tipo text not null,
  motivo text not null,
  chave text,
  dia date not null,
  limite boolean not null default false,
  criado timestamptz not null default now()
);
create unique index if not exists movimentos_chave on public.movimentos (user_id, chave) where chave is not null;
create index if not exists movimentos_dia on public.movimentos (user_id, dia);
create index if not exists movimentos_recentes on public.movimentos (user_id, id desc);

-- 6. Sessões de foco. A app manda um sinal a cada ~5 minutos; só conta o tempo com sinal.
create table if not exists public.sessoes_foco (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  disc text,
  dur int,
  inicio timestamptz not null,
  ultimo timestamptz not null,
  seg_validos numeric not null default 0,
  fim timestamptz,
  seg_final int,
  estado text not null default 'ativa' check (estado in ('ativa', 'fechada'))
);
create index if not exists sessoes_foco_aluno on public.sessoes_foco (user_id, inicio);
create index if not exists sessoes_foco_ativas on public.sessoes_foco (user_id) where estado = 'ativa';

-- 7. Objetivos (tarefas, temas, testes): o servidor guarda quando foram criados, para só contarem 24 h depois.
create table if not exists public.objetivos (
  user_id uuid not null references auth.users (id) on delete cascade,
  oid text not null check (length(oid) <= 100),
  criado timestamptz not null,
  cumprido timestamptz,
  contou boolean not null default false,
  primary key (user_id, oid)
);

-- 8. Ranks comprados, com o número de série ("o 412.º Ouro").
create table if not exists public.ranks_compras (
  user_id uuid not null references auth.users (id) on delete cascade,
  rank smallint not null references public.ranks (id),
  serie int not null,
  criado timestamptz not null default now(),
  primary key (user_id, rank),
  unique (rank, serie)
);

-- Acessos: cada aluno lê só o que é seu; ninguém escreve diretamente.
alter table public.ranks enable row level security;
alter table public.ganhos enable row level security;
alter table public.loja_itens enable row level security;
alter table public.conta enable row level security;
alter table public.movimentos enable row level security;
alter table public.sessoes_foco enable row level security;
alter table public.objetivos enable row level security;
alter table public.ranks_compras enable row level security;
revoke all on public.ranks, public.ganhos, public.loja_itens, public.conta, public.movimentos, public.sessoes_foco, public.objetivos, public.ranks_compras from anon, authenticated;
grant select on public.ranks, public.ganhos, public.loja_itens, public.conta, public.movimentos, public.sessoes_foco, public.ranks_compras to authenticated;
drop policy if exists "todos leem" on public.ranks;
create policy "todos leem" on public.ranks for select to authenticated using (true);
drop policy if exists "todos leem" on public.ganhos;
create policy "todos leem" on public.ganhos for select to authenticated using (true);
drop policy if exists "todos leem" on public.loja_itens;
create policy "todos leem" on public.loja_itens for select to authenticated using (true);
do $$
declare t text;
begin
  foreach t in array array['conta', 'movimentos', 'sessoes_foco', 'ranks_compras'] loop
    execute format('drop policy if exists "ler os meus" on public.%I', t);
    execute format('create policy "ler os meus" on public.%I for select to authenticated using ((select auth.uid()) = user_id)', t);
  end loop;
end $$;

-- ---------- Funções internas (só o servidor as chama) ----------

-- Cria a conta na primeira vez. Traz o que a app já tinha guardado: pontos (até 1000), temas comprados (devolvidos) e até 10 h de foco.
-- Os prémios únicos que a versão antiga já deu (boas-vindas, horário…) ficam marcados para não se darem outra vez.
create or replace function public.cumpre_conta_garantir(u uuid) returns void
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare d jsonb; antigo int := 0; temas int := 0; foco int := 0; k text; criado timestamptz;
begin
  if exists (select 1 from public.conta where user_id = u) then return; end if;
  select dados into d from public.estado where user_id = u;
  select au.created_at into criado from auth.users au where au.id = u;
  -- Só se migra quem já ganhou pontos na versão antiga (contas novas começam do zero no servidor).
  if d is not null and coalesce((d #>> '{pontos,ganho}')::numeric, 0) <= 0 then d := null; end if;
  if d is not null then
    antigo := least(greatest(coalesce((d #>> '{pontos,saldo}')::numeric, 0), 0), 1000)::int;
    select count(*) into temas from jsonb_object_keys(coalesce(d -> 'resgates', '{}'::jsonb)) x where x like 'paleta-%';
    select least(coalesce(sum(greatest(coalesce((s ->> 'min')::numeric, 0), 0)), 0), 600)::int into foco from jsonb_array_elements(coalesce(d -> 'sessoes', '[]'::jsonb)) s;
  end if;
  insert into public.conta (user_id, saldo, ganho, foco_seg, criado, protecoes)
  values (u, antigo + temas * 300, antigo + temas * 300, foco * 60, coalesce(criado, public.cumpre_agora()),
          least(greatest(coalesce((d #>> '{pontos,protecoes}')::numeric, 0), 0), 2)::int)
  on conflict (user_id) do nothing;
  if not found then return; end if;
  if antigo > 0 then insert into public.movimentos (user_id, n, tipo, motivo, dia) values (u, antigo, 'migracao', 'pontos que já tinhas', public.cumpre_dia(public.cumpre_agora())); end if;
  if temas > 0 then insert into public.movimentos (user_id, n, tipo, motivo, dia) values (u, temas * 300, 'devolucao', 'temas de cores devolvidos (agora as cores vêm dos ranks)', public.cumpre_dia(public.cumpre_agora())); end if;
  -- Prémios únicos que já foram dados não se dão outra vez.
  if d is not null and d -> 'perfil' is not null and jsonb_typeof(d -> 'perfil') = 'object' then
    insert into public.movimentos (user_id, n, tipo, motivo, chave, dia) values (u, 0, 'boas-vindas', 'já recebido', 'boas-vindas', public.cumpre_dia(public.cumpre_agora())) on conflict do nothing;
  end if;
  for k in select x from jsonb_object_keys(coalesce(d -> 'premios', '{}'::jsonb)) x loop
    if k in ('horario', 'calendario', 'lembretes', 'foto', 'foco-1') then
      insert into public.movimentos (user_id, n, tipo, motivo, chave, dia) values (u, 0, k, 'já recebido', k, public.cumpre_dia(public.cumpre_agora())) on conflict do nothing;
    end if;
  end loop;
end $$;

-- Dá pontos (respeitando os 200 por dia quando conta para o limite). Devolve quantos deu.
create or replace function public.cumpre_creditar(u uuid, n int, tp text, motivo text, ch text, lim boolean) returns int
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare dia date := public.cumpre_dia(public.cumpre_agora()); hoje int; dar int := n; novo bigint;
begin
  if n <= 0 then return 0; end if;
  perform 1 from public.conta where user_id = u for update;
  if lim then
    select coalesce(sum(m.n), 0) into hoje from public.movimentos m where m.user_id = u and m.dia = dia and m.limite and m.n > 0;
    dar := least(n, 200 - hoje);
    if dar <= 0 then return 0; end if;
  end if;
  insert into public.movimentos (user_id, n, tipo, motivo, chave, dia, limite) values (u, dar, tp, left(motivo, 120), ch, dia, lim)
  on conflict do nothing returning id into novo;
  if novo is null then return 0; end if;
  update public.conta set saldo = saldo + dar, ganho = ganho + dar where user_id = u;
  return dar;
end $$;

-- Tira pontos (troca na loja, compra de rank). Devolve false se não houver pontos que cheguem.
create or replace function public.cumpre_debitar(u uuid, n int, tp text, motivo text, ch text) returns boolean
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare s int; novo bigint;
begin
  select saldo into s from public.conta where user_id = u for update;
  if s is null or s < n then return false; end if;
  if n > 0 or ch is not null then
    insert into public.movimentos (user_id, n, tipo, motivo, chave, dia) values (u, -n, tp, left(motivo, 120), ch, public.cumpre_dia(public.cumpre_agora()))
    on conflict do nothing returning id into novo;
    if novo is null then return false; end if;
  end if;
  update public.conta set saldo = saldo - n where user_id = u;
  return true;
end $$;

-- Emblemas: séries com 5 níveis. Devolve o progresso e dá os pontos dos níveis novos.
create or replace function public.cumpre_emblemas(u uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare c public.conta; v jsonb := '[]'::jsonb; serie record; nivel int; i int; pts int[] := array[10, 25, 50, 100, 200]; val numeric;
  madrug int; fds int; testes int; ganhou int := 0;
begin
  select * into c from public.conta where user_id = u;
  select count(*) into madrug from public.sessoes_foco s where s.user_id = u and s.estado = 'fechada' and s.seg_final >= 600
    and extract(hour from s.inicio at time zone 'Europe/Lisbon') < 9;
  select count(*) into fds from (
    select date_trunc('week', (s.inicio at time zone 'Europe/Lisbon')) w from public.sessoes_foco s
    where s.user_id = u and s.estado = 'fechada' and extract(isodow from s.inicio at time zone 'Europe/Lisbon') in (6, 7)
    group by 1 having sum(s.seg_final) >= 7200) x;
  select count(*) into testes from public.movimentos m where m.user_id = u and m.tipo = 'teste' and m.n > 0;
  for serie in select * from (values
      ('foco', 'Foco', c.foco_seg / 3600.0, array[1, 10, 50, 150, 500], 'h de foco'),
      ('sequencia', 'Sequência', c.seq_max::numeric, array[3, 7, 30, 100, 365], 'dias seguidos'),
      ('objetivos', 'Objetivos', c.objetivos::numeric, array[5, 25, 100, 300, 1000], 'objetivos cumpridos'),
      ('testes', 'Testes', testes::numeric, array[1, 5, 15, 40, 100], 'testes feitos'),
      ('madrugador', 'Madrugador', madrug::numeric, array[3, 10, 30, 75, 150], 'sessões antes das 9:00'),
      ('fds', 'Fim de semana', fds::numeric, array[1, 4, 12, 26, 52], 'fins de semana com 2 h')
    ) t(k, nome, valor, lim, unid) loop
    nivel := 0;
    for i in 1..5 loop if serie.valor >= serie.lim[i] then nivel := i; end if; end loop;
    for i in 1..nivel loop
      ganhou := ganhou + public.cumpre_creditar(u, pts[i], 'emblema', 'emblema ' || serie.nome || ' ' || (array['I', 'II', 'III', 'IV', 'V'])[i], 'emb:' || serie.k || ':' || i, false);
    end loop;
    v := v || jsonb_build_object('k', serie.k, 'nome', serie.nome, 'nivel', nivel, 'valor', floor(serie.valor * 10) / 10, 'lim', to_jsonb(serie.lim), 'unid', serie.unid);
  end loop;
  return jsonb_build_object('series', v, 'fundador', c.criado < timestamptz '2027-09-01', 'ganhou', ganhou);
end $$;

-- Requisitos do rank seguinte: o que já tem e o que falta.
create or replace function public.cumpre_requisitos(u uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare c public.conta; r public.ranks; dias int;
begin
  select * into c from public.conta where user_id = u;
  select * into r from public.ranks where id = c.rank + 1;
  if r.id is null then return null; end if;
  dias := floor(extract(epoch from (public.cumpre_agora() - c.criado)) / 86400);
  return jsonb_build_object('rank', r.id, 'nome', r.nome, 'custo', r.custo,
    'itens', jsonb_build_array(
      jsonb_build_object('k', 'horas', 'tem', floor(c.foco_seg / 360.0) / 10, 'pede', r.horas, 'ok', c.foco_seg >= r.horas * 3600),
      jsonb_build_object('k', 'objetivos', 'tem', c.objetivos, 'pede', r.objetivos, 'ok', c.objetivos >= r.objetivos),
      jsonb_build_object('k', 'dias', 'tem', dias, 'pede', r.dias_conta, 'ok', dias >= r.dias_conta),
      jsonb_build_object('k', 'seq', 'tem', c.seq_max, 'pede', r.seq, 'ok', c.seq_max >= r.seq),
      jsonb_build_object('k', 'verificado', 'tem', c.verificado, 'pede', r.verificado, 'ok', c.verificado or not r.verificado),
      jsonb_build_object('k', 'pontos', 'tem', c.saldo, 'pede', r.custo, 'ok', c.saldo >= r.custo)));
end $$;

-- ---------- Funções que a app chama ----------

-- Tudo o que a app precisa de mostrar: pontos, rank, ID, emblemas, rank seguinte, últimos movimentos.
create or replace function public.conta_estado() returns jsonb
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare u uuid := auth.uid(); c public.conta; e jsonb; hoje int; dia date := public.cumpre_dia(public.cumpre_agora());
begin
  if u is null then raise exception 'sem sessão' using errcode = '42501'; end if;
  perform public.cumpre_conta_garantir(u);
  e := public.cumpre_emblemas(u);
  select * into c from public.conta where user_id = u;
  select coalesce(sum(m.n), 0) into hoje from public.movimentos m where m.user_id = u and m.dia = dia and m.limite and m.n > 0;
  return jsonb_build_object(
    'saldo', c.saldo, 'ganho', c.ganho, 'rank', c.rank, 'cor', coalesce(c.cor, c.rank), 'nome', c.nome, 'num', c.num,
    'pode_mudar_nome', c.nome_mudou is null or c.nome_mudou < public.cumpre_agora() - interval '30 days',
    'foco_seg', c.foco_seg, 'objetivos', c.objetivos, 'seq', case when c.ultimo_dia >= dia - 1 then c.seq else 0 end, 'seq_max', c.seq_max,
    'presente_hoje', c.ultimo_dia = dia, 'protecoes', c.protecoes, 'verificado', c.verificado,
    'dias_conta', floor(extract(epoch from (public.cumpre_agora() - c.criado)) / 86400), 'hoje_limite', hoje,
    'seg_hoje', (select coalesce(sum(s.seg_final), 0) from public.sessoes_foco s where s.user_id = u and s.estado = 'fechada' and public.cumpre_dia(s.inicio) = dia),
    'series', (select coalesce(jsonb_object_agg(rc.rank, rc.serie), '{}'::jsonb) from public.ranks_compras rc where rc.user_id = u),
    'seguinte', public.cumpre_requisitos(u),
    'emblemas', e,
    'log', (select coalesce(jsonb_agg(jsonb_build_object('t', extract(epoch from x.criado) * 1000, 'n', x.n, 'm', x.motivo) order by x.id desc), '[]'::jsonb)
            from (select * from public.movimentos m where m.user_id = u and m.n <> 0 order by m.id desc limit 30) x));
end $$;

-- Abrir a app conta para a sequência (uma vez por dia). Uma proteção salva um dia falhado.
create or replace function public.presenca() returns jsonb
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare u uuid := auth.uid(); c public.conta; dia date := public.cumpre_dia(public.cumpre_agora()); s int; marco int; dado int := 0;
begin
  if u is null then raise exception 'sem sessão' using errcode = '42501'; end if;
  perform public.cumpre_conta_garantir(u);
  select * into c from public.conta where user_id = u for update;
  if c.ultimo_dia = dia then return public.conta_estado(); end if;
  if c.ultimo_dia = dia - 1 then s := c.seq + 1;
  elsif c.ultimo_dia = dia - 2 and c.protecoes > 0 then s := c.seq + 2; update public.conta set protecoes = protecoes - 1 where user_id = u;
  else s := 1; end if;
  update public.conta set seq = s, seq_max = greatest(seq_max, s), ultimo_dia = dia where user_id = u;
  dado := public.cumpre_creditar(u, 5, 'presenca', 'presença de hoje', 'presenca:' || dia, false);
  marco := case s when 3 then 15 when 7 then 50 when 14 then 100 when 30 then 250 else case when s > 30 and s % 30 = 0 then 250 else 0 end end;
  if marco > 0 then dado := dado + public.cumpre_creditar(u, marco, 'sequencia', s || ' dias seguidos', 'seq:' || dia, false); end if;
  return public.conta_estado() || jsonb_build_object('dado', dado);
end $$;

-- Ganhar pontos por uma ação (tarefa feita, tema revisto, etc.). O servidor decide quanto e se ainda pode.
create or replace function public.pontos_ganhar(p_tipo text, p_ref text default null, p_sub text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare u uuid := auth.uid(); g public.ganhos; ch text; dia date := public.cumpre_dia(public.cumpre_agora()); n int; dado int := 0;
  motivo text; obj boolean := false; contados int;
begin
  if u is null then raise exception 'sem sessão' using errcode = '42501'; end if;
  perform public.cumpre_conta_garantir(u);
  select * into g from public.ganhos where tipo = p_tipo;
  if g.tipo is null then raise exception 'ação desconhecida'; end if;
  if (g.regra in ('ref', 'refsub') and coalesce(length(p_ref), 0) not between 1 and 80) or (g.regra = 'refsub' and coalesce(length(p_sub), 0) not between 1 and 80) then
    raise exception 'referência inválida';
  end if;
  ch := case g.regra when 'uma' then g.tipo when 'ref' then g.tipo || ':' || p_ref when 'dia' then g.tipo || ':' || dia else g.tipo || ':' || p_ref || ':' || p_sub end;
  motivo := case g.tipo when 'boas-vindas' then 'boas-vindas' when 'horario' then 'horário criado' when 'calendario' then 'calendário da escola ligado'
    when 'lembretes' then 'lembretes ligados' when 'foto' then 'foto de perfil' when 'tarefa' then 'tarefa feita' when 'tema' then 'tema revisto'
    when 'temas-teste' then 'temas de um teste' when 'teste' then 'teste feito' when 'plano' then 'estudo de hoje cumprido'
    when 'media' then 'notas na calculadora de média' when 'ler' then 'resumo lido até ao fim' else g.tipo end;
  if exists (select 1 from public.movimentos m where m.user_id = u and m.chave = ch) then return public.conta_estado() || jsonb_build_object('dado', 0); end if;
  select count(*) into n from public.movimentos m where m.user_id = u and m.tipo = g.tipo and m.dia = dia;
  if g.max_dia is null or n < g.max_dia then
    if g.max_grupo is not null then select count(*) into n from public.movimentos m where m.user_id = u and left(m.chave, length(g.tipo || ':' || p_ref || ':')) = g.tipo || ':' || p_ref || ':'; end if;
    if g.max_grupo is null or n < g.max_grupo then
      if g.max_total is not null then select count(*) into n from public.movimentos m where m.user_id = u and m.tipo = g.tipo; end if;
      if g.max_total is null or n < g.max_total then dado := public.cumpre_creditar(u, g.n, g.tipo, motivo, ch, g.limite); end if;
    end if;
  end if;
  -- Objetivo cumprido: conta para o rank se foi criado há pelo menos 24 h (no máximo 5 por dia).
  if g.objetivo then
    select count(*) into contados from public.objetivos o where o.user_id = u and o.contou and public.cumpre_dia(o.cumprido) = dia;
    update public.objetivos o set cumprido = public.cumpre_agora(), contou = (o.criado <= public.cumpre_agora() - interval '24 hours' and contados < 5)
      where o.user_id = u and o.oid = g.tipo || ':' || p_ref and o.cumprido is null returning o.contou into obj;
    if coalesce(obj, false) then update public.conta set objetivos = objetivos + 1 where user_id = u; end if;
  end if;
  return public.conta_estado() || jsonb_build_object('dado', dado, 'objetivo', coalesce(obj, false));
end $$;

-- Regista objetivos novos (a hora de criação é a do servidor).
create or replace function public.objetivos_criar(p_oids text[]) returns int
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare u uuid := auth.uid(); n int;
begin
  if u is null then raise exception 'sem sessão' using errcode = '42501'; end if;
  if coalesce(array_length(p_oids, 1), 0) > 300 then raise exception 'demasiados de uma vez'; end if;
  insert into public.objetivos (user_id, oid, criado)
  select u, x, public.cumpre_agora() from unnest(p_oids) x where length(x) between 3 and 100 and split_part(x, ':', 1) in ('tarefa', 'tema', 'teste')
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

-- Começar uma sessão de foco. Só pode haver uma de cada vez: começar outra fecha a anterior.
create or replace function public.foco_iniciar(p_disc text, p_dur int) returns uuid
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare u uuid := auth.uid(); s uuid; novo uuid; agora timestamptz := public.cumpre_agora();
begin
  if u is null then raise exception 'sem sessão' using errcode = '42501'; end if;
  perform public.cumpre_conta_garantir(u);
  for s in select id from public.sessoes_foco where user_id = u and estado = 'ativa' loop
    perform public.cumpre_foco_fechar(u, s, null, false);
  end loop;
  if (select count(*) from public.sessoes_foco where user_id = u and inicio > agora - interval '1 day') >= 40 then raise exception 'demasiadas sessões hoje'; end if;
  insert into public.sessoes_foco (user_id, disc, dur, inicio, ultimo) values (u, left(p_disc, 80), least(greatest(coalesce(p_dur, 25), 1), 240), agora, agora)
  returning id into novo;
  return novo;
end $$;

-- Sinal de "ainda estou a estudar". Conta o tempo desde o último sinal (no máximo 5,5 min).
-- p_reset = true quando o aluno volta de uma pausa ou de outra app: esse tempo não conta.
create or replace function public.foco_sinal(p_id uuid, p_reset boolean default false) returns numeric
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare u uuid := auth.uid(); v numeric; agora timestamptz := public.cumpre_agora();
begin
  if u is null then raise exception 'sem sessão' using errcode = '42501'; end if;
  update public.sessoes_foco set seg_validos = seg_validos + case when p_reset then 0 else least(greatest(extract(epoch from (agora - ultimo)), 0), 330) end, ultimo = agora
  where id = p_id and user_id = u and estado = 'ativa' returning seg_validos into v;
  return v;
end $$;

create or replace function public.cumpre_foco_fechar(u uuid, p_id uuid, p_seg int, p_completa boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare s public.sessoes_foco; agora timestamptz := public.cumpre_agora(); seg numeric; hoje int; mins int; pts int := 0; dado int := 0; extra int := 0;
begin
  select * into s from public.sessoes_foco where id = p_id and user_id = u and estado = 'ativa' for update;
  if s.id is null then return jsonb_build_object('min', 0, 'dado', 0); end if;
  seg := s.seg_validos + least(greatest(extract(epoch from (agora - s.ultimo)), 0), 330);
  if p_seg is not null then seg := least(seg, greatest(p_seg, 0)); end if;
  seg := least(seg, 10800, extract(epoch from (agora - s.inicio)));
  select coalesce(sum(x.seg_final), 0) into hoje from public.sessoes_foco x where x.user_id = u and x.estado = 'fechada' and public.cumpre_dia(x.inicio) = public.cumpre_dia(s.inicio);
  seg := greatest(least(seg, 28800 - hoje), 0);
  update public.sessoes_foco set estado = 'fechada', fim = agora, seg_final = floor(seg) where id = s.id;
  update public.conta set foco_seg = foco_seg + floor(seg) where user_id = u;
  mins := floor(seg / 60);
  if mins >= 1 then
    pts := (mins / 5) * 2 + case when p_completa and seg >= s.dur * 60 - 60 then 5 else 0 end;
    dado := public.cumpre_creditar(u, pts, 'foco', mins || ' min de foco', null, true);
    extra := public.cumpre_creditar(u, 20, 'foco-1', 'primeira sessão em modo foco', 'foco-1', false);
  end if;
  return jsonb_build_object('min', mins, 'pts', pts, 'dado', dado + extra);
end $$;

-- Terminar a sessão: o servidor conta só o tempo com sinal (máx. 3 h por sessão e 8 h por dia).
create or replace function public.foco_terminar(p_id uuid, p_seg int, p_completa boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare u uuid := auth.uid(); r jsonb;
begin
  if u is null then raise exception 'sem sessão' using errcode = '42501'; end if;
  r := public.cumpre_foco_fechar(u, p_id, p_seg, coalesce(p_completa, false));
  return public.conta_estado() || jsonb_build_object('foco', r);
end $$;

-- Cancelar a sessão (não conta nada).
create or replace function public.foco_cancelar(p_id uuid) returns void
language sql security definer set search_path = '' as $$
  update public.sessoes_foco set estado = 'fechada', fim = public.cumpre_agora(), seg_final = 0 where id = p_id and user_id = auth.uid() and estado = 'ativa';
$$;

-- Subir de rank: só o seguinte, e só com todos os requisitos.
create or replace function public.rank_subir() returns jsonb
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare u uuid := auth.uid(); req jsonb; r public.ranks; s int;
begin
  if u is null then raise exception 'sem sessão' using errcode = '42501'; end if;
  perform public.cumpre_conta_garantir(u);
  perform 1 from public.conta where user_id = u for update;
  req := public.cumpre_requisitos(u);
  if req is null then return public.conta_estado() || jsonb_build_object('ok', false, 'erro', 'Já estás no rank mais alto.'); end if;
  if exists (select 1 from jsonb_array_elements(req -> 'itens') i where not (i ->> 'ok')::boolean) then
    return public.conta_estado() || jsonb_build_object('ok', false, 'erro', 'Ainda faltam requisitos.');
  end if;
  select * into r from public.ranks where id = (req ->> 'rank')::smallint;
  if not public.cumpre_debitar(u, r.custo, 'rank', 'rank ' || r.nome, 'rank:' || r.id) then
    return public.conta_estado() || jsonb_build_object('ok', false, 'erro', 'Não tens pontos suficientes.');
  end if;
  perform pg_advisory_xact_lock(hashtext('cumpre-rank-' || r.id));
  select coalesce(max(serie), 0) + 1 into s from public.ranks_compras where rank = r.id;
  insert into public.ranks_compras (user_id, rank, serie, criado) values (u, r.id, s, public.cumpre_agora());
  update public.conta set rank = r.id, cor = null where user_id = u;
  return public.conta_estado() || jsonb_build_object('ok', true, 'serie', s);
end $$;

-- Usar a cor de um rank que já se tem (ou a do rank atual, com null).
create or replace function public.cor_escolher(p_rank smallint) returns jsonb
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'sem sessão' using errcode = '42501'; end if;
  update public.conta set cor = case when p_rank is null or p_rank >= rank then null else greatest(p_rank, 0) end where user_id = u;
  return public.conta_estado();
end $$;

-- Escolher o ID público (@nome#1234). O nome muda uma vez a cada 30 dias; o número fica se estiver livre.
create or replace function public.id_escolher(p_nome text) returns jsonb
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare u uuid := auth.uid(); c public.conta; nm text := lower(trim(coalesce(p_nome, ''))); n int; i int;
  proibidos text[] := array['cumpre', 'admin', 'administrador', 'suporte', 'mentor', 'moderador', 'equipa', 'staff', 'oficial', 'root', 'sistema'];
begin
  if u is null then raise exception 'sem sessão' using errcode = '42501'; end if;
  perform public.cumpre_conta_garantir(u);
  if nm !~ '^[a-z0-9_.]{3,16}$' then return public.conta_estado() || jsonb_build_object('ok', false, 'erro', 'Usa 3 a 16 letras minúsculas, números, _ ou .'); end if;
  if nm ~ '^[._]|[._]$|\.\.' then return public.conta_estado() || jsonb_build_object('ok', false, 'erro', 'O nome não pode começar nem acabar com . ou _'); end if;
  if exists (select 1 from unnest(proibidos) p where position(p in nm) > 0) then return public.conta_estado() || jsonb_build_object('ok', false, 'erro', 'Esse nome está reservado. Escolhe outro.'); end if;
  if exists (select 1 from unnest(array['merda', 'puta', 'caralho', 'foda', 'cona', 'piça', 'pila', 'fdp', 'nazi', 'hitler', 'porn', 'sexo', 'cabrao', 'paneleiro', 'preto', 'macaco']) p where position(p in nm) > 0) then
    return public.conta_estado() || jsonb_build_object('ok', false, 'erro', 'Esse nome não é permitido. Escolhe outro.');
  end if;
  select * into c from public.conta where user_id = u for update;
  if c.nome = nm then return public.conta_estado() || jsonb_build_object('ok', true); end if;
  if c.nome is not null and c.nome_mudou is not null and c.nome_mudou > public.cumpre_agora() - interval '30 days' then
    return public.conta_estado() || jsonb_build_object('ok', false, 'erro', 'Só podes mudar o nome uma vez a cada 30 dias.');
  end if;
  perform pg_advisory_xact_lock(hashtext('cumpre-id-' || nm));
  n := c.num;
  if n is null or exists (select 1 from public.conta where nome = nm and num = n) then
    n := null;
    for i in 1..60 loop
      n := 1 + floor(random() * 9999)::int;
      exit when not exists (select 1 from public.conta where nome = nm and num = n);
      n := null;
    end loop;
    if n is null then
      for i in 1..60 loop
        n := 10000 + floor(random() * 90000)::int;
        exit when not exists (select 1 from public.conta where nome = nm and num = n);
        n := null;
      end loop;
    end if;
  end if;
  if n is null then return public.conta_estado() || jsonb_build_object('ok', false, 'erro', 'Esse nome está muito usado. Experimenta outro.'); end if;
  update public.conta set nome = nm, num = n, nome_mudou = case when c.nome is null then null else public.cumpre_agora() end where user_id = u;
  return public.conta_estado() || jsonb_build_object('ok', true);
end $$;

-- Trocar pontos na loja (resumos, proteção da sequência, explicação).
create or replace function public.loja_trocar(p_item text, p_ref text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare u uuid := auth.uid(); it public.loja_itens; ch text; c public.conta;
begin
  if u is null then raise exception 'sem sessão' using errcode = '42501'; end if;
  perform public.cumpre_conta_garantir(u);
  select * into it from public.loja_itens where id = p_item;
  if it.id is null then return public.conta_estado() || jsonb_build_object('ok', false, 'erro', 'Este item já não existe.'); end if;
  select * into c from public.conta where user_id = u for update;
  if it.id = 'protecao' then
    if c.protecoes >= 2 then return public.conta_estado() || jsonb_build_object('ok', false, 'erro', 'Já tens 2 proteções.'); end if;
    ch := null;
  elsif it.id = 'explicacao' then
    if coalesce(length(p_ref), 0) not between 1 and 80 then raise exception 'referência inválida'; end if;
    ch := 'loja:explicacao:' || p_ref;
  else
    ch := 'loja:' || it.id;
    if exists (select 1 from public.movimentos m where m.user_id = u and m.chave = ch) then return public.conta_estado() || jsonb_build_object('ok', true, 'ja', true); end if;
  end if;
  if not public.cumpre_debitar(u, it.custo, 'loja', 'troca: ' || it.id, ch) then
    return public.conta_estado() || jsonb_build_object('ok', false, 'erro', 'Não tens pontos suficientes.');
  end if;
  if it.id = 'protecao' then update public.conta set protecoes = protecoes + 1 where user_id = u; end if;
  return public.conta_estado() || jsonb_build_object('ok', true);
end $$;

-- Devolver os pontos de uma explicação cancelada ou sem explicador (uma vez por pedido).
create or replace function public.loja_devolver(p_pid text) returns jsonb
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare u uuid := auth.uid(); p public.pedidos_explicacao; pago int; dado int := 0;
begin
  if u is null then raise exception 'sem sessão' using errcode = '42501'; end if;
  select -m.n into pago from public.movimentos m where m.user_id = u and m.chave = 'loja:explicacao:' || p_pid;
  select * into p from public.pedidos_explicacao where user_id = u and pid = p_pid;
  if pago > 0 and (p.id is null or p.estado in ('cancelado', 'sem explicador') or (p.estado = 'à procura' and p.criado < public.cumpre_agora() - interval '30 days')) then
    dado := public.cumpre_creditar(u, pago, 'devolucao', 'explicação: pontos devolvidos', 'dev:' || p_pid, false);
  end if;
  return public.conta_estado() || jsonb_build_object('dado', dado);
end $$;

-- Só a app (com sessão) chama as funções públicas; as internas ficam fechadas.
do $$
declare f text;
begin
  foreach f in array array['cumpre_conta_garantir(uuid)', 'cumpre_creditar(uuid,int,text,text,text,boolean)', 'cumpre_debitar(uuid,int,text,text,text)',
    'cumpre_emblemas(uuid)', 'cumpre_requisitos(uuid)', 'cumpre_foco_fechar(uuid,uuid,int,boolean)', 'cumpre_agora()', 'cumpre_dia(timestamptz)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
  end loop;
  foreach f in array array['conta_estado()', 'presenca()', 'pontos_ganhar(text,text,text)', 'objetivos_criar(text[])', 'foco_iniciar(text,int)',
    'foco_sinal(uuid,boolean)', 'foco_terminar(uuid,int,boolean)', 'foco_cancelar(uuid)', 'rank_subir()', 'cor_escolher(smallint)', 'id_escolher(text)',
    'loja_trocar(text,text)', 'loja_devolver(text)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;
