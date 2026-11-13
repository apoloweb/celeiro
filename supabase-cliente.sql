-- Site Celeiro · área do cliente (experiência web do aplicativo)
-- Contas de clientes, vídeos, abaixo-assinados, assinaturas e solicitações de serviço.
--
-- Rode no projeto Supabase do SITE, depois do supabase.sql (SQL Editor > New query > Run).
-- Pode ser rodado mais de uma vez sem duplicar nada.

-- =====================================================================
-- 1) TABELAS
-- =====================================================================

-- Dados do cliente (o e-mail e a senha ficam no cadastro de acesso do Supabase)
create table if not exists public.clientes (
  user_id       uuid primary key references auth.users(id) on delete cascade,
  nome          text not null check (char_length(nome) between 3 and 120),
  telefone      text check (telefone is null or char_length(telefone) <= 30),
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now()
);

create table if not exists public.videos (
  id         uuid primary key default gen_random_uuid(),
  titulo     text not null check (char_length(titulo) between 1 and 160),
  descricao  text not null default '' check (char_length(descricao) <= 4000),
  categoria  text not null default 'Institucional' check (char_length(categoria) between 1 and 40),
  origem     text not null check (origem in ('link', 'arquivo')),
  url        text check (url is null or (url ~ '^https://' and char_length(url) <= 500)),
  arquivo    text check (arquivo is null or char_length(arquivo) <= 300),
  publicado  boolean not null default true,
  criado_em  timestamptz not null default now(),
  constraint videos_origem check (
    (origem = 'link' and url is not null) or (origem = 'arquivo' and arquivo is not null)
  )
);

create table if not exists public.abaixo_assinados (
  id        uuid primary key default gen_random_uuid(),
  titulo    text not null check (char_length(titulo) between 1 and 160),
  resumo    text not null default '' check (char_length(resumo) <= 300),
  texto     text not null check (char_length(texto) between 1 and 8000),
  meta      int  not null check (meta > 0),
  prazo     date not null,
  aberto    boolean not null default true,
  criado_em timestamptz not null default now()
);

create table if not exists public.assinaturas (
  id        uuid primary key default gen_random_uuid(),
  abaixo_id uuid not null references public.abaixo_assinados(id) on delete restrict,
  user_id   uuid not null references auth.users(id) on delete restrict,
  nome      text not null,
  cpf       text not null,
  protocolo text not null unique,
  ip        text,
  criado_em timestamptz not null default now(),
  unique (abaixo_id, user_id),
  unique (abaixo_id, cpf)
);

create table if not exists public.solicitacoes (
  id             uuid primary key default gen_random_uuid(),
  user_id        uuid not null default auth.uid() references auth.users(id) on delete cascade,
  tipo           text not null check (tipo in ('conta_digital', 'cotacao_veicular', 'migracao_energia')),
  dados          jsonb not null default '{}'::jsonb check (length(dados::text) <= 8000),
  protocolo      text not null check (char_length(protocolo) between 4 and 40),
  enviado_office boolean not null default false,
  criado_em      timestamptz not null default now()
);

create index if not exists assinaturas_abaixo_data on public.assinaturas (abaixo_id, criado_em desc);
create index if not exists solicitacoes_user_data on public.solicitacoes (user_id, criado_em desc);

alter table public.clientes         enable row level security;
alter table public.videos           enable row level security;
alter table public.abaixo_assinados enable row level security;
alter table public.assinaturas      enable row level security;
alter table public.solicitacoes     enable row level security;

-- =====================================================================
-- 2) FUNÇÕES DE APOIO
-- =====================================================================

-- Está logado e já confirmou o e-mail
create or replace function public.acesso_confirmado()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from auth.users u
    where u.id = (select auth.uid()) and u.email_confirmed_at is not null
  );
$$;

-- Confere os dois dígitos verificadores do CPF
create or replace function public.cpf_valido(p_cpf text)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  d text := regexp_replace(coalesce(p_cpf, ''), '[^0-9]', '', 'g');
  s int; r int; i int;
begin
  if length(d) <> 11 or d ~ '^(.)\1{10}$' then
    return false;
  end if;
  s := 0;
  for i in 1..9 loop s := s + substr(d, i, 1)::int * (11 - i); end loop;
  r := (s * 10) % 11; if r = 10 then r := 0; end if;
  if r <> substr(d, 10, 1)::int then return false; end if;
  s := 0;
  for i in 1..10 loop s := s + substr(d, i, 1)::int * (12 - i); end loop;
  r := (s * 10) % 11; if r = 10 then r := 0; end if;
  return r = substr(d, 11, 1)::int;
end;
$$;

