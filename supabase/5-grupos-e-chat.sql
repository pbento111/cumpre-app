-- Cumpre — fase 3: grupos só por código, estudar juntos e chat com regras, denúncias, sanções e moderação.
-- Corre depois de 4-verificacao-e-ranking.sql. Pode correr-se mais do que uma vez.

-- ---------- Regras dos grupos (mudam-se aqui, sem atualizar a app) ----------
create table if not exists public.config_grupos (k text primary key, v jsonb not null);
insert into public.config_grupos (k, v) values ('regras', jsonb_build_object(
  'entrar', 1, 'criar', 2,                         -- rank mínimo para entrar (Bronze) e para criar (Prata)
  'lancamento_ate', '2026-12-31', 'entrar_lanc', 0, 'criar_lanc', 1,   -- nos 2 primeiros meses: entrar aberto, criar a partir de Bronze
  'max_entrar', jsonb_build_array(3, 5, 8, 10, 10, 12, 15),          -- quantos grupos pode ter, por rank
  'max_criar', jsonb_build_array(0, 1, 1, 2, 3, 4, 5),               -- quantos pode criar, por rank
  'tamanho', jsonb_build_array(15, 15, 15, 25, 40, 60, 100)          -- tamanho máximo do grupo, pelo rank de quem o cria
)) on conflict (k) do nothing;
alter table public.config_grupos enable row level security;
revoke all on public.config_grupos from anon, authenticated;

alter table public.conta add column if not exists regras_chat timestamptz;
alter table public.conta add column if not exists chat_ate timestamptz;
alter table public.conta add column if not exists chat_banido boolean not null default false;

create table if not exists public.admins (user_id uuid primary key references auth.users (id) on delete cascade);
alter table public.admins enable row level security;
revoke all on public.admins from anon, authenticated;
insert into public.admins (user_id) select id from auth.users where email = 'pedrombento.06@gmail.com' on conflict do nothing;

