-- Celeiro Office · backoffice · estrutura no Supabase (fase 1 + criação de usuários e níveis de permissão)
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
-- 7) PRIMEIRO USUÁRIO MASTER
--    Depois de criar o usuário em Authentication > Users, troque o e-mail e o nome,
--    tire os dois traços do início das linhas e rode:
-- =====================================================================
-- insert into public.usuarios (user_id, nome, email, perfil)
-- select id, 'Seu nome', email, 'master' from auth.users where email = 'seu-email@empresa.com.br'
-- on conflict (user_id) do nothing;
