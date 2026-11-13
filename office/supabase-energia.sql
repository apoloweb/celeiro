-- Celeiro Office · módulo Energia
-- Comercialização de energia: unidades consumidoras, contratos, apuração mensal
-- (consumo, faturamento e economia) e funil de migração para o mercado livre.
--
-- Rode DEPOIS do supabase.sql, no mesmo projeto (SQL Editor > New query > Run).
-- Se usar a integração com o aplicativo, rode também DEPOIS do supabase-app.sql:
-- assim os pedidos de "Energia com Desconto" do app entram sozinhos no funil de migração.
-- Pode ser rodado mais de uma vez sem duplicar nada.
--
-- Regras de acesso (as mesmas do Cadastro):
--   * Quem tem o módulo Energia vê e altera.
--   * Equipe Celeiro (Master e Gerencial) vê tudo; cada cliente corporativo vê só o da própria organização.
--   * O funil de migração é só da equipe Celeiro.
--   * Nada é apagado: unidades e contratos são inativados ou encerrados.
--   * Toda gravação passa pelas funções abaixo e entra na Auditoria.

-- =====================================================================
-- 1) MÓDULO NO BACKOFFICE
-- =====================================================================

insert into public.modulos (codigo, nome, ordem, fase) values
  ('energia', 'Energia', 10, 3)
on conflict (codigo) do update
  set nome = excluded.nome, ordem = excluded.ordem, fase = excluded.fase;

-- =====================================================================
-- 2) TABELAS
-- =====================================================================

-- Unidades consumidoras (UC): o ponto de consumo de um cliente na distribuidora
create table if not exists public.energia_unidades (
  id                  uuid primary key default gen_random_uuid(),
  organizacao_id      uuid references public.organizacoes(id) on delete cascade,
  situacao            text not null default 'ativo' check (situacao in ('ativo','inativo')),
  -- titular: uma pessoa física ou jurídica do Cadastro
  titular_pf_id       uuid references public.cadastro_pf(id),
  titular_pj_id       uuid references public.cadastro_pj(id),
  -- identificação na distribuidora
  apelido             text not null default '' check (char_length(apelido) <= 120),
  codigo_instalacao   text not null check (char_length(codigo_instalacao) between 1 and 40),
  distribuidora       text not null check (char_length(distribuidora) between 1 and 120),
  -- classificação tarifária
  grupo               text not null default 'B' check (grupo in ('A','B')),
  subgrupo            text not null default '' check (subgrupo in ('','A1','A2','A3','A3a','A4','AS','B1','B2','B3','B4')),
  modalidade          text not null default '' check (modalidade in ('','azul','verde','convencional','branca')),
  ambiente            text not null default 'cativo' check (ambiente in ('cativo','em_migracao','livre','gd')),
  demanda_ponta_kw    numeric(12,2) check (demanda_ponta_kw is null or demanda_ponta_kw >= 0),
  demanda_fora_kw     numeric(12,2) check (demanda_fora_kw is null or demanda_fora_kw >= 0),
  consumo_medio_kwh   numeric(14,2) check (consumo_medio_kwh is null or consumo_medio_kwh >= 0),
  -- endereço da unidade
  cep                 text not null default '' check (cep ~ '^([0-9]{8})?$'),
  logradouro          text not null default '' check (char_length(logradouro) <= 160),
  numero              text not null default '' check (char_length(numero) <= 20),
  complemento         text not null default '' check (char_length(complemento) <= 80),
  bairro              text not null default '' check (char_length(bairro) <= 100),
  cidade              text not null default '' check (char_length(cidade) <= 100),
  uf                  text not null default '' check (uf in ('','AC','AL','AP','AM','BA','CE','DF','ES','GO','MA','MT','MS','MG','PA','PB','PR','PE','PI','RJ','RN','RS','RO','RR','SC','SP','SE','TO')),
  observacoes         text not null default '' check (char_length(observacoes) <= 2000),
  -- controle
  criado_por          uuid references public.usuarios(user_id) on delete set null,
  criado_em           timestamptz not null default now(),
  atualizado_por      uuid references public.usuarios(user_id) on delete set null,
  atualizado_em       timestamptz not null default now(),
  constraint energia_unidades_um_titular check (num_nonnulls(titular_pf_id, titular_pj_id) = 1)
);

create unique index if not exists energia_unidades_instalacao_unica
  on public.energia_unidades (lower(distribuidora), codigo_instalacao);
create index if not exists energia_unidades_org on public.energia_unidades (organizacao_id);

-- Contratos de energia (venda ao cliente ou compra de um fornecedor/gerador)
create sequence if not exists public.energia_contratos_numero_seq;

create table if not exists public.energia_contratos (
  id                  uuid primary key default gen_random_uuid(),
  numero              int not null default nextval('public.energia_contratos_numero_seq'),
  organizacao_id      uuid references public.organizacoes(id) on delete cascade,
  tipo                text not null default 'venda' check (tipo in ('venda','compra')),
  produto             text not null default 'acl' check (produto in ('acl','gd')),
  -- contraparte: na venda, o cliente do Cadastro; na compra, o fornecedor ou gerador
  cliente_pf_id       uuid references public.cadastro_pf(id),
  cliente_pj_id       uuid references public.cadastro_pj(id),
  contraparte         text not null default '' check (char_length(contraparte) <= 160),
  status              text not null default 'rascunho'
                      check (status in ('rascunho','assinado','vigente','encerrado','cancelado')),
  inicio              date not null,
  fim                 date not null,
  -- condições comerciais
  volume_mwh_mes      numeric(14,3) check (volume_mwh_mes is null or volume_mwh_mes >= 0),
  preco_mwh           numeric(14,2) check (preco_mwh is null or preco_mwh >= 0),
  desconto_pct        numeric(5,2)  check (desconto_pct is null or desconto_pct between 0 and 100),
  flex_pct            numeric(5,2)  check (flex_pct is null or flex_pct between 0 and 100),
  sazo_pct            numeric(5,2)  check (sazo_pct is null or sazo_pct between 0 and 100),
  submercado          text not null default '' check (submercado in ('','SE/CO','S','NE','N')),
  fonte               text not null default '' check (fonte in ('','convencional','incentivada_50','incentivada_100','solar','eolica','hidrica','biomassa')),
  indice_reajuste     text not null default '' check (indice_reajuste in ('','IPCA','IGP-M','nenhum')),
  data_base_reajuste  date,
  observacoes         text not null default '' check (char_length(observacoes) <= 2000),
  -- controle
  criado_por          uuid references public.usuarios(user_id) on delete set null,
  criado_em           timestamptz not null default now(),
  atualizado_por      uuid references public.usuarios(user_id) on delete set null,
  atualizado_em       timestamptz not null default now(),
  constraint energia_contratos_periodo check (fim >= inicio),
  constraint energia_contratos_parte check (
    (tipo = 'venda'  and num_nonnulls(cliente_pf_id, cliente_pj_id) = 1) or
    (tipo = 'compra' and cliente_pf_id is null and cliente_pj_id is null and char_length(contraparte) >= 1)
  )
);

