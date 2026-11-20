-- Celeiro · conta de pagamento
-- Estrutura de dados para: cash in e cash out por Pix, emissão de boletos,
-- transferências internas e pagamento de contas.
--
-- COMO LER ESTE BANCO
--   • A conta e o dinheiro existem na instituição financeira autorizada pelo BCB (o "provedor").
--     Aqui fica o ESPELHO: o que mostrar ao cliente, o que foi pedido e em que situação está.
--   • Valores sempre em centavos (bigint), nunca com vírgula.
--   • O cliente só LÊ os próprios dados. Toda gravação é feita pelo servidor (service_role),
--     pelas funções do fim deste arquivo. Nenhuma tela grava direto nas tabelas.
--   • Toda operação tem uma "chave de idempotência": repetir o mesmo pedido não repete o débito.
--
-- Rode no Supabase do SITE, depois do supabase.sql e do supabase-cliente.sql.
-- Pode ser rodado mais de uma vez sem duplicar nada.

create extension if not exists pgcrypto with schema extensions;

-- =====================================================================
-- 1) TABELAS
-- =====================================================================

-- Instituições financeiras que prestam o serviço (uma ou mais)
create table if not exists public.conta_provedores (
  id        uuid primary key default gen_random_uuid(),
  codigo    text not null unique check (codigo ~ '^[a-z0-9_]{2,40}$'),
  nome      text not null,
  ispb      text check (ispb is null or ispb ~ '^[0-9]{8}$'),
  ativo     boolean not null default true,
  criado_em timestamptz not null default now()
);

-- A conta de pagamento do cliente
create table if not exists public.conta_contas (
  id                        uuid primary key default gen_random_uuid(),
  user_id                   uuid not null references auth.users(id) on delete restrict,
  provedor_id               uuid not null references public.conta_provedores(id),
  id_externo                text,                       -- identificador da conta no provedor
  tipo_pessoa               text not null check (tipo_pessoa in ('PF','PJ')),
  documento                 text not null check (documento ~ '^[0-9]{11}$|^[0-9]{14}$'),
  titular                   text not null check (char_length(titular) between 3 and 160),
  agencia                   text,
  numero                    text,
  status                    text not null default 'em_analise'
                              check (status in ('em_analise','ativa','bloqueada','encerrada')),
  saldo_disponivel_centavos bigint not null default 0 check (saldo_disponivel_centavos >= 0),
  saldo_bloqueado_centavos  bigint not null default 0 check (saldo_bloqueado_centavos >= 0),
  saldo_conferido_em        timestamptz,                -- última conferência com o provedor
  criado_em                 timestamptz not null default now(),
  atualizado_em             timestamptz not null default now(),
  unique (provedor_id, id_externo),
  unique (user_id, documento)
);

create table if not exists public.conta_chaves_pix (
  id         uuid primary key default gen_random_uuid(),
  conta_id   uuid not null references public.conta_contas(id) on delete restrict,
  tipo       text not null check (tipo in ('cpf','cnpj','email','telefone','aleatoria')),
  chave      text not null check (char_length(chave) between 5 and 80),
  status     text not null default 'em_registro'
               check (status in ('em_registro','ativa','em_portabilidade','removida')),
  id_externo text,
  criado_em  timestamptz not null default now()
);
create unique index if not exists conta_chaves_pix_ativa on public.conta_chaves_pix (chave) where status <> 'removida';

