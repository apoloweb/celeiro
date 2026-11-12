-- Celeiro Office · integração com o aplicativo
-- Recebe do app: instalações, leads, solicitações de abertura de conta,
-- cotações veiculares e pedidos de migração de energia. Controla também
-- quais módulos do app estão ligados.
--
-- Rode DEPOIS do supabase.sql, no mesmo projeto (SQL Editor > New query > Run).
-- Pode ser rodado mais de uma vez sem duplicar nada.

-- =====================================================================
-- 1) MÓDULO NO BACKOFFICE
-- =====================================================================

insert into public.modulos (codigo, nome, ordem, fase) values
  ('app', 'Aplicativo', 9, 2)
on conflict (codigo) do update
  set nome = excluded.nome, ordem = excluded.ordem, fase = excluded.fase;

-- =====================================================================
-- 2) TABELAS
-- =====================================================================

-- Módulos do aplicativo (o que aparece para quem usa o app)
create table if not exists public.app_modulos (
  codigo        text primary key,
  nome          text not null,
  ordem         int  not null,
  habilitado    boolean not null default true,
  atualizado_em timestamptz not null default now()
);

insert into public.app_modulos (codigo, nome, ordem) values
  ('videos',      'Vídeos',               1),
  ('assinaturas', 'Abaixo-assinados',     2),
  ('veicular',    'Aquisição Veicular',   3),
  ('energia',     'Energia com Desconto', 4),
  ('conta',       'Conta digital',        5)
on conflict (codigo) do update
  set nome = excluded.nome, ordem = excluded.ordem;

-- Instalações: uma linha por aparelho que abriu o app pela primeira vez
create table if not exists public.app_instalacoes (
  dispositivo_id text primary key,
  plataforma     text,
  versao         text,
  teste          boolean not null default false,
  primeira_em    timestamptz not null default now(),
  ultima_em      timestamptz not null default now()
);

-- Solicitações e leads vindos do app
create table if not exists public.app_solicitacoes (
  id             uuid primary key default gen_random_uuid(),
  tipo           text not null check (tipo in ('lead','conta_digital','cotacao_veicular','migracao_energia')),
  dispositivo_id text not null,
  nome           text,
  telefone       text,
  email          text,
  documento      text,
  dados          jsonb not null default '{}'::jsonb,
  teste          boolean not null default false,
  status         text not null default 'novo' check (status in ('novo','em_atendimento','concluido','descartado')),
  criado_em      timestamptz not null default now(),
  atualizado_em  timestamptz not null default now()
);

create index if not exists app_solicitacoes_tipo_data on public.app_solicitacoes (tipo, criado_em desc);
create index if not exists app_solicitacoes_dispositivo on public.app_solicitacoes (dispositivo_id, criado_em desc);

alter table public.app_modulos      enable row level security;
alter table public.app_instalacoes  enable row level security;
alter table public.app_solicitacoes enable row level security;

-- =====================================================================
-- 3) O QUE O APP CHAMA (sem login no backoffice)
-- =====================================================================

-- Módulos ligados, para o app montar o menu
create or replace function public.app_config()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object('modulos',
    coalesce(jsonb_agg(jsonb_build_object('codigo', m.codigo, 'nome', m.nome, 'habilitado', m.habilitado) order by m.ordem), '[]'::jsonb))
  from public.app_modulos m;
$$;

-- Registra uma instalação, um lead ou uma solicitação.
-- p_tipo: instalacao | lead | conta_digital | cotacao_veicular | migracao_energia
-- p_dispositivo: identificador gerado pelo app no primeiro uso
-- p_dados: campos do formulário (nome, telefone, email, documento e os demais)
create or replace function public.app_registrar(p_tipo text, p_dispositivo text, p_dados jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_dados  jsonb := coalesce(p_dados, '{}'::jsonb);
  v_teste  boolean := coalesce((v_dados ->> 'teste')::boolean, false);
  v_modulo text;
  v_id     uuid;
begin
  if p_dispositivo is null or length(p_dispositivo) < 8 or length(p_dispositivo) > 64 then
    raise exception 'Identificador do aparelho inválido.';
  end if;
  if jsonb_typeof(v_dados) <> 'object' or length(v_dados::text) > 8000 then
    raise exception 'Dados inválidos.';
  end if;

  if p_tipo = 'instalacao' then
    insert into public.app_instalacoes (dispositivo_id, plataforma, versao, teste)
    values (p_dispositivo, left(v_dados ->> 'plataforma', 40), left(v_dados ->> 'versao', 20), v_teste)
    on conflict (dispositivo_id) do update set ultima_em = now(), versao = excluded.versao;
    return jsonb_build_object('ok', true);
  end if;

  if p_tipo not in ('lead','conta_digital','cotacao_veicular','migracao_energia') then
    raise exception 'Tipo de registro desconhecido.';
  end if;

  -- Módulo do app desligado não recebe solicitação
  v_modulo := case p_tipo when 'conta_digital' then 'conta' when 'cotacao_veicular' then 'veicular' when 'migracao_energia' then 'energia' end;
  if v_modulo is not null and not exists (select 1 from public.app_modulos where codigo = v_modulo and habilitado) then
    raise exception 'Este serviço não está disponível no momento.';
  end if;

  -- Freio contra envio em massa: 20 registros por aparelho por hora
  if (select count(*) from public.app_solicitacoes
      where dispositivo_id = p_dispositivo and criado_em > now() - interval '1 hour') >= 20 then
    raise exception 'Muitos envios em pouco tempo. Tente mais tarde.';
  end if;

  insert into public.app_solicitacoes (tipo, dispositivo_id, nome, telefone, email, documento, dados, teste)
  values (p_tipo, p_dispositivo,
          left(v_dados ->> 'nome', 160), left(v_dados ->> 'telefone', 30),
          left(v_dados ->> 'email', 160), left(v_dados ->> 'documento', 20),
          v_dados - 'nome' - 'telefone' - 'email' - 'documento' - 'teste', v_teste)
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- =====================================================================
-- 4) O QUE A TELA DO BACKOFFICE CHAMA
-- =====================================================================