-- "Marina Lopes da Silva" vira "Marina S." na lista pública de assinantes
create or replace function public.nome_curto(p_nome text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when array_length(p, 1) is null then 'Assinante'
    when array_length(p, 1) = 1 then p[1]
    else p[1] || ' ' || upper(left(p[array_length(p, 1)], 1)) || '.'
  end
  from (select regexp_split_to_array(trim(coalesce(p_nome, '')), '\s+') as p) x;
$$;

-- =====================================================================
-- 3) ABAIXO-ASSINADOS
-- =====================================================================

-- Lista para o cliente: totais, se ele já assinou e as últimas assinaturas (nomes abreviados)
create or replace function public.abaixo_listar()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.acesso_confirmado() then
    raise exception 'Acesso negado';
  end if;
  return coalesce((
    select jsonb_agg(x.j order by x.aberto desc, x.prazo, x.criado_em desc)
    from (
      select a.aberto, a.prazo, a.criado_em,
        jsonb_build_object(
          'id', a.id, 'titulo', a.titulo, 'resumo', a.resumo, 'texto', a.texto,
          'meta', a.meta, 'prazo', a.prazo,
          'aberto', a.aberto and a.prazo >= (now() at time zone 'America/Sao_Paulo')::date,
          'total', (select count(*) from public.assinaturas s where s.abaixo_id = a.id),
          'minha', (select jsonb_build_object('protocolo', s.protocolo, 'data', s.criado_em)
                    from public.assinaturas s where s.abaixo_id = a.id and s.user_id = (select auth.uid())),
          'ultimas', coalesce((
            select jsonb_agg(jsonb_build_object('nome', public.nome_curto(u.nome), 'data', u.criado_em) order by u.criado_em desc)
            from (select s.nome, s.criado_em from public.assinaturas s
                  where s.abaixo_id = a.id order by s.criado_em desc limit 5) u), '[]'::jsonb)
        ) as j
      from public.abaixo_assinados a
    ) x), '[]'::jsonb);
end;
$$;

-- Assina. Uma assinatura por conta e por CPF em cada abaixo-assinado.
create or replace function public.assinar(p_id uuid, p_cpf text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := (select auth.uid());
  v_nome text;
  v_cpf  text := regexp_replace(coalesce(p_cpf, ''), '[^0-9]', '', 'g');
  v_a    public.abaixo_assinados%rowtype;
  v_prot text;
  v_ip   text;
  v_em   timestamptz;
begin
  if not public.acesso_confirmado() then
    raise exception 'Acesso negado';
  end if;
  select nome into v_nome from public.clientes where user_id = v_user;
  if v_nome is null then
    raise exception 'Complete o seu cadastro antes de assinar';
  end if;
  if not public.cpf_valido(v_cpf) then
    raise exception 'CPF inválido';
  end if;
  select * into v_a from public.abaixo_assinados where id = p_id;
  if v_a.id is null then
    raise exception 'Abaixo-assinado não encontrado';
  end if;
  if not v_a.aberto or v_a.prazo < (now() at time zone 'America/Sao_Paulo')::date then
    raise exception 'Este abaixo-assinado está encerrado';
  end if;
  if exists (select 1 from public.assinaturas where abaixo_id = p_id and user_id = v_user) then
    raise exception 'Você já assinou este abaixo-assinado';
  end if;
  if exists (select 1 from public.assinaturas where abaixo_id = p_id and cpf = v_cpf) then
    raise exception 'Este CPF já assinou este abaixo-assinado';
  end if;

  begin
    v_ip := split_part(current_setting('request.headers', true)::json ->> 'x-forwarded-for', ',', 1);
  exception when others then
    v_ip := null;
  end;
  v_prot := 'CEL-' || to_char(now() at time zone 'America/Sao_Paulo', 'YYYY') || '-' ||
            upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));

  insert into public.assinaturas (abaixo_id, user_id, nome, cpf, protocolo, ip)
  values (p_id, v_user, v_nome, v_cpf, v_prot, nullif(trim(v_ip), ''))
  returning criado_em into v_em;

  return jsonb_build_object('protocolo', v_prot, 'data', v_em);
end;
$$;

-- =====================================================================
-- 4) PERMISSÕES
-- =====================================================================

revoke all on public.clientes, public.videos, public.abaixo_assinados, public.assinaturas, public.solicitacoes from anon, authenticated;

grant select, insert on public.clientes to authenticated;
grant update (nome, telefone, atualizado_em) on public.clientes to authenticated;
grant select, insert, update, delete on public.videos to authenticated;
grant select, insert, update on public.abaixo_assinados to authenticated;
grant select on public.assinaturas to authenticated;
grant select, insert on public.solicitacoes to authenticated;
grant update (enviado_office) on public.solicitacoes to authenticated;