-- Extrato: cada linha é um lançamento a crédito (C) ou a débito (D)
create table if not exists public.conta_movimentos (
  id                    uuid primary key default gen_random_uuid(),
  conta_id              uuid not null references public.conta_contas(id) on delete restrict,
  tipo                  text not null check (tipo in (
                          'pix_recebido','pix_enviado','pix_devolucao_recebida','pix_devolucao_enviada',
                          'boleto_recebido','pagamento_conta',
                          'transferencia_recebida','transferencia_enviada',
                          'tarifa','ajuste')),
  sentido               text not null check (sentido in ('C','D')),
  valor_centavos        bigint not null check (valor_centavos > 0),
  status                text not null check (status in ('pendente','liquidado','falhou','devolvido')),
  descricao             text check (descricao is null or char_length(descricao) <= 140),
  contraparte_nome      text,
  contraparte_documento text,       -- guardar mascarado quando vier de terceiros (ex.: ***.123.456-**)
  contraparte_instituicao text,
  end_to_end_id         text,       -- identificador do Pix no SPI
  id_externo            text,       -- identificador da operação no provedor
  idempotencia          text not null check (char_length(idempotencia) between 8 and 80),
  origem                text check (origem in ('pix_envio','pix_cobranca','boleto','pagamento','transferencia','webhook','manual')),
  origem_id             uuid,
  saldo_apos_centavos   bigint,
  motivo_falha          text,
  criado_em             timestamptz not null default now(),
  liquidado_em          timestamptz,
  unique (conta_id, idempotencia)
);
create index if not exists conta_movimentos_extrato on public.conta_movimentos (conta_id, criado_em desc);
create index if not exists conta_movimentos_e2e on public.conta_movimentos (end_to_end_id) where end_to_end_id is not null;

-- Histórico de situação de cada lançamento (quem mudou, de quê para quê)
create table if not exists public.conta_movimento_eventos (
  id           bigint generated always as identity primary key,
  movimento_id uuid not null references public.conta_movimentos(id) on delete restrict,
  de           text,
  para         text not null,
  detalhe      text,
  em           timestamptz not null default now()
);

-- Cash in por Pix: cobrança com QR Code / copia e cola
create table if not exists public.conta_pix_cobrancas (
  id             uuid primary key default gen_random_uuid(),
  conta_id       uuid not null references public.conta_contas(id) on delete restrict,
  txid           text unique,
  chave          text not null,
  valor_centavos bigint check (valor_centavos is null or valor_centavos > 0),  -- nulo = valor livre
  descricao      text check (descricao is null or char_length(descricao) <= 140),
  copia_e_cola   text,
  status         text not null default 'ativa' check (status in ('ativa','paga','expirada','cancelada')),
  expira_em      timestamptz,
  movimento_id   uuid references public.conta_movimentos(id),
  criado_em      timestamptz not null default now()
);

-- Cash out por Pix
create table if not exists public.conta_pix_envios (
  id                  uuid primary key default gen_random_uuid(),
  conta_id            uuid not null references public.conta_contas(id) on delete restrict,
  chave_destino       text,
  destino_nome        text,
  destino_documento   text,
  destino_instituicao text,
  valor_centavos      bigint not null check (valor_centavos > 0),
  descricao           text check (descricao is null or char_length(descricao) <= 140),
  status              text not null default 'pendente' check (status in ('pendente','liquidado','falhou','devolvido')),
  movimento_id        uuid references public.conta_movimentos(id),
  criado_em           timestamptz not null default now()
);

-- Boletos emitidos pelo cliente (cobrança)
create table if not exists public.conta_boletos (
  id                  uuid primary key default gen_random_uuid(),
  conta_id            uuid not null references public.conta_contas(id) on delete restrict,
  pagador_nome        text not null check (char_length(pagador_nome) between 3 and 160),
  pagador_documento   text not null check (pagador_documento ~ '^[0-9]{11}$|^[0-9]{14}$'),
  pagador_endereco    jsonb,
  valor_centavos      bigint not null check (valor_centavos > 0),
  vencimento          date not null,
  descricao           text check (descricao is null or char_length(descricao) <= 140),
  multa_percentual    numeric(5,2) not null default 0 check (multa_percentual between 0 and 2),
  juros_mes_percentual numeric(5,2) not null default 0 check (juros_mes_percentual between 0 and 20),
  nosso_numero        text,
  linha_digitavel     text,
  codigo_barras       text,
  pix_copia_e_cola    text,          -- quando o provedor emite boleto com QR Code
  id_externo          text,
  status              text not null default 'em_registro'
                        check (status in ('em_registro','registrado','pago','vencido','cancelado','rejeitado')),
  valor_pago_centavos bigint,
  pago_em             timestamptz,
  movimento_id        uuid references public.conta_movimentos(id),
  criado_em           timestamptz not null default now()
);
create index if not exists conta_boletos_lista on public.conta_boletos (conta_id, vencimento);