create table if not exists public.grupos (
  id uuid primary key default gen_random_uuid(),
  nome text not null check (length(nome) between 3 and 40),
  codigo text not null unique,
  codigo_expira timestamptz,
  aprovacao boolean not null default false,
  dono uuid references auth.users (id) on delete set null,
  faixa text not null check (faixa in ('menores', 'adultos')),
  escola_id text,
  max int not null default 15,
  criado timestamptz not null default public.cumpre_agora(),
  atividade timestamptz not null default public.cumpre_agora(),
  arquivado boolean not null default false,
  sala jsonb
);
create table if not exists public.grupo_membros (
  grupo uuid not null references public.grupos (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  papel text not null default 'membro' check (papel in ('dono', 'membro')),
  estado text not null default 'ativo' check (estado in ('ativo', 'pendente')),
  entrou timestamptz not null default public.cumpre_agora(),
  silenciado_ate timestamptz,
  lido bigint not null default 0,
  primary key (grupo, user_id)
);
create index if not exists grupo_membros_aluno on public.grupo_membros (user_id);
create table if not exists public.mensagens (
  id bigint generated always as identity primary key,
  grupo uuid not null references public.grupos (id) on delete cascade,
  user_id uuid references auth.users (id) on delete set null,
  texto text not null default '' check (length(texto) <= 1000),
  anexo jsonb,
  criado timestamptz not null default public.cumpre_agora(),
  escondida boolean not null default false,
  apagada boolean not null default false,
  revisao text check (revisao in ('por rever', 'revista')),
  ia jsonb
);
create index if not exists mensagens_grupo on public.mensagens (grupo, id desc);
create index if not exists mensagens_por_rever on public.mensagens (criado) where revisao = 'por rever';
create table if not exists public.denuncias (
  id bigint generated always as identity primary key,
  mensagem bigint not null references public.mensagens (id) on delete cascade,
  por uuid not null references auth.users (id) on delete cascade,
  motivo text not null,
  criado timestamptz not null default public.cumpre_agora(),
  unique (mensagem, por)
);
create table if not exists public.sancoes (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  gravidade text not null check (gravidade in ('leve', 'media', 'grave', 'gravissima')),
  efeito text not null check (efeito in ('aviso', 'silencio', 'fora', 'banido', 'provisorio')),
  ate timestamptz,
  regra int,
  motivo text not null,
  mensagem bigint references public.mensagens (id) on delete set null,
  por text not null check (por in ('filtro', 'ia', 'equipa', 'dono')),
  criado timestamptz not null default public.cumpre_agora(),
  recurso text,
  recurso_estado text check (recurso_estado in ('pendente', 'aceite', 'recusado')),
  anulada boolean not null default false
);
create index if not exists sancoes_aluno on public.sancoes (user_id, criado desc);
create table if not exists public.chat_bloqueios (
  user_id uuid not null references auth.users (id) on delete cascade,
  criado timestamptz not null default public.cumpre_agora(),
  motivo text not null
);
create index if not exists chat_bloqueios_aluno on public.chat_bloqueios (user_id, criado);

do $$
declare t text;
begin
  foreach t in array array['grupos', 'grupo_membros', 'mensagens', 'denuncias', 'sancoes', 'chat_bloqueios'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
  end loop;
end $$;

-- ---------- Ficheiros do chat (fotos e PDF, a partir dos 16 anos) ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('chat', 'chat', false, 5242880, array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
on conflict (id) do update set file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

create or replace function public.cumpre_membro(u uuid, g uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.grupo_membros m join public.grupos gr on gr.id = m.grupo where m.grupo = g and m.user_id = u and m.estado = 'ativo' and not gr.arquivado)
$$;
-- Para as regras dos ficheiros: só sobre o próprio aluno (não deixam ver a idade nem os grupos de outros).
create or replace function public.cumpre_sou_membro(g text) returns boolean
language plpgsql stable security definer set search_path = '' as $$
begin
  return public.cumpre_membro(auth.uid(), g::uuid);
exception when others then return false;
end $$;
create or replace function public.cumpre_posso_anexar(g text) returns boolean
language plpgsql stable security definer set search_path = '' as $$
begin
  return public.cumpre_membro(auth.uid(), g::uuid) and public.cumpre_idade(auth.uid()) >= 16;
exception when others then return false;
end $$;
grant execute on function public.cumpre_sou_membro(text), public.cumpre_posso_anexar(text) to authenticated;
-- Caminho: <aluno>/<grupo>/<ficheiro>. Quem envia é o dono da pasta; quem lê é quem está no grupo.
drop policy if exists "chat: enviar" on storage.objects;
create policy "chat: enviar" on storage.objects for insert to authenticated
  with check (bucket_id = 'chat' and (storage.foldername(name))[1] = (select auth.uid())::text
    and public.cumpre_posso_anexar((storage.foldername(name))[2]));
drop policy if exists "chat: ver" on storage.objects;
create policy "chat: ver" on storage.objects for select to authenticated
  using (bucket_id = 'chat' and public.cumpre_sou_membro((storage.foldername(name))[2]));
drop policy if exists "chat: apagar os meus" on storage.objects;
create policy "chat: apagar os meus" on storage.objects for delete to authenticated
  using (bucket_id = 'chat' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- ---------- Ajudas ----------
create or replace function public.cumpre_regras_grupos() returns jsonb
language sql stable security definer set search_path = '' as $$ select v from public.config_grupos where k = 'regras' $$;

create or replace function public.cumpre_lancamento() returns boolean
language sql stable security definer set search_path = '' as $$
  select public.cumpre_dia(public.cumpre_agora()) <= ((public.cumpre_regras_grupos() ->> 'lancamento_ate')::date)
$$;

create or replace function public.cumpre_codigo_grupo() returns text
language plpgsql volatile security definer set search_path = '' as $$
declare a text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; c text; i int;
begin
  loop
    c := '';
    for i in 1..8 loop c := c || substr(a, 1 + floor(random() * length(a))::int, 1); end loop;
    exit when not exists (select 1 from public.grupos where codigo = c);
  end loop;
  return c;
end $$;

create or replace function public.cumpre_nome_publico(u uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('nome', c.nome, 'num', c.num, 'rank', c.rank, 'cor', coalesce(c.cor, c.rank)) from public.conta c where c.user_id = u
$$;

-- Estado do chat para o aluno: pode escrever? até quando? porquê?
create or replace function public.cumpre_chat_estado(u uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_variable
declare c public.conta; idade int := public.cumpre_idade(u); s public.sancoes;
begin
  select * into c from public.conta where user_id = u;
  select * into s from public.sancoes x where x.user_id = u and not x.anulada and x.efeito <> 'aviso' order by x.criado desc limit 1;
  return jsonb_build_object('idade', idade, 'pode_chat', idade >= 13, 'anexos', idade >= 16, 'links', case when idade >= 18 then 'todos' when idade >= 16 then 'confianca' else 'nenhum' end,
    'regras', c.regras_chat is not null, 'banido', c.chat_banido, 'ate', case when c.chat_ate > public.cumpre_agora() then c.chat_ate end,
    'sancao', case when s.id is not null and (c.chat_banido or c.chat_ate > public.cumpre_agora()) then jsonb_build_object('id', s.id, 'motivo', s.motivo, 'efeito', s.efeito, 'recurso', s.recurso_estado) end);
end $$;

create or replace function public.cumpre_conta_extra(u uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_variable
declare c public.conta; pr jsonb;
begin
  select * into c from public.conta where user_id = u;
  select jsonb_build_object('semana', p.semana, 'pts', p.pts, 'motivo', p.motivo, 'lugar', p.lugar) into pr
  from public.premios_semana p where p.user_id = u order by p.semana desc limit 1;
  return jsonb_build_object('verificacao', public.cumpre_verificacao_json(u), 'esconder', c.esconder, 'premio', pr,
    'podios', (select count(*) from public.premios_semana p where p.user_id = u and p.lugar between 1 and 3),
    'semana', public.cumpre_semana(public.cumpre_agora()), 'idade', public.cumpre_idade(u), 'nivel', c.nivel, 'ano', c.ano, 'escola', c.escola_nome,
    'chat', public.cumpre_chat_estado(u), 'admin', exists (select 1 from public.admins a where a.user_id = u),
    'grupos_regras', jsonb_build_object('lancamento', public.cumpre_lancamento()) || public.cumpre_regras_grupos());
end $$;

-- ---------- Grupos ----------
create or replace function public.regras_aceitar() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'sem sessão' using errcode = '42501'; end if;
  perform public.cumpre_conta_garantir(u);
  update public.conta set regras_chat = coalesce(regras_chat, public.cumpre_agora()) where user_id = u;
  return public.conta_estado();
end $$;

create or replace function public.grupos_meus() returns jsonb
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'sem sessão' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'nome', g.nome, 'papel', m.papel, 'estado', m.estado,
      'membros', (select count(*) from public.grupo_membros x where x.grupo = g.id and x.estado = 'ativo'),
      'a_estudar', (select count(*) from public.grupo_membros x join public.sessoes_foco s on s.user_id = x.user_id and s.estado = 'ativa' and s.ultimo > public.cumpre_agora() - interval '7 minutes' where x.grupo = g.id and x.estado = 'ativo'),
      'novas', (select count(*) from public.mensagens n where n.grupo = g.id and n.id > m.lido and n.user_id is distinct from u and not n.apagada),
      'ultima', (select jsonb_build_object('t', extract(epoch from n.criado) * 1000, 'texto', case when n.escondida then 'Mensagem escondida' when n.apagada then 'Mensagem apagada' else left(n.texto, 80) end)
                 from public.mensagens n where n.grupo = g.id order by n.id desc limit 1)) order by g.atividade desc)
    from public.grupo_membros m join public.grupos g on g.id = m.grupo where m.user_id = u and not g.arquivado), '[]'::jsonb);
end $$;

create or replace function public.grupo_criar(p_nome text) returns jsonb
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare u uuid := auth.uid(); c public.conta; R jsonb := public.cumpre_regras_grupos(); minimo int; criados int; tem int; g uuid; nm text := btrim(regexp_replace(coalesce(p_nome, ''), '\s+', ' ', 'g'));
  idade int;
begin
  if u is null then raise exception 'sem sessão' using errcode = '42501'; end if;
  perform public.cumpre_conta_garantir(u);
  select * into c from public.conta where user_id = u for update;
  idade := public.cumpre_idade(u);
  if c.regras_chat is null then return jsonb_build_object('ok', false, 'erro', 'regras'); end if;
  if c.chat_banido then return jsonb_build_object('ok', false, 'erro', 'A tua conta já não pode usar os grupos.'); end if;
  minimo := case when public.cumpre_lancamento() then (R ->> 'criar_lanc')::int else (R ->> 'criar')::int end;
  if c.rank < minimo then return jsonb_build_object('ok', false, 'erro', 'Para criar grupos precisas de chegar a ' || (select nome from public.ranks where id = minimo) || '.'); end if;
  select count(*) into criados from public.grupos where dono = u and not arquivado;
  if criados >= (R -> 'max_criar' ->> c.rank)::int then return jsonb_build_object('ok', false, 'erro', 'Já criaste os grupos que o teu rank deixa (' || criados || '). Sobe de rank para criar mais.'); end if;
  select count(*) into tem from public.grupo_membros m join public.grupos x on x.id = m.grupo where m.user_id = u and not x.arquivado;
  if tem >= (R -> 'max_entrar' ->> c.rank)::int then return jsonb_build_object('ok', false, 'erro', 'Já estás no máximo de grupos para o teu rank.'); end if;
  if length(nm) < 3 or length(nm) > 40 then return jsonb_build_object('ok', false, 'erro', 'O nome do grupo tem de ter entre 3 e 40 letras.'); end if;
  if public.cumpre_filtro(nm, 18) is not null then return jsonb_build_object('ok', false, 'erro', 'Esse nome não é permitido. Escolhe outro.'); end if;
  insert into public.grupos (nome, codigo, dono, faixa, escola_id, max)
  values (nm, public.cumpre_codigo_grupo(), u, case when idade >= 18 then 'adultos' else 'menores' end, c.escola_verificada, (R -> 'tamanho' ->> c.rank)::int)
  returning id into g;
  insert into public.grupo_membros (grupo, user_id, papel) values (g, u, 'dono');
  return jsonb_build_object('ok', true, 'grupo', g);
end $$;

create or replace function public.grupo_entrar(p_codigo text) returns jsonb
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare u uuid := auth.uid(); c public.conta; R jsonb := public.cumpre_regras_grupos(); g public.grupos; cod text := upper(regexp_replace(coalesce(p_codigo, ''), '[^A-Za-z0-9]', '', 'g'));
  minimo int; tem int; n int; idade int; minha text;
begin
  if u is null then raise exception 'sem sessão' using errcode = '42501'; end if;
  perform public.cumpre_conta_garantir(u);
  select * into c from public.conta where user_id = u;
  if c.regras_chat is null then return jsonb_build_object('ok', false, 'erro', 'regras'); end if;
  if c.chat_banido then return jsonb_build_object('ok', false, 'erro', 'A tua conta já não pode usar os grupos.'); end if;
  if length(cod) <> 8 then return jsonb_build_object('ok', false, 'erro', 'O código tem 8 letras e números (ex.: K7QM-4RTW).'); end if;
  select * into g from public.grupos where codigo = cod and not arquivado for update;
  if g.id is null or (g.codigo_expira is not null and g.codigo_expira < public.cumpre_agora()) then return jsonb_build_object('ok', false, 'erro', 'Não há nenhum grupo com esse código, ou o código já expirou.'); end if;
  if exists (select 1 from public.grupo_membros m where m.grupo = g.id and m.user_id = u) then return jsonb_build_object('ok', true, 'grupo', g.id, 'ja', true); end if;
  minimo := case when public.cumpre_lancamento() then (R ->> 'entrar_lanc')::int else (R ->> 'entrar')::int end;
  if c.rank < minimo then return jsonb_build_object('ok', false, 'erro', 'Para entrar em grupos precisas de chegar a ' || (select nome from public.ranks where id = minimo) || ' (5 horas de foco).'); end if;
  select count(*) into tem from public.grupo_membros m join public.grupos x on x.id = m.grupo where m.user_id = u and not x.arquivado;
  if tem >= (R -> 'max_entrar' ->> c.rank)::int then return jsonb_build_object('ok', false, 'erro', 'Já estás no máximo de grupos para o teu rank (' || tem || '). Sai de um ou sobe de rank.'); end if;
  idade := public.cumpre_idade(u);
  minha := case when idade >= 18 then 'adultos' else 'menores' end;
  if minha <> g.faixa then
    if not coalesce(minha = 'adultos' and g.faixa = 'menores' and c.verificado and c.escola_verificada is not null and g.escola_id is not null and c.escola_verificada = g.escola_id, false) then
      return jsonb_build_object('ok', false, 'erro', case when minha = 'menores' then 'Este grupo é só para maiores de 18 anos.' else 'Este grupo é de alunos com menos de 18 anos. Só podes entrar se fores verificado na mesma escola.' end);
    end if;
  end if;
  select count(*) into n from public.grupo_membros m where m.grupo = g.id;
  if n >= g.max then return jsonb_build_object('ok', false, 'erro', 'Este grupo está cheio.'); end if;
  insert into public.grupo_membros (grupo, user_id, estado, lido) values (g.id, u, case when g.aprovacao then 'pendente' else 'ativo' end, coalesce((select max(id) from public.mensagens where grupo = g.id), 0));
  update public.grupos set atividade = public.cumpre_agora() where id = g.id;
  return jsonb_build_object('ok', true, 'grupo', g.id, 'pendente', g.aprovacao);
end $$;

create or replace function public.grupo_ver(p_grupo uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare u uuid := auth.uid(); g public.grupos; m public.grupo_membros; sem date := public.cumpre_semana(public.cumpre_agora()); L uuid[];
begin
  if u is null then raise exception 'sem sessão' using errcode = '42501'; end if;
  select * into g from public.grupos where id = p_grupo and not arquivado;
  select * into m from public.grupo_membros where grupo = p_grupo and user_id = u;
  if g.id is null or m.user_id is null then return jsonb_build_object('ok', false, 'erro', 'Já não estás neste grupo.'); end if;
  if m.estado = 'pendente' then return jsonb_build_object('ok', true, 'pendente', true, 'nome', g.nome); end if;
  select array_agg(x.user_id) into L from public.grupo_membros x where x.grupo = g.id and x.estado = 'ativo';
  return jsonb_build_object('ok', true, 'id', g.id, 'nome', g.nome, 'codigo', g.codigo, 'codigo_expira', g.codigo_expira, 'aprovacao', g.aprovacao, 'faixa', g.faixa,
    'max', g.max, 'papel', m.papel, 'sala', case when (g.sala ->> 'fim')::timestamptz > public.cumpre_agora() then g.sala end,
    'membros', (select jsonb_agg(public.cumpre_nome_publico(x.user_id) || jsonb_build_object('id', x.user_id, 'papel', x.papel, 'estado', x.estado, 'eu', x.user_id = u,
        'silenciado', x.silenciado_ate > public.cumpre_agora(),
        'a_estudar', exists (select 1 from public.sessoes_foco s where s.user_id = x.user_id and s.estado = 'ativa' and s.ultimo > public.cumpre_agora() - interval '7 minutes'))
        order by x.papel, x.entrou)
      from public.grupo_membros x where x.grupo = g.id and (x.estado = 'ativo' or m.papel = 'dono')));
end $$;

create or replace function public.grupo_sair(p_grupo uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare u uuid := auth.uid(); m public.grupo_membros; novo uuid;
begin
  if u is null then raise exception 'sem sessão' using errcode = '42501'; end if;
  select * into m from public.grupo_membros where grupo = p_grupo and user_id = u;
  if m.user_id is null then return jsonb_build_object('ok', true); end if;
  delete from public.grupo_membros where grupo = p_grupo and user_id = u;
  if m.papel = 'dono' then
    select x.user_id into novo from public.grupo_membros x where x.grupo = p_grupo and x.estado = 'ativo' order by x.entrou limit 1;
    if novo is null then delete from public.grupos where id = p_grupo;
    else update public.grupo_membros set papel = 'dono' where grupo = p_grupo and user_id = novo; update public.grupos set dono = novo where id = p_grupo; end if;
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- O dono: código novo (com validade opcional), pedir aprovação, aprovar/recusar/remover/silenciar 24 h.
create or replace function public.grupo_gerir(p_grupo uuid, p_acao text, p_user uuid default null, p_valor text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare u uuid := auth.uid(); g public.grupos;
begin
  if u is null then raise exception 'sem sessão' using errcode = '42501'; end if;
  select * into g from public.grupos where id = p_grupo and dono = u and not arquivado for update;
  if g.id is null then return jsonb_build_object('ok', false, 'erro', 'Só quem criou o grupo pode fazer isto.'); end if;
  if p_acao = 'codigo' then
    update public.grupos set codigo = public.cumpre_codigo_grupo(), codigo_expira = case p_valor when '24h' then public.cumpre_agora() + interval '24 hours' when '7d' then public.cumpre_agora() + interval '7 days' end where id = g.id;
  elsif p_acao = 'aprovacao' then
    update public.grupos set aprovacao = coalesce(p_valor, 'false')::boolean where id = g.id;
  elsif p_acao = 'nome' then
    if length(btrim(coalesce(p_valor, ''))) not between 3 and 40 or public.cumpre_filtro(p_valor, 18) is not null then return jsonb_build_object('ok', false, 'erro', 'Nome inválido.'); end if;
    update public.grupos set nome = btrim(p_valor) where id = g.id;
  elsif p_acao in ('aprovar', 'recusar', 'remover', 'silenciar') then
    if p_user is null or p_user = u then return jsonb_build_object('ok', false, 'erro', 'Escolhe outro membro.'); end if;
    if p_acao = 'aprovar' then
      if (select count(*) from public.grupo_membros where grupo = g.id and estado = 'ativo') >= g.max then return jsonb_build_object('ok', false, 'erro', 'O grupo está cheio.'); end if;
      update public.grupo_membros set estado = 'ativo' where grupo = g.id and user_id = p_user;
    elsif p_acao in ('recusar', 'remover') then delete from public.grupo_membros where grupo = g.id and user_id = p_user;
    else update public.grupo_membros set silenciado_ate = public.cumpre_agora() + interval '24 hours' where grupo = g.id and user_id = p_user;
    end if;
  else raise exception 'ação desconhecida';
  end if;
  return public.grupo_ver(g.id);
end $$;

-- Estudar juntos: alguém abre uma sala com um temporizador; os outros entram e estudam ao mesmo tempo.
create or replace function public.grupo_sala(p_grupo uuid, p_dur int) returns jsonb
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare u uuid := auth.uid(); d int := least(greatest(coalesce(p_dur, 25), 10), 120); g public.grupos;
begin
  if u is null then raise exception 'sem sessão' using errcode = '42501'; end if;
  if not public.cumpre_membro(u, p_grupo) then return jsonb_build_object('ok', false, 'erro', 'Já não estás neste grupo.'); end if;
  select * into g from public.grupos where id = p_grupo for update;
  if (g.sala ->> 'fim')::timestamptz > public.cumpre_agora() then return public.grupo_ver(p_grupo); end if;
  update public.grupos set sala = jsonb_build_object('ini', public.cumpre_agora(), 'fim', public.cumpre_agora() + make_interval(mins => d), 'dur', d, 'por', public.cumpre_nome_publico(u)),
    atividade = public.cumpre_agora() where id = p_grupo;
  return public.grupo_ver(p_grupo);
end $$;

-- ---------- Chat ----------
-- Filtro: devolve o motivo do bloqueio (ou null). Palavras proibidas para todos; contactos pessoais e links conforme a idade.
create or replace function public.cumpre_filtro(p_texto text, idade int) returns text
language plpgsql immutable set search_path = '' as $$
#variable_conflict use_variable
declare t text := lower(translate(coalesce(p_texto, ''), 'ÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇáàâãäéèêëíìîïóòôõöúùûüç', 'AAAAAEEEEIIIIOOOOOUUUUCaaaaaeeeeiiiiooooouuuuc'));
  dom text; ok text[] := array['youtube.com', 'youtu.be', 'drive.google.com', 'docs.google.com', 'classroom.google.com', 'wikipedia.org', 'khanacademy.org', 'cumpre.pt', 'dges.gov.pt', 'iave.pt', 'escolavirtual.pt', 'gov.pt', 'edu.pt', 'ulisboa.pt', 'up.pt', 'uc.pt', 'ipleiria.pt'];
begin
  t := regexp_replace(t, '(.)\1{2,}', '\1\1', 'g');
  if t ~ '\m(merda|caralho|foda[- ]?se|fodase|fode|foder|fodido|puta|putas|cabrao|cabroes|paneleiro|panasca|maricas|cona|conas|piça|pica|pila|broche|boquete|punheta|filho da puta|fdp|vai te foder|vai-te foder|crl|pqp|otario|atrasado mental|mongoloide|preto de merda|heil hitler|sieg heil|porno|porn|nudes|nude|manda fotos nua|mata-te|matate|vai te matar|suicida-te)\M' then
    return 'palavras';
  end if;
  if idade < 18 and (t ~ '\m9[1236]\d[\s.-]*\d{3}[\s.-]*\d{3}\M' or t ~ '\m2\d{2}[\s.-]*\d{3}[\s.-]*\d{3}\M' or t ~ '\m(rua|avenida|av\.|travessa|largo|praceta)\s+[a-z][a-z ]{2,40},?\s*(n\.?o?\s*)?\d{1,4}\M' or t ~ '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}') then
    return 'contactos';
  end if;
  if t ~ '(https?://|www\.|\m[a-z0-9-]+\.(com|pt|net|org|io|gg|me|ly|tv|app)\M)' then
    if idade < 16 then return 'links'; end if;
    if idade < 18 then
      for dom in select (regexp_matches(t, '(?:https?://)?(?:www\.)?([a-z0-9.-]+\.[a-z]{2,})', 'g'))[1] loop
        if not exists (select 1 from unnest(ok) d where dom = d or dom like '%.' || d) then return 'links'; end if;
      end loop;
    end if;
  end if;
  return null;
end $$;

create or replace function public.cumpre_msg_json(n public.mensagens, u uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', n.id, 't', extract(epoch from n.criado) * 1000, 'eu', n.user_id = u, 'autor', public.cumpre_nome_publico(n.user_id),
    'texto', case when n.apagada then '' when n.escondida then '' else n.texto end,
    'anexo', case when n.apagada or n.escondida then null else n.anexo end,
    'estado', case when n.apagada then 'apagada' when n.escondida then 'escondida' end)
$$;

create or replace function public.chat_enviar(p_grupo uuid, p_texto text, p_anexo jsonb default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare u uuid := auth.uid(); c public.conta; m public.grupo_membros; idade int; txt text := btrim(coalesce(p_texto, '')); motivo text; n public.mensagens; recentes int; bloqueios int; anx jsonb;
begin
  if u is null then raise exception 'sem sessão' using errcode = '42501'; end if;
  select * into c from public.conta where user_id = u;
  select * into m from public.grupo_membros where grupo = p_grupo and user_id = u and estado = 'ativo';
  if m.user_id is null or not public.cumpre_membro(u, p_grupo) then return jsonb_build_object('ok', false, 'erro', 'Já não estás neste grupo.'); end if;
  idade := public.cumpre_idade(u);
  if idade < 13 then return jsonb_build_object('ok', false, 'erro', 'O chat é a partir dos 13 anos.'); end if;
  if c.regras_chat is null then return jsonb_build_object('ok', false, 'erro', 'regras'); end if;
  if c.chat_banido then return jsonb_build_object('ok', false, 'erro', 'A tua conta já não pode escrever nos grupos.'); end if;
  if c.chat_ate > public.cumpre_agora() then return jsonb_build_object('ok', false, 'erro', 'Não podes escrever até ' || to_char(c.chat_ate at time zone 'Europe/Lisbon', 'DD/MM "às" HH24:MI') || '.'); end if;
  if m.silenciado_ate > public.cumpre_agora() then return jsonb_build_object('ok', false, 'erro', 'Quem criou o grupo silenciou-te por 24 horas.'); end if;
  if length(txt) > 1000 then return jsonb_build_object('ok', false, 'erro', 'A mensagem é demasiado comprida (máx. 1000 letras).'); end if;
  if p_anexo is not null then
    if idade < 16 then return jsonb_build_object('ok', false, 'erro', 'Fotos e ficheiros no chat só a partir dos 16 anos.'); end if;
    if coalesce(p_anexo ->> 'path', '') !~ ('^' || u::text || '/' || p_grupo::text || '/[A-Za-z0-9_-]+\.(jpg|png|webp|pdf)$') then raise exception 'anexo inválido'; end if;
    anx := jsonb_build_object('path', p_anexo ->> 'path', 'tipo', left(p_anexo ->> 'tipo', 40), 'nome', left(coalesce(p_anexo ->> 'nome', 'ficheiro'), 80));
  end if;
  if txt = '' and anx is null then return jsonb_build_object('ok', false, 'erro', 'Escreve alguma coisa.'); end if;
  select count(*) into recentes from public.mensagens x where x.user_id = u and x.criado > public.cumpre_agora() - interval '30 seconds';
  if recentes >= 8 then return jsonb_build_object('ok', false, 'erro', 'Estás a escrever muito depressa. Espera um bocadinho.'); end if;
  motivo := public.cumpre_filtro(txt || ' ' || coalesce(anx ->> 'nome', ''), idade);
  if motivo is not null then
    insert into public.chat_bloqueios (user_id, motivo) values (u, motivo);
    select count(*) into bloqueios from public.chat_bloqueios b where b.user_id = u and b.criado > public.cumpre_agora() - interval '24 hours';
    if bloqueios >= 3 and not exists (select 1 from public.sancoes s where s.user_id = u and s.por = 'filtro' and s.criado > public.cumpre_agora() - interval '24 hours') then
      perform public.cumpre_sancionar(u, 'leve', 1, 'Várias mensagens bloqueadas pelo filtro no mesmo dia.', null, 'filtro');
    end if;
    return jsonb_build_object('ok', false, 'bloqueada', true, 'erro', case motivo
      when 'palavras' then 'A mensagem não foi enviada: tem palavras que não são permitidas no chat (regras 1 e 3).'
      when 'contactos' then 'A mensagem não foi enviada: não partilhes números, moradas ou emails no chat (regra 4).'
      else case when idade < 16 then 'A mensagem não foi enviada: links no chat só a partir dos 16 anos.' else 'A mensagem não foi enviada: aos 16 e 17 anos só dá para links da escola, Google Drive, YouTube e sites de estudo.' end end);
  end if;
  insert into public.mensagens (grupo, user_id, texto, anexo) values (p_grupo, u, txt, anx) returning * into n;
  update public.grupos set atividade = public.cumpre_agora() where id = p_grupo;
  update public.grupo_membros set lido = n.id where grupo = p_grupo and user_id = u;
  return jsonb_build_object('ok', true, 'mensagem', public.cumpre_msg_json(n, u));
end $$;

create or replace function public.chat_listar(p_grupo uuid, p_depois bigint default null, p_antes bigint default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare u uuid := auth.uid(); L jsonb; ultimo bigint;
begin
  if u is null then raise exception 'sem sessão' using errcode = '42501'; end if;
  if not public.cumpre_membro(u, p_grupo) then return jsonb_build_object('ok', false, 'erro', 'Já não estás neste grupo.'); end if;
  if (select chat_banido from public.conta where user_id = u) then return jsonb_build_object('ok', false, 'erro', 'A tua conta já não pode usar o chat.'); end if;
  select coalesce(jsonb_agg(public.cumpre_msg_json(x, u) order by x.id), '[]'::jsonb), max(x.id) into L, ultimo from (
    select * from public.mensagens n where n.grupo = p_grupo and (p_depois is null or n.id > p_depois) and (p_antes is null or n.id < p_antes)
    order by n.id desc limit 60) x;
  if ultimo is not null then update public.grupo_membros set lido = greatest(lido, ultimo) where grupo = p_grupo and user_id = u; end if;
  -- mensagens que mudaram (escondidas ou apagadas) desde a última vez: a app atualiza-as
  return jsonb_build_object('ok', true, 'mensagens', L,
    'mudadas', case when p_depois is not null then (select coalesce(jsonb_agg(public.cumpre_msg_json(x, u)), '[]'::jsonb) from public.mensagens x where x.grupo = p_grupo and x.id <= p_depois and x.id > p_depois - 200 and (x.escondida or x.apagada)) end,
    'chat', public.cumpre_chat_estado(u));
end $$;

create or replace function public.chat_apagar(p_msg bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'sem sessão' using errcode = '42501'; end if;
  update public.mensagens set apagada = true where id = p_msg and user_id = u;
  return jsonb_build_object('ok', found);
end $$;

-- Denunciar: 3 pessoas diferentes escondem a mensagem; a primeira denúncia pede a revisão por IA.
create or replace function public.chat_denunciar(p_msg bigint, p_motivo text) returns jsonb
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare u uuid := auth.uid(); n public.mensagens; k int; segredo text;
begin
  if u is null then raise exception 'sem sessão' using errcode = '42501'; end if;
  select * into n from public.mensagens where id = p_msg;
  if n.id is null or not public.cumpre_membro(u, n.grupo) then return jsonb_build_object('ok', false, 'erro', 'Esta mensagem já não existe.'); end if;
  if n.user_id = u then return jsonb_build_object('ok', false, 'erro', 'Não podes denunciar uma mensagem tua.'); end if;
  if p_motivo not in ('insulto', 'assedio', 'sexual', 'odio', 'privacidade', 'batota', 'spam', 'outro') then raise exception 'motivo inválido'; end if;
  insert into public.denuncias (mensagem, por, motivo) values (p_msg, u, p_motivo) on conflict do nothing;
  if not found then return jsonb_build_object('ok', true, 'ja', true); end if;
  select count(distinct por) into k from public.denuncias where mensagem = p_msg;
  update public.mensagens set escondida = escondida or k >= 3 or p_motivo = 'sexual', revisao = coalesce(revisao, 'por rever') where id = p_msg;
  if n.ia is null then
    update public.mensagens set ia = jsonb_build_object('pedido', public.cumpre_agora()) where id = p_msg;
    select valor #>> '{}' into segredo from public.config_privada where chave = 'cron';
    begin
      perform net.http_post(
        url := 'https://zvyhytddpqultyilcqsn.supabase.co/functions/v1/cumpre',
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-cumpre-cron', segredo),
        body := jsonb_build_object('acao', 'moderar', 'mensagem', p_msg),
        timeout_milliseconds := 30000);
    exception when others then null;
    end;
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Sanções ----------
create or replace function public.cumpre_sancionar(u uuid, p_grav text, p_regra int, p_motivo text, p_msg bigint, p_por text) returns jsonb
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare k int; ef text; ate timestamptz; agora timestamptz := public.cumpre_agora(); s public.sancoes;
begin
  select count(*) into k from public.sancoes x where x.user_id = u and x.gravidade = p_grav and not x.anulada and x.efeito <> 'provisorio'
    and (x.criado > agora - interval '6 months' or x.gravidade in ('grave', 'gravissima'));
  k := k + 1;
  if p_grav = 'leve' then ef := case k when 1 then 'aviso' when 2 then 'silencio' when 3 then 'silencio' else 'fora' end;
    ate := case k when 1 then null when 2 then agora + interval '24 hours' when 3 then agora + interval '7 days' else agora + interval '30 days' end;
  elsif p_grav = 'media' then ef := case k when 1 then 'silencio' when 2 then 'silencio' when 3 then 'fora' else 'banido' end;
    ate := case k when 1 then agora + interval '24 hours' when 2 then agora + interval '7 days' when 3 then agora + interval '30 days' end;
  elsif p_grav = 'grave' then ef := case when k = 1 then 'fora' else 'banido' end; ate := case when k = 1 then agora + interval '30 days' end;
  else ef := 'banido'; ate := null;
  end if;
  -- sanções provisórias (enquanto a equipa revê) deixam de contar
  update public.sancoes set anulada = true where user_id = u and efeito = 'provisorio' and not anulada;
  insert into public.sancoes (user_id, gravidade, efeito, ate, regra, motivo, mensagem, por) values (u, p_grav, ef, ate, p_regra, left(p_motivo, 300), p_msg, p_por) returning * into s;
  perform public.cumpre_chat_recalcular(u);
  return to_jsonb(s);
end $$;

-- Enquanto a equipa não revê um caso grave: sem escrever 72 h.
create or replace function public.cumpre_provisorio(u uuid, p_grav text, p_regra int, p_motivo text, p_msg bigint) returns void
language plpgsql security definer set search_path = '' as $$
begin
  insert into public.sancoes (user_id, gravidade, efeito, ate, regra, motivo, mensagem, por)
  values (u, p_grav, 'provisorio', public.cumpre_agora() + interval '72 hours', p_regra, left('Em revisão pela equipa: ' || p_motivo, 300), p_msg, 'ia');
  perform public.cumpre_chat_recalcular(u);
end $$;

create or replace function public.cumpre_chat_recalcular(u uuid) returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.conta set
    chat_banido = exists (select 1 from public.sancoes s where s.user_id = u and not s.anulada and s.efeito = 'banido'),
    chat_ate = (select max(s.ate) from public.sancoes s where s.user_id = u and not s.anulada and s.ate > public.cumpre_agora())
  where user_id = u;
end $$;

create or replace function public.sancoes_minhas() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'sem sessão' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', s.id, 'gravidade', s.gravidade, 'efeito', s.efeito, 'ate', s.ate, 'regra', s.regra, 'motivo', s.motivo,
      't', extract(epoch from s.criado) * 1000, 'recurso', s.recurso_estado, 'pode_recorrer', s.recurso is null and s.efeito <> 'aviso') order by s.criado desc)
    from public.sancoes s where s.user_id = u and not s.anulada), '[]'::jsonb);
end $$;

create or replace function public.sancao_recorrer(p_id bigint, p_texto text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'sem sessão' using errcode = '42501'; end if;
  if length(btrim(coalesce(p_texto, ''))) < 10 then return jsonb_build_object('ok', false, 'erro', 'Explica em poucas palavras porque achas que a sanção está errada.'); end if;
  update public.sancoes set recurso = left(btrim(p_texto), 1000), recurso_estado = 'pendente' where id = p_id and user_id = u and recurso is null and not anulada;
  if not found then return jsonb_build_object('ok', false, 'erro', 'Só dá para recorrer uma vez de cada sanção.'); end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------- Resultado da revisão por IA (só a função do servidor chama) ----------
create or replace function public.cumpre_moderar_resultado(p_msg bigint, p_grav text, p_regra int, p_motivo text) returns jsonb
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare n public.mensagens; r jsonb;
begin
  select * into n from public.mensagens where id = p_msg for update;
  if n.id is null then return null; end if;
  update public.mensagens set ia = coalesce(ia, '{}'::jsonb) || jsonb_build_object('gravidade', p_grav, 'regra', p_regra, 'motivo', p_motivo, 'em', public.cumpre_agora()) where id = p_msg;
  if p_grav = 'nenhuma' then
    -- nada de errado: volta a aparecer, mas fica na fila se 3+ pessoas denunciaram
    update public.mensagens set escondida = (select count(distinct por) from public.denuncias d where d.mensagem = p_msg) >= 3,
      revisao = case when (select count(distinct por) from public.denuncias d where d.mensagem = p_msg) >= 3 then 'por rever' else 'revista' end where id = p_msg;
    return jsonb_build_object('ok', true);
  end if;
  update public.mensagens set escondida = true where id = p_msg;
  if p_grav in ('leve', 'media') and n.user_id is not null then
    r := public.cumpre_sancionar(n.user_id, p_grav, p_regra, p_motivo, p_msg, 'ia');
    update public.mensagens set revisao = 'revista' where id = p_msg;
  elsif n.user_id is not null then
    perform public.cumpre_provisorio(n.user_id, p_grav, p_regra, p_motivo, p_msg);
    update public.mensagens set revisao = 'por rever' where id = p_msg;
  end if;
  return jsonb_build_object('ok', true, 'sancao', r);
end $$;

create or replace function public.cumpre_mensagem_contexto(p_msg bigint) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('mensagem', (select jsonb_build_object('id', n.id, 'texto', n.texto, 'anexo', n.anexo is not null, 'idade', public.cumpre_idade(n.user_id), 'autor', n.user_id) from public.mensagens n where n.id = p_msg),
    'denuncias', (select coalesce(jsonb_agg(d.motivo), '[]'::jsonb) from public.denuncias d where d.mensagem = p_msg),
    'contexto', (select coalesce(jsonb_agg(jsonb_build_object('quem', case when x.user_id = n.user_id then 'autor' else 'outro' end, 'texto', x.texto) order by x.id), '[]'::jsonb)
      from public.mensagens n, lateral (select * from public.mensagens y where y.grupo = n.grupo and y.id < n.id and y.id >= n.id - 50 order by y.id desc limit 10) x where n.id = p_msg))
$$;

-- ---------- Painel da equipa ----------
create or replace function public.cumpre_e_admin() returns boolean
language sql stable security definer set search_path = '' as $$ select exists (select 1 from public.admins where user_id = auth.uid()) $$;

create or replace function public.mod_fila() returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not public.cumpre_e_admin() then raise exception 'sem acesso' using errcode = '42501'; end if;
  return jsonb_build_object(
    'mensagens', (select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 't', extract(epoch from n.criado) * 1000, 'texto', n.texto, 'anexo', n.anexo, 'autor', public.cumpre_nome_publico(n.user_id),
        'idade', public.cumpre_idade(n.user_id), 'grupo', g.nome, 'ia', n.ia, 'escondida', n.escondida,
        'denuncias', (select coalesce(jsonb_agg(d.motivo), '[]'::jsonb) from public.denuncias d where d.mensagem = n.id),
        'contexto', (public.cumpre_mensagem_contexto(n.id) -> 'contexto'),
        'historico', (select count(*) from public.sancoes s where s.user_id = n.user_id and not s.anulada)) order by n.criado), '[]'::jsonb)
      from public.mensagens n join public.grupos g on g.id = n.grupo where n.revisao = 'por rever'),
    'recursos', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'autor', public.cumpre_nome_publico(s.user_id), 'gravidade', s.gravidade, 'efeito', s.efeito, 'motivo', s.motivo,
        'recurso', s.recurso, 'mensagem', (select n.texto from public.mensagens n where n.id = s.mensagem), 't', extract(epoch from s.criado) * 1000) order by s.criado), '[]'::jsonb)
      from public.sancoes s where s.recurso_estado = 'pendente'),
    'dominios', (select coalesce(jsonb_agg(jsonb_build_object('dominio', d.dominio, 'nome', d.nome) order by d.criado), '[]'::jsonb) from public.dominios_escola d where d.estado = 'por verificar'));
