// Celeiro Office · função "financeiro-integracao" (Supabase Edge Function)
//
// Leva cobranças (boleto e Pix) e notas fiscais de serviço do Financeiro para o
// provedor (a API do banco, do gateway de pagamento ou do emissor de notas) e
// recebe de volta o aviso de pagamento, que baixa o título sozinho.
//
// O PROVEDOR AINDA NÃO FOI ESCOLHIDO. Enquanto os segredos abaixo não existirem,
// a função responde "sem_provedor" e os pedidos ficam aguardando no sistema.
// Para ligar um provedor: escreva o adaptador dele em PROVEDORES (o formato está
// descrito logo abaixo) e informe o nome nos segredos.
//
// Segredos (Edge Functions → Secrets):
//   FIN_COBRANCA_PROVEDOR   nome do adaptador que emite boleto e Pix
//   FIN_NOTA_PROVEDOR       nome do adaptador que emite nota fiscal de serviço
//   FIN_WEBHOOK_SEGREDO     texto longo e aleatório que o provedor envia junto com os avisos
//   + as chaves do próprio provedor, lidas dentro do adaptador com segredo('NOME')
//
// Chamadas:
//   POST com sessão (segundo fator)  { acao: 'situacao' }
//                                    { acao: 'emitir' | 'cancelar', tipo: 'cobranca' | 'nota', id }
//   POST sem sessão ?aviso=<provedor>   aviso de pagamento do provedor. Exige o segredo no
//                                       cabeçalho x-webhook-segredo ou em ?segredo=
//
// Em "Verify JWT" do painel, esta função fica DESLIGADA (o aviso do provedor não tem sessão);
// a própria função confere a sessão nas chamadas do sistema.

import { withSupabase } from 'npm:@supabase/server@1'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

function resposta(corpo, status) {
  return Response.json(corpo, { status: status || 200 })
}

function segredo(nome) {
  return (Deno.env.get(nome) || '').trim()
}

// ---------------------------------------------------------------------------
// ADAPTADORES DE PROVEDOR
//
// Cada adaptador é um objeto com as funções que souber fazer. Todas recebem os
// dados prontos do banco (emitente, pagador e a cobrança ou a nota) e devolvem
// um objeto simples; nenhuma mexe no banco.
//
//   emitirCobranca(d)   d.cobranca = { id, meio: 'boleto' | 'pix', valor, vencimento, descricao, titulo }
//                       d.pagador  = { nome, documento, endereco, email }   d.emitente = { nome, cnpj, ... }
//       → { provedor_id, linha_digitavel?, pix_copia_cola?, url? }
//   cancelarCobranca(d) d.cobranca.provedor_id → {} (lança erro se o provedor recusar)
//   emitirNota(d)       d.nota = { id, valor, descricao_servico, codigo_servico, aliquota_iss, fatura, emissao }
//       → { provedor_id, numero?, codigo_verificacao?, url_pdf?, url_xml? }
//   cancelarNota(d)     d.nota.provedor_id → {}
//   lerAviso(corpo, req) corpo do aviso de pagamento, já em JSON
//       → { provedor_id, pago: true | false, data?: 'AAAA-MM-DD', valor?: número } ou null para ignorar
//
// Erros: lance new Error('mensagem que o usuário pode ler'). Ela aparece na tela.
// ---------------------------------------------------------------------------
const PROVEDORES = {
  // Só para ensaiar o fluxo de ponta a ponta. Não gera cobrança nem nota de verdade.
  simulado: {
    emitirCobranca: async (d) => ({
      provedor_id: 'SIM-' + d.cobranca.id,
      linha_digitavel: d.cobranca.meio === 'boleto' ? 'SIMULAÇÃO · sem valor para pagamento' : '',
      pix_copia_cola: d.cobranca.meio === 'pix' ? 'SIMULAÇÃO · sem valor para pagamento' : '',
    }),
    cancelarCobranca: async () => ({}),
    emitirNota: async (d) => ({ provedor_id: 'SIM-' + d.nota.id, numero: 'SIMULAÇÃO' }),
    cancelarNota: async () => ({}),
    lerAviso: async (corpo) =>
      corpo && corpo.provedor_id ? { provedor_id: String(corpo.provedor_id), pago: corpo.pago === true, data: corpo.data, valor: corpo.valor } : null,
  },
}

function provedorDe(tipo) {
  const nome = segredo(tipo === 'nota' ? 'FIN_NOTA_PROVEDOR' : 'FIN_COBRANCA_PROVEDOR').toLowerCase()
  const p = nome ? PROVEDORES[nome] : null
  return { nome: nome, adaptador: p || null }
}

function iguais(a, b) {
  if (!a || !b || a.length !== b.length) return false
  let d = 0
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return d === 0
}

function textoErro(e) {
  return String((e && e.message) || 'Falha ao falar com o provedor.').slice(0, 280)
}