-- Pagamento de contas (boletos, contas de consumo e tributos pagos pelo cliente)
create table if not exists public.conta_pagamentos (
  id               uuid primary key default gen_random_uuid(),
  conta_id         uuid not null references public.conta_contas(id) on delete restrict,
  linha_digitavel  text not null check (linha_digitavel ~ '^[0-9]{44,48}$'),
  tipo             text not null default 'boleto' check (tipo in ('boleto','consumo','tributo')),
  beneficiario     text,
  valor_centavos   bigint not null check (valor_centavos > 0),
  vencimento       date,
  agendado_para    date,                -- nulo = pagar agora
  autenticacao     text,                -- autenticação devolvida pelo provedor (comprovante)
  status           text not null default 'pendente' check (status in ('agendado','pendente','liquidado','falhou','cancelado')),
  movimento_id     uuid references public.conta_movimentos(id),
  criado_em        timestamptz not null default now()
);

-- Transferência entre duas contas Celeiro
create table if not exists public.conta_transferencias (
  id               uuid primary key default gen_random_uuid(),
  conta_origem_id  uuid not null references public.conta_contas(id) on delete restrict,
  conta_destino_id uuid not null references public.conta_contas(id) on delete restrict,
  valor_centavos   bigint not null check (valor_centavos > 0),
  descricao        text check (descricao is null or char_length(descricao) <= 140),
  movimento_debito_id  uuid references public.conta_movimentos(id),
  movimento_credito_id uuid references public.conta_movimentos(id),
  criado_em        timestamptz not null default now(),
  check (conta_origem_id <> conta_destino_id)
);

-- Limites por conta. Noturno = das 20h às 6h (horário de Brasília).
create table if not exists public.conta_limites (
  conta_id               uuid not null references public.conta_contas(id) on delete cascade,
  grupo                  text not null check (grupo in ('pix','pagamento','transferencia')),
  periodo                text not null check (periodo in ('diurno','noturno')),
  por_operacao_centavos  bigint not null check (por_operacao_centavos >= 0),
  diario_centavos        bigint not null check (diario_centavos >= por_operacao_centavos),
  atualizado_em          timestamptz not null default now(),
  primary key (conta_id, grupo, periodo)
);

-- Senha de 4 a 8 números pedida para confirmar cada saída de dinheiro
create table if not exists public.conta_senhas (
  conta_id      uuid primary key references public.conta_contas(id) on delete cascade,
  resumo        text not null,          -- nunca a senha; só o resumo criptográfico
  tentativas    int  not null default 0,
  bloqueada_ate timestamptz,
  atualizada_em timestamptz not null default now()
);

-- Avisos recebidos do provedor (caixa de entrada). O mesmo aviso nunca é processado duas vezes.
create table if not exists public.conta_webhooks (
  id                bigint generated always as identity primary key,
  provedor_id       uuid not null references public.conta_provedores(id),
  evento            text not null,
  id_evento         text not null,
  assinatura_valida boolean not null,
  conteudo          jsonb not null,
  recebido_em       timestamptz not null default now(),
  processado_em     timestamptz,
  erro              text,
  unique (provedor_id, id_evento)
);

alter table public.conta_provedores        enable row level security;
alter table public.conta_contas            enable row level security;
alter table public.conta_chaves_pix        enable row level security;
alter table public.conta_movimentos        enable row level security;
alter table public.conta_movimento_eventos enable row level security;
alter table public.conta_pix_cobrancas     enable row level security;
alter table public.conta_pix_envios        enable row level security;
alter table public.conta_boletos           enable row level security;
alter table public.conta_pagamentos        enable row level security;
alter table public.conta_transferencias    enable row level security;
alter table public.conta_limites           enable row level security;
alter table public.conta_senhas            enable row level security;
alter table public.conta_webhooks          enable row level security;

-- =====================================================================
-- 2) PROTEÇÕES DO EXTRATO
-- =====================================================================

