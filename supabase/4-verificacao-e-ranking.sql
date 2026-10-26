-- Cumpre — fase 2: verificação pelo email da escola e ranking semanal com prémios.
-- Corre depois de 3-ranks-e-pontos.sql. Pode correr-se mais do que uma vez.

-- ---------- Dados do perfil que o servidor precisa (copiados do estado de cada aluno) ----------
alter table public.conta add column if not exists esconder boolean not null default false;
alter table public.conta add column if not exists nivel text;
alter table public.conta add column if not exists ano smallint;
alter table public.conta add column if not exists escola_id text;
alter table public.conta add column if not exists escola_nome text;
alter table public.conta add column if not exists nasc date;
alter table public.conta add column if not exists escola_verificada text;

create or replace function public.cumpre_perfil_copiar(u uuid, d jsonb) returns void
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare p jsonb := d -> 'perfil'; nasc date; meta text;
begin
  if p is null or jsonb_typeof(p) <> 'object' then return; end if;
  begin nasc := nullif(p ->> 'nasc', '')::date; exception when others then nasc := null; end;
  if nasc is null then
    select au.raw_user_meta_data ->> 'nasc' into meta from auth.users au where au.id = u;
    begin nasc := nullif(meta, '')::date; exception when others then nasc := null; end;
  end if;
  update public.conta set
    nivel = left(p ->> 'nivel', 2),
    ano = case when (p ->> 'ano') ~ '^\d{1,2}$' then (p ->> 'ano')::smallint end,
    escola_id = left(p #>> '{escola,id}', 40),
    escola_nome = left(p #>> '{escola,n}', 160),
    nasc = coalesce(nasc, public.conta.nasc)
  where user_id = u;
end $$;

create or replace function public.cumpre_estado_mudou() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  perform public.cumpre_perfil_copiar(new.user_id, new.dados);
  return new;
end $$;
drop trigger if exists cumpre_estado_perfil on public.estado;
create trigger cumpre_estado_perfil after insert or update of dados on public.estado
  for each row execute function public.cumpre_estado_mudou();

-- Contas que já existem: copiar já.
do $$
declare r record;
begin
  for r in select e.user_id, e.dados from public.estado e join public.conta c on c.user_id = e.user_id loop
    perform public.cumpre_perfil_copiar(r.user_id, r.dados);
  end loop;
end $$;

create or replace function public.cumpre_idade(u uuid) returns int
language sql stable security definer set search_path = '' as $$
  select coalesce(extract(year from age((public.cumpre_agora() at time zone 'Europe/Lisbon')::date, c.nasc))::int, 0) from public.conta c where c.user_id = u
$$;

-- ---------- Domínios de email das escolas ----------
-- estado: confirmado (verifica logo), recusado (email pessoal, não serve), por verificar (a tarefa diária confirma).
create table if not exists public.dominios_escola (
  dominio text primary key check (dominio ~ '^[a-z0-9.-]+\.[a-z]{2,}$'),
  nome text not null,
  estado text not null default 'confirmado' check (estado in ('confirmado', 'recusado', 'por verificar')),
  nota text,
  criado timestamptz not null default now()
);
insert into public.dominios_escola (dominio, nome, estado) values
  ('ipleiria.pt', 'Universidade de Leiria e Oeste', 'confirmado'),
  ('ulisboa.pt', 'Universidade de Lisboa', 'confirmado'),
  ('campus.ul.pt', 'Universidade de Lisboa', 'confirmado'),
  ('uc.pt', 'Universidade de Coimbra', 'confirmado'),
  ('up.pt', 'Universidade do Porto', 'confirmado'),
  ('ua.pt', 'Universidade de Aveiro', 'confirmado'),
  ('uminho.pt', 'Universidade do Minho', 'confirmado'),
  ('unl.pt', 'Universidade NOVA de Lisboa', 'confirmado'),
  ('novasbe.pt', 'Nova SBE', 'confirmado'),
  ('iscte-iul.pt', 'Iscte – Instituto Universitário de Lisboa', 'confirmado'),
  ('utad.pt', 'Universidade de Trás-os-Montes e Alto Douro', 'confirmado'),
  ('ubi.pt', 'Universidade da Beira Interior', 'confirmado'),
  ('ualg.pt', 'Universidade do Algarve', 'confirmado'),
  ('uevora.pt', 'Universidade de Évora', 'confirmado'),
  ('uma.pt', 'Universidade da Madeira', 'confirmado'),
  ('uac.pt', 'Universidade dos Açores', 'confirmado'),
  ('ucp.pt', 'Universidade Católica Portuguesa', 'confirmado'),
  ('ipp.pt', 'Universidade Técnica do Porto', 'confirmado'),
  ('ipl.pt', 'Universidade Politécnica de Lisboa', 'confirmado'),
  ('ipc.pt', 'Universidade Politécnica de Coimbra', 'confirmado'),
  ('ipb.pt', 'Universidade Politécnica de Bragança', 'confirmado'),
  ('ipca.pt', 'Universidade Politécnica do Cávado e do Ave', 'confirmado'),
  ('ipcb.pt', 'Universidade Politécnica de Castelo Branco', 'confirmado'),
  ('ipg.pt', 'Universidade Politécnica da Guarda', 'confirmado'),
  ('ipportalegre.pt', 'Universidade Politécnica de Portalegre', 'confirmado'),
  ('ipsantarem.pt', 'Universidade Politécnica de Santarém', 'confirmado'),
  ('ips.pt', 'Universidade Politécnica de Setúbal', 'confirmado'),
  ('ipt.pt', 'Universidade Politécnica de Tomar', 'confirmado'),
  ('ipvc.pt', 'Universidade Politécnica de Viana do Castelo', 'confirmado'),
  ('ipv.pt', 'Universidade Politécnica de Viseu', 'confirmado'),
  ('ipbeja.pt', 'Universidade Politécnica de Beja', 'confirmado'),
  ('min-edu.pt', 'Ministério da Educação (escolas públicas)', 'confirmado'),
  ('gmail.com', 'email pessoal', 'recusado'), ('googlemail.com', 'email pessoal', 'recusado'),
  ('hotmail.com', 'email pessoal', 'recusado'), ('hotmail.pt', 'email pessoal', 'recusado'),
  ('outlook.com', 'email pessoal', 'recusado'), ('outlook.pt', 'email pessoal', 'recusado'),
  ('live.com', 'email pessoal', 'recusado'), ('live.com.pt', 'email pessoal', 'recusado'), ('msn.com', 'email pessoal', 'recusado'),
  ('yahoo.com', 'email pessoal', 'recusado'), ('yahoo.com.br', 'email pessoal', 'recusado'),
  ('icloud.com', 'email pessoal', 'recusado'), ('me.com', 'email pessoal', 'recusado'), ('mac.com', 'email pessoal', 'recusado'),
  ('sapo.pt', 'email pessoal', 'recusado'), ('mail.pt', 'email pessoal', 'recusado'), ('clix.pt', 'email pessoal', 'recusado'),
  ('iol.pt', 'email pessoal', 'recusado'), ('netcabo.pt', 'email pessoal', 'recusado'), ('aeiou.pt', 'email pessoal', 'recusado'),
  ('proton.me', 'email pessoal', 'recusado'), ('protonmail.com', 'email pessoal', 'recusado'),
  ('gmx.com', 'email pessoal', 'recusado'), ('gmx.pt', 'email pessoal', 'recusado'), ('aol.com', 'email pessoal', 'recusado'),
  ('zoho.com', 'email pessoal', 'recusado'), ('yandex.com', 'email pessoal', 'recusado'), ('mail.com', 'email pessoal', 'recusado'),
  ('tutanota.com', 'email pessoal', 'recusado'), ('hey.com', 'email pessoal', 'recusado')
on conflict (dominio) do nothing;
alter table public.dominios_escola enable row level security;
revoke all on public.dominios_escola from anon, authenticated;

-- Estado de um domínio: procura-o (ou o domínio "pai": alunos.escola.pt → escola.pt) na lista;
-- se não estiver, os domínios com cara de escola portuguesa (ae…, es…, eb…, .edu.pt) contam como confirmados.
create or replace function public.cumpre_dominio_estado(p_dominio text) returns text
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_variable
declare d text := lower(coalesce(p_dominio, '')); e text; partes text[]; i int;
begin
  partes := string_to_array(d, '.');
  for i in 1..greatest(array_length(partes, 1) - 1, 1) loop
    select de.estado into e from public.dominios_escola de where de.dominio = array_to_string(partes[i:], '.');
    if e is not null then return e; end if;
  end loop;
  if d ~ '\.edu\.pt$' or d ~ '^((alunos?|estudantes?|aluno|students?|mail|edu)\.)?(ae|agr|aec|age|agrup|es|esc|ese|eb|ebs|eps|ep|epr|cfp|colegio)[a-z0-9-]*\.pt$' then return 'confirmado'; end if;
  return 'por verificar';
end $$;

-- ---------- Verificações ----------
create table if not exists public.verificacoes (
  user_id uuid primary key references auth.users (id) on delete cascade,
  email text,
  dominio text,
  codigo text,
  expira timestamptz,
  tentativas int not null default 0,
  envios_dia date,
  envios int not null default 0,
  estado text not null default 'nenhum' check (estado in ('nenhum', 'codigo', 'verificado', 'por verificar', 'recusado', 'expirado')),
  escola_id text,
  escola_nome text,
  verificado_em timestamptz,
  valido_ate date
);
create unique index if not exists verificacoes_email_unico on public.verificacoes (lower(email)) where estado in ('verificado', 'por verificar');
alter table public.verificacoes enable row level security;
revoke all on public.verificacoes from anon, authenticated;

-- Chamada só pela função do servidor (que depois manda o email). Devolve o código para pôr no email.
create or replace function public.cumpre_verificacao_criar(u uuid, p_email text) returns jsonb
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare em text := lower(trim(coalesce(p_email, ''))); dom text; est text; v public.verificacoes; hoje date := public.cumpre_dia(public.cumpre_agora()); cod text;
begin
  perform public.cumpre_conta_garantir(u);
  if em !~ '^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$' or length(em) > 120 then return jsonb_build_object('ok', false, 'erro', 'Escreve o email completo da escola (ex.: nome@alunos.escola.pt).'); end if;
  dom := split_part(em, '@', 2);
  est := public.cumpre_dominio_estado(dom);
  if est = 'recusado' then return jsonb_build_object('ok', false, 'erro', 'Esse é um email pessoal. Usa o email que a tua escola te deu (muitas vezes acaba no nome da escola).'); end if;
  if exists (select 1 from public.verificacoes x where lower(x.email) = em and x.user_id <> u and x.estado in ('verificado', 'por verificar')) then
    return jsonb_build_object('ok', false, 'erro', 'Este email já verificou outra conta da Cumpre.');
  end if;
  insert into public.verificacoes (user_id) values (u) on conflict (user_id) do nothing;
  select * into v from public.verificacoes where user_id = u for update;
  if v.envios_dia is distinct from hoje then v.envios := 0; end if;
  if v.envios >= 3 then return jsonb_build_object('ok', false, 'erro', 'Já pediste 3 códigos hoje. Tenta outra vez amanhã.'); end if;
  cod := lpad(floor(random() * 1000000)::int::text, 6, '0');
  update public.verificacoes set email = em, dominio = dom, codigo = encode(sha256(convert_to(cod || u::text, 'UTF8')), 'hex'),
    expira = public.cumpre_agora() + interval '10 minutes', tentativas = 0, envios_dia = hoje, envios = v.envios + 1,
    estado = case when v.estado in ('verificado', 'por verificar') then v.estado else 'codigo' end
  where user_id = u;
  return jsonb_build_object('ok', true, 'codigo', cod, 'email', em);
end $$;

create or replace function public.cumpre_valido_ate() returns date
language sql stable set search_path = '' as $$
  select make_date(extract(year from (public.cumpre_agora() at time zone 'Europe/Lisbon'))::int + case when extract(month from (public.cumpre_agora() at time zone 'Europe/Lisbon')) >= 9 then 1 else 0 end, 9, 15)
$$;

create or replace function public.cumpre_verificacao_json(u uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce((select jsonb_build_object('estado', v.estado,
      'email', case when v.email is null then null else left(split_part(v.email, '@', 1), 2) || '•••@' || split_part(v.email, '@', 2) end,
      'escola', v.escola_nome, 'valido_ate', v.valido_ate, 'codigo_pendente', v.codigo is not null and v.expira > public.cumpre_agora())
    from public.verificacoes v where v.user_id = u), jsonb_build_object('estado', 'nenhum'))
$$;

-- O aluno escreve o código que recebeu.
create or replace function public.verificar_confirmar(p_codigo text) returns jsonb
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare u uuid := auth.uid(); v public.verificacoes; c public.conta; est text;
begin
  if u is null then raise exception 'sem sessão' using errcode = '42501'; end if;
  select * into v from public.verificacoes where user_id = u for update;
  if v.user_id is null or v.codigo is null then return jsonb_build_object('ok', false, 'erro', 'Pede primeiro um código.'); end if;
  if v.expira < public.cumpre_agora() then return jsonb_build_object('ok', false, 'erro', 'O código expirou. Pede um novo.'); end if;
  if v.tentativas >= 5 then return jsonb_build_object('ok', false, 'erro', 'Erraste o código 5 vezes. Pede um novo.'); end if;
  if encode(sha256(convert_to(regexp_replace(coalesce(p_codigo, ''), '\D', '', 'g') || u::text, 'UTF8')), 'hex') <> v.codigo then
    update public.verificacoes set tentativas = tentativas + 1 where user_id = u;
    return jsonb_build_object('ok', false, 'erro', 'Código errado. Confirma no email (pode estar no spam).');
  end if;
  select * into c from public.conta where user_id = u;
  if exists (select 1 from public.verificacoes x where lower(x.email) = lower(v.email) and x.user_id <> u and x.estado in ('verificado', 'por verificar')) then
    return jsonb_build_object('ok', false, 'erro', 'Este email já verificou outra conta da Cumpre.');
  end if;
  est := public.cumpre_dominio_estado(v.dominio);
  update public.verificacoes set codigo = null, expira = null, tentativas = 0,
    estado = case when est = 'confirmado' then 'verificado' else 'por verificar' end,
    escola_id = c.escola_id, escola_nome = c.escola_nome, verificado_em = public.cumpre_agora(), valido_ate = public.cumpre_valido_ate()
  where user_id = u;
  if est = 'confirmado' then
    update public.conta set verificado = true, escola_verificada = c.escola_id where user_id = u;
  else
    insert into public.dominios_escola (dominio, nome, estado, nota) values (v.dominio, coalesce(c.escola_nome, 'por confirmar'), 'por verificar', 'pedido por um aluno')
    on conflict (dominio) do nothing;
  end if;
  return public.conta_estado() || jsonb_build_object('ok', true, 'pendente', est <> 'confirmado');
end $$;

create or replace function public.verificacao_remover() returns jsonb
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'sem sessão' using errcode = '42501'; end if;
  update public.verificacoes set estado = 'nenhum', codigo = null, email = null, dominio = null where user_id = u;
  update public.conta set verificado = false, escola_verificada = null where user_id = u;
  return public.conta_estado();
end $$;

-- Todos os dias: confirma os que estavam à espera de um domínio que entretanto foi confirmado, recusa os outros e expira em setembro.
create or replace function public.cumpre_verificacoes_rever() returns int
language plpgsql security definer set search_path = '' as $$
declare n int := 0; r record; est text;
begin
  for r in select * from public.verificacoes where estado = 'por verificar' loop
    est := public.cumpre_dominio_estado(r.dominio);
    if est = 'confirmado' then
      update public.verificacoes set estado = 'verificado' where user_id = r.user_id;
      update public.conta set verificado = true, escola_verificada = r.escola_id where user_id = r.user_id; n := n + 1;
    elsif est = 'recusado' then
      update public.verificacoes set estado = 'recusado' where user_id = r.user_id; n := n + 1;
    end if;
  end loop;
  for r in select * from public.verificacoes where estado = 'verificado' and valido_ate < public.cumpre_dia(public.cumpre_agora()) loop
    update public.verificacoes set estado = 'expirado' where user_id = r.user_id;
    update public.conta set verificado = false, escola_verificada = null where user_id = r.user_id; n := n + 1;
  end loop;
  return n;
end $$;

-- ---------- Ranking semanal ----------
create table if not exists public.premios_semana (
  user_id uuid not null references auth.users (id) on delete cascade,
  semana date not null,
  pts int not null,
  lugar int,
  ambito text,
  motivo text not null,
  criado timestamptz not null default now(),
  primary key (user_id, semana)
);
alter table public.premios_semana enable row level security;
revoke all on public.premios_semana from anon, authenticated;

create or replace function public.cumpre_semana(t timestamptz) returns date
language sql stable set search_path = '' as $$ select date_trunc('week', (t at time zone 'Europe/Lisbon'))::date $$;

-- Horas da semana (sem as sessões começadas entre a 1:00 e as 6:00) e cumprimento dos objetivos, para uma lista de alunos.
create or replace function public.cumpre_quadro(alunos uuid[], sem date) returns table (user_id uuid, seg int, base int, feitos int)
language sql stable security definer set search_path = '' as $$
  with a as (select unnest(alunos) as u),
  h as (
    select s.user_id, sum(s.seg_final)::int seg from public.sessoes_foco s
    where s.user_id = any(alunos) and s.estado = 'fechada' and public.cumpre_dia(s.inicio) between sem and sem + 6
      and extract(hour from (s.inicio at time zone 'Europe/Lisbon')) not between 1 and 5
    group by s.user_id),
  o as (
    select o.user_id, count(*)::int base, count(*) filter (where o.cumprido is not null and public.cumpre_dia(o.cumprido) between sem and sem + 6)::int feitos
    from public.objetivos o
    where o.user_id = any(alunos) and public.cumpre_dia(o.criado) between sem - 7 and sem + 6
      and (o.cumprido is null or public.cumpre_dia(o.cumprido) >= sem)
    group by o.user_id)
  select a.u, coalesce(h.seg, 0), coalesce(o.base, 0), coalesce(o.feitos, 0) from a left join h on h.user_id = a.u left join o on o.user_id = a.u
$$;

-- Quem conta: não escondidos e sem sanções nesta semana (a tabela de sanções vem da fase 3; até lá ninguém está sancionado).
create or replace function public.cumpre_sancionado(u uuid, sem date) returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare r boolean := false;
begin
  if to_regclass('public.sancoes') is null then return false; end if;
  execute 'select exists (select 1 from public.sancoes s where s.user_id = $1 and not s.anulada and public.cumpre_dia(s.criado) between $2 and $2 + 6)' into r using u, sem;
  return r;
end $$;

create or replace function public.cumpre_populacao(u uuid, p_ambito text, p_grupo uuid) returns uuid[]
language plpgsql stable security definer set search_path = '' as $$
#variable_conflict use_variable
declare c public.conta; L uuid[];
begin
  select * into c from public.conta where user_id = u;
  if p_ambito = 'escola' then
    if not c.verificado or c.escola_verificada is null then return null; end if;
    select array_agg(x.user_id) into L from public.conta x where x.verificado and x.escola_verificada = c.escola_verificada and x.nivel is not distinct from c.nivel and x.ano is not distinct from c.ano;
  elsif p_ambito = 'nacional' then
    select array_agg(x.user_id) into L from public.conta x where x.nivel is not distinct from c.nivel and x.ano is not distinct from c.ano;
  elsif p_ambito = 'grupo' then
    if to_regclass('public.grupo_membros') is null then return null; end if;
    execute 'select array_agg(m.user_id) from public.grupo_membros m where m.grupo = $1 and m.estado = ''ativo'' and exists (select 1 from public.grupo_membros e where e.grupo = $1 and e.user_id = $2 and e.estado = ''ativo'')' into L using p_grupo, u;
  end if;
  return coalesce(L, '{}');
end $$;

create or replace function public.ranking_semana(p_ambito text, p_quadro text default 'horas', p_grupo uuid default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare u uuid := auth.uid(); c public.conta; sem date := public.cumpre_semana(public.cumpre_agora()); L uuid[]; itens jsonb; eu jsonb; n int; idade int;
begin
  if u is null then raise exception 'sem sessão' using errcode = '42501'; end if;
  perform public.cumpre_conta_garantir(u);
  select * into c from public.conta where user_id = u;
  if p_ambito not in ('escola', 'nacional', 'grupo') or p_quadro not in ('horas', 'cumprimento') then raise exception 'pedido inválido'; end if;
  L := public.cumpre_populacao(u, p_ambito, p_grupo);
  if L is null then return jsonb_build_object('semana', sem, 'erro', case when p_ambito = 'escola' then 'verificar' else 'sem acesso' end); end if;
  with q as (
    select x.*, k.nome, k.num, k.rank, coalesce(k.cor, k.rank) cor, k.esconder,
      case when x.base >= 5 then round(x.feitos * 100.0 / x.base)::int end pct
    from public.cumpre_quadro(L, sem) x join public.conta k on k.user_id = x.user_id
    where not public.cumpre_sancionado(x.user_id, sem)),
  v as (select q.*, case when p_quadro = 'horas' then q.seg else q.pct end valor from q where not q.esconder),
  o as (select v.*, rank() over (order by v.valor desc nulls last) pos, count(*) over () tot from v where v.valor is not null and v.valor > 0)
  select coalesce(jsonb_agg(jsonb_build_object('pos', o.pos, 'nome', o.nome, 'num', o.num, 'rank', o.rank, 'cor', o.cor, 'valor', o.valor, 'eu', o.user_id = u) order by o.pos, o.nome) filter (where o.pos <= case when p_ambito = 'nacional' then 100 else 50 end or o.user_id = u), '[]'::jsonb),
    max(o.tot)
  into itens, n from o;
  return jsonb_build_object('semana', sem, 'ambito', p_ambito, 'quadro', p_quadro, 'itens', itens, 'total', coalesce(n, 0),
    'populacao', coalesce(array_length(L, 1), 0), 'escondido', c.esconder, 'escola', case when p_ambito = 'escola' then c.escola_nome end);
end $$;

-- Tarefas, temas ou testes apagados na app deixam de contar para o cumprimento da semana.
create or replace function public.objetivos_apagar(p_oids text[]) returns int
language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid(); n int;
begin
  if u is null then raise exception 'sem sessão' using errcode = '42501'; end if;
  delete from public.objetivos where user_id = u and cumprido is null and oid = any(p_oids[1:300]);
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.ranking_esconder(p_esconder boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid();
begin
  if u is null then raise exception 'sem sessão' using errcode = '42501'; end if;
  update public.conta set esconder = coalesce(p_esconder, false) where user_id = u;
  return public.conta_estado();
end $$;

-- Prémios da semana (corre na segunda de madrugada, para a semana que acabou). Cada aluno recebe só o maior.
-- Escola (alunos verificados do mesmo ano) ou grupo com 10 ou mais pessoas com horas: 1.º 100, 2.º 60, 3.º 40, top 10 % 20.
-- Cumprimento de 100 % (com 5 ou mais objetivos): 30, para qualquer pessoa.
create or replace function public.cumpre_premios_semana(sem date) returns int
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_variable
declare r record; L uuid[]; n int := 0; tem_grupos boolean := to_regclass('public.grupo_membros') is not null;
begin
  create temp table if not exists _cand (user_id uuid, pts int, lugar int, ambito text, motivo text) on commit drop;
  truncate _cand;
  -- escolas
  for r in select escola_verificada, nivel, ano, array_agg(user_id) L from public.conta where verificado and escola_verificada is not null group by 1, 2, 3 loop
    insert into _cand
    select x.user_id, case when x.pos = 1 then 100 when x.pos = 2 then 60 when x.pos = 3 then 40 else 20 end, case when x.pos <= 3 then x.pos end, 'escola',
      case when x.pos <= 3 then x.pos || '.º lugar da semana na tua escola' else 'top 10 % da semana na tua escola' end
    from (select q.user_id, row_number() over (order by q.seg desc) pos, count(*) over () tot from public.cumpre_quadro(r.L, sem) q
          join public.conta k on k.user_id = q.user_id where q.seg > 0 and not k.esconder and not public.cumpre_sancionado(q.user_id, sem)) x
    where x.tot >= 10 and (x.pos <= 3 or x.pos <= ceil(x.tot * 0.1));
  end loop;
  -- grupos
  if tem_grupos then
    for r in execute 'select m.grupo, array_agg(m.user_id) L from public.grupo_membros m where m.estado = ''ativo'' group by 1' loop
      insert into _cand
      select x.user_id, case when x.pos = 1 then 100 when x.pos = 2 then 60 when x.pos = 3 then 40 else 20 end, case when x.pos <= 3 then x.pos end, 'grupo',
        case when x.pos <= 3 then x.pos || '.º lugar da semana no teu grupo' else 'top 10 % da semana no teu grupo' end
      from (select q.user_id, row_number() over (order by q.seg desc) pos, count(*) over () tot from public.cumpre_quadro(r.L, sem) q
            join public.conta k on k.user_id = q.user_id where q.seg > 0 and not k.esconder and not public.cumpre_sancionado(q.user_id, sem)) x
      where x.tot >= 10 and (x.pos <= 3 or x.pos <= ceil(x.tot * 0.1));
    end loop;
  end if;
  -- cumprimento de 100 %
  select array_agg(user_id) into L from public.conta;
  insert into _cand
  select q.user_id, 30, null, 'cumprimento', 'semana com 100 % dos objetivos cumpridos'
  from public.cumpre_quadro(coalesce(L, '{}'), sem) q where q.base >= 5 and q.feitos = q.base and not public.cumpre_sancionado(q.user_id, sem);
  for r in select distinct on (c.user_id) c.* from _cand c order by c.user_id, c.pts desc, c.lugar nulls last loop
    insert into public.premios_semana (user_id, semana, pts, lugar, ambito, motivo) values (r.user_id, sem, r.pts, r.lugar, r.ambito, r.motivo)
    on conflict do nothing;
    if found then
      perform public.cumpre_creditar(r.user_id, r.pts, 'premio-semana', 'prémio: ' || r.motivo, 'semana:' || sem, false);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- O que a fase 2 junta ao estado da conta (a fase 3 acrescenta mais coisas aqui).
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
    'semana', public.cumpre_semana(public.cumpre_agora()), 'idade', public.cumpre_idade(u), 'nivel', c.nivel, 'ano', c.ano, 'escola', c.escola_nome);
end $$;

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
            from (select * from public.movimentos m where m.user_id = u and m.n <> 0 order by m.id desc limit 30) x)) || public.cumpre_conta_extra(u);
end $$;

-- A conta nova copia logo o perfil (escola, ano, data de nascimento).
create or replace function public.cumpre_conta_nova() returns trigger
language plpgsql security definer set search_path = '' as $$
declare d jsonb;
begin
  select e.dados into d from public.estado e where e.user_id = new.user_id;
  if d is not null then perform public.cumpre_perfil_copiar(new.user_id, d); end if;
  return new;
end $$;
drop trigger if exists cumpre_conta_perfil on public.conta;
create trigger cumpre_conta_perfil after insert on public.conta for each row execute function public.cumpre_conta_nova();

-- Agendador: prémios à segunda de madrugada e revisão das verificações todos os dias.
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'cron') then
    perform cron.unschedule(jobid) from cron.job where jobname in ('cumpre-premios-semana', 'cumpre-verificacoes');
    perform cron.schedule('cumpre-premios-semana', '20 0 * * 1', $c$select public.cumpre_premios_semana(public.cumpre_semana(now()) - 7)$c$);
    perform cron.schedule('cumpre-verificacoes', '40 3 * * *', $c$select public.cumpre_verificacoes_rever()$c$);
  end if;
end $$;

do $$
declare f text;
begin
  foreach f in array array['cumpre_perfil_copiar(uuid,jsonb)', 'cumpre_estado_mudou()', 'cumpre_idade(uuid)', 'cumpre_dominio_estado(text)', 'cumpre_verificacao_criar(uuid,text)',
    'cumpre_valido_ate()', 'cumpre_verificacao_json(uuid)', 'cumpre_verificacoes_rever()', 'cumpre_semana(timestamptz)', 'cumpre_quadro(uuid[],date)',
    'cumpre_sancionado(uuid,date)', 'cumpre_populacao(uuid,text,uuid)', 'cumpre_premios_semana(date)', 'cumpre_conta_extra(uuid)', 'cumpre_conta_nova()'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
  end loop;
  foreach f in array array['objetivos_apagar(text[])', 'verificar_confirmar(text)', 'verificacao_remover()', 'ranking_semana(text,text,uuid)', 'ranking_esconder(boolean)', 'conta_estado()'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- A função do servidor (Edge Function) chama estas com a chave secreta.
grant execute on function public.cumpre_verificacao_criar(uuid, text) to service_role;
