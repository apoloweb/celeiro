# Conta Celeiro (conta de pagamento) — estrutura

Estrutura para a conta de pagamento da Celeiro: cash in e cash out por Pix, emissão de boletos, transferências entre contas Celeiro e pagamento de contas.

**Situação: estrutura e protótipo. Nada aqui move dinheiro.** Falta escolher a instituição financeira e ligar a API dela.

## Arquivos

| Arquivo | O que é | Situação |
|---|---|---|
| `index.html` | Protótipo navegável das telas, com dados fictícios | Testado em navegador (21 verificações) |
| `supabase-conta.sql` | Banco: tabelas, regras de acesso e operações do extrato | Testado em Postgres local (50 verificações). Não rodado no Supabase real |
| `provedor.ts` | Contrato entre o servidor da Celeiro e a instituição financeira | Só o contrato; nenhuma instituição ligada |
| `LEIA-ME.md` | Este guia, com a API do servidor | |

A pasta está no `.vercelignore`: não é publicada com o site, para um protótipo com saldos fictícios não aparecer no domínio oficial.

## Como as peças se encaixam

    Tela (app ou área do cliente)
        │  só lê o banco; para mover dinheiro, chama o servidor
        ▼
    Servidor da Celeiro (funções do Supabase)
        │  confere login, senha de confirmação, limite e saldo; grava o pedido
        ▼
    Adaptador do provedor  ──►  API da instituição financeira (autorizada pelo BCB)
        ▲                                   │
        └────── avisos (webhooks) ◄─────────┘   confirmação, recusa, Pix recebido, boleto pago

Três regras que valem para tudo:

1. **A conta e o dinheiro ficam na instituição financeira.** O banco da Celeiro guarda o espelho: o que mostrar, o que foi pedido e em que situação está. O saldo de referência é sempre o da instituição.
2. **A tela nunca grava.** O cliente só lê os próprios dados. Toda gravação passa pelo servidor.
3. **Toda saída tem duas etapas.** Primeiro o valor é separado (fica "em processamento"); só sai de vez quando a instituição confirma. Se ela recusar, o valor volta.

## Banco (`supabase-conta.sql`)

| Tabela | Guarda |
|---|---|
| `conta_provedores` | Instituições financeiras ligadas |
| `conta_contas` | A conta de cada cliente, a situação e o espelho dos saldos |
| `conta_chaves_pix` | Chaves Pix da conta |
| `conta_movimentos` | O extrato: cada entrada (C) ou saída (D), com situação e identificadores |
| `conta_movimento_eventos` | Histórico de situação de cada lançamento |
| `conta_pix_cobrancas` | Cash in: cobranças Pix (QR Code e copia e cola) |
| `conta_pix_envios` | Cash out: Pix enviados |
| `conta_boletos` | Boletos emitidos pelo cliente |
| `conta_pagamentos` | Contas pagas pelo cliente (boleto, consumo, tributo), inclusive agendadas |
| `conta_transferencias` | Transferências entre contas Celeiro |
| `conta_limites` | Limites por conta: Pix, pagamento e transferência, de dia e de noite |
| `conta_senhas` | Senha de confirmação (só o resumo criptográfico) |
| `conta_webhooks` | Avisos recebidos da instituição, sem repetição |

Operações do extrato (só o servidor chama):

| Função | O que faz |
|---|---|
| `conta_reservar` | Confere conta ativa, limite e saldo e separa o valor de uma saída |
| `conta_confirmar` | A instituição confirmou: o valor sai de vez |
| `conta_desfazer` | A instituição recusou: o valor volta ao saldo |
| `conta_creditar` | Entrada confirmada (Pix recebido, boleto pago, devolução) |
| `conta_transferir` | Transferência entre duas contas Celeiro, tudo ou nada |
| `conta_definir_senha`, `conta_conferir_senha` | Senha de confirmação; cinco erros bloqueiam por 30 minutos |
| `conta_resumo` | A única que a tela chama: conta, saldos, chaves, boletos a receber e limites do próprio cliente |

Proteções conferidas nos testes: pedido repetido não debita duas vezes; lançamento não é apagado nem tem o valor alterado; saldo nunca fica negativo; a soma do extrato bate com os saldos; cliente não vê conta de outro, não grava nada e não chama as operações; administrador do site só lê, e só com o autenticador.

Valores sempre em centavos. Os limites iniciais do arquivo são valores de partida, a ajustar com a instituição.

## API do servidor (a construir sobre este banco)