-- Lançamento não é apagado, e o que define o dinheiro não muda depois de criado.
create or replace function public.conta_movimento_protege()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Lançamento não pode ser apagado';
  end if;
  if new.conta_id <> old.conta_id or new.sentido <> old.sentido or new.valor_centavos <> old.valor_centavos
     or new.tipo <> old.tipo or new.idempotencia <> old.idempotencia then
    raise exception 'Conta, tipo, sentido e valor de um lançamento não podem ser alterados';
  end if;
  if old.status <> new.status then
    if not ((old.status = 'pendente' and new.status in ('liquidado','falhou'))
         or (old.status = 'liquidado' and new.status = 'devolvido')) then
      raise exception 'Mudança de situação não permitida: % para %', old.status, new.status;
    end if;
    insert into public.conta_movimento_eventos (movimento_id, de, para, detalhe)
    values (new.id, old.status, new.status, new.motivo_falha);
  end if;
  return new;
end;
$$;

drop trigger if exists conta_movimento_protege on public.conta_movimentos;
create trigger conta_movimento_protege
  before update or delete on public.conta_movimentos
  for each row execute function public.conta_movimento_protege();

-- Limites iniciais ao abrir a conta. São valores de partida: ajustar com a instituição parceira.
create or replace function public.conta_limites_iniciais()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  insert into public.conta_limites (conta_id, grupo, periodo, por_operacao_centavos, diario_centavos) values
    (new.id, 'pix',           'diurno',   500000,  1000000),
    (new.id, 'pix',           'noturno',  100000,   100000),
    (new.id, 'pagamento',     'diurno',  1000000,  2000000),
    (new.id, 'pagamento',     'noturno',  100000,   100000),
    (new.id, 'transferencia', 'diurno',  1000000,  2000000),
    (new.id, 'transferencia', 'noturno',  100000,   100000)
  on conflict do nothing;
  return new;
end;
$$;

drop trigger if exists conta_limites_iniciais on public.conta_contas;
create trigger conta_limites_iniciais
  after insert on public.conta_contas
  for each row execute function public.conta_limites_iniciais();

-- =====================================================================
-- 3) OPERAÇÕES (só o servidor chama)
-- =====================================================================

create or replace function public.conta_periodo_agora()
returns text
language sql
stable
set search_path = ''
as $$
  select case when extract(hour from now() at time zone 'America/Sao_Paulo') >= 20
                or extract(hour from now() at time zone 'America/Sao_Paulo') < 6
              then 'noturno' else 'diurno' end;
$$;

-- Saída de dinheiro, 1ª etapa: confere conta, limite e saldo, e separa o valor (fica "bloqueado").
-- Devolve o lançamento pendente. Chamar de novo com a mesma chave devolve o mesmo lançamento.
create or replace function public.conta_reservar(
  p_conta uuid, p_tipo text, p_valor bigint, p_idempotencia text,
  p_descricao text default null, p_contraparte jsonb default '{}'::jsonb,
  p_origem text default null, p_origem_id uuid default null
) returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_c     public.conta_contas%rowtype;
  v_id    uuid;
  v_grupo text;
  v_lim   public.conta_limites%rowtype;
  v_hoje  bigint;
begin
  select id into v_id from public.conta_movimentos where conta_id = p_conta and idempotencia = p_idempotencia;
  if v_id is not null then return v_id; end if;

  v_grupo := case p_tipo when 'pix_enviado' then 'pix' when 'pagamento_conta' then 'pagamento'
                         when 'transferencia_enviada' then 'transferencia' end;
  if v_grupo is null then raise exception 'Tipo de saída desconhecido'; end if;
  if p_valor is null or p_valor <= 0 then raise exception 'Valor inválido'; end if;

  select * into v_c from public.conta_contas where id = p_conta for update;
  if v_c.id is null then raise exception 'Conta não encontrada'; end if;
  if v_c.status <> 'ativa' then raise exception 'Conta não está ativa'; end if;

  select * into v_lim from public.conta_limites
   where conta_id = p_conta and grupo = v_grupo and periodo = public.conta_periodo_agora();
  if v_lim.conta_id is null then raise exception 'Limite não configurado'; end if;
  if p_valor > v_lim.por_operacao_centavos then raise exception 'Valor acima do limite por operação'; end if;

  select coalesce(sum(valor_centavos), 0) into v_hoje from public.conta_movimentos
   where conta_id = p_conta and sentido = 'D' and status in ('pendente','liquidado')
     and tipo = p_tipo
     and (criado_em at time zone 'America/Sao_Paulo')::date = (now() at time zone 'America/Sao_Paulo')::date;
  if v_hoje + p_valor > v_lim.diario_centavos then raise exception 'Valor acima do limite diário'; end if;

  if v_c.saldo_disponivel_centavos < p_valor then raise exception 'Saldo insuficiente'; end if;

  update public.conta_contas
     set saldo_disponivel_centavos = saldo_disponivel_centavos - p_valor,
         saldo_bloqueado_centavos  = saldo_bloqueado_centavos + p_valor,
         atualizado_em = now()
   where id = p_conta;

  insert into public.conta_movimentos (conta_id, tipo, sentido, valor_centavos, status, descricao,
    contraparte_nome, contraparte_documento, contraparte_instituicao, idempotencia, origem, origem_id)
  values (p_conta, p_tipo, 'D', p_valor, 'pendente', p_descricao,
    p_contraparte ->> 'nome', p_contraparte ->> 'documento', p_contraparte ->> 'instituicao',
    p_idempotencia, p_origem, p_origem_id)
  returning id into v_id;
  insert into public.conta_movimento_eventos (movimento_id, de, para) values (v_id, null, 'pendente');
  return v_id;