end $$;

create or replace function public.mod_decidir(p_msg bigint, p_grav text, p_regra int, p_motivo text) returns jsonb
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare n public.mensagens;
begin
  if not public.cumpre_e_admin() then raise exception 'sem acesso' using errcode = '42501'; end if;
  if p_grav not in ('nenhuma', 'leve', 'media', 'grave', 'gravissima') then raise exception 'gravidade inválida'; end if;
  select * into n from public.mensagens where id = p_msg for update;
  if n.id is null then return public.mod_fila(); end if;
  if p_grav = 'nenhuma' then
    update public.mensagens set escondida = false, revisao = 'revista' where id = p_msg;
    update public.sancoes set anulada = true where mensagem = p_msg and efeito = 'provisorio';
    if n.user_id is not null then perform public.cumpre_chat_recalcular(n.user_id); end if;
  else
    update public.mensagens set escondida = true, revisao = 'revista' where id = p_msg;
    if n.user_id is not null then perform public.cumpre_sancionar(n.user_id, p_grav, p_regra, coalesce(nullif(btrim(p_motivo), ''), 'Decisão da equipa'), p_msg, 'equipa'); end if;
  end if;
  return public.mod_fila();
end $$;

create or replace function public.mod_recurso(p_id bigint, p_aceitar boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare s public.sancoes;
begin
  if not public.cumpre_e_admin() then raise exception 'sem acesso' using errcode = '42501'; end if;
  update public.sancoes set recurso_estado = case when p_aceitar then 'aceite' else 'recusado' end, anulada = anulada or p_aceitar where id = p_id returning * into s;
  if s.id is not null then perform public.cumpre_chat_recalcular(s.user_id); end if;
  return public.mod_fila();
end $$;

create or replace function public.mod_dominio(p_dominio text, p_confirmar boolean, p_nome text default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not public.cumpre_e_admin() then raise exception 'sem acesso' using errcode = '42501'; end if;
  update public.dominios_escola set estado = case when p_confirmar then 'confirmado' else 'recusado' end, nome = coalesce(nullif(btrim(p_nome), ''), nome) where dominio = lower(p_dominio);
  perform public.cumpre_verificacoes_rever();
  return public.mod_fila();
end $$;

-- Grupos parados há 60 dias ficam arquivados (todos os dias às 4:10).
create or replace function public.cumpre_grupos_arquivar() returns int
language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  update public.grupos g set arquivado = true where not g.arquivado and g.atividade < public.cumpre_agora() - interval '60 days'
    and not exists (select 1 from public.grupo_membros m join public.sessoes_foco s on s.user_id = m.user_id where m.grupo = g.id and s.inicio > public.cumpre_agora() - interval '60 days');
  get diagnostics n = row_count;
  delete from public.chat_bloqueios where criado < public.cumpre_agora() - interval '30 days';
  return n;
end $$;
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'cumpre-grupos';
    perform cron.schedule('cumpre-grupos', '10 4 * * *', $c$select public.cumpre_grupos_arquivar()$c$);
  end if;
end $$;

do $$
declare f text;
begin
  foreach f in array array['cumpre_regras_grupos()', 'cumpre_lancamento()', 'cumpre_codigo_grupo()', 'cumpre_nome_publico(uuid)', 'cumpre_chat_estado(uuid)',
    'cumpre_conta_extra(uuid)', 'cumpre_filtro(text,int)', 'cumpre_msg_json(public.mensagens,uuid)', 'cumpre_sancionar(uuid,text,int,text,bigint,text)',
    'cumpre_provisorio(uuid,text,int,text,bigint)', 'cumpre_chat_recalcular(uuid)', 'cumpre_moderar_resultado(bigint,text,int,text)', 'cumpre_mensagem_contexto(bigint)',
    'cumpre_grupos_arquivar()'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
  end loop;
  foreach f in array array['regras_aceitar()', 'grupos_meus()', 'grupo_criar(text)', 'grupo_entrar(text)', 'grupo_ver(uuid)', 'grupo_sair(uuid)',
    'grupo_gerir(uuid,text,uuid,text)', 'grupo_sala(uuid,int)', 'chat_enviar(uuid,text,jsonb)', 'chat_listar(uuid,bigint,bigint)', 'chat_apagar(bigint)',
    'chat_denunciar(bigint,text)', 'sancoes_minhas()', 'sancao_recorrer(bigint,text)', 'mod_fila()', 'mod_decidir(bigint,text,int,text)', 'mod_recurso(bigint,boolean)',
    'mod_dominio(text,boolean,text)', 'cumpre_e_admin()'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
  revoke execute on function public.cumpre_membro(uuid, uuid) from public, anon, authenticated;
  revoke execute on function public.cumpre_idade(uuid) from public, anon, authenticated;
  revoke execute on function public.cumpre_sou_membro(text) from public, anon;
  revoke execute on function public.cumpre_posso_anexar(text) from public, anon;
end $$;

-- A função do servidor (Edge Function) chama estas com a chave secreta.
grant execute on function public.cumpre_mensagem_contexto(bigint), public.cumpre_moderar_resultado(bigint, text, int, text) to service_role;