create unique index if not exists energia_contratos_numero on public.energia_contratos (numero);
create index if not exists energia_contratos_org on public.energia_contratos (organizacao_id);

-- Unidades atendidas por um contrato de venda
create table if not exists public.energia_contrato_unidades (
  contrato_id uuid not null references public.energia_contratos(id) on delete cascade,
  unidade_id  uuid not null references public.energia_unidades(id) on delete cascade,
  primary key (contrato_id, unidade_id)
);
create index if not exists energia_contrato_unidades_unidade on public.energia_contrato_unidades (unidade_id);

-- Apuração mensal por unidade: consumo, quanto custaria no mercado cativo,
-- quanto foi pago à distribuidora (fio) e quanto a Celeiro faturou pela energia.
-- Economia = custo de referência no cativo - (distribuidora + energia).
create table if not exists public.energia_apuracoes (
  id                    uuid primary key default gen_random_uuid(),
  unidade_id            uuid not null references public.energia_unidades(id) on delete cascade,
  organizacao_id        uuid references public.organizacoes(id) on delete cascade,
  contrato_id           uuid references public.energia_contratos(id) on delete set null,
  competencia           date not null check (extract(day from competencia) = 1),
  consumo_kwh           numeric(14,2) not null check (consumo_kwh >= 0),
  valor_referencia      numeric(14,2) not null check (valor_referencia >= 0),
  valor_distribuidora   numeric(14,2) not null default 0 check (valor_distribuidora >= 0),
  valor_energia         numeric(14,2) not null default 0 check (valor_energia >= 0),
  economia              numeric(14,2) generated always as (valor_referencia - valor_distribuidora - valor_energia) stored,
  fatura_status         text not null default 'a_emitir'
                        check (fatura_status in ('a_emitir','emitida','paga','vencida','cancelada')),
  vencimento            date,
  observacoes           text not null default '' check (char_length(observacoes) <= 1000),
  criado_por            uuid references public.usuarios(user_id) on delete set null,
  criado_em             timestamptz not null default now(),
  atualizado_por        uuid references public.usuarios(user_id) on delete set null,
  atualizado_em         timestamptz not null default now()
);

create unique index if not exists energia_apuracoes_unica on public.energia_apuracoes (unidade_id, competencia);
create index if not exists energia_apuracoes_org_comp on public.energia_apuracoes (organizacao_id, competencia desc);

-- Funil de migração para o mercado livre (só equipe Celeiro)
create sequence if not exists public.energia_migracoes_numero_seq;

create table if not exists public.energia_migracoes (
  id                    uuid primary key default gen_random_uuid(),
  numero                int not null default nextval('public.energia_migracoes_numero_seq'),
  origem                text not null default 'manual' check (origem in ('manual','app')),
  app_solicitacao_id    uuid unique,
  etapa                 text not null default 'lead'
                        check (etapa in ('lead','analise','proposta','contrato','denuncia','ccee','migrada','perdida')),
  nome                  text not null check (char_length(nome) between 1 and 160),
  telefone              text not null default '' check (char_length(telefone) <= 30),
  email                 text not null default '' check (char_length(email) <= 254),
  documento             text not null default '' check (documento ~ '^([0-9]{11}|[0-9]{14})?$'),
  distribuidora         text not null default '' check (char_length(distribuidora) <= 120),
  unidade_texto         text not null default '' check (char_length(unidade_texto) <= 160),
  valor_fatura          numeric(14,2) check (valor_fatura is null or valor_fatura >= 0),
  economia_estimada_pct numeric(5,2)  check (economia_estimada_pct is null or economia_estimada_pct between 0 and 100),
  data_prevista         date,
  responsavel_id        uuid references public.usuarios(user_id) on delete set null,
  unidade_id            uuid references public.energia_unidades(id) on delete set null,
  motivo_perda          text not null default '' check (char_length(motivo_perda) <= 300),
  observacoes           text not null default '' check (char_length(observacoes) <= 2000),
  teste                 boolean not null default false,
  criado_por            uuid references public.usuarios(user_id) on delete set null,
  criado_em             timestamptz not null default now(),
  atualizado_por        uuid references public.usuarios(user_id) on delete set null,
  atualizado_em         timestamptz not null default now(),
  etapa_desde           timestamptz not null default now()
);

create unique index if not exists energia_migracoes_numero on public.energia_migracoes (numero);

alter table public.energia_unidades          enable row level security;
alter table public.energia_contratos         enable row level security;
alter table public.energia_contrato_unidades enable row level security;
alter table public.energia_apuracoes         enable row level security;
alter table public.energia_migracoes         enable row level security;

-- =====================================================================
-- 3) FUNÇÕES DE APOIO
-- =====================================================================