end;
$$;

-- Saída de dinheiro, 2ª etapa: o provedor confirmou. O valor sai de vez.
create or replace function public.conta_confirmar(p_movimento uuid, p_id_externo text default null, p_end_to_end text default null)
returns void
language plpgsql
set search_path = ''
as $$
declare v_m public.conta_movimentos%rowtype; v_saldo bigint;
begin
  select * into v_m from public.conta_movimentos where id = p_movimento for update;
  if v_m.id is null then raise exception 'Lançamento não encontrado'; end if;
  if v_m.status = 'liquidado' then return; end if;
  if v_m.status <> 'pendente' or v_m.sentido <> 'D' then raise exception 'Lançamento não está pendente'; end if;
  update public.conta_contas
     set saldo_bloqueado_centavos = saldo_bloqueado_centavos - v_m.valor_centavos, atualizado_em = now()
   where id = v_m.conta_id returning saldo_disponivel_centavos into v_saldo;
  update public.conta_movimentos
     set status = 'liquidado', liquidado_em = now(), saldo_apos_centavos = v_saldo,
         id_externo = coalesce(p_id_externo, id_externo), end_to_end_id = coalesce(p_end_to_end, end_to_end_id)
   where id = p_movimento;
end;
$$;

-- Saída de dinheiro que não aconteceu: o valor separado volta para o saldo.
create or replace function public.conta_desfazer(p_movimento uuid, p_motivo text)
returns void
language plpgsql
set search_path = ''
as $$
declare v_m public.conta_movimentos%rowtype;
begin
  select * into v_m from public.conta_movimentos where id = p_movimento for update;
  if v_m.id is null then raise exception 'Lançamento não encontrado'; end if;
  if v_m.status = 'falhou' then return; end if;
  if v_m.status <> 'pendente' or v_m.sentido <> 'D' then raise exception 'Lançamento não está pendente'; end if;
  update public.conta_contas
     set saldo_bloqueado_centavos  = saldo_bloqueado_centavos - v_m.valor_centavos,
         saldo_disponivel_centavos = saldo_disponivel_centavos + v_m.valor_centavos, atualizado_em = now()
   where id = v_m.conta_id;
  update public.conta_movimentos set status = 'falhou', motivo_falha = left(p_motivo, 300) where id = p_movimento;
end;
$$;