Todas exigem o login do cliente. As que movem dinheiro exigem também a senha de confirmação e uma chave de idempotência (cabeçalho `Idempotency-Key`).

| Método e caminho | Para quê | Chama no provedor |
|---|---|---|
| `POST /conta` | Pedir abertura da conta | `abrirConta` |
| `GET /conta` | Conta, saldos, chaves e limites | `consultarSaldo` (conferência) |
| `GET /extrato?de=&ate=` | Lançamentos | — |
| `POST /pix/chaves` · `DELETE /pix/chaves/{chave}` | Cadastrar e remover chave | `registrarChave`, `removerChave` |
| `POST /pix/consultas` | Conferir o destinatário antes de enviar | `consultarChave`, `lerCopiaECola` |
| `POST /pix/envios` | **Cash out por Pix** | `enviarPix` |
| `POST /pix/cobrancas` | **Cash in por Pix** (QR Code) | `criarCobrancaPix` |
| `POST /pix/devolucoes` | Devolver um Pix recebido | `devolverPix` |
| `POST /boletos` · `DELETE /boletos/{id}` | **Emitir e cancelar boleto** | `emitirBoleto`, `cancelarBoleto` |
| `POST /pagamentos/consultas` | Ler a linha digitável (valor do dia) | `consultarLinhaDigitavel` |
| `POST /pagamentos` | **Pagar conta**, agora ou agendado | `pagarConta` |
| `POST /transferencias` | **Transferência entre contas Celeiro** | `transferirInterna` |
| `PUT /senha` | Definir ou trocar a senha de confirmação | — |
| `PUT /limites` | Pedir mudança de limite | conforme a instituição |
| `POST /avisos/{provedor}` | Receber avisos da instituição | `lerAviso` |

Caminho de uma saída (Pix, pagamento ou transferência):

1. O servidor confere o login e a senha de confirmação (`conta_conferir_senha`).
2. `conta_reservar` confere limite e saldo e separa o valor.
3. O servidor chama a instituição com a mesma chave de idempotência.
4. Recusa imediata: `conta_desfazer`. Aceite: aguarda o aviso.
5. O aviso chega em `/avisos/{provedor}`, tem a assinatura conferida, é gravado em `conta_webhooks` e vira `conta_confirmar` ou `conta_desfazer`.

Caminho de uma entrada: o aviso de Pix recebido ou boleto pago vira `conta_creditar`, usando o identificador do aviso como chave de idempotência.

Conferência diária: comparar o saldo espelhado com `consultarSaldo` de cada conta e alertar diferenças.

## Telas (`index.html`)

Tema escuro da marca Celeiro. A tela inicial segue a estrutura pedida: saudação, ajuda e avisos, ocultar valores, cartões de saldo, campo para colar chave Pix, atalhos, contas a vencer e barra de navegação flutuante.

Fluxos: enviar Pix, receber Pix, chaves, transferir, pagar conta, emitir e acompanhar boleto, extrato com filtro, comprovante, limites, segurança. Toda saída pede a senha de confirmação (na demonstração, 4827).

O "servidor" do protótipo roda no navegador, com as mesmas regras do banco. Códigos Pix e linhas digitáveis exibidos são falsos de propósito e não funcionam em nenhum banco.

## O que falta decidir e fazer

1. **Instituição financeira.** Precisa ser autorizada pelo BCB a manter contas de pagamento e a operar Pix. O contrato com ela define tarifas, limites, horários e quem faz a análise cadastral (KYC) e a prevenção à lavagem de dinheiro.
2. **Modelo de conta.** Este desenho supõe uma conta por cliente, em nome dele, na instituição. Guardar o dinheiro de vários clientes em uma única conta da Celeiro é outro modelo, com exigências regulatórias próprias: confirmar com a instituição e com o jurídico antes.
3. **Adaptador do provedor** (`provedor.ts` implementado para a API escolhida) e as funções do servidor.
4. **Onde o banco fica.** O arquivo foi escrito para o Supabase do site, onde já estão as contas dos clientes. Avaliar um projeto separado para os dados financeiros.
5. **Regras a conferir com a instituição:** limite noturno do Pix, quantidade de chaves por conta, prazos de devolução, horários de liquidação de boletos.
6. **Termos de Uso e Política de Privacidade** específicos da conta, e canal de atendimento e de contestação.
7. **Segurança adicional:** biometria do aparelho, cadastro de aparelho confiável, alerta de novo acesso.