-- O usuário atual pode ver e alterar registros de energia desta organização (nulo = Celeiro)?
create or replace function public.energia_escopo_ok(p_org uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.pode_modulo('energia')
     and coalesce(public.eh_equipe() or p_org = public.minha_org(), false);
$$;

-- Funil de migração: equipe Celeiro com o módulo Energia
create or replace function public.energia_pode_funil()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.pode_modulo('energia') and public.eh_equipe();
$$;

-- Número do formulário (aceita "1.234,56" ou "1234.56"); nulo quando vazio
create or replace function public.energia_numero(p_dados jsonb, p_chave text, p_rotulo text)
returns numeric
language plpgsql
immutable
set search_path = ''
as $$
declare
  v text := trim(coalesce(p_dados ->> p_chave, ''));
  n numeric;
begin
  if v = '' then
    return null;
  end if;
  -- em português o ponto separa milhar: "1.234,56" e "60.000"
  if position(',' in v) > 0 then
    v := replace(replace(v, '.', ''), ',', '.');
  elsif v ~ '^[0-9]{1,3}([.][0-9]{3})+$' then
    v := replace(v, '.', '');
  end if;
  begin
    n := v::numeric;
  exception when others then
    raise exception '% inválido', p_rotulo;
  end;
  if n < 0 or n > 999999999999 then
    raise exception '% inválido', p_rotulo;
  end if;
  return n;
end;
$$;

-- Data do formulário; nula quando vazia
create or replace function public.energia_data(p_dados jsonb, p_chave text, p_rotulo text)
returns date
language plpgsql
immutable
set search_path = ''
as $$
declare
  v text := trim(coalesce(p_dados ->> p_chave, ''));
begin
  if v = '' then
    return null;
  end if;
  begin
    return v::date;
  exception when others then
    raise exception '% inválida', p_rotulo;
  end;
end;
$$;

-- Confere se a pessoa (física ou jurídica) do Cadastro pertence à mesma origem e está ativa
create or replace function public.energia_titular_ok(p_pf uuid, p_pj uuid, p_org uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when p_pf is not null and p_pj is null then exists (
      select 1 from public.cadastro_pf c
      where c.id = p_pf and c.organizacao_id is not distinct from p_org and c.situacao = 'ativo')
    when p_pj is not null and p_pf is null then exists (
      select 1 from public.cadastro_pj c
      where c.id = p_pj and c.organizacao_id is not distinct from p_org and c.situacao = 'ativo')
    else false
  end;
$$;

-- Pessoas do Cadastro que podem ser titulares ou clientes, para quem tem o módulo Energia
-- (mesmo sem o módulo Cadastro). Entrega só nome, documento, origem e situação.
create or replace function public.energia_pessoas()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.pode_modulo('energia') then
    raise exception 'Sem permissão para o módulo Energia.';
  end if;
  return jsonb_build_object(
    'pf', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'organizacao_id', c.organizacao_id, 'situacao', c.situacao,
                                                        'nome_completo', c.nome_completo, 'cpf', c.cpf) order by c.nome_completo)
                    from public.cadastro_pf c where public.energia_escopo_ok(c.organizacao_id)), '[]'::jsonb),
    'pj', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'organizacao_id', c.organizacao_id, 'situacao', c.situacao,
                                                        'razao_social', c.razao_social, 'nome_fantasia', c.nome_fantasia, 'cnpj', c.cnpj) order by c.razao_social)
                    from public.cadastro_pj c where public.energia_escopo_ok(c.organizacao_id)), '[]'::jsonb));
end;
$$;

-- =====================================================================
-- 4) UNIDADES CONSUMIDORAS
-- =====================================================================