-- Entrada de dinheiro já confirmada pelo provedor (Pix recebido, boleto pago, devolução).
create or replace function public.conta_creditar(
  p_conta uuid, p_tipo text, p_valor bigint, p_idempotencia text,
  p_descricao text default null, p_contraparte jsonb default '{}'::jsonb,
  p_id_externo text default null, p_end_to_end text default null,
  p_origem text default 'webhook', p_origem_id uuid default null
) returns uuid
language plpgsql
set search_path = ''
as $$
declare v_id uuid; v_saldo bigint;
begin
  select id into v_id from public.conta_movimentos where conta_id = p_conta and idempotencia = p_idempotencia;
  if v_id is not null then return v_id; end if;
  if p_tipo not in ('pix_recebido','pix_devolucao_recebida','boleto_recebido','transferencia_recebida','ajuste') then
    raise exception 'Tipo de entrada desconhecido';
  end if;
  if p_valor is null or p_valor <= 0 then raise exception 'Valor inválido'; end if;
  update public.conta_contas
     set saldo_disponivel_centavos = saldo_disponivel_centavos + p_valor, atualizado_em = now()
   where id = p_conta and status in ('ativa','bloqueada')
  returning saldo_disponivel_centavos into v_saldo;
  if v_saldo is null then raise exception 'Conta não encontrada ou encerrada'; end if;
  insert into public.conta_movimentos (conta_id, tipo, sentido, valor_centavos, status, descricao,
    contraparte_nome, contraparte_documento, contraparte_instituicao, idempotencia, origem, origem_id,
    id_externo, end_to_end_id, saldo_apos_centavos, liquidado_em)
  values (p_conta, p_tipo, 'C', p_valor, 'liquidado', p_descricao,
    p_contraparte ->> 'nome', p_contraparte ->> 'documento', p_contraparte ->> 'instituicao',
    p_idempotencia, p_origem, p_origem_id, p_id_externo, p_end_to_end, v_saldo, now())
  returning id into v_id;
  insert into public.conta_movimento_eventos (movimento_id, de, para) values (v_id, null, 'liquidado');
  return v_id;
end;
$$;

-- Transferência entre duas contas Celeiro: sai de uma e entra na outra no mesmo instante, ou nada acontece.
create or replace function public.conta_transferir(
  p_origem uuid, p_destino uuid, p_valor bigint, p_idempotencia text, p_descricao text default null
) returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_t uuid; v_d uuid; v_c uuid; v_o public.conta_contas%rowtype; v_dest public.conta_contas%rowtype;
begin
  select t.id into v_t from public.conta_transferencias t
    join public.conta_movimentos m on m.id = t.movimento_debito_id
   where m.conta_id = p_origem and m.idempotencia = p_idempotencia;
  if v_t is not null then return v_t; end if;
  if p_origem = p_destino then raise exception 'Origem e destino são a mesma conta'; end if;

  -- trava as duas contas sempre na mesma ordem, para duas transferências cruzadas não travarem uma à outra
  perform 1 from public.conta_contas where id in (p_origem, p_destino) order by id for update;
  select * into v_o from public.conta_contas where id = p_origem;
  select * into v_dest from public.conta_contas where id = p_destino;
  if v_dest.id is null or v_dest.status <> 'ativa' then raise exception 'Conta de destino não encontrada ou inativa'; end if;

  insert into public.conta_transferencias (conta_origem_id, conta_destino_id, valor_centavos, descricao)
  values (p_origem, p_destino, p_valor, p_descricao) returning id into v_t;

  v_d := public.conta_reservar(p_origem, 'transferencia_enviada', p_valor, p_idempotencia, p_descricao,
           jsonb_build_object('nome', v_dest.titular, 'instituicao', 'Celeiro'), 'transferencia', v_t);
  perform public.conta_confirmar(v_d);
  v_c := public.conta_creditar(p_destino, 'transferencia_recebida', p_valor, 'transf-' || v_t::text, p_descricao,
           jsonb_build_object('nome', v_o.titular, 'instituicao', 'Celeiro'), null, null, 'transferencia', v_t);
  update public.conta_transferencias set movimento_debito_id = v_d, movimento_credito_id = v_c where id = v_t;
  return v_t;
end;
$$;

