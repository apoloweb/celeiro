-- Celeiro Administradora · estrutura do site no Supabase
-- Rode este arquivo inteiro em: painel do Supabase > SQL Editor > New query > Run.
-- Pode ser rodado mais de uma vez sem duplicar nada.

-- 1) Quem pode administrar o site
create table if not exists public.administradores (
  user_id   uuid primary key references auth.users(id) on delete cascade,
  criado_em timestamptz not null default now()
);

-- 2) Textos do site (uma única linha, id = 'principal')
create table if not exists public.site_conteudo (
  id            text primary key default 'principal' check (id = 'principal'),
  dados         jsonb not null,
  atualizado_em timestamptz not null default now()
);

-- 3) Cadastro de conexões MCP (configuração; não guardar senhas ou tokens)
create table if not exists public.mcp_conexoes (
  id        uuid primary key default gen_random_uuid(),
  nome      text not null check (char_length(nome) between 1 and 80),
  url       text not null check (url ~ '^https://' and char_length(url) <= 300),
  descricao text not null default '' check (char_length(descricao) <= 400),
  modulos   text[] not null default '{}',
  perfis    text[] not null default '{}',
  acesso    text not null default 'Somente leitura'
            check (acesso in ('Somente leitura', 'Leitura e escrita')),
  ativo     boolean not null default true,
  criado_em timestamptz not null default now()
);

alter table public.administradores enable row level security;
alter table public.site_conteudo   enable row level security;
alter table public.mcp_conexoes    enable row level security;

-- 4) Regra central: é administrador E entrou com as duas etapas (senha + Google Authenticator)
create or replace function public.eh_admin_2fa()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce((select auth.jwt() ->> 'aal') = 'aal2', false)
     and exists (
       select 1 from public.administradores a
       where a.user_id = (select auth.uid())
     );
$$;

revoke all on function public.eh_admin_2fa() from public;
grant execute on function public.eh_admin_2fa() to authenticated;

-- 5) Permissões de tabela
grant select on public.site_conteudo to anon, authenticated;
grant insert, update, delete on public.site_conteudo to authenticated;
grant select on public.administradores to authenticated;
grant select, insert, update, delete on public.mcp_conexoes to authenticated;

-- 6) Políticas
drop policy if exists "admin ve o proprio registro" on public.administradores;
create policy "admin ve o proprio registro" on public.administradores
  for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists "todos leem o conteudo" on public.site_conteudo;
create policy "todos leem o conteudo" on public.site_conteudo
  for select to anon, authenticated
  using (true);

drop policy if exists "admin 2fa insere conteudo" on public.site_conteudo;
create policy "admin 2fa insere conteudo" on public.site_conteudo
  for insert to authenticated
  with check (public.eh_admin_2fa());

drop policy if exists "admin 2fa altera conteudo" on public.site_conteudo;
create policy "admin 2fa altera conteudo" on public.site_conteudo
  for update to authenticated
  using (public.eh_admin_2fa())
  with check (public.eh_admin_2fa());

drop policy if exists "admin 2fa apaga conteudo" on public.site_conteudo;
create policy "admin 2fa apaga conteudo" on public.site_conteudo
  for delete to authenticated
  using (public.eh_admin_2fa());

drop policy if exists "admin 2fa gerencia mcp" on public.mcp_conexoes;
create policy "admin 2fa gerencia mcp" on public.mcp_conexoes
  for all to authenticated
  using (public.eh_admin_2fa())
  with check (public.eh_admin_2fa());

-- 7) Depois de criar o usuário em Authentication > Users, torne-o administrador.
--    Troque o e-mail abaixo, tire os dois traços do início das linhas e rode:
-- insert into public.administradores (user_id)
-- select id from auth.users where email = 'seu-email@empresa.com.br'
-- on conflict do nothing;