-- Cria (p_id nulo) ou altera uma unidade consumidora
create or replace function public.energia_unidade_salvar(p_id uuid, p_org uuid, p_dados jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_org   uuid;
  v_id    uuid;
  v_atual public.energia_unidades%rowtype;
  v_pf    uuid := nullif(p_dados ->> 'titular_pf_id', '')::uuid;
  v_pj    uuid := nullif(p_dados ->> 'titular_pj_id', '')::uuid;
  v_cod   text := upper(regexp_replace(public.campo_texto(p_dados, 'codigo_instalacao', 40), '[[:space:]]', '', 'g'));
  v_dist  text := public.campo_texto(p_dados, 'distribuidora', 120);
  v_grupo text := upper(public.campo_texto(p_dados, 'grupo', 1));
  v_sub   text := public.campo_texto(p_dados, 'subgrupo', 3);
  v_mod   text := public.campo_texto(p_dados, 'modalidade', 20);
  v_amb   text := public.campo_texto(p_dados, 'ambiente', 20);
  v_cep   text := regexp_replace(coalesce(p_dados ->> 'cep', ''), '[^0-9]', '', 'g');
  v_uf    text := upper(public.campo_texto(p_dados, 'uf', 2));
begin
  if p_id is null then
    if not public.energia_escopo_ok(p_org) then
      raise exception 'Você não pode cadastrar unidades para esta organização';
    end if;
    if p_org is not null and not exists (select 1 from public.organizacoes where id = p_org and ativo) then
      raise exception 'Organização não encontrada ou inativa';
    end if;
    v_org := p_org;
  else
    select * into v_atual from public.energia_unidades where id = p_id;
    if not found or not public.energia_escopo_ok(v_atual.organizacao_id) then
      raise exception 'Unidade não encontrada';
    end if;
    v_org := v_atual.organizacao_id;
  end if;

  -- O titular pode continuar o mesmo mesmo que tenha sido inativado depois; um titular novo precisa estar ativo.
  if not (p_id is not null
          and v_pf is not distinct from v_atual.titular_pf_id
          and v_pj is not distinct from v_atual.titular_pj_id)
     and not public.energia_titular_ok(v_pf, v_pj, v_org) then
    raise exception 'Escolha o titular: uma pessoa física ou jurídica ativa do Cadastro, da mesma origem da unidade';
  end if;
  if v_cod = '' then
    raise exception 'Informe o número da instalação (código da unidade na distribuidora)';
  end if;
  if v_dist = '' then
    raise exception 'Informe a distribuidora';
  end if;
  if exists (
    select 1 from public.energia_unidades u
    where lower(u.distribuidora) = lower(v_dist) and u.codigo_instalacao = v_cod and u.id is distinct from p_id
  ) then
    raise exception 'Esta instalação já está cadastrada para esta distribuidora';
  end if;
  if v_grupo not in ('A','B') then
    raise exception 'Grupo tarifário inválido';
  end if;
  if v_sub not in ('','A1','A2','A3','A3a','A4','AS','B1','B2','B3','B4')
     or (v_sub <> '' and left(v_sub, 1) <> v_grupo) then
    raise exception 'Subgrupo inválido para o grupo %', v_grupo;
  end if;
  if v_mod not in ('','azul','verde','convencional','branca') then
    raise exception 'Modalidade tarifária inválida';
  end if;
  if v_amb not in ('cativo','em_migracao','livre','gd') then
    raise exception 'Ambiente de contratação inválido';
  end if;
  if v_cep <> '' and char_length(v_cep) <> 8 then
    raise exception 'CEP inválido: são 8 números';
  end if;
  if v_uf not in ('','AC','AL','AP','AM','BA','CE','DF','ES','GO','MA','MT','MS','MG','PA','PB','PR','PE','PI','RJ','RN','RS','RO','RR','SC','SP','SE','TO') then
    raise exception 'UF inválida';
  end if;

  if p_id is null then
    insert into public.energia_unidades (organizacao_id, titular_pf_id, titular_pj_id, codigo_instalacao, distribuidora, criado_por, atualizado_por)
    values (v_org, v_pf, v_pj, v_cod, v_dist, v_uid, v_uid)
    returning id into v_id;
  else
    v_id := p_id;
  end if;

  update public.energia_unidades set
    titular_pf_id     = v_pf,
    titular_pj_id     = v_pj,
    apelido           = public.campo_texto(p_dados, 'apelido', 120),
    codigo_instalacao = v_cod,
    distribuidora     = v_dist,
    grupo             = v_grupo,
    subgrupo          = v_sub,
    modalidade        = v_mod,
    ambiente          = v_amb,
    demanda_ponta_kw  = public.energia_numero(p_dados, 'demanda_ponta_kw', 'Demanda na ponta'),
    demanda_fora_kw   = public.energia_numero(p_dados, 'demanda_fora_kw', 'Demanda fora da ponta'),
    consumo_medio_kwh = public.energia_numero(p_dados, 'consumo_medio_kwh', 'Consumo médio'),
    cep               = v_cep,
    logradouro        = public.campo_texto(p_dados, 'logradouro', 160),
    numero            = public.campo_texto(p_dados, 'numero', 20),
    complemento       = public.campo_texto(p_dados, 'complemento', 80),
    bairro            = public.campo_texto(p_dados, 'bairro', 100),
    cidade            = public.campo_texto(p_dados, 'cidade', 100),
    uf                = v_uf,
    observacoes       = public.campo_texto(p_dados, 'observacoes', 2000),
    atualizado_por    = v_uid,
    atualizado_em     = now()
  where id = v_id;

  return v_id;
end;
$$;

-- Ativa ou inativa uma unidade
create or replace function public.energia_unidade_situacao(p_id uuid, p_situacao text)
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
  select organizacao_id into v_org from public.energia_unidades where id = p_id;
  if not found or not public.energia_escopo_ok(v_org) then
    raise exception 'Unidade não encontrada';
  end if;
  update public.energia_unidades
     set situacao = p_situacao, atualizado_por = (select auth.uid()), atualizado_em = now()
   where id = p_id and situacao <> p_situacao;
end;
$$;

-- =====================================================================
-- 5) CONTRATOS
-- =====================================================================

-- Cria (p_id nulo) ou altera um contrato. p_unidades: unidades atendidas (só em contratos de venda).
create or replace function public.energia_contrato_salvar(p_id uuid, p_org uuid, p_dados jsonb, p_unidades uuid[])
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid    uuid := (select auth.uid());
  v_org    uuid;
  v_id     uuid;
  v_atual  public.energia_contratos%rowtype;
  v_tipo   text := public.campo_texto(p_dados, 'tipo', 10);
  v_prod   text := public.campo_texto(p_dados, 'produto', 10);
  v_status text := public.campo_texto(p_dados, 'status', 20);
  v_pf     uuid := nullif(p_dados ->> 'cliente_pf_id', '')::uuid;
  v_pj     uuid := nullif(p_dados ->> 'cliente_pj_id', '')::uuid;
  v_contra text := public.campo_texto(p_dados, 'contraparte', 160);
  v_ini    date := public.energia_data(p_dados, 'inicio', 'Data de início');
  v_fim    date := public.energia_data(p_dados, 'fim', 'Data de término');
  v_sub    text := public.campo_texto(p_dados, 'submercado', 10);
  v_fonte  text := public.campo_texto(p_dados, 'fonte', 20);
  v_ind    text := public.campo_texto(p_dados, 'indice_reajuste', 10);
  v_desc   numeric := public.energia_numero(p_dados, 'desconto_pct', 'Desconto');
  v_flex   numeric := public.energia_numero(p_dados, 'flex_pct', 'Flexibilidade');
  v_sazo   numeric := public.energia_numero(p_dados, 'sazo_pct', 'Sazonalidade');
  v_unids  uuid[] := coalesce(p_unidades, '{}'::uuid[]);