-- Senha de confirmação: define
create or replace function public.conta_definir_senha(p_conta uuid, p_senha text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  if p_senha !~ '^[0-9]{4,8}$' then raise exception 'A senha deve ter de 4 a 8 números'; end if;
  if p_senha ~ '^(.)\1+$' or p_senha in ('1234','12345','123456','4321','654321') then
    raise exception 'Escolha uma senha menos óbvia';
  end if;
  insert into public.conta_senhas (conta_id, resumo)
  values (p_conta, extensions.crypt(p_senha, extensions.gen_salt('bf', 10)))
  on conflict (conta_id) do update
    set resumo = excluded.resumo, tentativas = 0, bloqueada_ate = null, atualizada_em = now();
end;
$$;

-- Senha de confirmação: confere. Cinco erros seguidos bloqueiam por 30 minutos.
create or replace function public.conta_conferir_senha(p_conta uuid, p_senha text)
returns boolean
language plpgsql
set search_path = ''
as $$
declare v_s public.conta_senhas%rowtype;
begin
  select * into v_s from public.conta_senhas where conta_id = p_conta for update;
  if v_s.conta_id is null then raise exception 'Senha de confirmação não cadastrada'; end if;
  if v_s.bloqueada_ate is not null and v_s.bloqueada_ate > now() then
    raise exception 'Senha bloqueada por tentativas erradas. Tente mais tarde.';
  end if;
  if v_s.resumo = extensions.crypt(coalesce(p_senha, ''), v_s.resumo) then
    update public.conta_senhas set tentativas = 0, bloqueada_ate = null where conta_id = p_conta;
    return true;
  end if;
  update public.conta_senhas
     set tentativas = tentativas + 1,
         bloqueada_ate = case when tentativas + 1 >= 5 then now() + interval '30 minutes' end
   where conta_id = p_conta;
  return false;
end;
$$;

-- =====================================================================
-- 4) O QUE A TELA DO CLIENTE CHAMA
-- =====================================================================

-- Resumo para a tela inicial: conta, saldos, chaves e boletos a vencer
create or replace function public.conta_resumo()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_c public.conta_contas%rowtype;
begin
  if not public.acesso_confirmado() then raise exception 'Acesso negado'; end if;
  select * into v_c from public.conta_contas
   where user_id = (select auth.uid()) and status <> 'encerrada' order by criado_em limit 1;
  if v_c.id is null then return jsonb_build_object('conta', null); end if;
  return jsonb_build_object(
    'conta', jsonb_build_object('id', v_c.id, 'titular', v_c.titular, 'status', v_c.status,
               'agencia', v_c.agencia, 'numero', v_c.numero,
               'saldo_disponivel_centavos', v_c.saldo_disponivel_centavos,
               'saldo_bloqueado_centavos', v_c.saldo_bloqueado_centavos,
               'saldo_conferido_em', v_c.saldo_conferido_em,
               'tem_senha', exists (select 1 from public.conta_senhas s where s.conta_id = v_c.id)),
    'chaves', coalesce((select jsonb_agg(jsonb_build_object('tipo', k.tipo, 'chave', k.chave, 'status', k.status))
                        from public.conta_chaves_pix k where k.conta_id = v_c.id and k.status <> 'removida'), '[]'::jsonb),
    'boletos_a_receber', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'pagador', b.pagador_nome,
                          'valor_centavos', b.valor_centavos, 'vencimento', b.vencimento) order by b.vencimento)
                        from public.conta_boletos b where b.conta_id = v_c.id and b.status = 'registrado'), '[]'::jsonb),
    'limites', coalesce((select jsonb_agg(jsonb_build_object('grupo', l.grupo, 'periodo', l.periodo,
                          'por_operacao_centavos', l.por_operacao_centavos, 'diario_centavos', l.diario_centavos))
                        from public.conta_limites l where l.conta_id = v_c.id), '[]'::jsonb));
end;
$$;

-- =====================================================================
-- 5) PERMISSÕES
-- =====================================================================

revoke all on public.conta_provedores, public.conta_contas, public.conta_chaves_pix, public.conta_movimentos,
  public.conta_movimento_eventos, public.conta_pix_cobrancas, public.conta_pix_envios, public.conta_boletos,
  public.conta_pagamentos, public.conta_transferencias, public.conta_limites, public.conta_senhas,
  public.conta_webhooks from anon, authenticated;

-- O cliente só lê; senhas e avisos do provedor não são lidos por ninguém além do servidor.
grant select on public.conta_contas, public.conta_chaves_pix, public.conta_movimentos, public.conta_pix_cobrancas,
  public.conta_pix_envios, public.conta_boletos, public.conta_pagamentos, public.conta_transferencias,
  public.conta_limites to authenticated;