async function aviso(req, ctx, nome) {
  const esperado = segredo('FIN_WEBHOOK_SEGREDO')
  const url = new URL(req.url)
  const recebido = (req.headers.get('x-webhook-segredo') || url.searchParams.get('segredo') || '').trim()
  if (!esperado || !iguais(recebido, esperado)) return resposta({ erro: 'Não autorizado.' }, 401)
  const p = PROVEDORES[nome]
  if (!p || !p.lerAviso || nome !== provedorDe('cobranca').nome) return resposta({ erro: 'Provedor desconhecido.' }, 404)
  let corpo
  try {
    corpo = await req.json()
  } catch (_e) {
    return resposta({ erro: 'Dados inválidos.' }, 400)
  }
  let lido
  try {
    lido = await p.lerAviso(corpo, req)
  } catch (e) {
    console.error('Aviso do provedor não entendido:', textoErro(e))
    return resposta({ erro: 'Aviso não entendido.' }, 400)
  }
  if (!lido || !lido.pago || !lido.provedor_id) return resposta({ ok: true, situacao: 'ignorado' })
  const data = /^\d{4}-\d{2}-\d{2}$/.test(String(lido.data || '')) ? lido.data : null
  const valor = Number.isFinite(Number(lido.valor)) && lido.valor !== null && lido.valor !== undefined ? Number(lido.valor) : null
  const r = await ctx.supabaseAdmin.rpc('fin_cobranca_liquidar', {
    p_provedor: nome, p_provedor_id: String(lido.provedor_id).slice(0, 120), p_data: data, p_valor: valor,
  })
  if (r.error) {
    console.error('Não foi possível registrar o pagamento:', r.error.message)
    return resposta({ erro: 'Não foi possível registrar o pagamento.' }, 500)
  }
  return resposta({ ok: true, situacao: r.data && r.data.situacao })
}

export default {
  fetch: withSupabase({ auth: ['user', 'none'] }, async (req, ctx) => {
    if (req.method !== 'POST') return resposta({ erro: 'Método não permitido.' }, 405)
    const nomeAviso = new URL(req.url).searchParams.get('aviso')
    if (nomeAviso !== null) return aviso(req, ctx, nomeAviso.toLowerCase())
    if (ctx.authMode !== 'user') return resposta({ erro: 'Entre no sistema para continuar.' }, 401)

    let dados
    try {
      dados = await req.json()
    } catch (_e) {
      return resposta({ erro: 'Dados inválidos.' }, 400)
    }
    const acao = String((dados && dados.acao) || '')
    if (acao === 'situacao') {
      const c = provedorDe('cobranca'), n = provedorDe('nota')
      return resposta({
        cobranca: { provedor: c.adaptador ? c.nome : '', pronto: !!(c.adaptador && c.adaptador.emitirCobranca) },
        nota: { provedor: n.adaptador ? n.nome : '', pronto: !!(n.adaptador && n.adaptador.emitirNota) },
        aviso: !!segredo('FIN_WEBHOOK_SEGREDO'),
      })
    }
    const tipo = String((dados && dados.tipo) || '')
    const id = String((dados && dados.id) || '')
    if ((acao !== 'emitir' && acao !== 'cancelar') || (tipo !== 'cobranca' && tipo !== 'nota') || !UUID.test(id)) {
      return resposta({ erro: 'Dados inválidos.' }, 400)
    }

    // Quem chama alcança este registro? (exige segundo fator e o módulo Financeiro)
    const pode = await ctx.supabase.rpc('fin_integracao_pode', { p_tipo: tipo, p_id: id })
    if (pode.error) return resposta({ erro: 'Não foi possível conferir sua permissão: ' + pode.error.message }, 400)
    if (pode.data !== true) return resposta({ erro: 'Você não alcança este registro.' }, 403)

    const lido = await ctx.supabaseAdmin.rpc('fin_integracao_dados', { p_tipo: tipo, p_id: id })
    if (lido.error || !lido.data) return resposta({ erro: 'Registro não encontrado.' }, 404)
    const d = lido.data
    const reg = d[tipo]
    const registrar = (campos) => ctx.supabaseAdmin.rpc('fin_integracao_registrar', { p_tipo: tipo, p_id: id, p_dados: campos })

    if (acao === 'emitir') {
      if (reg.status === 'emitida') return resposta({ situacao: 'emitida' })
      if (reg.status !== 'aguardando' && reg.status !== 'falhou') return resposta({ erro: 'Este pedido já foi encerrado.' }, 409)
      if (tipo === 'cobranca' && reg.titulo_status !== 'aberto') return resposta({ erro: 'O título não está mais em aberto.' }, 409)
      const p = provedorDe(tipo)
      const fn = p.adaptador && (tipo === 'cobranca' ? p.adaptador.emitirCobranca : p.adaptador.emitirNota)
      if (!fn) return resposta({ situacao: 'sem_provedor' })
      let saida
      try {
        saida = await fn(d)
      } catch (e) {
        console.error('Provedor recusou a emissão:', textoErro(e))
        const g = await registrar({ status: 'falhou', provedor: p.nome, mensagem: textoErro(e) })
        if (g.error) console.error('Falha não registrada:', g.error.message)
        return resposta({ situacao: 'falhou', mensagem: textoErro(e) })
      }
      const g = await registrar(Object.assign({}, saida || {}, { status: 'emitida', provedor: p.nome, mensagem: '' }))
      if (g.error) return resposta({ erro: 'Emitido no provedor, mas não foi possível gravar: ' + g.error.message }, 500)
      return resposta({ situacao: 'emitida' })
    }

    // cancelar
    if (reg.status !== 'emitida') return resposta({ erro: 'Só o que já foi emitido é cancelado por aqui.' }, 409)
    const p = PROVEDORES[reg.provedor]
    const fn = p && (tipo === 'cobranca' ? p.cancelarCobranca : p.cancelarNota)
    if (!fn) return resposta({ erro: 'O provedor que emitiu não está mais ligado. Cancele direto com ele.' }, 409)
    try {
      await fn(d)
    } catch (e) {
      console.error('Provedor recusou o cancelamento:', textoErro(e))
      return resposta({ erro: 'O provedor não cancelou: ' + textoErro(e) }, 502)
    }
    const g = await registrar({ status: 'cancelada', mensagem: '' })
    if (g.error) return resposta({ erro: 'Cancelado no provedor, mas não foi possível gravar: ' + g.error.message }, 500)
    return resposta({ situacao: 'cancelada' })
  }),
}