begin
  if p_id is null then
    if not public.energia_escopo_ok(p_org) then
      raise exception 'Você não pode cadastrar contratos para esta organização';
    end if;
    if p_org is not null and not exists (select 1 from public.organizacoes where id = p_org and ativo) then
      raise exception 'Organização não encontrada ou inativa';
    end if;
    v_org := p_org;
  else
    select * into v_atual from public.energia_contratos where id = p_id;
    if not found or not public.energia_escopo_ok(v_atual.organizacao_id) then
      raise exception 'Contrato não encontrado';
    end if;
    v_org := v_atual.organizacao_id;
  end if;

  if v_tipo not in ('venda','compra') then
    raise exception 'Tipo de contrato inválido';
  end if;
  if v_prod not in ('acl','gd') then
    raise exception 'Produto inválido';
  end if;
  if v_status not in ('rascunho','assinado','vigente','encerrado','cancelado') then
    raise exception 'Situação do contrato inválida';
  end if;
  if v_ini is null or v_fim is null then
    raise exception 'Informe o início e o término do contrato';
  end if;
  if v_fim < v_ini then
    raise exception 'O término não pode ser antes do início';
  end if;
  if v_sub not in ('','SE/CO','S','NE','N') then
    raise exception 'Submercado inválido';
  end if;
  if v_fonte not in ('','convencional','incentivada_50','incentivada_100','solar','eolica','hidrica','biomassa') then
    raise exception 'Fonte inválida';
  end if;
  if v_ind not in ('','IPCA','IGP-M','nenhum') then
    raise exception 'Índice de reajuste inválido';
  end if;
  if (v_desc is not null and v_desc > 100) or (v_flex is not null and v_flex > 100) or (v_sazo is not null and v_sazo > 100) then
    raise exception 'Percentuais vão de 0 a 100';
  end if;

  if v_tipo = 'venda' then
    if not (p_id is not null
            and v_pf is not distinct from v_atual.cliente_pf_id
            and v_pj is not distinct from v_atual.cliente_pj_id)
       and not public.energia_titular_ok(v_pf, v_pj, v_org) then
      raise exception 'Escolha o cliente: uma pessoa física ou jurídica ativa do Cadastro, da mesma origem do contrato';
    end if;
    v_contra := '';
    if exists (
      select 1 from unnest(v_unids) x(uid)
      where not exists (select 1 from public.energia_unidades u
                        where u.id = x.uid and u.organizacao_id is not distinct from v_org)
    ) then
      raise exception 'Uma das unidades escolhidas não pertence à mesma origem do contrato';
    end if;
  else
    v_pf := null;
    v_pj := null;
    v_unids := '{}'::uuid[];
    if v_contra = '' then
      raise exception 'Informe o fornecedor ou gerador do contrato de compra';
    end if;
  end if;

  if p_id is null then
    insert into public.energia_contratos (organizacao_id, tipo, produto, cliente_pf_id, cliente_pj_id, contraparte, inicio, fim, criado_por, atualizado_por)
    values (v_org, v_tipo, v_prod, v_pf, v_pj, v_contra, v_ini, v_fim, v_uid, v_uid)
    returning id into v_id;
  else
    v_id := p_id;
  end if;

  update public.energia_contratos set
    tipo               = v_tipo,
    produto            = v_prod,
    cliente_pf_id      = v_pf,
    cliente_pj_id      = v_pj,
    contraparte        = v_contra,
    status             = v_status,
    inicio             = v_ini,
    fim                = v_fim,
    volume_mwh_mes     = public.energia_numero(p_dados, 'volume_mwh_mes', 'Volume mensal'),
    preco_mwh          = public.energia_numero(p_dados, 'preco_mwh', 'Preço do MWh'),
    desconto_pct       = v_desc,
    flex_pct           = v_flex,
    sazo_pct           = v_sazo,
    submercado         = v_sub,
    fonte              = v_fonte,
    indice_reajuste    = v_ind,
    data_base_reajuste = public.energia_data(p_dados, 'data_base_reajuste', 'Data-base do reajuste'),
    observacoes        = public.campo_texto(p_dados, 'observacoes', 2000),
    atualizado_por     = v_uid,
    atualizado_em      = now()
  where id = v_id;

  delete from public.energia_contrato_unidades c
   where c.contrato_id = v_id and not (c.unidade_id = any(v_unids));
  insert into public.energia_contrato_unidades (contrato_id, unidade_id)
  select v_id, x.uid from unnest(v_unids) x(uid)
  on conflict do nothing;

  return v_id;
end;
$$;

-- =====================================================================
-- 6) APURAÇÃO MENSAL
-- =====================================================================

