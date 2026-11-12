-- Celeiro Office · backoffice · estrutura no Supabase
-- (acesso, perfis, módulos, níveis de permissão, auditoria e Workflow)
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
-- 9) PRIMEIRO USUÁRIO MASTER
--    Depois de criar o usuário em Authentication > Users, troque o e-mail e o nome,
--    tire os dois traços do início das linhas e rode:
-- =====================================================================
-- insert into public.usuarios (user_id, nome, email, perfil)
-- select id, 'Seu nome', email, 'master' from auth.users where email = 'seu-email@empresa.com.br'
-- on conflict (user_id) do nothing;