-- Pode ver os dados do app: equipe Celeiro com o módulo Aplicativo habilitado
create or replace function public.pode_app()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.eh_equipe() and public.pode_modulo('app');
$$;

-- Totais para o topo da tela (registros de teste ficam de fora)
create or replace function public.app_resumo()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.pode_app() then
    raise exception 'Sem permissão para o módulo Aplicativo.';
  end if;
  return jsonb_build_object(
    'instalacoes',    (select count(*) from public.app_instalacoes where not teste),
    'instalacoes_7d', (select count(*) from public.app_instalacoes where not teste and primeira_em > now() - interval '7 days'),
    'tipos', coalesce((
      select jsonb_object_agg(t.tipo, jsonb_build_object('total', t.total, 'novos', t.novos))
      from (select tipo, count(*) as total, count(*) filter (where status = 'novo') as novos
            from public.app_solicitacoes where not teste group by tipo) t), '{}'::jsonb));
end;
$$;

-- Muda a situação de uma solicitação
create or replace function public.app_definir_status(p_id uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.pode_app() then
    raise exception 'Sem permissão para o módulo Aplicativo.';
  end if;
  if p_status not in ('novo','em_atendimento','concluido','descartado') then
    raise exception 'Situação desconhecida.';
  end if;
  update public.app_solicitacoes set status = p_status, atualizado_em = now() where id = p_id;
  if not found then
    raise exception 'Solicitação não encontrada.';
  end if;
end;
$$;

-- Liga ou desliga um módulo do app (somente Master)
create or replace function public.app_definir_modulo(p_codigo text, p_habilitado boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.eh_master() then
    raise exception 'Somente o perfil Master altera os módulos do aplicativo.';
  end if;
  update public.app_modulos set habilitado = p_habilitado, atualizado_em = now() where codigo = p_codigo;
  if not found then
    raise exception 'Módulo do aplicativo não encontrado.';
  end if;
end;
$$;

-- =====================================================================
-- 5) AUDITORIA (o que a equipe altera; o que chega do app não tem usuário)
-- =====================================================================

drop trigger if exists auditar_app_solicitacoes on public.app_solicitacoes;
create trigger auditar_app_solicitacoes
  after update or delete on public.app_solicitacoes
  for each row execute function public.auditar('Aplicativo');

drop trigger if exists auditar_app_modulos on public.app_modulos;
create trigger auditar_app_modulos
  after update or delete on public.app_modulos
  for each row execute function public.auditar('Aplicativo');

-- =====================================================================
-- 6) PERMISSÕES
-- =====================================================================

revoke all on public.app_modulos, public.app_instalacoes, public.app_solicitacoes from anon, authenticated;
grant select on public.app_modulos, public.app_instalacoes, public.app_solicitacoes to authenticated;

revoke all on function public.app_config()                        from public;
revoke all on function public.app_registrar(text, text, jsonb)    from public;
revoke all on function public.pode_app()                          from public, anon;
revoke all on function public.app_resumo()                        from public, anon;
revoke all on function public.app_definir_status(uuid, text)      from public, anon;
revoke all on function public.app_definir_modulo(text, boolean)   from public, anon;

-- O app chama estas duas com a chave pública, sem login
grant execute on function public.app_config()                     to anon, authenticated;
grant execute on function public.app_registrar(text, text, jsonb) to anon, authenticated;

grant execute on function public.pode_app()                        to authenticated;
grant execute on function public.app_resumo()                      to authenticated;
grant execute on function public.app_definir_status(uuid, text)    to authenticated;
grant execute on function public.app_definir_modulo(text, boolean) to authenticated;

-- =====================================================================
-- 7) REGRAS DE ACESSO POR LINHA
--    Leitura só para a equipe Celeiro com o módulo habilitado e as duas etapas de login.
--    Gravação só pelas funções acima.
-- =====================================================================

drop policy if exists "app_modulos leitura" on public.app_modulos;
create policy "app_modulos leitura" on public.app_modulos
  for select to authenticated using ((select public.pode_app()));

drop policy if exists "app_instalacoes leitura" on public.app_instalacoes;
create policy "app_instalacoes leitura" on public.app_instalacoes
  for select to authenticated using ((select public.pode_app()));

drop policy if exists "app_solicitacoes leitura" on public.app_solicitacoes;
create policy "app_solicitacoes leitura" on public.app_solicitacoes
  for select to authenticated using ((select public.pode_app()));