-- Grava (cria ou substitui) a apuração de uma unidade em uma competência (mês)
create or replace function public.energia_apuracao_salvar(p_unidade uuid, p_dados jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_org   uuid;
  v_id    uuid;
  v_comp  date := date_trunc('month', public.energia_data(p_dados, 'competencia', 'Competência'))::date;
  v_cons  numeric := public.energia_numero(p_dados, 'consumo_kwh', 'Consumo');
  v_ref   numeric := public.energia_numero(p_dados, 'valor_referencia', 'Custo de referência no cativo');
  v_dist  numeric := coalesce(public.energia_numero(p_dados, 'valor_distribuidora', 'Valor pago à distribuidora'), 0);
  v_ener  numeric := coalesce(public.energia_numero(p_dados, 'valor_energia', 'Valor da energia'), 0);
  v_fat   text := coalesce(nullif(public.campo_texto(p_dados, 'fatura_status', 20), ''), 'a_emitir');
  v_ctr   uuid := nullif(p_dados ->> 'contrato_id', '')::uuid;
begin
  select organizacao_id into v_org from public.energia_unidades where id = p_unidade;
  if not found or not public.energia_escopo_ok(v_org) then
    raise exception 'Unidade não encontrada';
  end if;
  if v_comp is null then
    raise exception 'Informe a competência (mês de consumo)';
  end if;
  if v_comp > date_trunc('month', current_date)::date then
    raise exception 'A competência não pode ser um mês futuro';
  end if;
  if v_cons is null then
    raise exception 'Informe o consumo do mês em kWh';
  end if;
  if v_ref is null then
    raise exception 'Informe quanto a unidade pagaria no mercado cativo (custo de referência)';
  end if;
  if v_fat not in ('a_emitir','emitida','paga','vencida','cancelada') then
    raise exception 'Situação da fatura inválida';
  end if;
  if v_ctr is not null and not exists (
    select 1 from public.energia_contrato_unidades cu where cu.contrato_id = v_ctr and cu.unidade_id = p_unidade
  ) then
    raise exception 'O contrato escolhido não atende esta unidade';
  end if;

  insert into public.energia_apuracoes as a (
    unidade_id, organizacao_id, contrato_id, competencia, consumo_kwh, valor_referencia,
    valor_distribuidora, valor_energia, fatura_status, vencimento, observacoes, criado_por, atualizado_por)
  values (
    p_unidade, v_org, v_ctr, v_comp, v_cons, v_ref, v_dist, v_ener, v_fat,
    public.energia_data(p_dados, 'vencimento', 'Vencimento'),
    public.campo_texto(p_dados, 'observacoes', 1000), v_uid, v_uid)
  on conflict (unidade_id, competencia) do update set
    contrato_id         = excluded.contrato_id,
    consumo_kwh         = excluded.consumo_kwh,
    valor_referencia    = excluded.valor_referencia,
    valor_distribuidora = excluded.valor_distribuidora,
    valor_energia       = excluded.valor_energia,
    fatura_status       = excluded.fatura_status,
    vencimento          = excluded.vencimento,
    observacoes         = excluded.observacoes,
    atualizado_por      = v_uid,
    atualizado_em       = now()
  returning a.id into v_id;

  return v_id;
end;
$$;

-- Muda só a situação da fatura de uma apuração
create or replace function public.energia_apuracao_fatura(p_id uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_org uuid;
begin
  if coalesce(p_status, '') not in ('a_emitir','emitida','paga','vencida','cancelada') then
    raise exception 'Situação da fatura inválida';
  end if;
  select organizacao_id into v_org from public.energia_apuracoes where id = p_id;
  if not found or not public.energia_escopo_ok(v_org) then
    raise exception 'Apuração não encontrada';
  end if;
  update public.energia_apuracoes
     set fatura_status = p_status, atualizado_por = (select auth.uid()), atualizado_em = now()
   where id = p_id and fatura_status <> p_status;
end;
$$;

-- =====================================================================
-- 7) FUNIL DE MIGRAÇÃO
-- =====================================================================

-- Cria (p_id nulo) ou altera um pedido de migração
create or replace function public.energia_migracao_salvar(p_id uuid, p_dados jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid   uuid := (select auth.uid());
  v_id    uuid;
  v_nome  text := public.campo_texto(p_dados, 'nome', 160);
  v_etapa text := coalesce(nullif(public.campo_texto(p_dados, 'etapa', 20), ''), 'lead');
  v_doc   text := regexp_replace(coalesce(p_dados ->> 'documento', ''), '[^0-9]', '', 'g');
  v_email text := lower(public.campo_texto(p_dados, 'email', 254));
  v_resp  uuid := nullif(p_dados ->> 'responsavel_id', '')::uuid;
  v_unid  uuid := nullif(p_dados ->> 'unidade_id', '')::uuid;
  v_eco   numeric := public.energia_numero(p_dados, 'economia_estimada_pct', 'Economia estimada');
  v_perda text := public.campo_texto(p_dados, 'motivo_perda', 300);
begin
  if not public.energia_pode_funil() then
    raise exception 'Sem permissão para o funil de migração';
  end if;
  if p_id is not null and not exists (select 1 from public.energia_migracoes where id = p_id) then
    raise exception 'Pedido de migração não encontrado';
  end if;
  if v_nome = '' then
    raise exception 'Informe o nome do cliente';
  end if;
  if v_etapa not in ('lead','analise','proposta','contrato','denuncia','ccee','migrada','perdida') then
    raise exception 'Etapa inválida';
  end if;
  if v_doc <> '' and not (public.cpf_valido(v_doc) or public.cnpj_valido(v_doc)) then
    raise exception 'CPF ou CNPJ inválido';
  end if;
  if v_email <> '' and v_email !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' then
    raise exception 'E-mail inválido';
  end if;
  if v_eco is not null and v_eco > 100 then
    raise exception 'Economia estimada vai de 0 a 100%%';
  end if;
  if v_etapa = 'perdida' and v_perda = '' then
    raise exception 'Informe o motivo da perda';
  end if;
  if v_resp is not null and not exists (
    select 1 from public.usuarios u
    where u.user_id = v_resp and u.ativo and u.perfil in ('master','gerencial')
  ) then
    raise exception 'O responsável precisa ser um usuário ativo da equipe Celeiro';
  end if;
  if v_unid is not null and not exists (select 1 from public.energia_unidades where id = v_unid) then
    raise exception 'Unidade consumidora não encontrada';
  end if;

  if p_id is null then
    insert into public.energia_migracoes (nome, etapa, criado_por, atualizado_por)
    values (v_nome, v_etapa, v_uid, v_uid)
    returning id into v_id;
  else
    v_id := p_id;
  end if;

  update public.energia_migracoes m set
    nome                  = v_nome,
    etapa_desde           = case when m.etapa <> v_etapa then now() else m.etapa_desde end,
    etapa                 = v_etapa,
    telefone              = regexp_replace(public.campo_texto(p_dados, 'telefone', 30), '[^0-9]', '', 'g'),
    email                 = v_email,
    documento             = v_doc,
    distribuidora         = public.campo_texto(p_dados, 'distribuidora', 120),
    unidade_texto         = public.campo_texto(p_dados, 'unidade_texto', 160),
    valor_fatura          = public.energia_numero(p_dados, 'valor_fatura', 'Valor da fatura'),
    economia_estimada_pct = v_eco,
    data_prevista         = public.energia_data(p_dados, 'data_prevista', 'Data prevista'),
    responsavel_id        = v_resp,
    unidade_id            = v_unid,
    motivo_perda          = case when v_etapa = 'perdida' then v_perda else '' end,
    observacoes           = public.campo_texto(p_dados, 'observacoes', 2000),
    atualizado_por        = v_uid,
    atualizado_em         = now()
  where m.id = v_id;

  return v_id;
end;
$$;

-- Move o pedido de etapa (usado pelo quadro)
create or replace function public.energia_migracao_mover(p_id uuid, p_etapa text, p_motivo text default '')
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.energia_pode_funil() then
    raise exception 'Sem permissão para o funil de migração';
  end if;
  if coalesce(p_etapa, '') not in ('lead','analise','proposta','contrato','denuncia','ccee','migrada','perdida') then
    raise exception 'Etapa inválida';
  end if;
  if p_etapa = 'perdida' and trim(coalesce(p_motivo, '')) = '' then
    raise exception 'Informe o motivo da perda';
  end if;
  update public.energia_migracoes set
    etapa          = p_etapa,
    etapa_desde    = now(),
    motivo_perda   = case when p_etapa = 'perdida' then left(trim(p_motivo), 300) else '' end,
    atualizado_por = (select auth.uid()),
    atualizado_em  = now()
  where id = p_id and etapa <> p_etapa;
  if not found and not exists (select 1 from public.energia_migracoes where id = p_id) then
    raise exception 'Pedido de migração não encontrado';
  end if;
end;
$$;

-- =====================================================================
-- 8) RESUMO (visão geral e Dashboard)
--    Roda com as permissões de quem chama: cada um vê só o que pode ver.
-- =====================================================================

create or replace function public.energia_resumo()
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_mes date := date_trunc('month', current_date)::date;
begin
  if not public.pode_modulo('energia') then
    raise exception 'Sem permissão para o módulo Energia.';
  end if;
  return jsonb_build_object(
    'unidades', (select count(*) from public.energia_unidades where situacao = 'ativo'),
    'por_ambiente', coalesce((select jsonb_object_agg(ambiente, n) from (
        select ambiente, count(*) n from public.energia_unidades where situacao = 'ativo' group by ambiente) t), '{}'::jsonb),
    'contratos_vigentes', (select count(*) from public.energia_contratos where status = 'vigente'),
    'volume_venda_mwh', coalesce((select sum(volume_mwh_mes) from public.energia_contratos where status = 'vigente' and tipo = 'venda'), 0),
    'volume_compra_mwh', coalesce((select sum(volume_mwh_mes) from public.energia_contratos where status = 'vigente' and tipo = 'compra'), 0),
    'vencendo_90d', (select count(*) from public.energia_contratos
                     where status in ('assinado','vigente') and fim between current_date and current_date + 90),
    'economia_12m', coalesce((select sum(economia) from public.energia_apuracoes
                              where competencia >= (v_mes - interval '12 months')::date), 0),
    'referencia_12m', coalesce((select sum(valor_referencia) from public.energia_apuracoes
                                where competencia >= (v_mes - interval '12 months')::date), 0),
    'faturas_abertas', (select count(*) from public.energia_apuracoes where fatura_status in ('emitida','vencida')),
    'faturas_vencidas', (select count(*) from public.energia_apuracoes where fatura_status = 'vencida'),
    'meses', coalesce((select jsonb_agg(jsonb_build_object('competencia', competencia, 'economia', economia, 'referencia', referencia, 'consumo', consumo) order by competencia)
                       from (select competencia, sum(economia) economia, sum(valor_referencia) referencia, sum(consumo_kwh) consumo
                             from public.energia_apuracoes
                             where competencia >= (v_mes - interval '11 months')::date
                             group by competencia) m), '[]'::jsonb),
    'funil', case when public.energia_pode_funil() then coalesce((select jsonb_object_agg(etapa, n) from (
        select etapa, count(*) n from public.energia_migracoes where not teste group by etapa) f), '{}'::jsonb) else null end
  );
end;
$$;

-- =====================================================================
-- 9) PEDIDOS DO APLICATIVO ENTRAM NO FUNIL
--    Só é ligado se a integração com o app (supabase-app.sql) já existir.
--    Se rodar o supabase-app.sql depois, rode este arquivo de novo.
-- =====================================================================

