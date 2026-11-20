// Celeiro · conta de pagamento
// Contrato único entre o servidor da Celeiro e a instituição financeira autorizada pelo BCB.
//
// Cada instituição (o "provedor") ganha um arquivo que implementa esta interface, traduzindo
// para a API dela. O resto do sistema (telas, banco, regras) não muda quando o provedor muda.
//
// Convenções:
//   • valores em centavos (number inteiro);
//   • toda chamada que move dinheiro recebe `idempotencia`: repetir a chamada não repete a operação;
//   • o provedor responde "aceito" e confirma depois por aviso (webhook). O dinheiro só é dado
//     como liquidado quando o aviso chega e é validado.

export type Centavos = number;
export type TipoPessoa = "PF" | "PJ";
export type TipoChavePix = "cpf" | "cnpj" | "email" | "telefone" | "aleatoria";

export interface Titular {
  tipoPessoa: TipoPessoa;
  documento: string;          // só números
  nome: string;
  email: string;
  celular: string;
  nascimento?: string;        // AAAA-MM-DD (PF)
  responsavelLegal?: string;  // PJ
}

export interface ContaAberta {
  idExterno: string;
  status: "em_analise" | "ativa" | "recusada";
  agencia?: string;
  numero?: string;
  pendencias?: string[];      // documentos que a instituição ainda pede (KYC)
}

export interface Saldo { disponivel: Centavos; bloqueado: Centavos; consultadoEm: string }

export interface DestinoPix {
  chave: string;
  nome: string;
  documentoMascarado: string; // como devolvido pelo DICT, ex.: ***.123.456-**
  instituicao: string;
  ispb: string;
  endToEndId: string;         // reservado na consulta e usado no envio
}

export interface OperacaoAceita {
  idExterno: string;
  status: "aceito" | "liquidado" | "recusado";
  endToEndId?: string;
  autenticacao?: string;
  motivo?: string;
}

export interface CobrancaPix { txid: string; copiaECola: string; expiraEm?: string }

export interface BoletoEmitido {
  idExterno: string;
  nossoNumero: string;
  linhaDigitavel: string;
  codigoBarras: string;
  pixCopiaECola?: string;
  urlPdf?: string;
}

export interface BoletoConsultado {
  tipo: "boleto" | "consumo" | "tributo";
  beneficiario: string;
  valor: Centavos;            // já com multa, juros e desconto do dia
  valorOriginal?: Centavos;
  vencimento?: string;
  podePagarAgora: boolean;    // fora do horário de liquidação o provedor pode só agendar
  motivo?: string;
}

// O que o provedor avisa. Cada provedor tem o seu formato; o adaptador converte para este.
export type Aviso =
  | { tipo: "pix_recebido"; idEvento: string; contaIdExterno: string; valor: Centavos; endToEndId: string; txid?: string;
      pagador: { nome: string; documentoMascarado: string; instituicao: string }; descricao?: string }
  | { tipo: "pix_enviado_liquidado" | "pix_enviado_recusado"; idEvento: string; idExterno: string; endToEndId?: string; motivo?: string }
  | { tipo: "pix_devolvido"; idEvento: string; endToEndIdOriginal: string; valor: Centavos; sentido: "recebida" | "enviada" }
  | { tipo: "boleto_registrado" | "boleto_rejeitado" | "boleto_cancelado"; idEvento: string; idExterno: string; motivo?: string }
  | { tipo: "boleto_pago"; idEvento: string; idExterno: string; valorPago: Centavos; pagoEm: string }
  | { tipo: "pagamento_liquidado" | "pagamento_recusado"; idEvento: string; idExterno: string; autenticacao?: string; motivo?: string }
  | { tipo: "conta_status"; idEvento: string; contaIdExterno: string; status: "ativa" | "bloqueada" | "encerrada" | "recusada" }
  | { tipo: "chave_pix_status"; idEvento: string; chave: string; status: "ativa" | "em_portabilidade" | "removida" };

export interface Provedor {
  /** Código gravado em conta_provedores.codigo */
  readonly codigo: string;

  // ---- Conta ----
  abrirConta(titular: Titular, idempotencia: string): Promise<ContaAberta>;
  consultarSaldo(contaIdExterno: string): Promise<Saldo>;

  // ---- Pix: chaves ----
  registrarChave(contaIdExterno: string, tipo: TipoChavePix, chave: string | null, idempotencia: string): Promise<{ chave: string; status: "ativa" | "em_registro" }>;
  removerChave(contaIdExterno: string, chave: string): Promise<void>;

  // ---- Pix: cash out ----
  /** Consulta a chave no DICT. Obrigatória antes de enviar, para o cliente conferir o nome. */
  consultarChave(contaIdExterno: string, chave: string): Promise<DestinoPix>;
  enviarPix(contaIdExterno: string, destino: DestinoPix, valor: Centavos, descricao: string | null, idempotencia: string): Promise<OperacaoAceita>;
  /** Lê um QR Code ou copia e cola e devolve o destino e o valor, quando houver. */
  lerCopiaECola(contaIdExterno: string, copiaECola: string): Promise<{ destino: DestinoPix; valor?: Centavos; descricao?: string }>;

  // ---- Pix: cash in ----
  criarCobrancaPix(contaIdExterno: string, chave: string, valor: Centavos | null, descricao: string | null, expiraEmSegundos: number, idempotencia: string): Promise<CobrancaPix>;
  devolverPix(contaIdExterno: string, endToEndIdOriginal: string, valor: Centavos, motivo: string, idempotencia: string): Promise<OperacaoAceita>;

  // ---- Boletos emitidos (cobrança) ----
  emitirBoleto(contaIdExterno: string, boleto: {
    pagador: { nome: string; documento: string; endereco?: Record<string, string> };
    valor: Centavos; vencimento: string; descricao?: string; multaPercentual?: number; jurosMesPercentual?: number;
  }, idempotencia: string): Promise<BoletoEmitido>;
  cancelarBoleto(contaIdExterno: string, idExterno: string): Promise<void>;

  // ---- Pagamento de contas ----
  consultarLinhaDigitavel(contaIdExterno: string, linhaDigitavel: string): Promise<BoletoConsultado>;
  pagarConta(contaIdExterno: string, linhaDigitavel: string, valor: Centavos, agendarPara: string | null, idempotencia: string): Promise<OperacaoAceita>;

  // ---- Transferência entre contas Celeiro no mesmo provedor ----
  transferirInterna(origemIdExterno: string, destinoIdExterno: string, valor: Centavos, descricao: string | null, idempotencia: string): Promise<OperacaoAceita>;

  // ---- Avisos ----
  /** Confere a assinatura do aviso e o converte. Devolve null quando a assinatura não confere. */
  lerAviso(cabecalhos: Headers, corpo: string): Promise<Aviso | null>;
}
