-- Celeiro Office · backoffice · estrutura no Supabase
-- (acesso, perfis, módulos, níveis de permissão, auditoria, Workflow e Cadastro de pessoas físicas e jurídicas)
-- Projeto Supabase PRÓPRIO do backoffice (separado do projeto do site).
-- Rode este arquivo inteiro em: painel do Supabase > SQL Editor > New query > Run.
-- Pode ser rodado mais de uma vez sem duplicar nada.

-- =====================================================================
-- 1) TABELAS
-- =====================================================================

-- Organizações (clientes corporativos)
create table if not exists public.organizacoes (
  id        uuid primary key default gen_random_uuid(),
  nome      text not null check (char_length(nome) between 1 and 160),
  cnpj      text not null default '' check (char_length(cnpj) <= 18),
  ativo     boolean not null default true,
  criado_em timestamptz not null default now()
);

-- Usuários do backoffice (perfil de cada acesso criado em Authentication)
create table if not exists public.usuarios (
  user_id        uuid primary key references auth.users(id) on delete cascade,
  nome           text not null check (char_length(nome) between 1 and 120),
  email          text not null,
  perfil         text not null check (perfil in ('master','gerencial','corp_master','corp_operador')),
  organizacao_id uuid references public.organizacoes(id),
  ativo          boolean not null default true,
  criado_em      timestamptz not null default now(),
  constraint usuarios_perfil_org check (
    (perfil in ('master','gerencial') and organizacao_id is null) or
    (perfil in ('corp_master','corp_operador') and organizacao_id is not null)
  )
);

-- Módulos do sistema
create table if not exists public.modulos (
  codigo text primary key,
  nome   text not null,
  ordem  int  not null,
  fase   int  not null
);

insert into public.modulos (codigo, nome, ordem, fase) values
  ('dashboard',     'Dashboard',                1, 3),
  ('workflow',      'Workflow',                 2, 2),
  ('cadastro',      'Cadastro',                 3, 2),
  ('financeiro',    'Financeiro',               4, 3),
  ('investimentos', 'Investimentos',            5, 4),
  ('mcp',           'Conexão MCP',              6, 4),
  ('conteudo',      'Conteúdo do app e do site', 7, 5),
  ('auditoria',     'Auditoria',                8, 1)
on conflict (codigo) do update
  set nome = excluded.nome, ordem = excluded.ordem, fase = excluded.fase;

-- Habilitação de módulos por perfil.
-- Gerencial: organizacao_id nulo (vale para a equipe da Celeiro).
-- Corporativo master / operador: uma linha por organização.
create table if not exists public.modulo_permissoes (
  id             uuid primary key default gen_random_uuid(),
  organizacao_id uuid references public.organizacoes(id) on delete cascade,
  perfil         text not null check (perfil in ('gerencial','corp_master','corp_operador')),
  modulo         text not null references public.modulos(codigo),
  habilitado     boolean not null default false,
  atualizado_em  timestamptz not null default now(),
  constraint modulo_permissoes_org check (
    (perfil = 'gerencial' and organizacao_id is null) or
    (perfil <> 'gerencial' and organizacao_id is not null)
  )
);

create unique index if not exists modulo_permissoes_unica
  on public.modulo_permissoes (
    coalesce(organizacao_id, '00000000-0000-0000-0000-000000000000'::uuid), perfil, modulo
  );

-- Níveis de permissão: conjuntos de módulos que podem ser atribuídos a usuários.
-- organizacao_id nulo = nível da equipe Celeiro (perfil Gerencial).
-- Um nível só libera módulos que também estejam habilitados para o perfil em modulo_permissoes.
create table if not exists public.niveis_permissao (
  id             uuid primary key default gen_random_uuid(),
  nome           text not null check (char_length(nome) between 1 and 80),
  descricao      text not null default '' check (char_length(descricao) <= 300),
  organizacao_id uuid references public.organizacoes(id) on delete cascade,
  modulos        text[] not null default '{}',
  criado_em      timestamptz not null default now()
);

alter table public.usuarios
  add column if not exists nivel_id uuid references public.niveis_permissao(id);

-- Auditoria: todas as ações de todos os usuários
create table if not exists public.auditoria (
  id             bigint generated always as identity primary key,
  ocorrido_em    timestamptz not null default now(),
  user_id        uuid,
  usuario_nome   text,
  usuario_email  text,
  perfil         text,
  organizacao_id uuid,
  acao           text not null,
  modulo         text not null default '',
  tabela         text,
  registro_id    text,
  detalhes       jsonb,
  ip             text,
  pais           text,
  local          text,
  navegador      text,
  origem         text not null default 'banco'
);

create index if not exists auditoria_ocorrido_em on public.auditoria (ocorrido_em desc);
create index if not exists auditoria_user_id     on public.auditoria (user_id);
create index if not exists auditoria_org         on public.auditoria (organizacao_id);

alter table public.organizacoes      enable row level security;
alter table public.usuarios          enable row level security;
alter table public.modulos           enable row level security;
alter table public.modulo_permissoes enable row level security;
alter table public.auditoria         enable row level security;
alter table public.niveis_permissao  enable row level security;

-- =====================================================================
-- 2) FUNÇÕES DE APOIO (quem é o usuário e o que ele pode)
-- =====================================================================

-- Entrou com as duas etapas (senha + Google Authenticator)?
create or replace function public.aal2()
returns boolean
language sql
stable
set search_path = ''
as $$
  select coalesce((select auth.jwt() ->> 'aal') = 'aal2', false);
$$;

-- Perfil do usuário atual (nulo se inativo ou se a organização estiver inativa)
create or replace function public.meu_perfil()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select u.perfil
  from public.usuarios u
  left join public.organizacoes o on o.id = u.organizacao_id
  where u.user_id = (select auth.uid())
    and u.ativo
    and (u.organizacao_id is null or o.ativo);
$$;

create or replace function public.minha_org()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select u.organizacao_id
  from public.usuarios u
  join public.organizacoes o on o.id = u.organizacao_id
  where u.user_id = (select auth.uid())
    and u.ativo
    and o.ativo;
$$;

create or replace function public.eh_master()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.aal2() and coalesce(public.meu_perfil() = 'master', false);
$$;

create or replace function public.eh_equipe()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.aal2() and coalesce(public.meu_perfil() in ('master','gerencial'), false);
$$;

-- Módulos que um usuário realmente tem (uso interno).
-- Master: todos. Demais: módulos habilitados para o perfil (e organização),
-- limitados aos módulos do nível de permissão do usuário, quando ele tem um.
create or replace function public.modulos_efetivos(p_user uuid)
returns text[]
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(array_agg(m.codigo order by m.ordem), '{}'::text[])
  from public.usuarios u
  left join public.organizacoes o on o.id = u.organizacao_id
  left join public.niveis_permissao n on n.id = u.nivel_id
  cross join public.modulos m
  where u.user_id = p_user
    and u.ativo
    and (u.organizacao_id is null or o.ativo)
    and (
      u.perfil = 'master'
      or (
        exists (
          select 1
          from public.modulo_permissoes p
          where p.modulo = m.codigo
            and p.habilitado
            and p.perfil = u.perfil
            and p.organizacao_id is not distinct from u.organizacao_id
        )
        and (u.nivel_id is null or m.codigo = any(n.modulos))
      )
    );
$$;