-- Valor em reais escrito no app ("1.234,56", "1234.56" ou "R$ 850"); nulo quando não dá para ler
create or replace function public.energia_valor_texto(p_txt text)
returns numeric
language plpgsql
immutable
set search_path = ''
as $$
declare
  v text := regexp_replace(coalesce(p_txt, ''), '[^0-9,.]', '', 'g');
  n numeric;
begin
  if position(',' in v) > 0 then
    v := replace(replace(v, '.', ''), ',', '.');
  elsif v ~ '^[0-9]{1,3}([.][0-9]{3})+$' then
    v := replace(v, '.', '');
  end if;
  if v = '' then
    return null;
  end if;
  begin
    n := round(v::numeric, 2);
  exception when others then
    return null;
  end;
  return case when n >= 0 and n < 1e12 then n end;
end;
$$;

-- Copia um pedido de "Energia com Desconto" do app para o funil (uso interno)
create or replace function public.energia_de_app()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_doc text := regexp_replace(coalesce(new.documento, ''), '[^0-9]', '', 'g');
begin
  if new.tipo <> 'migracao_energia' then
    return new;
  end if;
  insert into public.energia_migracoes (
    origem, app_solicitacao_id, nome, telefone, email, documento, distribuidora, unidade_texto, valor_fatura, teste, observacoes)
  values (
    'app', new.id, coalesce(nullif(left(trim(coalesce(new.nome, '')), 160), ''), 'Sem nome'),
    left(regexp_replace(coalesce(new.telefone, ''), '[^0-9]', '', 'g'), 30),
    left(lower(trim(coalesce(new.email, ''))), 254),
    case when char_length(v_doc) in (11, 14) then v_doc else '' end,
    left(coalesce(new.dados ->> 'distribuidora', ''), 120),
    left(coalesce(new.dados ->> 'unidade', ''), 160),
    public.energia_valor_texto(new.dados ->> 'valor_fatura'),
    new.teste,
    case when coalesce(new.dados ->> 'fatura_anexada', '') = 'true' then 'O cliente anexou a fatura no app.' else '' end)
  on conflict (app_solicitacao_id) do nothing;
  return new;
end;
$$;

do $$
begin
  if to_regclass('public.app_solicitacoes') is not null then
    execute 'drop trigger if exists energia_de_app on public.app_solicitacoes';
    execute 'create trigger energia_de_app after insert on public.app_solicitacoes
             for each row execute function public.energia_de_app()';
    -- pedidos que já tinham chegado do app antes deste arquivo
    insert into public.energia_migracoes (
      origem, app_solicitacao_id, nome, telefone, email, documento, distribuidora, unidade_texto, valor_fatura, teste, observacoes, criado_em)
    select 'app', s.id, coalesce(nullif(left(trim(coalesce(s.nome, '')), 160), ''), 'Sem nome'),
           left(regexp_replace(coalesce(s.telefone, ''), '[^0-9]', '', 'g'), 30),
           left(lower(trim(coalesce(s.email, ''))), 254),
           case when char_length(regexp_replace(coalesce(s.documento, ''), '[^0-9]', '', 'g')) in (11, 14)
                then regexp_replace(coalesce(s.documento, ''), '[^0-9]', '', 'g') else '' end,
           left(coalesce(s.dados ->> 'distribuidora', ''), 120),
           left(coalesce(s.dados ->> 'unidade', ''), 160),
           public.energia_valor_texto(s.dados ->> 'valor_fatura'),
           s.teste,
           'Pedido recebido pelo app antes do módulo Energia existir.',
           s.criado_em
      from public.app_solicitacoes s
     where s.tipo = 'migracao_energia'
    on conflict (app_solicitacao_id) do nothing;
  end if;