revoke all on function public.conta_reservar(uuid, text, bigint, text, text, jsonb, text, uuid) from public, anon, authenticated;
revoke all on function public.conta_confirmar(uuid, text, text) from public, anon, authenticated;
revoke all on function public.conta_desfazer(uuid, text) from public, anon, authenticated;
revoke all on function public.conta_creditar(uuid, text, bigint, text, text, jsonb, text, text, text, uuid) from public, anon, authenticated;
revoke all on function public.conta_transferir(uuid, uuid, bigint, text, text) from public, anon, authenticated;
revoke all on function public.conta_definir_senha(uuid, text) from public, anon, authenticated;
revoke all on function public.conta_conferir_senha(uuid, text) from public, anon, authenticated;
revoke all on function public.conta_resumo() from public, anon;

grant execute on function public.conta_reservar(uuid, text, bigint, text, text, jsonb, text, uuid) to service_role;
grant execute on function public.conta_confirmar(uuid, text, text) to service_role;
grant execute on function public.conta_desfazer(uuid, text) to service_role;
grant execute on function public.conta_creditar(uuid, text, bigint, text, text, jsonb, text, text, text, uuid) to service_role;
grant execute on function public.conta_transferir(uuid, uuid, bigint, text, text) to service_role;
grant execute on function public.conta_definir_senha(uuid, text) to service_role;
grant execute on function public.conta_conferir_senha(uuid, text) to service_role;
grant execute on function public.conta_resumo() to authenticated;

-- =====================================================================
-- 6) REGRAS DE ACESSO POR LINHA
--    Cliente: só a própria conta. Administrador do site com as duas etapas: leitura de tudo.
--    Não existe regra de gravação: nenhuma tela grava nestas tabelas.
-- =====================================================================

create or replace function public.conta_e_minha(p_conta uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (select 1 from public.conta_contas c where c.id = p_conta and c.user_id = (select auth.uid()));
$$;
revoke all on function public.conta_e_minha(uuid) from public, anon;
grant execute on function public.conta_e_minha(uuid) to authenticated;

drop policy if exists "conta: titular le" on public.conta_contas;
create policy "conta: titular le" on public.conta_contas for select to authenticated
  using (user_id = (select auth.uid()) or (select public.eh_admin_2fa()));

drop policy if exists "chaves: titular le" on public.conta_chaves_pix;
create policy "chaves: titular le" on public.conta_chaves_pix for select to authenticated
  using ((select public.conta_e_minha(conta_id)) or (select public.eh_admin_2fa()));

drop policy if exists "movimentos: titular le" on public.conta_movimentos;
create policy "movimentos: titular le" on public.conta_movimentos for select to authenticated
  using ((select public.conta_e_minha(conta_id)) or (select public.eh_admin_2fa()));

drop policy if exists "cobrancas pix: titular le" on public.conta_pix_cobrancas;
create policy "cobrancas pix: titular le" on public.conta_pix_cobrancas for select to authenticated
  using ((select public.conta_e_minha(conta_id)) or (select public.eh_admin_2fa()));

drop policy if exists "envios pix: titular le" on public.conta_pix_envios;
create policy "envios pix: titular le" on public.conta_pix_envios for select to authenticated
  using ((select public.conta_e_minha(conta_id)) or (select public.eh_admin_2fa()));

drop policy if exists "boletos: titular le" on public.conta_boletos;
create policy "boletos: titular le" on public.conta_boletos for select to authenticated
  using ((select public.conta_e_minha(conta_id)) or (select public.eh_admin_2fa()));

drop policy if exists "pagamentos: titular le" on public.conta_pagamentos;
create policy "pagamentos: titular le" on public.conta_pagamentos for select to authenticated
  using ((select public.conta_e_minha(conta_id)) or (select public.eh_admin_2fa()));

drop policy if exists "transferencias: partes leem" on public.conta_transferencias;
create policy "transferencias: partes leem" on public.conta_transferencias for select to authenticated
  using ((select public.conta_e_minha(conta_origem_id)) or (select public.conta_e_minha(conta_destino_id))
         or (select public.eh_admin_2fa()));

drop policy if exists "limites: titular le" on public.conta_limites;
create policy "limites: titular le" on public.conta_limites for select to authenticated
  using ((select public.conta_e_minha(conta_id)) or (select public.eh_admin_2fa()));