-- O usuário atual tem o módulo habilitado? (Master tem todos.)
create or replace function public.pode_modulo(p_modulo text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.aal2()
     and coalesce(p_modulo = any(public.modulos_efetivos((select auth.uid()))), false);
$$;

-- O usuário atual pode criar um usuário com este perfil nesta organização?
create or replace function public.pode_criar_usuario(p_perfil text, p_org uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.aal2()
     and coalesce(p_perfil in ('master','gerencial','corp_master','corp_operador'), false)
     and (p_perfil in ('master','gerencial')) = (p_org is null)
     and (p_org is null or exists (select 1 from public.organizacoes o where o.id = p_org))
     and coalesce(
       public.meu_perfil() = 'master'
       or (public.meu_perfil() = 'corp_master' and p_perfil = 'corp_operador' and p_org = public.minha_org()),
       false);
$$;

-- O nível serve para um usuário com este perfil nesta organização?
create or replace function public.nivel_valido(p_nivel uuid, p_perfil text, p_org uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_nivel is null
      or (
        p_perfil <> 'master'
        and exists (
          select 1 from public.niveis_permissao n
          where n.id = p_nivel
            and n.organizacao_id is not distinct from (case when p_perfil = 'gerencial' then null else p_org end)
        )
      );
$$;

-- =====================================================================
-- 3) AUDITORIA
-- =====================================================================

-- Lê um cabeçalho da requisição (IP, navegador)
create or replace function public.cabecalho(p_nome text)
returns text
language plpgsql
stable
set search_path = ''
as $$
declare
  h text;
begin
  h := current_setting('request.headers', true);
  if h is null or h = '' then
    return null;
  end if;
  return h::json ->> p_nome;
exception when others then
  return null;
end;
$$;

-- Grava uma linha de auditoria (uso interno; não é chamada pelo navegador)
create or replace function public.grava_auditoria(
  p_acao text, p_modulo text, p_tabela text, p_registro text, p_detalhes jsonb, p_origem text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_u     public.usuarios%rowtype;
  v_email text;
begin
  if v_uid is not null then
    select * into v_u from public.usuarios where user_id = v_uid;
    if v_u.user_id is null then
      select email into v_email from auth.users where id = v_uid;
    end if;
  end if;

  insert into public.auditoria (
    user_id, usuario_nome, usuario_email, perfil, organizacao_id,
    acao, modulo, tabela, registro_id, detalhes,
    ip, pais, navegador, origem
  ) values (
    v_uid, v_u.nome, coalesce(v_u.email, v_email), v_u.perfil, v_u.organizacao_id,
    p_acao, coalesce(p_modulo, ''), p_tabela, p_registro, p_detalhes,
    nullif(trim(split_part(coalesce(public.cabecalho('x-forwarded-for'), ''), ',', 1)), ''),
    nullif(public.cabecalho('cf-ipcountry'), ''),
    left(public.cabecalho('user-agent'), 300),
    p_origem
  );
end;
$$;

-- Eventos vindos da tela (login, saída, telas abertas)
create or replace function public.registrar_evento(
  p_acao text, p_modulo text default '', p_detalhes jsonb default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    raise exception 'Sessão necessária';
  end if;
  if p_acao is null or char_length(trim(p_acao)) = 0 then
    raise exception 'Ação não informada';
  end if;
  if p_detalhes is not null and pg_column_size(p_detalhes) > 4000 then
    p_detalhes := null;
  end if;
  perform public.grava_auditoria(
    left(trim(p_acao), 160), left(coalesce(p_modulo, ''), 60), null, null, p_detalhes, 'tela'
  );
end;
$$;

-- Gatilho: grava toda inclusão, alteração e exclusão nas tabelas
create or replace function public.auditar()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_novo  jsonb;
  v_velho jsonb;
begin
  if tg_op = 'INSERT' then
    v_novo := to_jsonb(new);
    perform public.grava_auditoria('Criou registro', tg_argv[0], tg_table_name,
      coalesce(v_novo ->> 'id', v_novo ->> 'user_id'),
      jsonb_build_object('depois', v_novo), 'banco');
    return new;
  elsif tg_op = 'UPDATE' then
    v_novo := to_jsonb(new);
    v_velho := to_jsonb(old);
    perform public.grava_auditoria('Alterou registro', tg_argv[0], tg_table_name,
      coalesce(v_novo ->> 'id', v_novo ->> 'user_id'),
      jsonb_build_object('antes', v_velho, 'depois', v_novo), 'banco');
    return new;
  else
    v_velho := to_jsonb(old);
    perform public.grava_auditoria('Excluiu registro', tg_argv[0], tg_table_name,
      coalesce(v_velho ->> 'id', v_velho ->> 'user_id'),
      jsonb_build_object('antes', v_velho), 'banco');
    return old;
  end if;
end;
$$;

drop trigger if exists auditar_organizacoes on public.organizacoes;
create trigger auditar_organizacoes
  after insert or update or delete on public.organizacoes
  for each row execute function public.auditar('Organizações');

drop trigger if exists auditar_usuarios on public.usuarios;
create trigger auditar_usuarios
  after insert or update or delete on public.usuarios
  for each row execute function public.auditar('Usuários');

drop trigger if exists auditar_modulo_permissoes on public.modulo_permissoes;
create trigger auditar_modulo_permissoes
  after insert or update or delete on public.modulo_permissoes
  for each row execute function public.auditar('Módulos e permissões');

drop trigger if exists auditar_niveis_permissao on public.niveis_permissao;
create trigger auditar_niveis_permissao
  after insert or update or delete on public.niveis_permissao
  for each row execute function public.auditar('Usuários');

-- A auditoria não pode ser alterada nem apagada
create or replace function public.auditoria_imutavel()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'O registro de auditoria não pode ser alterado nem apagado';
end;
$$;

drop trigger if exists auditoria_sem_alteracao on public.auditoria;
create trigger auditoria_sem_alteracao
  before update or delete on public.auditoria
  for each row execute function public.auditoria_imutavel();

drop trigger if exists auditoria_sem_truncate on public.auditoria;
create trigger auditoria_sem_truncate
  before truncate on public.auditoria
  for each statement execute function public.auditoria_imutavel();

-- =====================================================================
-- 4) OPERAÇÕES CHAMADAS PELA TELA
-- =====================================================================

-- Situação e módulos do usuário atual
create or replace function public.meu_acesso()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_u    public.usuarios%rowtype;
  v_org  public.organizacoes%rowtype;
  v_mods jsonb;
begin
  if not public.aal2() then
    return jsonb_build_object('situacao', 'sem_2fa');
  end if;
  select * into v_u from public.usuarios where user_id = (select auth.uid());
  if v_u.user_id is null then
    return jsonb_build_object('situacao', 'sem_cadastro');
  end if;
  if v_u.organizacao_id is not null then
    select * into v_org from public.organizacoes where id = v_u.organizacao_id;
  end if;
  if not v_u.ativo or (v_u.organizacao_id is not null and not coalesce(v_org.ativo, false)) then
    return jsonb_build_object('situacao', 'inativo');
  end if;
  v_mods := to_jsonb(public.modulos_efetivos(v_u.user_id));
  return jsonb_build_object(
    'situacao', 'ok',
    'user_id', v_u.user_id,
    'nome', v_u.nome,
    'email', v_u.email,
    'perfil', v_u.perfil,
    'organizacao_id', v_u.organizacao_id,
    'organizacao', v_org.nome,
    'nivel_id', v_u.nivel_id,
    'modulos', v_mods
  );
end;
$$;

-- Vincula um acesso já criado em Authentication a um perfil do backoffice
drop function if exists public.vincular_usuario(text, text, text, uuid);
create or replace function public.vincular_usuario(
  p_email text, p_nome text, p_perfil text, p_org uuid default null, p_nivel uuid default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
begin
  if not public.aal2() or public.meu_perfil() is null then
    raise exception 'Acesso negado';
  end if;
  if not public.pode_criar_usuario(p_perfil, p_org) then
    raise exception 'Seu perfil não pode criar este tipo de usuário';
  end if;
  if not public.nivel_valido(p_nivel, p_perfil, p_org) then
    raise exception 'Este nível de permissão não serve para este perfil ou organização';
  end if;

  select id into v_id from auth.users where lower(email) = lower(trim(p_email));
  if v_id is null then
    raise exception 'Não existe acesso criado para este e-mail.';
  end if;
  if exists (select 1 from public.usuarios where user_id = v_id) then
    raise exception 'Este e-mail já está vinculado a um usuário';
  end if;

  insert into public.usuarios (user_id, nome, email, perfil, organizacao_id, nivel_id)
  values (v_id, trim(p_nome), lower(trim(p_email)), p_perfil, p_org, p_nivel);
  return v_id;
end;
$$;

-- Altera nome, perfil, organização, nível e situação de um usuário
drop function if exists public.atualizar_usuario(uuid, text, text, uuid, boolean);
create or replace function public.atualizar_usuario(
  p_user uuid, p_nome text, p_perfil text, p_org uuid, p_ativo boolean, p_nivel uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_meu  text := public.meu_perfil();
  v_alvo public.usuarios%rowtype;
begin
  if not public.aal2() or v_meu is null then
    raise exception 'Acesso negado';
  end if;
  select * into v_alvo from public.usuarios where user_id = p_user;
  if v_alvo.user_id is null then
    raise exception 'Usuário não encontrado';
  end if;
  if p_perfil in ('master','gerencial') then
    p_org := null;
  end if;

  if v_meu = 'master' then
    if p_user = (select auth.uid()) and (p_perfil <> v_alvo.perfil or not p_ativo) then
      raise exception 'Você não pode mudar o próprio perfil nem desativar o próprio acesso';
    end if;
  elsif v_meu = 'corp_master'
        and v_alvo.perfil = 'corp_operador'
        and v_alvo.organizacao_id = public.minha_org()
        and p_perfil = 'corp_operador'
        and p_org = public.minha_org() then
    null;
  else
    raise exception 'Seu perfil não pode alterar este usuário';
  end if;
  if not public.nivel_valido(p_nivel, p_perfil, p_org) then
    raise exception 'Este nível de permissão não serve para este perfil ou organização';
  end if;

  update public.usuarios
     set nome = trim(p_nome),
         perfil = p_perfil,
         organizacao_id = p_org,
         nivel_id = p_nivel,
         ativo = p_ativo
   where user_id = p_user;
end;
$$;

-- Troca o e-mail de acesso de um usuário (o login passa a ser o e-mail novo)
create or replace function public.alterar_email_usuario(p_user uuid, p_email text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_meu   text := public.meu_perfil();
  v_alvo  public.usuarios%rowtype;
  v_email text := lower(trim(coalesce(p_email, '')));
begin
  if not public.aal2() or v_meu is null then
    raise exception 'Acesso negado';
  end if;
  select * into v_alvo from public.usuarios where user_id = p_user;
  if v_alvo.user_id is null then
    raise exception 'Usuário não encontrado';
  end if;
  if not (v_meu = 'master'
          or (v_meu = 'corp_master' and v_alvo.perfil = 'corp_operador'
              and v_alvo.organizacao_id = public.minha_org())) then
    raise exception 'Seu perfil não pode alterar este usuário';
  end if;
  if v_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' or char_length(v_email) > 254 then
    raise exception 'E-mail inválido';
  end if;
  if v_email = lower(v_alvo.email) then
    return;
  end if;
  if exists (select 1 from auth.users where lower(email) = v_email and id <> p_user) then
    raise exception 'Já existe um acesso com este e-mail';
  end if;

  update auth.users set email = v_email, updated_at = now() where id = p_user;
  update auth.identities
     set identity_data = coalesce(identity_data, '{}'::jsonb) || jsonb_build_object('email', v_email),
         updated_at = now()
   where user_id = p_user and provider = 'email';
  update public.usuarios set email = v_email where user_id = p_user;
end;
$$;

-- Cria ou altera um nível de permissão (p_id nulo = novo)
create or replace function public.salvar_nivel(
  p_id uuid, p_nome text, p_descricao text, p_org uuid, p_modulos text[]
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_meu   text := public.meu_perfil();
  v_atual public.niveis_permissao%rowtype;
  v_mods  text[];
  v_id    uuid;
begin
  if not public.aal2() or v_meu is null then
    raise exception 'Acesso negado';
  end if;
  select coalesce(array_agg(m.codigo order by m.ordem), '{}'::text[]) into v_mods
    from public.modulos m where m.codigo = any(coalesce(p_modulos, '{}'::text[]));
  if coalesce(array_length(v_mods, 1), 0) <> (select count(distinct x) from unnest(coalesce(p_modulos, '{}'::text[])) x) then
    raise exception 'Módulo desconhecido na lista';
  end if;

  if v_meu = 'master' then
    if p_org is not null and not exists (select 1 from public.organizacoes where id = p_org) then
      raise exception 'Organização não encontrada';
    end if;
  elsif v_meu = 'corp_master'
        and p_org = public.minha_org()
        and v_mods <@ public.modulos_efetivos((select auth.uid())) then
    null;
  else
    raise exception 'Seu perfil não pode criar este nível de permissão';
  end if;

  if p_id is null then
    insert into public.niveis_permissao (nome, descricao, organizacao_id, modulos)
    values (trim(p_nome), coalesce(trim(p_descricao), ''), p_org, v_mods)
    returning id into v_id;
    return v_id;
  end if;

  select * into v_atual from public.niveis_permissao where id = p_id;
  if v_atual.id is null then
    raise exception 'Nível não encontrado';
  end if;
  if v_atual.organizacao_id is distinct from p_org then
    raise exception 'Não é possível mudar a organização de um nível já criado';
  end if;
  update public.niveis_permissao
     set nome = trim(p_nome), descricao = coalesce(trim(p_descricao), ''), modulos = v_mods
   where id = p_id;
  return p_id;
end;
$$;

-- Exclui um nível de permissão que não esteja em uso
create or replace function public.excluir_nivel(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_meu   text := public.meu_perfil();
  v_atual public.niveis_permissao%rowtype;
begin
  if not public.aal2() or v_meu is null then
    raise exception 'Acesso negado';
  end if;
  select * into v_atual from public.niveis_permissao where id = p_id;
  if v_atual.id is null then
    raise exception 'Nível não encontrado';
  end if;
  if not coalesce(v_meu = 'master' or (v_meu = 'corp_master' and v_atual.organizacao_id = public.minha_org()), false) then
    raise exception 'Seu perfil não pode excluir este nível de permissão';
  end if;
  if exists (select 1 from public.usuarios where nivel_id = p_id) then
    raise exception 'Há usuários com este nível. Troque o nível deles antes de excluir.';
  end if;
  delete from public.niveis_permissao where id = p_id;
end;
$$;

-- Módulos de cada usuário que o usuário atual pode ver:
-- "modulos" = o que a pessoa realmente acessa; "bloqueados" = está no nível dela,
-- mas não está habilitado para o perfil em Módulos e permissões.
create or replace function public.usuarios_com_modulos()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'user_id', u.user_id,
    'modulos', to_jsonb(public.modulos_efetivos(u.user_id)),
    'bloqueados', to_jsonb(coalesce((
      select array_agg(x) from unnest(n.modulos) x
      where x <> all(public.modulos_efetivos(u.user_id))), '{}'::text[]))
  )), '[]'::jsonb)
  from public.usuarios u
  left join public.niveis_permissao n on n.id = u.nivel_id
  where public.aal2()
    and (
      u.user_id = (select auth.uid())
      or public.eh_equipe()
      or (public.meu_perfil() = 'corp_master' and u.organizacao_id = public.minha_org())
    );
$$;

-- Liga ou desliga um módulo para um perfil
create or replace function public.definir_modulo(
  p_org uuid, p_perfil text, p_modulo text, p_habilitado boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_meu text := public.meu_perfil();
begin
  if not public.aal2() or v_meu is null then
    raise exception 'Acesso negado';
  end if;
  if p_perfil = 'gerencial' then
    p_org := null;
  end if;

  if v_meu = 'master' then
    null;
  elsif v_meu = 'corp_master'
        and p_perfil = 'corp_operador'
        and p_org = public.minha_org()
        and (not p_habilitado or public.pode_modulo(p_modulo)) then
    null;
  else
    raise exception 'Seu perfil não pode alterar esta permissão';
  end if;

  update public.modulo_permissoes
     set habilitado = p_habilitado, atualizado_em = now()
   where organizacao_id is not distinct from p_org
     and perfil = p_perfil
     and modulo = p_modulo;
  if not found then
    insert into public.modulo_permissoes (organizacao_id, perfil, modulo, habilitado)
    values (p_org, p_perfil, p_modulo, p_habilitado);
  end if;
end;
$$;

-- =====================================================================
-- 5) PERMISSÕES
-- =====================================================================

revoke all on public.organizacoes, public.usuarios, public.modulos,
              public.modulo_permissoes, public.auditoria, public.niveis_permissao
  from anon, authenticated;

grant select, insert, update on public.organizacoes to authenticated;
grant select on public.usuarios          to authenticated;
grant select on public.modulos           to authenticated;
grant select on public.modulo_permissoes to authenticated;
grant select on public.auditoria         to authenticated;
grant select on public.niveis_permissao  to authenticated;

revoke all on function public.grava_auditoria(text, text, text, text, jsonb, text) from public, anon, authenticated;
revoke all on function public.auditar()            from public, anon, authenticated;
revoke all on function public.auditoria_imutavel() from public, anon, authenticated;
revoke all on function public.modulos_efetivos(uuid) from public, anon, authenticated;

revoke all on function public.aal2()              from public, anon;
revoke all on function public.cabecalho(text)     from public, anon;
revoke all on function public.meu_perfil()        from public, anon;
revoke all on function public.minha_org()         from public, anon;
revoke all on function public.eh_master()         from public, anon;
revoke all on function public.eh_equipe()         from public, anon;
revoke all on function public.pode_modulo(text)   from public, anon;
revoke all on function public.meu_acesso()        from public, anon;
revoke all on function public.registrar_evento(text, text, jsonb)             from public, anon;
revoke all on function public.vincular_usuario(text, text, text, uuid, uuid)   from public, anon;
revoke all on function public.atualizar_usuario(uuid, text, text, uuid, boolean, uuid) from public, anon;
revoke all on function public.alterar_email_usuario(uuid, text) from public, anon;
revoke all on function public.pode_criar_usuario(text, uuid)                   from public, anon;
revoke all on function public.nivel_valido(uuid, text, uuid)                   from public, anon;
revoke all on function public.salvar_nivel(uuid, text, text, uuid, text[])     from public, anon;
revoke all on function public.excluir_nivel(uuid)                              from public, anon;
revoke all on function public.usuarios_com_modulos()                           from public, anon;
revoke all on function public.definir_modulo(uuid, text, text, boolean)        from public, anon;

grant execute on function public.aal2()            to authenticated;
grant execute on function public.cabecalho(text)   to authenticated;
grant execute on function public.meu_perfil()      to authenticated;
grant execute on function public.minha_org()       to authenticated;
grant execute on function public.eh_master()       to authenticated;
grant execute on function public.eh_equipe()       to authenticated;
grant execute on function public.pode_modulo(text) to authenticated;
grant execute on function public.meu_acesso()      to authenticated;
grant execute on function public.registrar_evento(text, text, jsonb)             to authenticated;
grant execute on function public.vincular_usuario(text, text, text, uuid, uuid)   to authenticated;
grant execute on function public.atualizar_usuario(uuid, text, text, uuid, boolean, uuid) to authenticated;
grant execute on function public.alterar_email_usuario(uuid, text) to authenticated;
grant execute on function public.pode_criar_usuario(text, uuid)                   to authenticated;
grant execute on function public.nivel_valido(uuid, text, uuid)                   to authenticated;
grant execute on function public.salvar_nivel(uuid, text, text, uuid, text[])     to authenticated;
grant execute on function public.excluir_nivel(uuid)                              to authenticated;
grant execute on function public.usuarios_com_modulos()                           to authenticated;
grant execute on function public.definir_modulo(uuid, text, text, boolean)        to authenticated;

-- =====================================================================
-- 6) REGRAS DE ACESSO POR LINHA
--    Nada é entregue a quem entrou só com a senha (sem o segundo fator).
-- =====================================================================

drop policy if exists "organizacoes leitura" on public.organizacoes;
create policy "organizacoes leitura" on public.organizacoes
  for select to authenticated
  using ((select public.eh_equipe()) or ((select public.aal2()) and id = (select public.minha_org())));

drop policy if exists "organizacoes inclusao master" on public.organizacoes;
create policy "organizacoes inclusao master" on public.organizacoes
  for insert to authenticated
  with check ((select public.eh_master()));

drop policy if exists "organizacoes alteracao master" on public.organizacoes;
create policy "organizacoes alteracao master" on public.organizacoes
  for update to authenticated
  using ((select public.eh_master()))
  with check ((select public.eh_master()));

drop policy if exists "usuarios leitura" on public.usuarios;
create policy "usuarios leitura" on public.usuarios
  for select to authenticated
  using (
    (select public.aal2()) and (
      user_id = (select auth.uid())
      or (select public.eh_equipe())
      or ((select public.meu_perfil()) = 'corp_master' and organizacao_id = (select public.minha_org()))
    )
  );

drop policy if exists "modulos leitura" on public.modulos;
create policy "modulos leitura" on public.modulos
  for select to authenticated
  using ((select public.aal2()) and (select public.meu_perfil()) is not null);

drop policy if exists "modulo_permissoes leitura" on public.modulo_permissoes;
create policy "modulo_permissoes leitura" on public.modulo_permissoes
  for select to authenticated
  using ((select public.eh_equipe()) or ((select public.aal2()) and organizacao_id = (select public.minha_org())));

drop policy if exists "niveis_permissao leitura" on public.niveis_permissao;
create policy "niveis_permissao leitura" on public.niveis_permissao
  for select to authenticated
  using ((select public.eh_equipe()) or ((select public.aal2()) and organizacao_id = (select public.minha_org())));

drop policy if exists "auditoria leitura" on public.auditoria;
create policy "auditoria leitura" on public.auditoria
  for select to authenticated
  using (
    (select public.eh_master())
    or (
      (select public.pode_modulo('auditoria'))
      and ((select public.meu_perfil()) = 'gerencial' or organizacao_id = (select public.minha_org()))
    )
  );

-- =====================================================================
-- 8) WORKFLOW (tarefas em lista e em quadro)
--    Tarefa da equipe Celeiro: organizacao_id nulo. Tarefa de um cliente: organizacao_id dele.
--    Quem vê: quem tem o módulo Workflow; equipe Celeiro vê todas, cliente vê as da própria organização.
--    Tarefa confidencial: só quem criou, os responsáveis e os envolvidos.
--    Toda gravação passa pelas funções abaixo.
-- =====================================================================

create table if not exists public.workflow_tarefas (
  id             uuid primary key default gen_random_uuid(),
  numero         bigint generated always as identity,
  organizacao_id uuid references public.organizacoes(id) on delete cascade,
  titulo         text not null check (char_length(titulo) between 1 and 500),
  descricao      text not null default '' check (char_length(descricao) <= 4000),
  status         text not null default 'a_fazer'
                 check (status in ('a_fazer','em_andamento','em_revisao','concluida')),
  prioridade     text not null default 'media' check (prioridade in ('baixa','media','alta','urgente')),
  prazo          date,
  modulo         text not null default '' check (char_length(modulo) <= 60),
  categoria      text not null default '' check (char_length(categoria) <= 80),
  confidencial   boolean not null default false,
  origem_rotulo  text not null default '' check (char_length(origem_rotulo) <= 160),
  criado_por     uuid references public.usuarios(user_id) on delete set null,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now(),
  atualizado_por uuid references public.usuarios(user_id) on delete set null,
  concluida_em   timestamptz
);

create table if not exists public.workflow_participantes (
  tarefa_id uuid not null references public.workflow_tarefas(id) on delete cascade,
  user_id   uuid not null references public.usuarios(user_id) on delete cascade,
  papel     text not null check (papel in ('responsavel','envolvido')),
  primary key (tarefa_id, user_id)
);

create table if not exists public.workflow_comentarios (
  id        uuid primary key default gen_random_uuid(),
  tarefa_id uuid not null references public.workflow_tarefas(id) on delete cascade,
  user_id   uuid references public.usuarios(user_id) on delete set null,
  texto     text not null check (char_length(texto) between 1 and 2000),
  criado_em timestamptz not null default now()
);

-- Quando cada pessoa abriu cada tarefa pela última vez (para marcar "não lidas")
create table if not exists public.workflow_leituras (
  tarefa_id uuid not null references public.workflow_tarefas(id) on delete cascade,
  user_id   uuid not null references public.usuarios(user_id) on delete cascade,
  lido_em   timestamptz not null default now(),
  primary key (tarefa_id, user_id)
);

create unique index if not exists workflow_tarefas_numero on public.workflow_tarefas (numero);
create index if not exists workflow_tarefas_org        on public.workflow_tarefas (organizacao_id);
create index if not exists workflow_participantes_user on public.workflow_participantes (user_id);
create index if not exists workflow_comentarios_tarefa on public.workflow_comentarios (tarefa_id);

alter table public.workflow_tarefas       enable row level security;
alter table public.workflow_participantes enable row level security;
alter table public.workflow_comentarios   enable row level security;
alter table public.workflow_leituras      enable row level security;

-- O usuário atual pode ver e criar tarefas desta organização (nulo = equipe Celeiro)?
create or replace function public.workflow_escopo_ok(p_org uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.pode_modulo('workflow')
     and coalesce(public.eh_equipe() or p_org = public.minha_org(), false);
$$;

-- O usuário atual pode ver esta tarefa? (considera as confidenciais)
create or replace function public.workflow_pode_ver(p_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.workflow_tarefas t
    where t.id = p_id
      and public.workflow_escopo_ok(t.organizacao_id)
      and (
        not t.confidencial
        or t.criado_por = (select auth.uid())
        or exists (
          select 1 from public.workflow_participantes p
          where p.tarefa_id = t.id and p.user_id = (select auth.uid())
        )
      )
  );
$$;

-- Esta pessoa pode ser marcada em uma tarefa desta organização? (uso interno)
create or replace function public.workflow_pessoa_ok(p_user uuid, p_org uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.usuarios u
    where u.user_id = p_user
      and u.ativo
      and 'workflow' = any(public.modulos_efetivos(u.user_id))
      and (
        (p_org is not null and u.organizacao_id = p_org)
        or (u.perfil in ('master','gerencial') and (p_org is null or public.eh_equipe()))
      )
  );
$$;

-- Pessoas que o usuário atual pode marcar em uma tarefa
create or replace function public.workflow_pessoas(p_org uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.workflow_escopo_ok(p_org) then
    raise exception 'Acesso negado';
  end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
      'user_id', u.user_id, 'nome', u.nome, 'perfil', u.perfil) order by u.nome), '[]'::jsonb)
    from public.usuarios u
    where public.workflow_pessoa_ok(u.user_id, p_org)
  );
end;
$$;

-- Tarefas que o usuário atual enxerga, com participantes, comentários e "não lida"
create or replace function public.workflow_listar()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(s.x order by s.numero desc), '[]'::jsonb)
  from (
    select t.numero, jsonb_build_object(
      'id', t.id,
      'numero', t.numero,
      'codigo', 'WF-' || lpad(t.numero::text, 4, '0'),
      'organizacao_id', t.organizacao_id,
      'organizacao', o.nome,
      'titulo', t.titulo,
      'descricao', t.descricao,
      'status', t.status,
      'prioridade', t.prioridade,
      'prazo', t.prazo,
      'modulo', t.modulo,
      'categoria', t.categoria,
      'confidencial', t.confidencial,
      'origem_rotulo', t.origem_rotulo,
      'criado_por', t.criado_por,
      'criado_por_nome', c.nome,
      'criado_em', t.criado_em,
      'atualizado_em', t.atualizado_em,
      'concluida_em', t.concluida_em,
      'participantes', coalesce((
        select jsonb_agg(jsonb_build_object('user_id', p.user_id, 'nome', u.nome, 'papel', p.papel)
                         order by p.papel desc, u.nome)
        from public.workflow_participantes p
        join public.usuarios u on u.user_id = p.user_id
        where p.tarefa_id = t.id), '[]'::jsonb),
      'comentarios', (select count(*) from public.workflow_comentarios k where k.tarefa_id = t.id),
      'nao_lida', coalesce(t.atualizado_por <> (select auth.uid()), false)
                  and coalesce(l.lido_em < t.atualizado_em, true),
      'pode_excluir', coalesce(
        t.criado_por = (select auth.uid())
        or public.meu_perfil() = 'master'
        or (public.meu_perfil() = 'corp_master' and t.organizacao_id = public.minha_org()), false)
    ) as x
    from public.workflow_tarefas t
    left join public.organizacoes o on o.id = t.organizacao_id
    left join public.usuarios c on c.user_id = t.criado_por
    left join public.workflow_leituras l on l.tarefa_id = t.id and l.user_id = (select auth.uid())
    where public.workflow_pode_ver(t.id)
  ) s;
$$;

-- Comentários de uma tarefa
create or replace function public.workflow_detalhe(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.workflow_pode_ver(p_id) then
    raise exception 'Tarefa não encontrada';
  end if;
  return jsonb_build_object(
    'id', p_id,
    'comentarios', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', k.id, 'nome', coalesce(u.nome, 'Usuário removido'), 'texto', k.texto, 'criado_em', k.criado_em)
        order by k.criado_em)
      from public.workflow_comentarios k
      left join public.usuarios u on u.user_id = k.user_id
      where k.tarefa_id = p_id), '[]'::jsonb)
  );
end;
$$;