revoke all on function public.acesso_confirmado()  from public, anon;
revoke all on function public.abaixo_listar()      from public, anon;
revoke all on function public.assinar(uuid, text)  from public, anon;
grant execute on function public.acesso_confirmado() to authenticated;
grant execute on function public.abaixo_listar()     to authenticated;
grant execute on function public.assinar(uuid, text) to authenticated;
grant execute on function public.cpf_valido(text)    to authenticated;
grant execute on function public.nome_curto(text)    to authenticated;

-- =====================================================================
-- 5) REGRAS DE ACESSO POR LINHA
--    Cliente: só com o e-mail confirmado, e só os próprios dados.
--    Conteúdo: quem grava é administrador do site com as duas etapas de login.
-- =====================================================================

drop policy if exists "cliente le o proprio cadastro" on public.clientes;
create policy "cliente le o proprio cadastro" on public.clientes
  for select to authenticated
  using (user_id = (select auth.uid()) or (select public.eh_admin_2fa()));

drop policy if exists "cliente cria o proprio cadastro" on public.clientes;
create policy "cliente cria o proprio cadastro" on public.clientes
  for insert to authenticated
  with check (user_id = (select auth.uid()) and (select public.acesso_confirmado()));

drop policy if exists "cliente altera o proprio cadastro" on public.clientes;
create policy "cliente altera o proprio cadastro" on public.clientes
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

drop policy if exists "clientes veem videos publicados" on public.videos;
create policy "clientes veem videos publicados" on public.videos
  for select to authenticated
  using (((select public.acesso_confirmado()) and publicado) or (select public.eh_admin_2fa()));

drop policy if exists "admin 2fa gerencia videos" on public.videos;
create policy "admin 2fa gerencia videos" on public.videos
  for all to authenticated
  using ((select public.eh_admin_2fa()))
  with check ((select public.eh_admin_2fa()));

drop policy if exists "clientes veem abaixo-assinados" on public.abaixo_assinados;
create policy "clientes veem abaixo-assinados" on public.abaixo_assinados
  for select to authenticated
  using ((select public.acesso_confirmado()) or (select public.eh_admin_2fa()));

drop policy if exists "admin 2fa cria abaixo-assinados" on public.abaixo_assinados;
create policy "admin 2fa cria abaixo-assinados" on public.abaixo_assinados
  for insert to authenticated
  with check ((select public.eh_admin_2fa()));

drop policy if exists "admin 2fa altera abaixo-assinados" on public.abaixo_assinados;
create policy "admin 2fa altera abaixo-assinados" on public.abaixo_assinados
  for update to authenticated
  using ((select public.eh_admin_2fa()))
  with check ((select public.eh_admin_2fa()));

-- Assinatura só entra pela função assinar; ninguém altera nem apaga
drop policy if exists "assinante ve a propria assinatura" on public.assinaturas;
create policy "assinante ve a propria assinatura" on public.assinaturas
  for select to authenticated
  using (user_id = (select auth.uid()) or (select public.eh_admin_2fa()));

drop policy if exists "cliente ve as proprias solicitacoes" on public.solicitacoes;
create policy "cliente ve as proprias solicitacoes" on public.solicitacoes
  for select to authenticated
  using (user_id = (select auth.uid()) or (select public.eh_admin_2fa()));

drop policy if exists "cliente cria solicitacao" on public.solicitacoes;
create policy "cliente cria solicitacao" on public.solicitacoes
  for insert to authenticated
  with check (user_id = (select auth.uid()) and (select public.acesso_confirmado()));

drop policy if exists "cliente marca envio ao office" on public.solicitacoes;
create policy "cliente marca envio ao office" on public.solicitacoes
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

-- =====================================================================
-- 6) ARQUIVOS DE VÍDEO (Storage)
--    Pasta privada: cliente assiste por link temporário; só administrador envia e apaga.
-- =====================================================================

insert into storage.buckets (id, name, public)
values ('videos', 'videos', false)
on conflict (id) do nothing;

drop policy if exists "clientes assistem videos" on storage.objects;
create policy "clientes assistem videos" on storage.objects
  for select to authenticated
  using (bucket_id = 'videos' and ((select public.acesso_confirmado()) or (select public.eh_admin_2fa())));

drop policy if exists "admin 2fa envia videos" on storage.objects;
create policy "admin 2fa envia videos" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'videos' and (select public.eh_admin_2fa()));

drop policy if exists "admin 2fa apaga videos" on storage.objects;
create policy "admin 2fa apaga videos" on storage.objects
  for delete to authenticated
  using (bucket_id = 'videos' and (select public.eh_admin_2fa()));