end;
$$;

-- =====================================================================
-- 10) AUDITORIA
-- =====================================================================

drop trigger if exists auditar_energia_unidades on public.energia_unidades;
create trigger auditar_energia_unidades
  after insert or update or delete on public.energia_unidades
  for each row execute function public.auditar('Energia');

drop trigger if exists auditar_energia_contratos on public.energia_contratos;
create trigger auditar_energia_contratos
  after insert or update or delete on public.energia_contratos
  for each row execute function public.auditar('Energia');

drop trigger if exists auditar_energia_contrato_unidades on public.energia_contrato_unidades;
create trigger auditar_energia_contrato_unidades
  after insert or delete on public.energia_contrato_unidades
  for each row execute function public.auditar('Energia');

drop trigger if exists auditar_energia_apuracoes on public.energia_apuracoes;
create trigger auditar_energia_apuracoes
  after insert or update or delete on public.energia_apuracoes
  for each row execute function public.auditar('Energia');

drop trigger if exists auditar_energia_migracoes on public.energia_migracoes;
create trigger auditar_energia_migracoes
  after insert or update or delete on public.energia_migracoes
  for each row execute function public.auditar('Energia');

-- =====================================================================
-- 11) PERMISSÕES
-- =====================================================================

revoke all on public.energia_unidades, public.energia_contratos, public.energia_contrato_unidades,
              public.energia_apuracoes, public.energia_migracoes
  from anon, authenticated;
grant select on public.energia_unidades, public.energia_contratos, public.energia_contrato_unidades,
                public.energia_apuracoes, public.energia_migracoes
  to authenticated;
revoke all on sequence public.energia_contratos_numero_seq, public.energia_migracoes_numero_seq from anon, authenticated;

revoke all on function public.energia_de_app() from public, anon, authenticated;
revoke all on function public.energia_valor_texto(text) from public, anon, authenticated;

revoke all on function public.energia_escopo_ok(uuid)                               from public, anon;
revoke all on function public.energia_pode_funil()                                  from public, anon;
revoke all on function public.energia_numero(jsonb, text, text)                     from public, anon;
revoke all on function public.energia_data(jsonb, text, text)                       from public, anon;
revoke all on function public.energia_titular_ok(uuid, uuid, uuid)                  from public, anon;
revoke all on function public.energia_unidade_salvar(uuid, uuid, jsonb)             from public, anon;
revoke all on function public.energia_unidade_situacao(uuid, text)                  from public, anon;
revoke all on function public.energia_contrato_salvar(uuid, uuid, jsonb, uuid[])    from public, anon;
revoke all on function public.energia_apuracao_salvar(uuid, jsonb)                  from public, anon;
revoke all on function public.energia_apuracao_fatura(uuid, text)                   from public, anon;
revoke all on function public.energia_migracao_salvar(uuid, jsonb)                  from public, anon;
revoke all on function public.energia_migracao_mover(uuid, text, text)              from public, anon;
revoke all on function public.energia_resumo()                                      from public, anon;
revoke all on function public.energia_pessoas()                                     from public, anon;

grant execute on function public.energia_escopo_ok(uuid)                            to authenticated;
grant execute on function public.energia_pode_funil()                               to authenticated;
grant execute on function public.energia_numero(jsonb, text, text)                  to authenticated;
grant execute on function public.energia_data(jsonb, text, text)                    to authenticated;
grant execute on function public.energia_titular_ok(uuid, uuid, uuid)               to authenticated;
grant execute on function public.energia_unidade_salvar(uuid, uuid, jsonb)          to authenticated;
grant execute on function public.energia_unidade_situacao(uuid, text)               to authenticated;
grant execute on function public.energia_contrato_salvar(uuid, uuid, jsonb, uuid[]) to authenticated;
grant execute on function public.energia_apuracao_salvar(uuid, jsonb)               to authenticated;
grant execute on function public.energia_apuracao_fatura(uuid, text)                to authenticated;
grant execute on function public.energia_migracao_salvar(uuid, jsonb)               to authenticated;
grant execute on function public.energia_migracao_mover(uuid, text, text)           to authenticated;
grant execute on function public.energia_resumo()                                   to authenticated;
grant execute on function public.energia_pessoas()                                  to authenticated;

-- =====================================================================
-- 12) REGRAS DE ACESSO POR LINHA
--     Leitura: quem tem o módulo Energia e entrou com as duas etapas.
--     Equipe Celeiro vê tudo; cliente vê só a própria organização. Gravação só pelas funções.
-- =====================================================================

drop policy if exists "energia_unidades leitura" on public.energia_unidades;
create policy "energia_unidades leitura" on public.energia_unidades
  for select to authenticated
  using ((select public.pode_modulo('energia'))
         and ((select public.eh_equipe()) or organizacao_id = (select public.minha_org())));

drop policy if exists "energia_contratos leitura" on public.energia_contratos;
create policy "energia_contratos leitura" on public.energia_contratos
  for select to authenticated
  using ((select public.pode_modulo('energia'))
         and ((select public.eh_equipe()) or organizacao_id = (select public.minha_org())));

drop policy if exists "energia_contrato_unidades leitura" on public.energia_contrato_unidades;
create policy "energia_contrato_unidades leitura" on public.energia_contrato_unidades
  for select to authenticated
  using (exists (select 1 from public.energia_contratos c where c.id = contrato_id));

drop policy if exists "energia_apuracoes leitura" on public.energia_apuracoes;
create policy "energia_apuracoes leitura" on public.energia_apuracoes
  for select to authenticated
  using ((select public.pode_modulo('energia'))
         and ((select public.eh_equipe()) or organizacao_id = (select public.minha_org())));

drop policy if exists "energia_migracoes leitura" on public.energia_migracoes;
create policy "energia_migracoes leitura" on public.energia_migracoes
  for select to authenticated
  using ((select public.energia_pode_funil()));