-- Marca a tarefa como lida pelo usuário atual
create or replace function public.workflow_marcar_lida(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.workflow_pode_ver(p_id) then
    raise exception 'Tarefa não encontrada';
  end if;
  insert into public.workflow_leituras (tarefa_id, user_id, lido_em)
  values (p_id, (select auth.uid()), now())
  on conflict (tarefa_id, user_id) do update set lido_em = excluded.lido_em;
end;
$$;

-- Cria (p_id nulo) ou altera uma tarefa e seus participantes
drop function if exists public.workflow_salvar(uuid, text, text, uuid, text, date, text, uuid[], uuid[], text, text);
create or replace function public.workflow_salvar(
  p_id uuid, p_titulo text, p_descricao text, p_org uuid, p_status text, p_prazo date,
  p_prioridade text, p_modulo text, p_categoria text, p_confidencial boolean,
  p_responsaveis uuid[], p_envolvidos uuid[], p_origem_rotulo text default ''
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid  uuid := (select auth.uid());
  v_id   uuid;
  v_org  uuid;
  v_resp uuid[];
  v_env  uuid[];
  v_u    uuid;
begin
  if char_length(trim(coalesce(p_titulo, ''))) = 0 then
    raise exception 'Informe o título da tarefa';
  end if;
  if coalesce(p_status, '') not in ('a_fazer','em_andamento','em_revisao','concluida') then
    raise exception 'Situação inválida';
  end if;
  if coalesce(p_prioridade, '') not in ('baixa','media','alta','urgente') then
    raise exception 'Prioridade inválida';
  end if;

  if p_id is null then
    if not public.workflow_escopo_ok(p_org) then
      raise exception 'Você não pode criar tarefas para esta organização';
    end if;
    if p_org is not null and not exists (select 1 from public.organizacoes where id = p_org and ativo) then
      raise exception 'Organização não encontrada ou inativa';
    end if;
    v_org := p_org;
    insert into public.workflow_tarefas (
      organizacao_id, titulo, descricao, status, prioridade, prazo, modulo, categoria,
      confidencial, origem_rotulo, criado_por, atualizado_por, concluida_em)
    values (
      v_org, left(trim(p_titulo), 500), coalesce(p_descricao, ''), p_status, p_prioridade, p_prazo,
      left(coalesce(p_modulo, ''), 60), left(trim(coalesce(p_categoria, '')), 80),
      coalesce(p_confidencial, false), left(coalesce(p_origem_rotulo, ''), 160), v_uid, v_uid,
      case when p_status = 'concluida' then now() end)
    returning id into v_id;
  else
    if not public.workflow_pode_ver(p_id) then
      raise exception 'Tarefa não encontrada';
    end if;
    v_id := p_id;
    select organizacao_id into v_org from public.workflow_tarefas where id = p_id;
    update public.workflow_tarefas
       set titulo = left(trim(p_titulo), 500),
           descricao = coalesce(p_descricao, ''),
           status = p_status,
           prioridade = p_prioridade,
           prazo = p_prazo,
           modulo = left(coalesce(p_modulo, ''), 60),
           categoria = left(trim(coalesce(p_categoria, '')), 80),
           confidencial = coalesce(p_confidencial, false),
           atualizado_em = now(),
           atualizado_por = v_uid,
           concluida_em = case when p_status = 'concluida' then coalesce(concluida_em, now()) end
     where id = p_id;
  end if;

  select coalesce(array_agg(distinct x), '{}'::uuid[]) into v_resp
    from unnest(coalesce(p_responsaveis, '{}'::uuid[])) x where x is not null;
  if p_id is null and coalesce(array_length(v_resp, 1), 0) = 0 then
    v_resp := array[v_uid];
  end if;
  select coalesce(array_agg(distinct x), '{}'::uuid[]) into v_env
    from unnest(coalesce(p_envolvidos, '{}'::uuid[])) x where x is not null and x <> all(v_resp);

  foreach v_u in array (v_resp || v_env) loop
    if not exists (select 1 from public.workflow_participantes where tarefa_id = v_id and user_id = v_u)
       and not public.workflow_pessoa_ok(v_u, v_org) then
      raise exception 'Uma das pessoas marcadas não pode participar desta tarefa';
    end if;
  end loop;

  delete from public.workflow_participantes
   where tarefa_id = v_id and user_id <> all(v_resp || v_env);
  insert into public.workflow_participantes (tarefa_id, user_id, papel)
    select v_id, x, 'responsavel' from unnest(v_resp) x
    union all
    select v_id, x, 'envolvido' from unnest(v_env) x
  on conflict (tarefa_id, user_id) do update set papel = excluded.papel
    where public.workflow_participantes.papel <> excluded.papel;

  insert into public.workflow_leituras (tarefa_id, user_id, lido_em)
  values (v_id, v_uid, now())
  on conflict (tarefa_id, user_id) do update set lido_em = excluded.lido_em;

  return v_id;
end;
$$;

-- Move a tarefa de situação
create or replace function public.workflow_mover(p_id uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(p_status, '') not in ('a_fazer','em_andamento','em_revisao','concluida') then
    raise exception 'Situação inválida';
  end if;
  if not public.workflow_pode_ver(p_id) then
    raise exception 'Tarefa não encontrada';
  end if;
  update public.workflow_tarefas
     set status = p_status,
         atualizado_em = now(),
         atualizado_por = (select auth.uid()),
         concluida_em = case when p_status = 'concluida' then now() end
   where id = p_id and status <> p_status;
end;
$$;

-- Acrescenta um comentário
create or replace function public.workflow_comentar(p_id uuid, p_texto text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.workflow_pode_ver(p_id) then
    raise exception 'Tarefa não encontrada';
  end if;
  if char_length(trim(coalesce(p_texto, ''))) = 0 then
    raise exception 'Escreva o comentário';
  end if;
  insert into public.workflow_comentarios (tarefa_id, user_id, texto)
  values (p_id, (select auth.uid()), left(trim(p_texto), 2000));
  update public.workflow_tarefas
     set atualizado_em = now(), atualizado_por = (select auth.uid())
   where id = p_id;
  insert into public.workflow_leituras (tarefa_id, user_id, lido_em)
  values (p_id, (select auth.uid()), now())
  on conflict (tarefa_id, user_id) do update set lido_em = excluded.lido_em;
end;
$$;

-- Exclui uma tarefa: quem criou, o Master ou o Corporativo master da organização
create or replace function public.workflow_excluir(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_t public.workflow_tarefas%rowtype;
begin
  if not public.workflow_pode_ver(p_id) then
    raise exception 'Tarefa não encontrada';
  end if;
  select * into v_t from public.workflow_tarefas where id = p_id;
  if not coalesce(
       v_t.criado_por = (select auth.uid())
       or public.meu_perfil() = 'master'
       or (public.meu_perfil() = 'corp_master' and v_t.organizacao_id = public.minha_org()), false) then
    raise exception 'Só quem criou a tarefa, o Master ou o responsável da organização pode excluir';
  end if;
  delete from public.workflow_tarefas where id = p_id;
end;
$$;

drop trigger if exists auditar_workflow_tarefas on public.workflow_tarefas;
create trigger auditar_workflow_tarefas
  after insert or update or delete on public.workflow_tarefas
  for each row execute function public.auditar('Workflow');

drop trigger if exists auditar_workflow_participantes on public.workflow_participantes;
create trigger auditar_workflow_participantes
  after insert or update or delete on public.workflow_participantes
  for each row execute function public.auditar('Workflow');

drop trigger if exists auditar_workflow_comentarios on public.workflow_comentarios;
create trigger auditar_workflow_comentarios
  after insert or update or delete on public.workflow_comentarios
  for each row execute function public.auditar('Workflow');

revoke all on public.workflow_tarefas, public.workflow_participantes,
              public.workflow_comentarios, public.workflow_leituras
  from anon, authenticated;
grant select on public.workflow_tarefas, public.workflow_participantes,
                public.workflow_comentarios, public.workflow_leituras
  to authenticated;

revoke all on function public.workflow_pessoa_ok(uuid, uuid) from public, anon, authenticated;
revoke all on function public.workflow_escopo_ok(uuid)       from public, anon;
revoke all on function public.workflow_pode_ver(uuid)        from public, anon;
revoke all on function public.workflow_pessoas(uuid)         from public, anon;
revoke all on function public.workflow_listar()              from public, anon;
revoke all on function public.workflow_detalhe(uuid)         from public, anon;
revoke all on function public.workflow_marcar_lida(uuid)     from public, anon;
revoke all on function public.workflow_salvar(uuid, text, text, uuid, text, date, text, text, text, boolean, uuid[], uuid[], text) from public, anon;
revoke all on function public.workflow_mover(uuid, text)     from public, anon;
revoke all on function public.workflow_comentar(uuid, text)  from public, anon;
revoke all on function public.workflow_excluir(uuid)         from public, anon;

grant execute on function public.workflow_escopo_ok(uuid)      to authenticated;
grant execute on function public.workflow_pode_ver(uuid)       to authenticated;
grant execute on function public.workflow_pessoas(uuid)        to authenticated;
grant execute on function public.workflow_listar()             to authenticated;
grant execute on function public.workflow_detalhe(uuid)        to authenticated;
grant execute on function public.workflow_marcar_lida(uuid)    to authenticated;
grant execute on function public.workflow_salvar(uuid, text, text, uuid, text, date, text, text, text, boolean, uuid[], uuid[], text) to authenticated;
grant execute on function public.workflow_mover(uuid, text)    to authenticated;
grant execute on function public.workflow_comentar(uuid, text) to authenticated;
grant execute on function public.workflow_excluir(uuid)        to authenticated;

drop policy if exists "workflow_tarefas leitura" on public.workflow_tarefas;
create policy "workflow_tarefas leitura" on public.workflow_tarefas
  for select to authenticated
  using (public.workflow_pode_ver(id));

drop policy if exists "workflow_participantes leitura" on public.workflow_participantes;
create policy "workflow_participantes leitura" on public.workflow_participantes
  for select to authenticated
  using (public.workflow_pode_ver(tarefa_id));

drop policy if exists "workflow_comentarios leitura" on public.workflow_comentarios;
create policy "workflow_comentarios leitura" on public.workflow_comentarios
  for select to authenticated
  using (public.workflow_pode_ver(tarefa_id));

drop policy if exists "workflow_leituras leitura" on public.workflow_leituras;
create policy "workflow_leituras leitura" on public.workflow_leituras
  for select to authenticated
  using (user_id = (select auth.uid()) and public.workflow_pode_ver(tarefa_id));

-- =====================================================================
-- 9) CADASTRO: PESSOAS FÍSICAS
--    Cadastro da Celeiro: organizacao_id nulo. Cadastro de um cliente corporativo: organizacao_id dele.
--    Quem vê e altera: quem tem o módulo Cadastro; equipe Celeiro vê todos, cliente vê os da própria organização.
--    Não há exclusão: o cadastro é inativado. Toda gravação passa pelas funções abaixo.
-- =====================================================================

-- Confere os dígitos verificadores do CPF
create or replace function public.cpf_valido(p_cpf text)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  d text := regexp_replace(coalesce(p_cpf, ''), '[^0-9]', '', 'g');
  s int;
  r int;
  i int;
begin
  if char_length(d) <> 11 or d ~ '^(.)\1{10}$' then
    return false;
  end if;
  s := 0;
  for i in 1..9 loop s := s + substr(d, i, 1)::int * (11 - i); end loop;
  r := (s * 10) % 11;
  if r = 10 then r := 0; end if;
  if r <> substr(d, 10, 1)::int then
    return false;
  end if;
  s := 0;
  for i in 1..10 loop s := s + substr(d, i, 1)::int * (12 - i); end loop;
  r := (s * 10) % 11;
  if r = 10 then r := 0; end if;
  return r = substr(d, 11, 1)::int;
end;
$$;

create table if not exists public.cadastro_pf (
  id                 uuid primary key default gen_random_uuid(),
  organizacao_id     uuid references public.organizacoes(id) on delete cascade,
  situacao           text not null default 'ativo' check (situacao in ('ativo','inativo')),
  -- dados pessoais
  nome_completo      text not null check (char_length(nome_completo) between 1 and 160),
  nome_social        text not null default '' check (char_length(nome_social) <= 160),
  cpf                text not null check (cpf ~ '^[0-9]{11}$'),
  nascimento         date,
  sexo               text not null default '' check (sexo in ('','masculino','feminino','outro','nao_informado')),
  nome_mae           text not null default '' check (char_length(nome_mae) <= 160),
  naturalidade       text not null default '' check (char_length(naturalidade) <= 120),
  nacionalidade      text not null default '' check (char_length(nacionalidade) <= 60),
  estado_civil       text not null default ''
                     check (estado_civil in ('','solteiro','casado','uniao_estavel','separado','divorciado','viuvo')),
  -- contatos
  telefone_celular   text not null default '' check (telefone_celular ~ '^[0-9]{0,13}$'),
  celular_verificado boolean not null default false,
  telefone_fixo      text not null default '' check (telefone_fixo ~ '^[0-9]{0,13}$'),
  email              text not null default '' check (char_length(email) <= 254),
  email_verificado   boolean not null default false,
  -- endereço
  cep                text not null default '' check (cep ~ '^([0-9]{8})?$'),
  logradouro         text not null default '' check (char_length(logradouro) <= 160),
  numero             text not null default '' check (char_length(numero) <= 20),
  complemento        text not null default '' check (char_length(complemento) <= 80),
  bairro             text not null default '' check (char_length(bairro) <= 100),
  cidade             text not null default '' check (char_length(cidade) <= 100),
  uf                 text not null default '' check (uf in ('','AC','AL','AP','AM','BA','CE','DF','ES','GO','MA','MT','MS','MG','PA','PB','PR','PE','PI','RJ','RN','RS','RO','RR','SC','SP','SE','TO')),
  -- profissional e financeiro
  profissao          text not null default '' check (char_length(profissao) <= 100),
  fonte_renda        text not null default ''
                     check (fonte_renda in ('','assalariado','empresario','autonomo','profissional_liberal','servidor_publico','aposentado','rendimentos','outros')),
  renda_mensal       numeric(14,2) check (renda_mensal is null or renda_mensal >= 0),
  mei                boolean not null default false,
  isento_ir          boolean not null default false,
  pep                boolean not null default false,
  fatca              boolean not null default false,
  crs                boolean not null default false,
  observacoes        text not null default '' check (char_length(observacoes) <= 2000),
  -- controle
  criado_por         uuid references public.usuarios(user_id) on delete set null,
  criado_em          timestamptz not null default now(),
  atualizado_por     uuid references public.usuarios(user_id) on delete set null,
  atualizado_em      timestamptz not null default now()
);

create unique index if not exists cadastro_pf_cpf_unico
  on public.cadastro_pf (coalesce(organizacao_id, '00000000-0000-0000-0000-000000000000'::uuid), cpf);
create index if not exists cadastro_pf_nome on public.cadastro_pf (nome_completo);

alter table public.cadastro_pf enable row level security;

-- O usuário atual pode ver e alterar cadastros desta organização (nulo = Celeiro)?
create or replace function public.cadastro_escopo_ok(p_org uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.pode_modulo('cadastro')
     and coalesce(public.eh_equipe() or p_org = public.minha_org(), false);
$$;

-- Texto de um campo do formulário: sem espaços nas pontas e limitado ao tamanho
create or replace function public.campo_texto(p_dados jsonb, p_chave text, p_max int)
returns text
language sql
immutable
set search_path = ''
as $$
  select left(trim(coalesce(p_dados ->> p_chave, '')), p_max);
$$;

-- Cria (p_id nulo) ou altera um cadastro de pessoa física. p_dados traz os campos do formulário.
create or replace function public.cadastro_pf_salvar(p_id uuid, p_org uuid, p_dados jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_org   uuid;
  v_id    uuid;
  v_cpf   text := regexp_replace(coalesce(p_dados ->> 'cpf', ''), '[^0-9]', '', 'g');
  v_nome  text := public.campo_texto(p_dados, 'nome_completo', 160);
  v_email text := lower(public.campo_texto(p_dados, 'email', 254));
  v_cep   text := regexp_replace(coalesce(p_dados ->> 'cep', ''), '[^0-9]', '', 'g');
  v_cel   text := regexp_replace(coalesce(p_dados ->> 'telefone_celular', ''), '[^0-9]', '', 'g');
  v_fixo  text := regexp_replace(coalesce(p_dados ->> 'telefone_fixo', ''), '[^0-9]', '', 'g');
  v_uf    text := upper(public.campo_texto(p_dados, 'uf', 2));
  v_sexo  text := public.campo_texto(p_dados, 'sexo', 20);
  v_civil text := public.campo_texto(p_dados, 'estado_civil', 20);
  v_fonte text := public.campo_texto(p_dados, 'fonte_renda', 30);
  v_nasc  date;
  v_renda numeric(14,2);
begin
  if p_id is null then
    if not public.cadastro_escopo_ok(p_org) then
      raise exception 'Você não pode criar cadastros para esta organização';
    end if;
    if p_org is not null and not exists (select 1 from public.organizacoes where id = p_org and ativo) then
      raise exception 'Organização não encontrada ou inativa';
    end if;
    v_org := p_org;
  else
    select organizacao_id into v_org from public.cadastro_pf where id = p_id;
    if not found or not public.cadastro_escopo_ok(v_org) then
      raise exception 'Cadastro não encontrado';
    end if;
  end if;

  if v_nome = '' then
    raise exception 'Informe o nome completo';
  end if;
  if not public.cpf_valido(v_cpf) then
    raise exception 'CPF inválido. Confira os números.';
  end if;
  if exists (
    select 1 from public.cadastro_pf c
    where c.cpf = v_cpf and c.organizacao_id is not distinct from v_org and c.id is distinct from p_id
  ) then
    raise exception 'Já existe um cadastro com este CPF';
  end if;

  if coalesce(p_dados ->> 'nascimento', '') <> '' then
    begin
      v_nasc := (p_dados ->> 'nascimento')::date;
    exception when others then
      raise exception 'Data de nascimento inválida';
    end;
    if v_nasc > current_date or v_nasc < date '1900-01-01' then
      raise exception 'Data de nascimento inválida';
    end if;
  end if;
  if coalesce(p_dados ->> 'renda_mensal', '') <> '' then
    begin
      v_renda := round((p_dados ->> 'renda_mensal')::numeric, 2);
    exception when others then
      raise exception 'Renda mensal inválida';
    end;
    if v_renda < 0 or v_renda > 999999999999 then
      raise exception 'Renda mensal inválida';
    end if;
  end if;
  if v_email <> '' and v_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then
    raise exception 'E-mail inválido';
  end if;
  if v_cep <> '' and char_length(v_cep) <> 8 then
    raise exception 'CEP inválido: são 8 números';
  end if;
  if (v_cel <> '' and char_length(v_cel) not between 10 and 13)
     or (v_fixo <> '' and char_length(v_fixo) not between 10 and 13) then
    raise exception 'Telefone inválido: informe DDD e número';
  end if;
  if v_uf not in ('','AC','AL','AP','AM','BA','CE','DF','ES','GO','MA','MT','MS','MG','PA','PB','PR','PE','PI','RJ','RN','RS','RO','RR','SC','SP','SE','TO') then
    raise exception 'UF inválida';
  end if;
  if v_sexo not in ('','masculino','feminino','outro','nao_informado') then
    raise exception 'Sexo inválido';
  end if;
  if v_civil not in ('','solteiro','casado','uniao_estavel','separado','divorciado','viuvo') then
    raise exception 'Estado civil inválido';
  end if;
  if v_fonte not in ('','assalariado','empresario','autonomo','profissional_liberal','servidor_publico','aposentado','rendimentos','outros') then
    raise exception 'Fonte de renda inválida';
  end if;

  if p_id is null then
    insert into public.cadastro_pf (organizacao_id, nome_completo, cpf, criado_por, atualizado_por)
    values (v_org, v_nome, v_cpf, v_uid, v_uid)
    returning id into v_id;
  else
    v_id := p_id;
  end if;

  update public.cadastro_pf set
    nome_completo      = v_nome,
    nome_social        = public.campo_texto(p_dados, 'nome_social', 160),
    cpf                = v_cpf,
    nascimento         = v_nasc,
    sexo               = v_sexo,
    nome_mae           = public.campo_texto(p_dados, 'nome_mae', 160),
    naturalidade       = public.campo_texto(p_dados, 'naturalidade', 120),
    nacionalidade      = public.campo_texto(p_dados, 'nacionalidade', 60),
    estado_civil       = v_civil,
    telefone_celular   = v_cel,
    celular_verificado = v_cel <> '' and coalesce(p_dados ->> 'celular_verificado', '') = 'true',
    telefone_fixo      = v_fixo,
    email              = v_email,
    email_verificado   = v_email <> '' and coalesce(p_dados ->> 'email_verificado', '') = 'true',
    cep                = v_cep,
    logradouro         = public.campo_texto(p_dados, 'logradouro', 160),
    numero             = public.campo_texto(p_dados, 'numero', 20),
    complemento        = public.campo_texto(p_dados, 'complemento', 80),
    bairro             = public.campo_texto(p_dados, 'bairro', 100),
    cidade             = public.campo_texto(p_dados, 'cidade', 100),
    uf                 = v_uf,
    profissao          = public.campo_texto(p_dados, 'profissao', 100),
    fonte_renda        = v_fonte,
    renda_mensal       = v_renda,
    mei                = coalesce(p_dados ->> 'mei', '') = 'true',
    isento_ir          = coalesce(p_dados ->> 'isento_ir', '') = 'true',
    pep                = coalesce(p_dados ->> 'pep', '') = 'true',
    fatca              = coalesce(p_dados ->> 'fatca', '') = 'true',
    crs                = coalesce(p_dados ->> 'crs', '') = 'true',
    observacoes        = public.campo_texto(p_dados, 'observacoes', 2000),
    atualizado_por     = v_uid,
    atualizado_em      = now()
  where id = v_id;

  return v_id;
end;
$$;

-- Ativa ou inativa um cadastro
create or replace function public.cadastro_pf_situacao(p_id uuid, p_situacao text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org uuid;
begin
  if coalesce(p_situacao, '') not in ('ativo','inativo') then
    raise exception 'Situação inválida';
  end if;
  select organizacao_id into v_org from public.cadastro_pf where id = p_id;
  if not found or not public.cadastro_escopo_ok(v_org) then
    raise exception 'Cadastro não encontrado';
  end if;
  update public.cadastro_pf
     set situacao = p_situacao, atualizado_por = (select auth.uid()), atualizado_em = now()
   where id = p_id and situacao <> p_situacao;
end;
$$;

drop trigger if exists auditar_cadastro_pf on public.cadastro_pf;
create trigger auditar_cadastro_pf
  after insert or update or delete on public.cadastro_pf
  for each row execute function public.auditar('Cadastro');

revoke all on public.cadastro_pf from anon, authenticated;
grant select on public.cadastro_pf to authenticated;

revoke all on function public.cpf_valido(text)                        from public, anon;
revoke all on function public.campo_texto(jsonb, text, int)           from public, anon;
revoke all on function public.cadastro_escopo_ok(uuid)                from public, anon;
revoke all on function public.cadastro_pf_salvar(uuid, uuid, jsonb)   from public, anon;
revoke all on function public.cadastro_pf_situacao(uuid, text)        from public, anon;

grant execute on function public.cpf_valido(text)                      to authenticated;
grant execute on function public.campo_texto(jsonb, text, int)         to authenticated;
grant execute on function public.cadastro_escopo_ok(uuid)              to authenticated;
grant execute on function public.cadastro_pf_salvar(uuid, uuid, jsonb) to authenticated;
grant execute on function public.cadastro_pf_situacao(uuid, text)      to authenticated;

drop policy if exists "cadastro_pf leitura" on public.cadastro_pf;
create policy "cadastro_pf leitura" on public.cadastro_pf
  for select to authenticated
  using ((select public.pode_modulo('cadastro'))
         and ((select public.eh_equipe()) or organizacao_id = (select public.minha_org())));

-- =====================================================================
-- 10) CADASTRO: PESSOAS JURÍDICAS
--     Empresa, quadro de sócios e administradores (QSA) e representante.
--     O representante é um cadastro de pessoa física (cadastro_pf) ligado à empresa.
--     Mesmas regras de acesso do cadastro de pessoas físicas.
-- =====================================================================

-- Confere os dígitos verificadores do CNPJ
create or replace function public.cnpj_valido(p_cnpj text)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  d  text := regexp_replace(coalesce(p_cnpj, ''), '[^0-9]', '', 'g');
  p1 int[] := array[5,4,3,2,9,8,7,6,5,4,3,2];
  p2 int[] := array[6,5,4,3,2,9,8,7,6,5,4,3,2];
  s  int;
  r  int;
  i  int;
begin
  if char_length(d) <> 14 or d ~ '^(.)\1{13}$' then
    return false;
  end if;
  s := 0;
  for i in 1..12 loop s := s + substr(d, i, 1)::int * p1[i]; end loop;
  r := s % 11;
  r := case when r < 2 then 0 else 11 - r end;
  if r <> substr(d, 13, 1)::int then
    return false;
  end if;
  s := 0;
  for i in 1..13 loop s := s + substr(d, i, 1)::int * p2[i]; end loop;
  r := s % 11;
  r := case when r < 2 then 0 else 11 - r end;
  return r = substr(d, 14, 1)::int;
end;
$$;

create table if not exists public.cadastro_pj (
  id                   uuid primary key default gen_random_uuid(),
  organizacao_id       uuid references public.organizacoes(id) on delete cascade,
  situacao             text not null default 'ativo' check (situacao in ('ativo','inativo')),
  -- dados da empresa
  razao_social         text not null check (char_length(razao_social) between 1 and 200),
  nome_fantasia        text not null default '' check (char_length(nome_fantasia) <= 200),
  cnpj                 text not null check (cnpj ~ '^[0-9]{14}$'),
  situacao_cadastral   text not null default '' check (char_length(situacao_cadastral) <= 60),
  enriquecimento       text not null default 'nao_feito' check (enriquecimento in ('nao_feito','concluido')),
  enriquecido_em       timestamptz,
  -- contatos
  email                text not null default '' check (char_length(email) <= 254),
  telefone_fixo        text not null default '' check (telefone_fixo ~ '^[0-9]{0,13}$'),
  telefone_celular     text not null default '' check (telefone_celular ~ '^[0-9]{0,13}$'),
  -- endereço
  cep                  text not null default '' check (cep ~ '^([0-9]{8})?$'),
  logradouro           text not null default '' check (char_length(logradouro) <= 160),
  numero               text not null default '' check (char_length(numero) <= 20),
  complemento          text not null default '' check (char_length(complemento) <= 80),
  bairro               text not null default '' check (char_length(bairro) <= 100),
  cidade               text not null default '' check (char_length(cidade) <= 100),
  uf                   text not null default '' check (uf in ('','AC','AL','AP','AM','BA','CE','DF','ES','GO','MA','MT','MS','MG','PA','PB','PR','PE','PI','RJ','RN','RS','RO','RR','SC','SP','SE','TO')),
  -- responsável financeiro
  financeiro_nome      text not null default '' check (char_length(financeiro_nome) <= 160),
  financeiro_email     text not null default '' check (char_length(financeiro_email) <= 254),
  financeiro_telefone  text not null default '' check (financeiro_telefone ~ '^[0-9]{0,13}$'),
  -- representante (responsável legal): um cadastro de pessoa física
  representante_pf_id  uuid references public.cadastro_pf(id) on delete set null,
  observacoes          text not null default '' check (char_length(observacoes) <= 2000),
  -- controle
  criado_por           uuid references public.usuarios(user_id) on delete set null,
  criado_em            timestamptz not null default now(),
  atualizado_por       uuid references public.usuarios(user_id) on delete set null,
  atualizado_em        timestamptz not null default now()
);

create unique index if not exists cadastro_pj_cnpj_unico
  on public.cadastro_pj (coalesce(organizacao_id, '00000000-0000-0000-0000-000000000000'::uuid), cnpj);
create index if not exists cadastro_pj_razao on public.cadastro_pj (razao_social);

-- Quadro de sócios e administradores
create table if not exists public.cadastro_pj_socios (
  id           uuid primary key default gen_random_uuid(),
  pj_id        uuid not null references public.cadastro_pj(id) on delete cascade,
  nome         text not null check (char_length(nome) between 1 and 160),
  documento    text not null default '' check (char_length(documento) <= 20),
  qualificacao text not null default '' check (char_length(qualificacao) <= 100),
  selecionado  boolean not null default false,
  ordem        int not null default 0
);
create index if not exists cadastro_pj_socios_pj on public.cadastro_pj_socios (pj_id);
create unique index if not exists cadastro_pj_socios_um_selecionado
  on public.cadastro_pj_socios (pj_id) where selecionado;

alter table public.cadastro_pj        enable row level security;
alter table public.cadastro_pj_socios enable row level security;

-- O usuário atual pode ver e alterar esta empresa?
create or replace function public.cadastro_pj_pode(p_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.cadastro_pj j
    where j.id = p_id and public.cadastro_escopo_ok(j.organizacao_id)
  );
$$;

-- Cria (p_id nulo) ou altera uma empresa. p_dados traz os campos do formulário.
create or replace function public.cadastro_pj_salvar(p_id uuid, p_org uuid, p_dados jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_org   uuid;
  v_id    uuid;
  v_cnpj  text := regexp_replace(coalesce(p_dados ->> 'cnpj', ''), '[^0-9]', '', 'g');
  v_razao text := public.campo_texto(p_dados, 'razao_social', 200);
  v_email text := lower(public.campo_texto(p_dados, 'email', 254));
  v_fmail text := lower(public.campo_texto(p_dados, 'financeiro_email', 254));
  v_cep   text := regexp_replace(coalesce(p_dados ->> 'cep', ''), '[^0-9]', '', 'g');
  v_fixo  text := regexp_replace(coalesce(p_dados ->> 'telefone_fixo', ''), '[^0-9]', '', 'g');
  v_cel   text := regexp_replace(coalesce(p_dados ->> 'telefone_celular', ''), '[^0-9]', '', 'g');
  v_ftel  text := regexp_replace(coalesce(p_dados ->> 'financeiro_telefone', ''), '[^0-9]', '', 'g');
  v_uf    text := upper(public.campo_texto(p_dados, 'uf', 2));
  v_enr   boolean := coalesce(p_dados ->> 'enriquecido', '') = 'true';
begin
  if p_id is null then
    if not public.cadastro_escopo_ok(p_org) then
      raise exception 'Você não pode criar cadastros para esta organização';
    end if;
    if p_org is not null and not exists (select 1 from public.organizacoes where id = p_org and ativo) then
      raise exception 'Organização não encontrada ou inativa';
    end if;
    v_org := p_org;
  else
    select organizacao_id into v_org from public.cadastro_pj where id = p_id;
    if not found or not public.cadastro_escopo_ok(v_org) then
      raise exception 'Cadastro não encontrado';
    end if;
  end if;

  if v_razao = '' then
    raise exception 'Informe a razão social';
  end if;
  if not public.cnpj_valido(v_cnpj) then
    raise exception 'CNPJ inválido. Confira os números.';
  end if;
  if exists (
    select 1 from public.cadastro_pj c
    where c.cnpj = v_cnpj and c.organizacao_id is not distinct from v_org and c.id is distinct from p_id
  ) then
    raise exception 'Já existe um cadastro com este CNPJ';
  end if;
  if (v_email <> '' and v_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$')
     or (v_fmail <> '' and v_fmail !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$') then
    raise exception 'E-mail inválido';
  end if;
  if v_cep <> '' and char_length(v_cep) <> 8 then
    raise exception 'CEP inválido: são 8 números';
  end if;
  if (v_fixo <> '' and char_length(v_fixo) not between 10 and 13)
     or (v_cel <> '' and char_length(v_cel) not between 10 and 13)
     or (v_ftel <> '' and char_length(v_ftel) not between 10 and 13) then
    raise exception 'Telefone inválido: informe DDD e número';
  end if;
  if v_uf not in ('','AC','AL','AP','AM','BA','CE','DF','ES','GO','MA','MT','MS','MG','PA','PB','PR','PE','PI','RJ','RN','RS','RO','RR','SC','SP','SE','TO') then
    raise exception 'UF inválida';
  end if;

  if p_id is null then
    insert into public.cadastro_pj (organizacao_id, razao_social, cnpj, criado_por, atualizado_por)
    values (v_org, v_razao, v_cnpj, v_uid, v_uid)
    returning id into v_id;
  else
    v_id := p_id;
  end if;

  update public.cadastro_pj set
    razao_social        = v_razao,
    nome_fantasia       = public.campo_texto(p_dados, 'nome_fantasia', 200),
    cnpj                = v_cnpj,
    situacao_cadastral  = public.campo_texto(p_dados, 'situacao_cadastral', 60),
    enriquecimento      = case when v_enr then 'concluido' else enriquecimento end,
    enriquecido_em      = case when v_enr then now() else enriquecido_em end,
    email               = v_email,
    telefone_fixo       = v_fixo,
    telefone_celular    = v_cel,
    cep                 = v_cep,
    logradouro          = public.campo_texto(p_dados, 'logradouro', 160),
    numero              = public.campo_texto(p_dados, 'numero', 20),
    complemento         = public.campo_texto(p_dados, 'complemento', 80),
    bairro              = public.campo_texto(p_dados, 'bairro', 100),
    cidade              = public.campo_texto(p_dados, 'cidade', 100),
    uf                  = v_uf,
    financeiro_nome     = public.campo_texto(p_dados, 'financeiro_nome', 160),
    financeiro_email    = v_fmail,
    financeiro_telefone = v_ftel,
    observacoes         = public.campo_texto(p_dados, 'observacoes', 2000),
    atualizado_por      = v_uid,
    atualizado_em       = now()
  where id = v_id;

  return v_id;
end;
$$;

-- Ativa ou inativa uma empresa
create or replace function public.cadastro_pj_situacao(p_id uuid, p_situacao text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(p_situacao, '') not in ('ativo','inativo') then
    raise exception 'Situação inválida';
  end if;
  if not public.cadastro_pj_pode(p_id) then
    raise exception 'Cadastro não encontrado';
  end if;
  update public.cadastro_pj
     set situacao = p_situacao, atualizado_por = (select auth.uid()), atualizado_em = now()
   where id = p_id and situacao <> p_situacao;
end;
$$;

-- Substitui o quadro de sócios e administradores.
-- p_socios: lista de {nome, documento, qualificacao, selecionado}. No máximo um selecionado.
create or replace function public.cadastro_pj_socios_definir(p_pj uuid, p_socios jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_s   jsonb;
  v_i   int := 0;
  v_sel boolean := false;
  v_e   boolean;
begin
  if not public.cadastro_pj_pode(p_pj) then
    raise exception 'Cadastro não encontrado';
  end if;
  if p_socios is null or jsonb_typeof(p_socios) <> 'array' or jsonb_array_length(p_socios) > 100 then
    raise exception 'Lista de sócios inválida';
  end if;
  delete from public.cadastro_pj_socios where pj_id = p_pj;
  for v_s in select * from jsonb_array_elements(p_socios) loop
    if public.campo_texto(v_s, 'nome', 160) = '' then
      raise exception 'Informe o nome de cada sócio ou administrador';
    end if;
    v_e := coalesce(v_s ->> 'selecionado', '') = 'true' and not v_sel;
    v_sel := v_sel or v_e;
    v_i := v_i + 1;
    insert into public.cadastro_pj_socios (pj_id, nome, documento, qualificacao, selecionado, ordem)
    values (p_pj, public.campo_texto(v_s, 'nome', 160), public.campo_texto(v_s, 'documento', 20),
            public.campo_texto(v_s, 'qualificacao', 100), v_e, v_i);
  end loop;
  update public.cadastro_pj
     set atualizado_por = (select auth.uid()), atualizado_em = now()
   where id = p_pj;
end;
$$;

-- Escolhe quem do quadro é o representante da empresa
create or replace function public.cadastro_pj_selecionar_socio(p_pj uuid, p_socio uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.cadastro_pj_pode(p_pj) then
    raise exception 'Cadastro não encontrado';
  end if;
  if not exists (select 1 from public.cadastro_pj_socios where id = p_socio and pj_id = p_pj) then
    raise exception 'Sócio não encontrado neste cadastro';
  end if;
  update public.cadastro_pj_socios set selecionado = false where pj_id = p_pj and selecionado and id <> p_socio;
  update public.cadastro_pj_socios set selecionado = true  where id = p_socio and not selecionado;
end;
$$;

-- Grava os dados do representante (pessoa física) e liga à empresa.
-- Se já existir um cadastro de pessoa física com o mesmo CPF na mesma origem, ele é atualizado e usado.
create or replace function public.cadastro_pj_representante_salvar(p_pj uuid, p_dados jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org uuid;
  v_cpf text := regexp_replace(coalesce(p_dados ->> 'cpf', ''), '[^0-9]', '', 'g');
  v_pf  uuid;
begin
  if not public.cadastro_pj_pode(p_pj) then
    raise exception 'Cadastro não encontrado';
  end if;
  select organizacao_id into v_org from public.cadastro_pj where id = p_pj;
  select id into v_pf from public.cadastro_pf
   where cpf = v_cpf and organizacao_id is not distinct from v_org;
  v_pf := public.cadastro_pf_salvar(v_pf, v_org, p_dados);
  update public.cadastro_pj
     set representante_pf_id = v_pf, atualizado_por = (select auth.uid()), atualizado_em = now()
   where id = p_pj;
  return v_pf;
end;
$$;

drop trigger if exists auditar_cadastro_pj on public.cadastro_pj;
create trigger auditar_cadastro_pj
  after insert or update or delete on public.cadastro_pj
  for each row execute function public.auditar('Cadastro');

drop trigger if exists auditar_cadastro_pj_socios on public.cadastro_pj_socios;
create trigger auditar_cadastro_pj_socios
  after insert or update or delete on public.cadastro_pj_socios
  for each row execute function public.auditar('Cadastro');

revoke all on public.cadastro_pj, public.cadastro_pj_socios from anon, authenticated;
grant select on public.cadastro_pj, public.cadastro_pj_socios to authenticated;

revoke all on function public.cnpj_valido(text)                              from public, anon;
revoke all on function public.cadastro_pj_pode(uuid)                         from public, anon;
revoke all on function public.cadastro_pj_salvar(uuid, uuid, jsonb)          from public, anon;
revoke all on function public.cadastro_pj_situacao(uuid, text)               from public, anon;
revoke all on function public.cadastro_pj_socios_definir(uuid, jsonb)        from public, anon;
revoke all on function public.cadastro_pj_selecionar_socio(uuid, uuid)       from public, anon;
revoke all on function public.cadastro_pj_representante_salvar(uuid, jsonb)  from public, anon;

grant execute on function public.cnpj_valido(text)                             to authenticated;
grant execute on function public.cadastro_pj_pode(uuid)                        to authenticated;
grant execute on function public.cadastro_pj_salvar(uuid, uuid, jsonb)         to authenticated;
grant execute on function public.cadastro_pj_situacao(uuid, text)              to authenticated;
grant execute on function public.cadastro_pj_socios_definir(uuid, jsonb)       to authenticated;
grant execute on function public.cadastro_pj_selecionar_socio(uuid, uuid)      to authenticated;
grant execute on function public.cadastro_pj_representante_salvar(uuid, jsonb) to authenticated;

drop policy if exists "cadastro_pj leitura" on public.cadastro_pj;
create policy "cadastro_pj leitura" on public.cadastro_pj
  for select to authenticated
  using ((select public.pode_modulo('cadastro'))
         and ((select public.eh_equipe()) or organizacao_id = (select public.minha_org())));

drop policy if exists "cadastro_pj_socios leitura" on public.cadastro_pj_socios;
create policy "cadastro_pj_socios leitura" on public.cadastro_pj_socios
  for select to authenticated
  using (public.cadastro_pj_pode(pj_id));

-- =====================================================================
-- 11) CONEXÃO MCP
--    O backoffice expõe um servidor MCP próprio (função "mcp"), para que
--    assistentes de IA consultem e operem o sistema em nome de um usuário.
--    - Cada conexão pertence a um usuário e nunca vê mais do que ele vê na tela.
--    - Nada funciona até o Master liberar: por organização e módulo
--      (mcp_liberacoes) e por usuário (mcp_usuarios).
--    - Somente leitura por padrão; escrita exige liberação do Master no módulo
--      e a opção marcada na própria conexão.
--    - O token aparece uma única vez; o banco guarda só o resumo (SHA-256).
--    - Toda chamada entra na Auditoria com origem "mcp".
-- =====================================================================

-- Liberação por organização (nulo = equipe Celeiro) e módulo
create table if not exists public.mcp_liberacoes (
  id             uuid primary key default gen_random_uuid(),
  organizacao_id uuid references public.organizacoes(id) on delete cascade,
  modulo         text not null references public.modulos(codigo),
  leitura        boolean not null default false,
  escrita        boolean not null default false,
  atualizado_em  timestamptz not null default now(),
  constraint mcp_liberacoes_escrita_pede_leitura check (leitura or not escrita)
);
create unique index if not exists mcp_liberacoes_unica
  on public.mcp_liberacoes (coalesce(organizacao_id, '00000000-0000-0000-0000-000000000000'::uuid), modulo);

-- Liberação por usuário (o Master não precisa de linha aqui)
create table if not exists public.mcp_usuarios (
  user_id       uuid primary key references public.usuarios(user_id) on delete cascade,
  liberado      boolean not null default false,
  atualizado_em timestamptz not null default now()
);

-- Conexões (uma por assistente ligado). O token em si não é guardado.
create table if not exists public.mcp_conexoes (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null references public.usuarios(user_id) on delete cascade,
  nome           text not null check (char_length(nome) between 1 and 80),
  prefixo        text not null,
  token_hash     text not null unique,
  escrita        boolean not null default false,
  criado_em      timestamptz not null default now(),
  expira_em      timestamptz not null,
  ultimo_uso     timestamptz,
  chamadas       bigint not null default 0,
  janela_inicio  timestamptz,
  janela_chamadas int not null default 0,
  revogada_em    timestamptz,
  revogada_por   uuid
);
create index if not exists mcp_conexoes_user on public.mcp_conexoes (user_id);

-- Catálogo de ferramentas oferecidas pelo servidor MCP
create table if not exists public.mcp_ferramentas (
  nome       text primary key,
  modulo     text references public.modulos(codigo),
  escrita    boolean not null default false,
  titulo     text not null,
  descricao  text not null,
  parametros jsonb not null default '{"type":"object","properties":{}}'::jsonb,
  ordem      int not null default 0
);

insert into public.mcp_ferramentas (nome, modulo, escrita, titulo, descricao, parametros, ordem) values
  ('quem_sou_eu', null, false, 'Quem sou eu',
   'Mostra em nome de qual usuário do Celeiro Office esta conexão atua, o perfil, a organização e quais módulos estão liberados para leitura e para escrita. Use antes de qualquer outra ferramenta.',
   '{"type":"object","properties":{},"additionalProperties":false}', 1),
  ('dashboard_resumo', 'dashboard', false, 'Resumo do dashboard',
   'Resumo dos indicadores que o usuário enxerga: tarefas por situação, vencidas, urgentes, sob responsabilidade dele, e quantidade de cadastros.',
   '{"type":"object","properties":{},"additionalProperties":false}', 10),
  ('workflow_listar_tarefas', 'workflow', false, 'Listar tarefas',
   'Lista as tarefas do Workflow que o usuário pode ver, das mais recentes para as mais antigas.',
   '{"type":"object","properties":{"situacao":{"type":"string","enum":["abertas","a_fazer","em_andamento","em_revisao","concluida","todas"],"description":"Padrão: abertas (tudo que não foi concluído)."},"texto":{"type":"string","description":"Trecho do título ou da descrição."},"somente_minhas":{"type":"boolean","description":"Só as tarefas em que o usuário é responsável."},"limite":{"type":"integer","minimum":1,"maximum":100,"description":"Padrão: 30."}},"additionalProperties":false}', 20),
  ('workflow_ver_tarefa', 'workflow', false, 'Ver tarefa',
   'Mostra uma tarefa completa, com descrição, participantes e comentários.',
   '{"type":"object","properties":{"codigo":{"type":"string","description":"Código da tarefa, por exemplo WF-0012."}},"required":["codigo"],"additionalProperties":false}', 21),
  ('workflow_criar_tarefa', 'workflow', true, 'Criar tarefa',
   'Cria uma tarefa no Workflow, com o usuário desta conexão como responsável. Confirme título e prazo com a pessoa antes de criar.',
   '{"type":"object","properties":{"titulo":{"type":"string","maxLength":500},"descricao":{"type":"string","maxLength":4000},"prazo":{"type":"string","description":"Data no formato AAAA-MM-DD."},"prioridade":{"type":"string","enum":["baixa","media","alta","urgente"],"description":"Padrão: media."}},"required":["titulo"],"additionalProperties":false}', 22),
  ('workflow_mover_tarefa', 'workflow', true, 'Mover tarefa',
   'Muda a situação de uma tarefa (coluna do quadro).',
   '{"type":"object","properties":{"codigo":{"type":"string","description":"Código da tarefa, por exemplo WF-0012."},"situacao":{"type":"string","enum":["a_fazer","em_andamento","em_revisao","concluida"]}},"required":["codigo","situacao"],"additionalProperties":false}', 23),
  ('workflow_comentar', 'workflow', true, 'Comentar tarefa',
   'Acrescenta um comentário a uma tarefa, em nome do usuário desta conexão.',
   '{"type":"object","properties":{"codigo":{"type":"string","description":"Código da tarefa, por exemplo WF-0012."},"texto":{"type":"string","maxLength":2000}},"required":["codigo","texto"],"additionalProperties":false}', 24),
  ('cadastro_buscar', 'cadastro', false, 'Buscar cadastros',
   'Procura pessoas físicas e empresas no Cadastro por nome ou por documento. A lista traz o documento mascarado; use as ferramentas de ver cadastro para os dados completos.',
   '{"type":"object","properties":{"texto":{"type":"string","description":"Parte do nome, da razão social ou os números do CPF/CNPJ."},"tipo":{"type":"string","enum":["todos","pf","pj"],"description":"Padrão: todos."},"situacao":{"type":"string","enum":["ativo","inativo","todas"],"description":"Padrão: ativo."},"limite":{"type":"integer","minimum":1,"maximum":50,"description":"Padrão: 20."}},"additionalProperties":false}', 30),
  ('cadastro_ver_pessoa_fisica', 'cadastro', false, 'Ver pessoa física',
   'Mostra o cadastro completo de uma pessoa física. Contém dados pessoais: use só o que a tarefa pedir.',
   '{"type":"object","properties":{"id":{"type":"string","description":"Identificador devolvido por cadastro_buscar."}},"required":["id"],"additionalProperties":false}', 31),
  ('cadastro_ver_empresa', 'cadastro', false, 'Ver empresa',
   'Mostra o cadastro completo de uma empresa, com quadro societário e representante.',
   '{"type":"object","properties":{"id":{"type":"string","description":"Identificador devolvido por cadastro_buscar."}},"required":["id"],"additionalProperties":false}', 32),
  ('auditoria_consultar', 'auditoria', false, 'Consultar auditoria',
   'Consulta o registro de auditoria que o usuário pode ver: quem fez o quê, quando, de qual IP e por qual origem (tela, banco ou mcp).',
   '{"type":"object","properties":{"dias":{"type":"integer","minimum":1,"maximum":90,"description":"Quantos dias para trás. Padrão: 7."},"texto":{"type":"string","description":"Trecho da ação ou do nome do usuário."},"origem":{"type":"string","enum":["tela","banco","mcp"]},"limite":{"type":"integer","minimum":1,"maximum":100,"description":"Padrão: 30."}},"additionalProperties":false}', 40)
on conflict (nome) do update
  set modulo = excluded.modulo, escrita = excluded.escrita, titulo = excluded.titulo,
      descricao = excluded.descricao, parametros = excluded.parametros, ordem = excluded.ordem;

alter table public.mcp_liberacoes  enable row level security;
alter table public.mcp_usuarios    enable row level security;
alter table public.mcp_conexoes    enable row level security;
alter table public.mcp_ferramentas enable row level security;

drop trigger if exists auditar_mcp_liberacoes on public.mcp_liberacoes;
create trigger auditar_mcp_liberacoes
  after insert or update or delete on public.mcp_liberacoes
  for each row execute function public.auditar('Conexão MCP');

drop trigger if exists auditar_mcp_usuarios on public.mcp_usuarios;
create trigger auditar_mcp_usuarios
  after insert or update or delete on public.mcp_usuarios
  for each row execute function public.auditar('Conexão MCP');

-- (mcp_conexoes não tem gatilho de auditoria: criar e revogar são registrados
--  pelas próprias operações, sem copiar o resumo do token para a auditoria,
--  e o "último uso" mudaria a cada chamada.)

-- O usuário pode usar o MCP? (ativo, com o módulo Conexão MCP e liberado pelo Master)
create or replace function public.mcp_usuario_liberado(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce('mcp' = any(public.modulos_efetivos(p_user)), false)
     and exists (
       select 1 from public.usuarios u
       where u.user_id = p_user
         and (u.perfil = 'master'
              or exists (select 1 from public.mcp_usuarios m where m.user_id = u.user_id and m.liberado))
     );
$$;

-- Módulos que o usuário alcança pelo MCP: os que ele tem na tela e que o Master
-- liberou para a organização dele (nulo = equipe Celeiro).
create or replace function public.mcp_modulos(p_user uuid)
returns table (modulo text, nome text, escrita boolean)
language sql
stable
security definer
set search_path = ''
as $$
  select m.codigo, m.nome, l.escrita
  from public.usuarios u
  join public.mcp_liberacoes l on l.organizacao_id is not distinct from u.organizacao_id and l.leitura
  join public.modulos m on m.codigo = l.modulo
  where u.user_id = p_user
    and public.mcp_usuario_liberado(p_user)
    and m.codigo = any(public.modulos_efetivos(p_user))
  order by m.ordem;
$$;

-- Ferramentas que uma conexão alcança
create or replace function public.mcp_ferramentas_de(p_user uuid, p_conexao_escrita boolean)
returns setof public.mcp_ferramentas
language sql
stable
security definer
set search_path = ''
as $$
  select f.*
  from public.mcp_ferramentas f
  where public.mcp_usuario_liberado(p_user)
    and (
      f.modulo is null
      or exists (
        select 1 from public.mcp_modulos(p_user) m
        where m.modulo = f.modulo
          and (not f.escrita or (m.escrita and coalesce(p_conexao_escrita, false)))
      )
    )
  order by f.ordem, f.nome;
$$;

-- Tudo o que a tela "Conexão MCP" precisa, em uma chamada
create or replace function public.mcp_painel()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_r   jsonb;
begin
  if not public.pode_modulo('mcp') then
    raise exception 'Módulo Conexão MCP não habilitado para você';
  end if;

  v_r := jsonb_build_object(
    'liberado', public.mcp_usuario_liberado(v_uid),
    'modulos', coalesce((
      select jsonb_agg(jsonb_build_object('modulo', m.modulo, 'nome', m.nome, 'escrita', m.escrita))
      from public.mcp_modulos(v_uid) m), '[]'::jsonb),
    'ferramentas', coalesce((
      select jsonb_agg(jsonb_build_object(
        'nome', f.nome, 'titulo', f.titulo, 'descricao', f.descricao, 'modulo', f.modulo,
        'modulo_nome', mo.nome, 'escrita', f.escrita,
        'disponivel', exists (select 1 from public.mcp_ferramentas_de(v_uid, true) d where d.nome = f.nome)
      ) order by f.ordem, f.nome)
      from public.mcp_ferramentas f
      left join public.modulos mo on mo.codigo = f.modulo), '[]'::jsonb),
    'conexoes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', c.id, 'nome', c.nome, 'prefixo', c.prefixo, 'escrita', c.escrita,
        'criado_em', c.criado_em, 'expira_em', c.expira_em, 'ultimo_uso', c.ultimo_uso,
        'chamadas', c.chamadas, 'revogada_em', c.revogada_em
      ) order by c.criado_em desc)
      from public.mcp_conexoes c where c.user_id = v_uid), '[]'::jsonb)
  );

  if public.eh_master() then
    v_r := v_r || jsonb_build_object(
      'organizacoes', coalesce((
        select jsonb_agg(jsonb_build_object('id', o.id, 'nome', o.nome) order by o.nome)
        from public.organizacoes o where o.ativo), '[]'::jsonb),
      'modulos_com_ferramentas', coalesce((
        select jsonb_agg(jsonb_build_object(
          'modulo', mo.codigo, 'nome', mo.nome,
          'tem_escrita', exists (select 1 from public.mcp_ferramentas f where f.modulo = mo.codigo and f.escrita)
        ) order by mo.ordem)
        from public.modulos mo
        where exists (select 1 from public.mcp_ferramentas f where f.modulo = mo.codigo)), '[]'::jsonb),
      'liberacoes', coalesce((
        select jsonb_agg(jsonb_build_object(
          'organizacao_id', l.organizacao_id, 'modulo', l.modulo, 'leitura', l.leitura, 'escrita', l.escrita))
        from public.mcp_liberacoes l), '[]'::jsonb),
      'usuarios', coalesce((
        select jsonb_agg(jsonb_build_object(
          'user_id', u.user_id, 'nome', u.nome, 'email', u.email, 'perfil', u.perfil,
          'organizacao', o.nome, 'ativo', u.ativo,
          'tem_modulo', 'mcp' = any(public.modulos_efetivos(u.user_id)),
          'liberado', u.perfil = 'master' or coalesce(mu.liberado, false)
        ) order by u.nome)
        from public.usuarios u
        left join public.organizacoes o on o.id = u.organizacao_id
        left join public.mcp_usuarios mu on mu.user_id = u.user_id), '[]'::jsonb),
      'todas_conexoes', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', c.id, 'nome', c.nome, 'prefixo', c.prefixo, 'escrita', c.escrita,
          'usuario', u.nome, 'organizacao', o.nome,
          'criado_em', c.criado_em, 'expira_em', c.expira_em, 'ultimo_uso', c.ultimo_uso,
          'chamadas', c.chamadas, 'revogada_em', c.revogada_em
        ) order by c.criado_em desc)
        from public.mcp_conexoes c
        join public.usuarios u on u.user_id = c.user_id
        left join public.organizacoes o on o.id = u.organizacao_id
        where c.user_id <> v_uid), '[]'::jsonb)
    );
  end if;
  return v_r;
end;
$$;

-- Cria uma conexão e devolve o token. É a única vez em que o token aparece.
create or replace function public.mcp_criar_conexao(p_nome text, p_dias int, p_escrita boolean)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_token text;
  v_id    uuid;
  v_nome  text := left(trim(coalesce(p_nome, '')), 80);
begin
  if not public.pode_modulo('mcp') then
    raise exception 'Módulo Conexão MCP não habilitado para você';
  end if;
  if not public.mcp_usuario_liberado(v_uid) then
    raise exception 'Seu usuário ainda não foi liberado pelo Master para usar o MCP';
  end if;
  if char_length(v_nome) = 0 then
    raise exception 'Dê um nome à conexão';
  end if;
  if p_dias is null or p_dias < 1 or p_dias > 365 then
    raise exception 'A validade precisa ficar entre 1 e 365 dias';
  end if;
  if (select count(*) from public.mcp_conexoes
      where user_id = v_uid and revogada_em is null and expira_em > now()) >= 5 then
    raise exception 'Limite de 5 conexões ativas por usuário. Revogue uma antes de criar outra';
  end if;

  v_token := 'clro_' || replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  insert into public.mcp_conexoes (user_id, nome, prefixo, token_hash, escrita, expira_em)
  values (v_uid, v_nome, left(v_token, 11),
          encode(sha256(convert_to(v_token, 'UTF8')), 'hex'),
          coalesce(p_escrita, false), now() + make_interval(days => p_dias))
  returning id into v_id;

  perform public.grava_auditoria('Criou conexão MCP', 'Conexão MCP', 'mcp_conexoes', v_id::text,
    jsonb_build_object('nome', v_nome, 'escrita', coalesce(p_escrita, false), 'dias', p_dias), 'banco');

  return jsonb_build_object('id', v_id, 'token', v_token);
end;
$$;

-- Revoga uma conexão: o dono, o Master ou o Corporativo master (usuários da própria organização)
create or replace function public.mcp_revogar_conexao(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_c   public.mcp_conexoes%rowtype;
  v_org uuid;
begin
  if not public.aal2() or public.meu_perfil() is null then
    raise exception 'Sessão sem permissão';
  end if;
  select * into v_c from public.mcp_conexoes where id = p_id;
  if v_c.id is null then
    raise exception 'Conexão não encontrada';
  end if;
  select organizacao_id into v_org from public.usuarios where user_id = v_c.user_id;
  if not coalesce(
       v_c.user_id = v_uid
       or public.eh_master()
       or (public.meu_perfil() = 'corp_master' and v_org = public.minha_org()), false) then
    raise exception 'Conexão não encontrada';
  end if;
  if v_c.revogada_em is not null then
    return;
  end if;
  update public.mcp_conexoes set revogada_em = now(), revogada_por = v_uid where id = p_id;
  perform public.grava_auditoria('Revogou conexão MCP', 'Conexão MCP', 'mcp_conexoes', p_id::text,
    jsonb_build_object('nome', v_c.nome, 'dono', v_c.user_id), 'banco');
end;
$$;

-- Master: liga ou desliga o MCP de um módulo para uma organização (nulo = equipe Celeiro)
create or replace function public.mcp_definir_liberacao(p_org uuid, p_modulo text, p_leitura boolean, p_escrita boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_leitura boolean := coalesce(p_leitura, false);
  v_escrita boolean := coalesce(p_leitura, false) and coalesce(p_escrita, false);
begin
  if not public.eh_master() then
    raise exception 'Só o Master libera o MCP';
  end if;
  if not exists (select 1 from public.mcp_ferramentas where modulo = p_modulo) then
    raise exception 'Este módulo ainda não tem ferramentas no MCP';
  end if;
  if p_org is not null and not exists (select 1 from public.organizacoes where id = p_org) then
    raise exception 'Organização não encontrada';
  end if;
  update public.mcp_liberacoes
     set leitura = v_leitura, escrita = v_escrita, atualizado_em = now()
   where organizacao_id is not distinct from p_org and modulo = p_modulo
     and (leitura, escrita) is distinct from (v_leitura, v_escrita);
  if not exists (select 1 from public.mcp_liberacoes
                 where organizacao_id is not distinct from p_org and modulo = p_modulo) then
    insert into public.mcp_liberacoes (organizacao_id, modulo, leitura, escrita)
    values (p_org, p_modulo, v_leitura, v_escrita);
  end if;
end;
$$;

-- Master: libera ou bloqueia o MCP para um usuário
create or replace function public.mcp_liberar_usuario(p_user uuid, p_liberado boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.eh_master() then
    raise exception 'Só o Master libera o MCP';
  end if;
  if not exists (select 1 from public.usuarios where user_id = p_user) then
    raise exception 'Usuário não encontrado';
  end if;
  if (select perfil from public.usuarios where user_id = p_user) = 'master' then
    raise exception 'Usuários Master já têm o MCP liberado';
  end if;
  insert into public.mcp_usuarios (user_id, liberado) values (p_user, coalesce(p_liberado, false))
  on conflict (user_id) do update
    set liberado = excluded.liberado, atualizado_em = now()
    where public.mcp_usuarios.liberado is distinct from excluded.liberado;
end;
$$;

-- Acha a tarefa pelo código (WF-0012 ou 12), só entre as que o usuário atual vê
create or replace function public.mcp_tarefa(p_codigo text)
returns uuid
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_n  bigint;
  v_id uuid;
begin
  v_n := nullif(regexp_replace(coalesce(p_codigo, ''), '[^0-9]', '', 'g'), '')::bigint;
  if v_n is null then
    raise exception 'Informe o código da tarefa, por exemplo WF-0012';
  end if;
  select t.id into v_id from public.workflow_tarefas t
   where t.numero = v_n and public.workflow_pode_ver(t.id);
  if v_id is null then
    raise exception 'Tarefa não encontrada';
  end if;
  return v_id;
end;
$$;

-- Executa uma ferramenta. Uso interno: só é chamada por mcp_chamar, depois que a
-- conexão foi conferida e a sessão passou a valer como a do usuário dono dela.
create or replace function public.mcp_executar(p_nome text, p_args jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_u     public.usuarios%rowtype;
  v_a     jsonb := coalesce(p_args, '{}'::jsonb);
  v_lim   int;
  v_txt   text := lower(trim(coalesce(p_args ->> 'texto', '')));
  v_num   text := regexp_replace(coalesce(p_args ->> 'texto', ''), '[^0-9]', '', 'g');
  v_id    uuid;
  v_ts    jsonb;
  v_r     jsonb;
  v_sit   text;
  v_tipo  text;
begin
  select * into v_u from public.usuarios where user_id = v_uid;

  if p_nome = 'quem_sou_eu' then
    return jsonb_build_object(
      'nome', v_u.nome, 'perfil', v_u.perfil,
      'organizacao', coalesce((select o.nome from public.organizacoes o where o.id = v_u.organizacao_id), 'Celeiro (equipe)'),
      'modulos_liberados', coalesce((
        select jsonb_agg(jsonb_build_object('modulo', m.nome, 'leitura', true, 'escrita_liberada_pelo_master', m.escrita))
        from public.mcp_modulos(v_uid) m), '[]'::jsonb),
      'conexao_permite_escrita', coalesce((select auth.jwt() ->> 'mcp_escrita') = 'true', false)
    );

  elsif p_nome = 'dashboard_resumo' then
    v_r := '{}'::jsonb;
    if public.pode_modulo('workflow') then
      v_ts := public.workflow_listar();
      v_r := v_r || jsonb_build_object('tarefas', (
        select jsonb_build_object(
          'a_fazer',      count(*) filter (where t ->> 'status' = 'a_fazer'),
          'em_andamento', count(*) filter (where t ->> 'status' = 'em_andamento'),
          'em_revisao',   count(*) filter (where t ->> 'status' = 'em_revisao'),
          'concluidas',   count(*) filter (where t ->> 'status' = 'concluida'),
          'vencidas',     count(*) filter (where t ->> 'status' <> 'concluida' and (t ->> 'prazo')::date < current_date),
          'urgentes',     count(*) filter (where t ->> 'status' <> 'concluida' and t ->> 'prioridade' = 'urgente'),
          'sob_minha_responsabilidade', count(*) filter (where t ->> 'status' <> 'concluida' and exists (
              select 1 from jsonb_array_elements(t -> 'participantes') p
              where p ->> 'user_id' = v_uid::text and p ->> 'papel' = 'responsavel'))
        ) from jsonb_array_elements(v_ts) t));
    end if;
    if public.pode_modulo('cadastro') then
      v_r := v_r || jsonb_build_object('cadastros', jsonb_build_object(
        'pessoas_fisicas_ativas', (select count(*) from public.cadastro_pf f
                                   where f.situacao = 'ativo' and public.cadastro_escopo_ok(f.organizacao_id)),
        'empresas_ativas',        (select count(*) from public.cadastro_pj j
                                   where j.situacao = 'ativo' and public.cadastro_escopo_ok(j.organizacao_id))));
    end if;
    return v_r;

  elsif p_nome = 'workflow_listar_tarefas' then
    v_lim := least(greatest(coalesce((v_a ->> 'limite')::int, 30), 1), 100);
    v_sit := coalesce(nullif(v_a ->> 'situacao', ''), 'abertas');
    if v_sit not in ('abertas','a_fazer','em_andamento','em_revisao','concluida','todas') then
      raise exception 'Situação inválida';
    end if;
    v_ts := public.workflow_listar();
    return (
      with f as (
        select t, row_number() over (order by (t ->> 'numero')::bigint desc) as n
        from jsonb_array_elements(v_ts) t
        where (v_sit = 'todas'
               or (v_sit = 'abertas' and t ->> 'status' <> 'concluida')
               or t ->> 'status' = v_sit)
          and (v_txt = '' or position(v_txt in lower((t ->> 'titulo') || ' ' || (t ->> 'descricao'))) > 0)
          and (not coalesce((v_a ->> 'somente_minhas')::boolean, false) or exists (
                select 1 from jsonb_array_elements(t -> 'participantes') p
                where p ->> 'user_id' = v_uid::text and p ->> 'papel' = 'responsavel'))
      )
      select jsonb_build_object(
        'encontradas', (select count(*) from f),
        'tarefas', coalesce((
          select jsonb_agg(jsonb_build_object(
            'codigo', t ->> 'codigo', 'titulo', t ->> 'titulo', 'situacao', t ->> 'status',
            'prioridade', t ->> 'prioridade', 'prazo', t ->> 'prazo', 'organizacao', t ->> 'organizacao',
            'responsaveis', coalesce((select jsonb_agg(p ->> 'nome') from jsonb_array_elements(t -> 'participantes') p
                                      where p ->> 'papel' = 'responsavel'), '[]'::jsonb),
            'comentarios', t -> 'comentarios', 'criada_em', t ->> 'criado_em'
          ) order by n) from f where n <= v_lim), '[]'::jsonb))
    );

  elsif p_nome = 'workflow_ver_tarefa' then
    v_id := public.mcp_tarefa(v_a ->> 'codigo');
    select t into v_r from jsonb_array_elements(public.workflow_listar()) t where t ->> 'id' = v_id::text;
    return jsonb_build_object(
      'codigo', v_r ->> 'codigo', 'titulo', v_r ->> 'titulo', 'descricao', v_r ->> 'descricao',
      'situacao', v_r ->> 'status', 'prioridade', v_r ->> 'prioridade', 'prazo', v_r ->> 'prazo',
      'organizacao', v_r ->> 'organizacao', 'confidencial', v_r -> 'confidencial',
      'criada_por', v_r ->> 'criado_por_nome', 'criada_em', v_r ->> 'criado_em',
      'concluida_em', v_r ->> 'concluida_em',
      'participantes', coalesce((select jsonb_agg(jsonb_build_object('nome', p ->> 'nome', 'papel', p ->> 'papel'))
                                 from jsonb_array_elements(v_r -> 'participantes') p), '[]'::jsonb),
      'comentarios', coalesce((select jsonb_agg(jsonb_build_object(
                                   'autor', k ->> 'nome', 'texto', k ->> 'texto', 'quando', k ->> 'criado_em'))
                               from jsonb_array_elements(public.workflow_detalhe(v_id) -> 'comentarios') k), '[]'::jsonb)
    );

  elsif p_nome = 'workflow_criar_tarefa' then
    v_id := public.workflow_salvar(
      null, v_a ->> 'titulo', coalesce(v_a ->> 'descricao', ''), v_u.organizacao_id, 'a_fazer',
      nullif(v_a ->> 'prazo', '')::date, coalesce(nullif(v_a ->> 'prioridade', ''), 'media'),
      '', '', false, array[v_uid], '{}'::uuid[], 'Criada por assistente (MCP)');
    return jsonb_build_object('criada', true,
      'codigo', (select 'WF-' || lpad(t.numero::text, 4, '0') from public.workflow_tarefas t where t.id = v_id));

  elsif p_nome = 'workflow_mover_tarefa' then
    v_id := public.mcp_tarefa(v_a ->> 'codigo');
    perform public.workflow_mover(v_id, v_a ->> 'situacao');
    return jsonb_build_object('movida', true, 'situacao', v_a ->> 'situacao');

  elsif p_nome = 'workflow_comentar' then
    v_id := public.mcp_tarefa(v_a ->> 'codigo');
    perform public.workflow_comentar(v_id, v_a ->> 'texto');
    return jsonb_build_object('comentado', true);

  elsif p_nome = 'cadastro_buscar' then
    v_lim  := least(greatest(coalesce((v_a ->> 'limite')::int, 20), 1), 50);
    v_tipo := coalesce(nullif(v_a ->> 'tipo', ''), 'todos');
    v_sit  := coalesce(nullif(v_a ->> 'situacao', ''), 'ativo');
    if v_tipo not in ('todos','pf','pj') or v_sit not in ('ativo','inativo','todas') then
      raise exception 'Filtro inválido';
    end if;
    return (
      with tudo as (
        select 'pf' as tipo, f.id, f.nome_completo as nome,
               '***.' || substr(f.cpf, 4, 3) || '.' || substr(f.cpf, 7, 3) || '-**' as documento,
               f.cidade, f.uf, f.situacao, o.nome as organizacao
        from public.cadastro_pf f
        left join public.organizacoes o on o.id = f.organizacao_id
        where v_tipo in ('todos','pf')
          and public.cadastro_escopo_ok(f.organizacao_id)
          and (v_sit = 'todas' or f.situacao = v_sit)
          and (v_txt = '' or position(v_txt in lower(f.nome_completo || ' ' || f.nome_social)) > 0
               or (char_length(v_num) >= 3 and position(v_num in f.cpf) > 0))
        union all
        select 'pj', j.id, j.razao_social,
               substr(j.cnpj, 1, 2) || '.' || substr(j.cnpj, 3, 3) || '.***/' || substr(j.cnpj, 9, 4) || '-**',
               j.cidade, j.uf, j.situacao, o.nome
        from public.cadastro_pj j
        left join public.organizacoes o on o.id = j.organizacao_id
        where v_tipo in ('todos','pj')
          and public.cadastro_escopo_ok(j.organizacao_id)
          and (v_sit = 'todas' or j.situacao = v_sit)
          and (v_txt = '' or position(v_txt in lower(j.razao_social || ' ' || j.nome_fantasia)) > 0
               or (char_length(v_num) >= 3 and position(v_num in j.cnpj) > 0))
      ), num as (
        select tudo.*, row_number() over (order by nome) as n from tudo
      )
      select jsonb_build_object(
        'encontrados', (select count(*) from num),
        'cadastros', coalesce((
          select jsonb_agg(jsonb_build_object(
            'tipo', tipo, 'id', id, 'nome', nome, 'documento', documento,
            'cidade', cidade, 'uf', uf, 'situacao', situacao, 'organizacao', organizacao) order by n)
          from num where n <= v_lim), '[]'::jsonb))
    );

  elsif p_nome = 'cadastro_ver_pessoa_fisica' then
    select to_jsonb(f) - 'criado_por' - 'atualizado_por' - 'organizacao_id' into v_r
    from public.cadastro_pf f
    where f.id = (v_a ->> 'id')::uuid and public.cadastro_escopo_ok(f.organizacao_id);
    if v_r is null then
      raise exception 'Cadastro não encontrado';
    end if;
    return v_r;

  elsif p_nome = 'cadastro_ver_empresa' then
    select to_jsonb(j) - 'criado_por' - 'atualizado_por' - 'organizacao_id' - 'representante_pf_id'
           || jsonb_build_object(
             'representante', (select jsonb_build_object('id', f.id, 'nome', f.nome_completo)
                               from public.cadastro_pf f where f.id = j.representante_pf_id),
             'socios', coalesce((select jsonb_agg(jsonb_build_object(
                                   'nome', s.nome, 'qualificacao', s.qualificacao, 'selecionado', s.selecionado)
                                   order by s.ordem)
                                 from public.cadastro_pj_socios s where s.pj_id = j.id), '[]'::jsonb))
      into v_r
    from public.cadastro_pj j
    where j.id = (v_a ->> 'id')::uuid and public.cadastro_escopo_ok(j.organizacao_id);
    if v_r is null then
      raise exception 'Cadastro não encontrado';
    end if;
    return v_r;

  elsif p_nome = 'auditoria_consultar' then
    v_lim := least(greatest(coalesce((v_a ->> 'limite')::int, 30), 1), 100);
    return (
      with f as (
        select a.*, row_number() over (order by a.ocorrido_em desc, a.id desc) as n
        from public.auditoria a
        where a.ocorrido_em >= now() - make_interval(days => least(greatest(coalesce((v_a ->> 'dias')::int, 7), 1), 90))
          and (public.eh_master()
               or (public.pode_modulo('auditoria')
                   and (public.meu_perfil() = 'gerencial' or a.organizacao_id = public.minha_org())))
          and (v_txt = '' or position(v_txt in lower(a.acao || ' ' || coalesce(a.usuario_nome, ''))) > 0)
          and (coalesce(v_a ->> 'origem', '') = '' or a.origem = v_a ->> 'origem')
      )
      select jsonb_build_object(
        'encontrados', (select count(*) from f),
        'registros', coalesce((
          select jsonb_agg(jsonb_build_object(
            'quando', ocorrido_em, 'usuario', usuario_nome, 'perfil', perfil, 'acao', acao,
            'modulo', modulo, 'ip', ip, 'pais', pais, 'origem', origem) order by n)
          from f where n <= v_lim), '[]'::jsonb))
    );
  end if;

  raise exception 'Ferramenta desconhecida';
end;
$$;

-- Porta de entrada do servidor MCP. Só a função "mcp" (com a chave secreta do
-- projeto) chama isto; o navegador não. Recebe o resumo do token, confere a
-- conexão, passa a agir como o usuário dono dela e registra tudo na auditoria.
create or replace function public.mcp_chamar(
  p_hash text, p_metodo text, p_ferramenta text, p_args jsonb,
  p_ip text, p_pais text, p_agente text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_c    public.mcp_conexoes%rowtype;
  v_f    public.mcp_ferramentas%rowtype;
  v_mod  text;
  v_res  jsonb;
  v_erro text;
  v_args jsonb := coalesce(p_args, '{}'::jsonb);
begin
  select * into v_c from public.mcp_conexoes where token_hash = p_hash;
  if v_c.id is null then
    return jsonb_build_object('ok', false, 'codigo', 'token_invalido', 'erro', 'Token não reconhecido');
  end if;

  -- A partir daqui a chamada vale como a do usuário dono da conexão: as mesmas
  -- regras da tela (perfil, organização, módulos) decidem o que ele vê e faz.
  perform set_config('request.jwt.claims', jsonb_build_object(
    'sub', v_c.user_id, 'role', 'authenticated', 'aal', 'aal2',
    'mcp_conexao', v_c.id, 'mcp_escrita', v_c.escrita)::text, true);
  perform set_config('request.jwt.claim.sub', v_c.user_id::text, true);
  perform set_config('request.headers', jsonb_build_object(
    'x-forwarded-for', coalesce(p_ip, ''), 'cf-ipcountry', coalesce(p_pais, ''),
    'user-agent', left('MCP · ' || v_c.nome || ' · ' || coalesce(p_agente, ''), 300))::text, true);

  if v_c.revogada_em is not null or v_c.expira_em <= now() then
    perform public.grava_auditoria('MCP: conexão recusada', 'Conexão MCP', 'mcp_conexoes', v_c.id::text,
      jsonb_build_object('conexao', v_c.nome,
        'motivo', case when v_c.revogada_em is not null then 'revogada' else 'expirada' end), 'mcp');
    return jsonb_build_object('ok', false, 'codigo', 'token_invalido',
      'erro', case when v_c.revogada_em is not null then 'Conexão revogada' else 'Conexão expirada' end);
  end if;

  if not public.mcp_usuario_liberado(v_c.user_id) then
    perform public.grava_auditoria('MCP: conexão recusada', 'Conexão MCP', 'mcp_conexoes', v_c.id::text,
      jsonb_build_object('conexao', v_c.nome, 'motivo', 'usuário sem liberação'), 'mcp');
    return jsonb_build_object('ok', false, 'codigo', 'sem_acesso',
      'erro', 'O uso do MCP não está liberado para este usuário');
  end if;

  -- Limite de 120 chamadas por minuto por conexão
  if v_c.janela_inicio is null or v_c.janela_inicio < now() - interval '1 minute' then
    update public.mcp_conexoes
       set janela_inicio = now(), janela_chamadas = 1, ultimo_uso = now(), chamadas = chamadas + 1
     where id = v_c.id;
  elsif v_c.janela_chamadas >= 120 then
    return jsonb_build_object('ok', false, 'codigo', 'limite',
      'erro', 'Muitas chamadas em pouco tempo. Aguarde um minuto');
  else
    update public.mcp_conexoes
       set janela_chamadas = janela_chamadas + 1, ultimo_uso = now(), chamadas = chamadas + 1
     where id = v_c.id;
  end if;

  if p_metodo = 'iniciar' then
    perform public.grava_auditoria('MCP: assistente conectou', 'Conexão MCP', 'mcp_conexoes', v_c.id::text,
      jsonb_build_object('conexao', v_c.nome, 'cliente', left(coalesce(p_agente, ''), 200)), 'mcp');
    return jsonb_build_object('ok', true,
      'usuario', (select u.nome from public.usuarios u where u.user_id = v_c.user_id));

  elsif p_metodo = 'ferramentas' then
    return jsonb_build_object('ok', true, 'ferramentas', coalesce((
      select jsonb_agg(jsonb_build_object(
        'nome', f.nome, 'titulo', f.titulo, 'descricao', f.descricao,
        'parametros', f.parametros, 'escrita', f.escrita) order by f.ordem, f.nome)
      from public.mcp_ferramentas_de(v_c.user_id, v_c.escrita) f), '[]'::jsonb));

  elsif p_metodo = 'chamar' then
    select * into v_f from public.mcp_ferramentas where nome = p_ferramenta;
    if v_f.nome is null then
      return jsonb_build_object('ok', false, 'codigo', 'ferramenta_desconhecida', 'erro', 'Ferramenta desconhecida');
    end if;
    v_mod := coalesce((select nome from public.modulos where codigo = v_f.modulo), 'Conexão MCP');
    if pg_column_size(v_args) > 2000 then
      v_args := jsonb_build_object('resumo', 'argumentos longos, não copiados');
    end if;

    if not exists (select 1 from public.mcp_ferramentas_de(v_c.user_id, v_c.escrita) d where d.nome = v_f.nome) then
      perform public.grava_auditoria('MCP: chamada recusada', v_mod, null, null,
        jsonb_build_object('conexao', v_c.nome, 'ferramenta', v_f.nome, 'escrita', v_f.escrita), 'mcp');
      return jsonb_build_object('ok', false, 'codigo', 'negado', 'erro',
        case when v_f.escrita
          then 'Esta conexão não tem permissão de escrita neste módulo. A escrita precisa ser liberada pelo Master e marcada na conexão'
          else 'Este módulo não está liberado para uso pelo MCP' end);
    end if;

    begin
      v_res := public.mcp_executar(v_f.nome, coalesce(p_args, '{}'::jsonb));
    exception when others then
      v_erro := sqlerrm;
    end;

    if v_erro is not null then
      perform public.grava_auditoria('MCP: ' || v_f.titulo || ' (falhou)', v_mod, null, null,
        jsonb_build_object('conexao', v_c.nome, 'ferramenta', v_f.nome, 'argumentos', v_args, 'erro', left(v_erro, 300)), 'mcp');
      return jsonb_build_object('ok', false, 'codigo', 'erro', 'erro', v_erro);
    end if;

    perform public.grava_auditoria('MCP: ' || v_f.titulo, v_mod, null, null,
      jsonb_build_object('conexao', v_c.nome, 'ferramenta', v_f.nome, 'argumentos', v_args, 'escrita', v_f.escrita), 'mcp');
    return jsonb_build_object('ok', true, 'resultado', v_res);
  end if;

  return jsonb_build_object('ok', false, 'codigo', 'metodo', 'erro', 'Método desconhecido');
end;
$$;

revoke all on public.mcp_liberacoes, public.mcp_usuarios, public.mcp_conexoes, public.mcp_ferramentas
  from anon, authenticated;

revoke all on function public.mcp_usuario_liberado(uuid)      from public, anon, authenticated;
revoke all on function public.mcp_modulos(uuid)               from public, anon, authenticated;
revoke all on function public.mcp_ferramentas_de(uuid, boolean) from public, anon, authenticated;
revoke all on function public.mcp_tarefa(text)                from public, anon, authenticated;
revoke all on function public.mcp_executar(text, jsonb)       from public, anon, authenticated;
revoke all on function public.mcp_chamar(text, text, text, jsonb, text, text, text) from public, anon, authenticated;
grant execute on function public.mcp_chamar(text, text, text, jsonb, text, text, text) to service_role;

revoke all on function public.mcp_painel()                                   from public, anon;
revoke all on function public.mcp_criar_conexao(text, int, boolean)          from public, anon;
revoke all on function public.mcp_revogar_conexao(uuid)                      from public, anon;
revoke all on function public.mcp_definir_liberacao(uuid, text, boolean, boolean) from public, anon;
revoke all on function public.mcp_liberar_usuario(uuid, boolean)             from public, anon;

grant execute on function public.mcp_painel()                                   to authenticated;
grant execute on function public.mcp_criar_conexao(text, int, boolean)          to authenticated;
grant execute on function public.mcp_revogar_conexao(uuid)                      to authenticated;
grant execute on function public.mcp_definir_liberacao(uuid, text, boolean, boolean) to authenticated;
grant execute on function public.mcp_liberar_usuario(uuid, boolean)             to authenticated;

-- =====================================================================
-- 12) FINANCEIRO
--    Contas a pagar e a receber, faturas, fluxo de caixa, DRE, balanço e
--    balancete. Cada organização tem os próprios livros; organizacao_id
--    nulo = livros da própria Celeiro (só a equipe Celeiro alcança).
--    - Quem tem o módulo Financeiro vê e altera, dentro do seu alcance.
--    - A contabilidade é por partidas dobradas, geradas a partir dos
--      títulos (emissão e pagamento) e dos lançamentos manuais.
--    - Emitir fatura cria automaticamente o título em contas a receber.
--    - Nada é apagado: títulos e faturas são cancelados, e ficam no histórico.
--    - As tabelas não são lidas direto pelo navegador; tudo passa pelas
--      operações abaixo, que conferem o alcance.
-- =====================================================================

create table if not exists public.fin_contas (
  id             uuid primary key default gen_random_uuid(),
  organizacao_id uuid references public.organizacoes(id) on delete cascade,
  codigo         text not null check (codigo ~ '^[0-9]+(\.[0-9]+){0,4}$'),
  nome           text not null check (char_length(nome) between 1 and 120),
  tipo           text not null check (tipo in ('ativo','passivo','patrimonio','receita','custo','despesa')),
  grupo          boolean not null default false,
  caixa          boolean not null default false,
  papel          text check (papel in ('clientes','fornecedores')),
  ativo          boolean not null default true,
  criado_em      timestamptz not null default now(),
  constraint fin_contas_caixa_ativo check (not caixa or (tipo = 'ativo' and not grupo))
);
create unique index if not exists fin_contas_codigo
  on public.fin_contas (coalesce(organizacao_id, '00000000-0000-0000-0000-000000000000'::uuid), codigo);

create table if not exists public.fin_faturas (
  id                uuid primary key default gen_random_uuid(),
  organizacao_id    uuid references public.organizacoes(id) on delete cascade,
  numero            bigint generated always as identity,
  cliente_tipo      text check (cliente_tipo in ('pf','pj')),
  cliente_id        uuid,
  cliente_nome      text not null check (char_length(cliente_nome) between 1 and 200),
  cliente_documento text not null default '',
  cliente_endereco  text not null default '',
  cliente_email     text not null default '',
  emissao           date not null,
  vencimento        date not null,
  conta_id          uuid not null references public.fin_contas(id),
  itens             jsonb not null,
  total             numeric(14,2) not null check (total > 0),
  forma             text not null default '',
  observacoes       text not null default '',
  status            text not null default 'emitida' check (status in ('emitida','cancelada')),
  cancelada_em      timestamptz,
  criado_por        uuid,
  criado_em         timestamptz not null default now(),
  constraint fin_faturas_datas check (vencimento >= emissao)
);
create index if not exists fin_faturas_org on public.fin_faturas (organizacao_id, emissao);

create table if not exists public.fin_titulos (
  id             uuid primary key default gen_random_uuid(),
  organizacao_id uuid references public.organizacoes(id) on delete cascade,
  tipo           text not null check (tipo in ('pagar','receber')),
  numero         bigint generated always as identity,
  descricao      text not null check (char_length(descricao) between 1 and 200),
  pessoa_tipo    text check (pessoa_tipo in ('pf','pj')),
  pessoa_id      uuid,
  pessoa_nome    text not null default '',
  conta_id       uuid not null references public.fin_contas(id),
  emissao        date not null,
  vencimento     date not null,
  valor          numeric(14,2) not null check (valor > 0),
  status         text not null default 'aberto' check (status in ('aberto','pago','cancelado')),
  pago_em        date,
  conta_caixa_id uuid references public.fin_contas(id),
  forma          text not null default '',
  fatura_id      uuid references public.fin_faturas(id),
  observacoes    text not null default '',
  criado_por     uuid,
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now(),
  constraint fin_titulos_datas check (vencimento >= emissao),
  constraint fin_titulos_pago check ((status = 'pago') = (pago_em is not null and conta_caixa_id is not null))
);
create index if not exists fin_titulos_org on public.fin_titulos (organizacao_id, tipo, vencimento);

create table if not exists public.fin_lancamentos (
  id             uuid primary key default gen_random_uuid(),
  organizacao_id uuid references public.organizacoes(id) on delete cascade,
  data           date not null,
  historico      text not null check (char_length(historico) between 1 and 200),
  conta_debito   uuid not null references public.fin_contas(id),
  conta_credito  uuid not null references public.fin_contas(id),
  valor          numeric(14,2) not null check (valor > 0),
  criado_por     uuid,
  criado_em      timestamptz not null default now(),
  constraint fin_lancamentos_contas check (conta_debito <> conta_credito)
);
create index if not exists fin_lancamentos_org on public.fin_lancamentos (organizacao_id, data);

alter table public.fin_contas      enable row level security;
alter table public.fin_faturas     enable row level security;
alter table public.fin_titulos     enable row level security;
alter table public.fin_lancamentos enable row level security;

drop trigger if exists auditar_fin_faturas on public.fin_faturas;
create trigger auditar_fin_faturas
  after insert or update or delete on public.fin_faturas
  for each row execute function public.auditar('Financeiro');

drop trigger if exists auditar_fin_titulos on public.fin_titulos;
create trigger auditar_fin_titulos
  after insert or update or delete on public.fin_titulos
  for each row execute function public.auditar('Financeiro');

drop trigger if exists auditar_fin_lancamentos on public.fin_lancamentos;
create trigger auditar_fin_lancamentos
  after insert or update or delete on public.fin_lancamentos
  for each row execute function public.auditar('Financeiro');

drop trigger if exists auditar_fin_contas on public.fin_contas;
create trigger auditar_fin_contas
  after update or delete on public.fin_contas
  for each row execute function public.auditar('Financeiro');

-- O usuário atual alcança os livros desta organização? (nulo = Celeiro)
create or replace function public.fin_escopo_ok(p_org uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.pode_modulo('financeiro')
     and coalesce(
       (public.eh_equipe() and (p_org is null or exists (select 1 from public.organizacoes o where o.id = p_org)))
       or (p_org is not null and p_org = public.minha_org()), false);
$$;

-- Cria o plano de contas padrão na primeira vez (uso interno)
create or replace function public.fin_preparar(p_org uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (select 1 from public.fin_contas where organizacao_id is not distinct from p_org) then
    return;
  end if;
  insert into public.fin_contas (organizacao_id, codigo, nome, tipo, grupo, caixa, papel)
  select p_org, v.codigo, v.nome, v.tipo, v.grupo, v.caixa, v.papel
  from (values
    ('1',     'Ativo',                                'ativo',      true,  false, null),
    ('1.1',   'Ativo circulante',                     'ativo',      true,  false, null),
    ('1.1.1', 'Caixa',                                'ativo',      false, true,  null),
    ('1.1.2', 'Banco conta movimento',                'ativo',      false, true,  null),
    ('1.1.3', 'Clientes a receber',                   'ativo',      false, false, 'clientes'),
    ('1.2',   'Ativo não circulante',                 'ativo',      true,  false, null),
    ('1.2.1', 'Imobilizado',                          'ativo',      false, false, null),
    ('2',     'Passivo',                              'passivo',    true,  false, null),
    ('2.1',   'Passivo circulante',                   'passivo',    true,  false, null),
    ('2.1.1', 'Fornecedores a pagar',                 'passivo',    false, false, 'fornecedores'),
    ('2.1.2', 'Impostos a recolher',                  'passivo',    false, false, null),
    ('2.1.3', 'Empréstimos e financiamentos',         'passivo',    false, false, null),
    ('3',     'Patrimônio líquido',                   'patrimonio', true,  false, null),
    ('3.1',   'Capital social',                       'patrimonio', false, false, null),
    ('3.2',   'Lucros ou prejuízos acumulados',       'patrimonio', false, false, null),
    ('4',     'Receitas',                             'receita',    true,  false, null),
    ('4.1',   'Receita de serviços',                  'receita',    false, false, null),
    ('4.2',   'Receita de energia',                   'receita',    false, false, null),
    ('4.3',   'Receita de financiamentos',            'receita',    false, false, null),
    ('4.4',   'Receita de captação de recursos',      'receita',    false, false, null),
    ('4.5',   'Receitas financeiras',                 'receita',    false, false, null),
    ('4.9',   'Outras receitas',                      'receita',    false, false, null),
    ('5',     'Custos',                               'custo',      true,  false, null),
    ('5.1',   'Custo dos serviços prestados',         'custo',      false, false, null),
    ('6',     'Despesas',                             'despesa',    true,  false, null),
    ('6.1',   'Pessoal',                              'despesa',    false, false, null),
    ('6.2',   'Aluguel e ocupação',                   'despesa',    false, false, null),
    ('6.3',   'Serviços de terceiros',                'despesa',    false, false, null),
    ('6.4',   'Impostos e taxas',                     'despesa',    false, false, null),
    ('6.5',   'Marketing',                            'despesa',    false, false, null),
    ('6.6',   'Tecnologia',                           'despesa',    false, false, null),
    ('6.7',   'Despesas financeiras',                 'despesa',    false, false, null),
    ('6.9',   'Outras despesas',                      'despesa',    false, false, null)
  ) as v(codigo, nome, tipo, grupo, caixa, papel);
  perform public.grava_auditoria('Criou o plano de contas padrão', 'Financeiro', 'fin_contas', null,
    jsonb_build_object('organizacao_id', p_org), 'banco');
end;
$$;

-- Ordena códigos como 1.2.10 depois de 1.2.9
create or replace function public.fin_ordem(p_codigo text)
returns int[]
language sql
immutable
set search_path = ''
as $$
  select string_to_array(p_codigo, '.')::int[];
$$;

-- Plano de contas (cria o padrão na primeira vez)
create or replace function public.fin_plano(p_org uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.fin_escopo_ok(p_org) then
    raise exception 'Financeiro não disponível para você nesta organização';
  end if;
  perform public.fin_preparar(p_org);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.id, 'codigo', c.codigo, 'nome', c.nome, 'tipo', c.tipo, 'grupo', c.grupo,
      'caixa', c.caixa, 'papel', c.papel, 'ativo', c.ativo) order by public.fin_ordem(c.codigo))
    from public.fin_contas c where c.organizacao_id is not distinct from p_org), '[]'::jsonb);
end;
$$;

-- Cria ou altera uma conta do plano
create or replace function public.fin_conta_salvar(
  p_id uuid, p_org uuid, p_codigo text, p_nome text, p_tipo text, p_grupo boolean, p_caixa boolean, p_ativo boolean
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_c      public.fin_contas%rowtype;
  v_codigo text := trim(coalesce(p_codigo, ''));
  v_nome   text := left(trim(coalesce(p_nome, '')), 120);
  v_grupo  boolean := coalesce(p_grupo, false);
  v_caixa  boolean := coalesce(p_caixa, false);
  v_usada  boolean;
  v_id     uuid;
begin
  if not public.fin_escopo_ok(p_org) then
    raise exception 'Financeiro não disponível para você nesta organização';
  end if;
  perform public.fin_preparar(p_org);
  if v_codigo !~ '^[0-9]+(\.[0-9]+){0,4}$' then
    raise exception 'Código inválido. Use números separados por ponto, como 6.10';
  end if;
  if char_length(v_nome) = 0 then
    raise exception 'Informe o nome da conta';
  end if;
  if p_tipo is null or p_tipo not in ('ativo','passivo','patrimonio','receita','custo','despesa') then
    raise exception 'Tipo de conta inválido';
  end if;
  if v_caixa and (p_tipo <> 'ativo' or v_grupo) then
    raise exception 'Só contas de ativo que recebem lançamentos podem ser de caixa ou banco';
  end if;
  if exists (select 1 from public.fin_contas
             where organizacao_id is not distinct from p_org and codigo = v_codigo and id is distinct from p_id) then
    raise exception 'Já existe uma conta com este código';
  end if;

  if p_id is null then
    insert into public.fin_contas (organizacao_id, codigo, nome, tipo, grupo, caixa)
    values (p_org, v_codigo, v_nome, p_tipo, v_grupo, v_caixa)
    returning id into v_id;
    perform public.grava_auditoria('Criou conta do plano', 'Financeiro', 'fin_contas', v_id::text,
      jsonb_build_object('codigo', v_codigo, 'nome', v_nome, 'tipo', p_tipo), 'banco');
    return v_id;
  end if;

  select * into v_c from public.fin_contas where id = p_id and organizacao_id is not distinct from p_org;
  if v_c.id is null then
    raise exception 'Conta não encontrada';
  end if;
  v_usada := exists (select 1 from public.fin_titulos where conta_id = p_id or conta_caixa_id = p_id)
          or exists (select 1 from public.fin_lancamentos where conta_debito = p_id or conta_credito = p_id)
          or exists (select 1 from public.fin_faturas where conta_id = p_id);
  if (v_usada or v_c.papel is not null) and (v_c.tipo <> p_tipo or v_c.grupo <> v_grupo) then
    raise exception 'Esta conta já tem movimento ou é usada pelo sistema: o tipo não pode mudar';
  end if;
  if v_c.papel is not null and (v_caixa or not coalesce(p_ativo, true)) then
    raise exception 'Esta conta é usada pelo sistema e não pode ser desativada';
  end if;
  if v_usada and v_c.caixa and not v_caixa then
    raise exception 'Esta conta já recebeu pagamentos: continua sendo de caixa ou banco';
  end if;
  update public.fin_contas
     set codigo = v_codigo, nome = v_nome, tipo = p_tipo, grupo = v_grupo, caixa = v_caixa,
         ativo = coalesce(p_ativo, true)
   where id = p_id;
  return p_id;
end;
$$;

-- Partidas dobradas de uma organização (uso interno): títulos e lançamentos manuais
create or replace function public.fin_partidas(p_org uuid)
returns table (data date, conta_id uuid, debito numeric, credito numeric, historico text, origem text, ref uuid)
language sql
stable
security definer
set search_path = ''
as $$
  with t as (
    select x.*, x.descricao || case when x.pessoa_nome <> '' then ' · ' || x.pessoa_nome else '' end as hist,
           (select c.id from public.fin_contas c
             where c.organizacao_id is not distinct from p_org
               and c.papel = case when x.tipo = 'receber' then 'clientes' else 'fornecedores' end) as contra
    from public.fin_titulos x
    where x.organizacao_id is not distinct from p_org and x.status <> 'cancelado'
  )
  -- competência: receber = D Clientes / C Receita; pagar = D Despesa / C Fornecedores
  select t.emissao, case when t.tipo = 'receber' then t.contra else t.conta_id end, t.valor, 0::numeric, t.hist, 'titulo', t.id from t
  union all
  select t.emissao, case when t.tipo = 'receber' then t.conta_id else t.contra end, 0::numeric, t.valor, t.hist, 'titulo', t.id from t
  union all
  -- pagamento: receber = D Caixa / C Clientes; pagar = D Fornecedores / C Caixa
  select t.pago_em, case when t.tipo = 'receber' then t.conta_caixa_id else t.contra end, t.valor, 0::numeric, t.hist, 'pagamento', t.id
  from t where t.status = 'pago'
  union all
  select t.pago_em, case when t.tipo = 'receber' then t.contra else t.conta_caixa_id end, 0::numeric, t.valor, t.hist, 'pagamento', t.id
  from t where t.status = 'pago'
  union all
  select l.data, l.conta_debito, l.valor, 0::numeric, l.historico, 'lancamento', l.id
  from public.fin_lancamentos l where l.organizacao_id is not distinct from p_org
  union all
  select l.data, l.conta_credito, 0::numeric, l.valor, l.historico, 'lancamento', l.id
  from public.fin_lancamentos l where l.organizacao_id is not distinct from p_org;
$$;

-- Confere um período e devolve erro claro
create or replace function public.fin_periodo_ok(p_ini date, p_fim date)
returns void
language plpgsql
immutable
set search_path = ''
as $$
begin
  if p_ini is null or p_fim is null or p_fim < p_ini then
    raise exception 'Período inválido';
  end if;
  if p_fim - p_ini > 3660 then
    raise exception 'Período longo demais (máximo de 10 anos)';
  end if;
end;
$$;

-- Lê texto de um campo e corta no tamanho
create or replace function public.fin_texto(p_dados jsonb, p_chave text, p_max int)
returns text
language sql
immutable
set search_path = ''
as $$
  select left(trim(coalesce(p_dados ->> p_chave, '')), p_max);
$$;

-- A pessoa informada existe no Cadastro desta organização?
create or replace function public.fin_pessoa_ok(p_org uuid, p_tipo text, p_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_id is null
      or (p_tipo = 'pf' and exists (select 1 from public.cadastro_pf f where f.id = p_id and f.organizacao_id is not distinct from p_org))
      or (p_tipo = 'pj' and exists (select 1 from public.cadastro_pj j where j.id = p_id and j.organizacao_id is not distinct from p_org));
$$;

-- Pessoas do Cadastro para escolher como cliente ou fornecedor
create or replace function public.fin_pessoas(p_org uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.fin_escopo_ok(p_org) then
    raise exception 'Financeiro não disponível para você nesta organização';
  end if;
  return coalesce((
    select jsonb_agg(x order by x ->> 'nome') from (
      select jsonb_build_object('tipo', 'pf', 'id', f.id, 'nome', f.nome_completo, 'documento', f.cpf,
               'email', f.email,
               'endereco', concat_ws(', ', nullif(f.logradouro, ''), nullif(f.numero, ''), nullif(f.bairro, ''),
                                     nullif(concat_ws('/', nullif(f.cidade, ''), nullif(f.uf, '')), ''))) as x
      from public.cadastro_pf f
      where f.organizacao_id is not distinct from p_org and f.situacao = 'ativo'
      union all
      select jsonb_build_object('tipo', 'pj', 'id', j.id, 'nome', j.razao_social, 'documento', j.cnpj,
               'email', j.email,
               'endereco', concat_ws(', ', nullif(j.logradouro, ''), nullif(j.numero, ''), nullif(j.bairro, ''),
                                     nullif(concat_ws('/', nullif(j.cidade, ''), nullif(j.uf, '')), '')))
      from public.cadastro_pj j
      where j.organizacao_id is not distinct from p_org and j.situacao = 'ativo'
      limit 2000
    ) s), '[]'::jsonb);
end;
$$;

-- Um título em formato de tela (uso interno)
create or replace function public.fin_titulo_json(t public.fin_titulos)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', t.id, 'tipo', t.tipo,
    'codigo', case when t.tipo = 'receber' then 'CR-' else 'CP-' end || lpad(t.numero::text, 6, '0'),
    'descricao', t.descricao, 'pessoa_tipo', t.pessoa_tipo, 'pessoa_id', t.pessoa_id, 'pessoa_nome', t.pessoa_nome,
    'conta_id', t.conta_id,
    'conta', (select c.codigo || ' ' || c.nome from public.fin_contas c where c.id = t.conta_id),
    'emissao', t.emissao, 'vencimento', t.vencimento, 'valor', t.valor, 'status', t.status,
    'pago_em', t.pago_em, 'conta_caixa_id', t.conta_caixa_id,
    'conta_caixa', (select c.nome from public.fin_contas c where c.id = t.conta_caixa_id),
    'forma', t.forma, 'fatura_id', t.fatura_id,
    'fatura', (select 'FAT-' || lpad(f.numero::text, 6, '0') from public.fin_faturas f where f.id = t.fatura_id),
    'observacoes', t.observacoes);
$$;

-- Lista títulos a pagar ou a receber de um período
-- p_campo: vencimento | emissao | pagamento. p_status: todos | aberto | vencido | pago | cancelado
create or replace function public.fin_titulos_listar(
  p_org uuid, p_tipo text, p_ini date, p_fim date, p_campo text, p_status text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_campo  text := coalesce(nullif(p_campo, ''), 'vencimento');
  v_status text := coalesce(nullif(p_status, ''), 'todos');
begin
  if not public.fin_escopo_ok(p_org) then
    raise exception 'Financeiro não disponível para você nesta organização';
  end if;
  perform public.fin_periodo_ok(p_ini, p_fim);
  if p_tipo is null or p_tipo not in ('pagar','receber') then
    raise exception 'Tipo inválido';
  end if;
  if v_campo not in ('vencimento','emissao','pagamento') or v_status not in ('todos','aberto','vencido','pago','cancelado') then
    raise exception 'Filtro inválido';
  end if;
  return coalesce((
    select jsonb_agg(public.fin_titulo_json(t) order by
             case v_campo when 'emissao' then t.emissao when 'pagamento' then t.pago_em else t.vencimento end, t.numero)
    from public.fin_titulos t
    where t.organizacao_id is not distinct from p_org and t.tipo = p_tipo
      and (case v_campo when 'emissao' then t.emissao when 'pagamento' then t.pago_em else t.vencimento end) between p_ini and p_fim
      and (v_status = 'todos'
           or (v_status = 'vencido' and t.status = 'aberto' and t.vencimento < current_date)
           or (v_status <> 'vencido' and t.status = v_status))
  ), '[]'::jsonb);
end;
$$;

-- Cria ou altera um título (lançamento manual de contas a pagar ou a receber)
create or replace function public.fin_titulo_salvar(p_id uuid, p_org uuid, p_dados jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_d      jsonb := coalesce(p_dados, '{}'::jsonb);
  v_t      public.fin_titulos%rowtype;
  v_tipo   text := v_d ->> 'tipo';
  v_desc   text := public.fin_texto(v_d, 'descricao', 200);
  v_conta  public.fin_contas%rowtype;
  v_emis   date;
  v_venc   date;
  v_valor  numeric(14,2);
  v_ptipo  text := nullif(v_d ->> 'pessoa_tipo', '');
  v_pid    uuid := nullif(v_d ->> 'pessoa_id', '')::uuid;
  v_id     uuid;
begin
  if not public.fin_escopo_ok(p_org) then
    raise exception 'Financeiro não disponível para você nesta organização';
  end if;
  perform public.fin_preparar(p_org);
  if p_id is not null then
    select * into v_t from public.fin_titulos where id = p_id and organizacao_id is not distinct from p_org;
    if v_t.id is null then
      raise exception 'Título não encontrado';
    end if;
    if v_t.status <> 'aberto' then
      raise exception 'Só títulos em aberto podem ser alterados';
    end if;
    if v_t.fatura_id is not null then
      raise exception 'Este título veio de uma fatura. Para mudar, cancele a fatura e emita outra';
    end if;
    v_tipo := v_t.tipo;
  end if;
  if v_tipo is null or v_tipo not in ('pagar','receber') then
    raise exception 'Tipo inválido';
  end if;
  if char_length(v_desc) = 0 then
    raise exception 'Informe a descrição';
  end if;
  begin
    v_emis  := (v_d ->> 'emissao')::date;
    v_venc  := (v_d ->> 'vencimento')::date;
    v_valor := round((v_d ->> 'valor')::numeric, 2);
  exception when others then
    raise exception 'Confira as datas e o valor';
  end;
  if v_emis is null or v_venc is null then
    raise exception 'Informe a data de competência e o vencimento';
  end if;
  if v_venc < v_emis then
    raise exception 'O vencimento não pode ser anterior à data de competência';
  end if;
  if v_valor is null or v_valor <= 0 or v_valor > 999999999999.99 then
    raise exception 'Informe um valor maior que zero';
  end if;
  select * into v_conta from public.fin_contas
   where id = nullif(v_d ->> 'conta_id', '')::uuid and organizacao_id is not distinct from p_org;
  if v_conta.id is null or v_conta.grupo or not v_conta.ativo
     or (v_tipo = 'receber' and v_conta.tipo <> 'receita')
     or (v_tipo = 'pagar' and v_conta.tipo not in ('custo','despesa')) then
    raise exception 'Escolha uma categoria de %', case when v_tipo = 'receber' then 'receita' else 'custo ou despesa' end;
  end if;
  if v_ptipo is not null and v_ptipo not in ('pf','pj') then
    raise exception 'Pessoa inválida';
  end if;
  if not public.fin_pessoa_ok(p_org, v_ptipo, v_pid) then
    raise exception 'Pessoa não encontrada no Cadastro desta organização';
  end if;

  if p_id is null then
    insert into public.fin_titulos (organizacao_id, tipo, descricao, pessoa_tipo, pessoa_id, pessoa_nome,
      conta_id, emissao, vencimento, valor, observacoes, criado_por)
    values (p_org, v_tipo, v_desc, case when v_pid is null then null else v_ptipo end, v_pid,
      public.fin_texto(v_d, 'pessoa_nome', 200), v_conta.id, v_emis, v_venc, v_valor,
      public.fin_texto(v_d, 'observacoes', 1000), (select auth.uid()))
    returning id into v_id;
    return v_id;
  end if;
  update public.fin_titulos
     set descricao = v_desc, pessoa_tipo = case when v_pid is null then null else v_ptipo end, pessoa_id = v_pid,
         pessoa_nome = public.fin_texto(v_d, 'pessoa_nome', 200), conta_id = v_conta.id,
         emissao = v_emis, vencimento = v_venc, valor = v_valor,
         observacoes = public.fin_texto(v_d, 'observacoes', 1000), atualizado_em = now()
   where id = p_id;
  return p_id;
end;
$$;

-- Baixa: registra o recebimento ou o pagamento
create or replace function public.fin_titulo_baixar(p_id uuid, p_data date, p_caixa uuid, p_forma text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_t public.fin_titulos%rowtype;
begin
  select * into v_t from public.fin_titulos where id = p_id;
  if v_t.id is null or not public.fin_escopo_ok(v_t.organizacao_id) then
    raise exception 'Título não encontrado';
  end if;
  if v_t.status <> 'aberto' then
    raise exception 'Este título não está em aberto';
  end if;
  if p_data is null or p_data > current_date then
    raise exception 'Informe a data do pagamento, que não pode ser futura';
  end if;
  if not exists (select 1 from public.fin_contas c
                 where c.id = p_caixa and c.organizacao_id is not distinct from v_t.organizacao_id and c.caixa and c.ativo) then
    raise exception 'Escolha a conta de caixa ou banco';
  end if;
  update public.fin_titulos
     set status = 'pago', pago_em = p_data, conta_caixa_id = p_caixa,
         forma = left(trim(coalesce(p_forma, '')), 40), atualizado_em = now()
   where id = p_id;
end;
$$;

-- Estorno da baixa: o título volta a ficar em aberto
create or replace function public.fin_titulo_estornar(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_t public.fin_titulos%rowtype;
begin
  select * into v_t from public.fin_titulos where id = p_id;
  if v_t.id is null or not public.fin_escopo_ok(v_t.organizacao_id) then
    raise exception 'Título não encontrado';
  end if;
  if v_t.status <> 'pago' then
    raise exception 'Só títulos pagos podem ser estornados';
  end if;
  update public.fin_titulos
     set status = 'aberto', pago_em = null, conta_caixa_id = null, forma = '', atualizado_em = now()
   where id = p_id;
end;
$$;

-- Cancela um título em aberto (títulos de fatura são cancelados pela fatura)
create or replace function public.fin_titulo_cancelar(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_t public.fin_titulos%rowtype;
begin
  select * into v_t from public.fin_titulos where id = p_id;
  if v_t.id is null or not public.fin_escopo_ok(v_t.organizacao_id) then
    raise exception 'Título não encontrado';
  end if;
  if v_t.status <> 'aberto' then
    raise exception 'Só títulos em aberto podem ser cancelados. Se já foi pago, estorne antes';
  end if;
  if v_t.fatura_id is not null then
    raise exception 'Este título veio de uma fatura. Cancele a fatura';
  end if;
  update public.fin_titulos set status = 'cancelado', atualizado_em = now() where id = p_id;
end;
$$;

-- Uma fatura em formato de tela (uso interno)
create or replace function public.fin_fatura_json(f public.fin_faturas)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', f.id, 'codigo', 'FAT-' || lpad(f.numero::text, 6, '0'),
    'cliente_tipo', f.cliente_tipo, 'cliente_id', f.cliente_id, 'cliente_nome', f.cliente_nome,
    'cliente_documento', f.cliente_documento, 'cliente_endereco', f.cliente_endereco, 'cliente_email', f.cliente_email,
    'emissao', f.emissao, 'vencimento', f.vencimento, 'conta_id', f.conta_id,
    'conta', (select c.codigo || ' ' || c.nome from public.fin_contas c where c.id = f.conta_id),
    'itens', f.itens, 'total', f.total, 'forma', f.forma, 'observacoes', f.observacoes, 'status', f.status,
    'emitente', coalesce((select jsonb_build_object('nome', o.nome, 'cnpj', o.cnpj)
                          from public.organizacoes o where o.id = f.organizacao_id),
                         jsonb_build_object('nome', 'Celeiro Administradora', 'cnpj', '')),
    'titulo', (select jsonb_build_object('id', t.id, 'codigo', 'CR-' || lpad(t.numero::text, 6, '0'),
                        'status', t.status, 'pago_em', t.pago_em)
               from public.fin_titulos t where t.fatura_id = f.id));
$$;

-- Emite uma fatura e lança o título correspondente em contas a receber
create or replace function public.fin_fatura_emitir(p_org uuid, p_dados jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_d     jsonb := coalesce(p_dados, '{}'::jsonb);
  v_nome  text := public.fin_texto(v_d, 'cliente_nome', 200);
  v_ptipo text := nullif(v_d ->> 'cliente_tipo', '');
  v_pid   uuid := nullif(v_d ->> 'cliente_id', '')::uuid;
  v_conta public.fin_contas%rowtype;
  v_emis  date;
  v_venc  date;
  v_itens jsonb := '[]'::jsonb;
  v_i     jsonb;
  v_q     numeric;
  v_v     numeric;
  v_total numeric(14,2) := 0;
  v_f     public.fin_faturas%rowtype;
  v_tid   uuid;
begin
  if not public.fin_escopo_ok(p_org) then
    raise exception 'Financeiro não disponível para você nesta organização';
  end if;
  perform public.fin_preparar(p_org);
  if char_length(v_nome) = 0 then
    raise exception 'Informe o cliente';
  end if;
  if v_ptipo is not null and v_ptipo not in ('pf','pj') then
    raise exception 'Cliente inválido';
  end if;
  if not public.fin_pessoa_ok(p_org, v_ptipo, v_pid) then
    raise exception 'Cliente não encontrado no Cadastro desta organização';
  end if;
  begin
    v_emis := coalesce(nullif(v_d ->> 'emissao', '')::date, current_date);
    v_venc := (v_d ->> 'vencimento')::date;
  exception when others then
    raise exception 'Confira as datas';
  end;
  if v_venc is null or v_venc < v_emis then
    raise exception 'Informe um vencimento igual ou posterior à emissão';
  end if;
  select * into v_conta from public.fin_contas
   where id = nullif(v_d ->> 'conta_id', '')::uuid and organizacao_id is not distinct from p_org;
  if v_conta.id is null or v_conta.grupo or not v_conta.ativo or v_conta.tipo <> 'receita' then
    raise exception 'Escolha uma categoria de receita';
  end if;
  if jsonb_typeof(v_d -> 'itens') is distinct from 'array' or jsonb_array_length(v_d -> 'itens') = 0 then
    raise exception 'Inclua ao menos um item na fatura';
  end if;
  if jsonb_array_length(v_d -> 'itens') > 50 then
    raise exception 'Máximo de 50 itens por fatura';
  end if;
  for v_i in select * from jsonb_array_elements(v_d -> 'itens') loop
    begin
      v_q := (v_i ->> 'quantidade')::numeric;
      v_v := (v_i ->> 'valor_unitario')::numeric;
    exception when others then
      raise exception 'Confira quantidade e valor dos itens';
    end;
    if char_length(public.fin_texto(v_i, 'descricao', 200)) = 0 or v_q is null or v_q <= 0 or v_v is null or v_v < 0 then
      raise exception 'Cada item precisa de descrição, quantidade maior que zero e valor';
    end if;
    v_itens := v_itens || jsonb_build_object(
      'descricao', public.fin_texto(v_i, 'descricao', 200), 'quantidade', v_q,
      'valor_unitario', round(v_v, 2), 'total', round(v_q * v_v, 2));
    v_total := v_total + round(v_q * v_v, 2);
  end loop;
  if v_total <= 0 then
    raise exception 'O total da fatura precisa ser maior que zero';
  end if;

  insert into public.fin_faturas (organizacao_id, cliente_tipo, cliente_id, cliente_nome, cliente_documento,
    cliente_endereco, cliente_email, emissao, vencimento, conta_id, itens, total, forma, observacoes, criado_por)
  values (p_org, case when v_pid is null then null else v_ptipo end, v_pid, v_nome,
    public.fin_texto(v_d, 'cliente_documento', 20), public.fin_texto(v_d, 'cliente_endereco', 300),
    public.fin_texto(v_d, 'cliente_email', 200), v_emis, v_venc, v_conta.id, v_itens, v_total,
    public.fin_texto(v_d, 'forma', 40), public.fin_texto(v_d, 'observacoes', 1000), (select auth.uid()))
  returning * into v_f;

  -- Lançamento automático em contas a receber
  insert into public.fin_titulos (organizacao_id, tipo, descricao, pessoa_tipo, pessoa_id, pessoa_nome,
    conta_id, emissao, vencimento, valor, fatura_id, criado_por)
  values (p_org, 'receber', 'Fatura FAT-' || lpad(v_f.numero::text, 6, '0'), v_f.cliente_tipo, v_f.cliente_id, v_nome,
    v_conta.id, v_emis, v_venc, v_total, v_f.id, (select auth.uid()))
  returning id into v_tid;

  return public.fin_fatura_json(v_f);
end;
$$;

-- Cancela a fatura e o título dela (se ainda não foi recebido)
create or replace function public.fin_fatura_cancelar(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_f public.fin_faturas%rowtype;
begin
  select * into v_f from public.fin_faturas where id = p_id;
  if v_f.id is null or not public.fin_escopo_ok(v_f.organizacao_id) then
    raise exception 'Fatura não encontrada';
  end if;
  if v_f.status = 'cancelada' then
    return;
  end if;
  if exists (select 1 from public.fin_titulos where fatura_id = p_id and status = 'pago') then
    raise exception 'Esta fatura já foi recebida. Estorne o recebimento antes de cancelar';
  end if;
  update public.fin_titulos set status = 'cancelado', atualizado_em = now() where fatura_id = p_id and status = 'aberto';
  update public.fin_faturas set status = 'cancelada', cancelada_em = now() where id = p_id;
end;
$$;

create or replace function public.fin_fatura_ver(p_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_f public.fin_faturas%rowtype;
begin
  select * into v_f from public.fin_faturas where id = p_id;
  if v_f.id is null or not public.fin_escopo_ok(v_f.organizacao_id) then
    raise exception 'Fatura não encontrada';
  end if;
  return public.fin_fatura_json(v_f);
end;
$$;

-- Lançamento manual (saldo inicial, capital, transferência entre contas, ajustes)
create or replace function public.fin_lancamento_salvar(
  p_org uuid, p_data date, p_historico text, p_debito uuid, p_credito uuid, p_valor numeric
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id   uuid;
  v_hist text := left(trim(coalesce(p_historico, '')), 200);
begin
  if not public.fin_escopo_ok(p_org) then
    raise exception 'Financeiro não disponível para você nesta organização';
  end if;
  if p_data is null then
    raise exception 'Informe a data';
  end if;
  if char_length(v_hist) = 0 then
    raise exception 'Informe o histórico';
  end if;
  if p_valor is null or round(p_valor, 2) <= 0 or p_valor > 999999999999.99 then
    raise exception 'Informe um valor maior que zero';
  end if;
  if p_debito is null or p_credito is null or p_debito = p_credito then
    raise exception 'Escolha duas contas diferentes';
  end if;
  if (select count(*) from public.fin_contas c
      where c.id in (p_debito, p_credito) and c.organizacao_id is not distinct from p_org
        and not c.grupo and c.ativo) <> 2 then
    raise exception 'Escolha contas ativas deste plano que recebem lançamentos';
  end if;
  insert into public.fin_lancamentos (organizacao_id, data, historico, conta_debito, conta_credito, valor, criado_por)
  values (p_org, p_data, v_hist, p_debito, p_credito, round(p_valor, 2), (select auth.uid()))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.fin_lancamento_excluir(p_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org uuid;
begin
  if not exists (select 1 from public.fin_lancamentos where id = p_id) then
    raise exception 'Lançamento não encontrado';
  end if;
  select organizacao_id into v_org from public.fin_lancamentos where id = p_id;
  if not public.fin_escopo_ok(v_org) then
    raise exception 'Lançamento não encontrado';
  end if;
  delete from public.fin_lancamentos where id = p_id;
end;
$$;

-- Balancete: por conta, débitos e créditos antes do período e dentro dele, mais os
-- lançamentos manuais do período. DRE e balanço são montados a partir daqui.
create or replace function public.fin_balancete(p_org uuid, p_ini date, p_fim date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.fin_escopo_ok(p_org) then
    raise exception 'Financeiro não disponível para você nesta organização';
  end if;
  perform public.fin_periodo_ok(p_ini, p_fim);
  perform public.fin_preparar(p_org);
  return jsonb_build_object(
    'contas', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', c.id, 'codigo', c.codigo, 'nome', c.nome, 'tipo', c.tipo, 'grupo', c.grupo, 'caixa', c.caixa,
        'ant_d', coalesce(s.ant_d, 0), 'ant_c', coalesce(s.ant_c, 0),
        'per_d', coalesce(s.per_d, 0), 'per_c', coalesce(s.per_c, 0)) order by public.fin_ordem(c.codigo))
      from public.fin_contas c
      left join (
        select p.conta_id,
               sum(p.debito)  filter (where p.data < p_ini) as ant_d,
               sum(p.credito) filter (where p.data < p_ini) as ant_c,
               sum(p.debito)  filter (where p.data between p_ini and p_fim) as per_d,
               sum(p.credito) filter (where p.data between p_ini and p_fim) as per_c
        from public.fin_partidas(p_org) p group by p.conta_id
      ) s on s.conta_id = c.id
      where c.organizacao_id is not distinct from p_org), '[]'::jsonb),
    'lancamentos', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', l.id, 'data', l.data, 'historico', l.historico, 'valor', l.valor,
        'debito', (select c.codigo || ' ' || c.nome from public.fin_contas c where c.id = l.conta_debito),
        'credito', (select c.codigo || ' ' || c.nome from public.fin_contas c where c.id = l.conta_credito))
        order by l.data desc, l.criado_em desc)
      from public.fin_lancamentos l
      where l.organizacao_id is not distinct from p_org and l.data between p_ini and p_fim), '[]'::jsonb));
end;
$$;

-- Fluxo de caixa: saldo de caixa antes do período, movimentos realizados no
-- período e títulos em aberto com vencimento até o fim dele (para o projetado)
create or replace function public.fin_fluxo(p_org uuid, p_ini date, p_fim date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.fin_escopo_ok(p_org) then
    raise exception 'Financeiro não disponível para você nesta organização';
  end if;
  perform public.fin_periodo_ok(p_ini, p_fim);
  perform public.fin_preparar(p_org);
  return (
    with cx as (
      select p.*, c.nome as conta_nome
      from public.fin_partidas(p_org) p
      join public.fin_contas c on c.id = p.conta_id and c.caixa
    )
    select jsonb_build_object(
      'saldo_anterior', coalesce((select sum(debito - credito) from cx where data < p_ini), 0),
      'saldo_hoje',     coalesce((select sum(debito - credito) from cx where data <= current_date), 0),
      'hoje', current_date,
      'movimentos', coalesce((
        select jsonb_agg(jsonb_build_object('data', data, 'historico', historico, 'conta', conta_nome,
                 'entrada', debito, 'saida', credito, 'origem', origem) order by data, historico)
        from cx where data between p_ini and p_fim), '[]'::jsonb),
      'abertos', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'codigo', case when t.tipo = 'receber' then 'CR-' else 'CP-' end || lpad(t.numero::text, 6, '0'),
                 'tipo', t.tipo, 'descricao', t.descricao, 'pessoa_nome', t.pessoa_nome,
                 'vencimento', t.vencimento, 'valor', t.valor) order by t.vencimento, t.numero)
        from public.fin_titulos t
        where t.organizacao_id is not distinct from p_org and t.status = 'aberto' and t.vencimento <= p_fim), '[]'::jsonb))
  );
end;
$$;

-- Dashboard financeiro do período
create or replace function public.fin_dashboard(p_org uuid, p_ini date, p_fim date)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.fin_escopo_ok(p_org) then
    raise exception 'Financeiro não disponível para você nesta organização';
  end if;
  perform public.fin_periodo_ok(p_ini, p_fim);
  perform public.fin_preparar(p_org);
  return (
    with p as (
      select x.*, c.tipo, c.caixa, c.nome as conta_nome
      from public.fin_partidas(p_org) x join public.fin_contas c on c.id = x.conta_id
    ), t as (
      select * from public.fin_titulos where organizacao_id is not distinct from p_org and status = 'aberto'
    ), meses as (
      select date_trunc('month', p_fim)::date - (n || ' months')::interval as mes from generate_series(5, 0, -1) n
    )
    select jsonb_build_object(
      'saldo_caixa',     coalesce((select sum(debito - credito) from p where caixa and data <= current_date), 0),
      'receber_aberto',  coalesce((select sum(valor) from t where tipo = 'receber'), 0),
      'pagar_aberto',    coalesce((select sum(valor) from t where tipo = 'pagar'), 0),
      'receber_vencido', coalesce((select sum(valor) from t where tipo = 'receber' and vencimento < current_date), 0),
      'pagar_vencido',   coalesce((select sum(valor) from t where tipo = 'pagar' and vencimento < current_date), 0),
      'receber_vencido_qtd', (select count(*) from t where tipo = 'receber' and vencimento < current_date),
      'pagar_vencido_qtd',   (select count(*) from t where tipo = 'pagar' and vencimento < current_date),
      'recebido',  coalesce((select sum(debito)  from p where caixa and origem = 'pagamento' and data between p_ini and p_fim), 0),
      'pago',      coalesce((select sum(credito) from p where caixa and origem = 'pagamento' and data between p_ini and p_fim), 0),
      'receitas',  coalesce((select sum(credito - debito) from p where tipo = 'receita' and data between p_ini and p_fim), 0),
      'despesas',  coalesce((select sum(debito - credito) from p where tipo in ('custo','despesa') and data between p_ini and p_fim), 0),
      'meses', (select jsonb_agg(jsonb_build_object(
                  'mes', to_char(m.mes, 'YYYY-MM'),
                  'receitas', coalesce((select sum(credito - debito) from p where tipo = 'receita' and date_trunc('month', data) = m.mes), 0),
                  'despesas', coalesce((select sum(debito - credito) from p where tipo in ('custo','despesa') and date_trunc('month', data) = m.mes), 0),
                  'entradas', coalesce((select sum(debito)  from p where caixa and date_trunc('month', data) = m.mes), 0),
                  'saidas',   coalesce((select sum(credito) from p where caixa and date_trunc('month', data) = m.mes), 0)
                ) order by m.mes) from meses m),
      'despesas_por_conta', coalesce((
        select jsonb_agg(jsonb_build_object('conta', conta_nome, 'valor', v) order by v desc)
        from (select conta_nome, sum(debito - credito) as v from p
              where tipo in ('custo','despesa') and data between p_ini and p_fim
              group by conta_nome having sum(debito - credito) > 0 order by 2 desc limit 6) d), '[]'::jsonb),
      'proximos', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'codigo', case when x.tipo = 'receber' then 'CR-' else 'CP-' end || lpad(x.numero::text, 6, '0'),
                 'tipo', x.tipo, 'descricao', x.descricao, 'pessoa_nome', x.pessoa_nome,
                 'vencimento', x.vencimento, 'valor', x.valor) order by x.vencimento, x.numero)
        from (select * from t order by vencimento, numero limit 8) x), '[]'::jsonb))
  );
end;
$$;

revoke all on public.fin_contas, public.fin_faturas, public.fin_titulos, public.fin_lancamentos from anon, authenticated;

revoke all on function public.fin_preparar(uuid)                 from public, anon, authenticated;
revoke all on function public.fin_partidas(uuid)                 from public, anon, authenticated;
revoke all on function public.fin_pessoa_ok(uuid, text, uuid)    from public, anon, authenticated;
revoke all on function public.fin_titulo_json(public.fin_titulos) from public, anon, authenticated;
revoke all on function public.fin_fatura_json(public.fin_faturas) from public, anon, authenticated;

revoke all on function public.fin_escopo_ok(uuid)                from public, anon;
revoke all on function public.fin_ordem(text)                    from public, anon;
revoke all on function public.fin_periodo_ok(date, date)         from public, anon;
revoke all on function public.fin_texto(jsonb, text, int)        from public, anon;
revoke all on function public.fin_plano(uuid)                    from public, anon;
revoke all on function public.fin_conta_salvar(uuid, uuid, text, text, text, boolean, boolean, boolean) from public, anon;
revoke all on function public.fin_pessoas(uuid)                  from public, anon;
revoke all on function public.fin_titulos_listar(uuid, text, date, date, text, text) from public, anon;
revoke all on function public.fin_titulo_salvar(uuid, uuid, jsonb) from public, anon;
revoke all on function public.fin_titulo_baixar(uuid, date, uuid, text) from public, anon;
revoke all on function public.fin_titulo_estornar(uuid)          from public, anon;
revoke all on function public.fin_titulo_cancelar(uuid)          from public, anon;
revoke all on function public.fin_fatura_emitir(uuid, jsonb)     from public, anon;
revoke all on function public.fin_fatura_cancelar(uuid)          from public, anon;
revoke all on function public.fin_fatura_ver(uuid)               from public, anon;
revoke all on function public.fin_lancamento_salvar(uuid, date, text, uuid, uuid, numeric) from public, anon;
revoke all on function public.fin_lancamento_excluir(uuid)       from public, anon;
revoke all on function public.fin_balancete(uuid, date, date)    from public, anon;
revoke all on function public.fin_fluxo(uuid, date, date)        from public, anon;
revoke all on function public.fin_dashboard(uuid, date, date)    from public, anon;

grant execute on function public.fin_escopo_ok(uuid)                to authenticated;
grant execute on function public.fin_ordem(text)                    to authenticated;
grant execute on function public.fin_periodo_ok(date, date)         to authenticated;
grant execute on function public.fin_texto(jsonb, text, int)        to authenticated;
grant execute on function public.fin_plano(uuid)                    to authenticated;
grant execute on function public.fin_conta_salvar(uuid, uuid, text, text, text, boolean, boolean, boolean) to authenticated;
grant execute on function public.fin_pessoas(uuid)                  to authenticated;
grant execute on function public.fin_titulos_listar(uuid, text, date, date, text, text) to authenticated;
grant execute on function public.fin_titulo_salvar(uuid, uuid, jsonb) to authenticated;
grant execute on function public.fin_titulo_baixar(uuid, date, uuid, text) to authenticated;
grant execute on function public.fin_titulo_estornar(uuid)          to authenticated;
grant execute on function public.fin_titulo_cancelar(uuid)          to authenticated;
grant execute on function public.fin_fatura_emitir(uuid, jsonb)     to authenticated;
grant execute on function public.fin_fatura_cancelar(uuid)          to authenticated;
grant execute on function public.fin_fatura_ver(uuid)               to authenticated;
grant execute on function public.fin_lancamento_salvar(uuid, date, text, uuid, uuid, numeric) to authenticated;
grant execute on function public.fin_lancamento_excluir(uuid)       to authenticated;
grant execute on function public.fin_balancete(uuid, date, date)    to authenticated;
grant execute on function public.fin_fluxo(uuid, date, date)        to authenticated;
grant execute on function public.fin_dashboard(uuid, date, date)    to authenticated;

-- =====================================================================
-- 13) PRIMEIRO USUÁRIO MASTER
--    Depois de criar o usuário em Authentication > Users, troque o e-mail e o nome,
--    tire os dois traços do início das linhas e rode:
-- =====================================================================
-- insert into public.usuarios (user_id, nome, email, perfil)
-- select id, 'Seu nome', email, 'master' from auth.users where email = 'seu-email@empresa.com.br'
-- on conflict (user_id) do nothing;
