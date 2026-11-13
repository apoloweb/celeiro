// Celeiro Office · função "enviar-verificacao" (Supabase Edge Function)
//
// Envia o código de verificação de contato por e-mail (Resend) e por WhatsApp (Z-API)
// para uma pessoa do Cadastro ou para um usuário do sistema.
//
// Só atende quem está logado com o segundo fator e pode alterar aquele registro
// (a regra fica no banco, em public.verificacao_pode). O código é gerado no banco,
// passa só por aqui para ser enviado e nunca volta para o navegador.
//
// Segredos (Edge Functions → Secrets). Sem eles, o canal responde "nao_configurado":
//   RESEND_API_KEY           chave da Resend
//   VERIFICACAO_REMETENTE    opcional. Padrão: Celeiro Administradora <nao-responda@celeiroadministradora.com.br>
//   ZAPI_INSTANCE_ID         identificador da instância na Z-API
//   ZAPI_TOKEN               token da instância na Z-API
//   ZAPI_CLIENT_TOKEN        token de segurança da conta na Z-API
//   VERIFICACAO_URL          opcional. Padrão: https://office.celeiroadministradora.com.br/verificar/

import { withSupabase } from 'npm:@supabase/server@1'

const CANAIS = ['email', 'whatsapp']
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

function resposta(corpo, status) {
  return Response.json(corpo, { status: status || 200 })
}

function segredo(nome) {
  return (Deno.env.get(nome) || '').trim()
}

function esc(s) {
  return String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]))
}

async function enviarEmail(v, link) {
  const chave = segredo('RESEND_API_KEY')
  if (!chave) return 'nao_configurado'
  const de = segredo('VERIFICACAO_REMETENTE') || 'Celeiro Administradora <nao-responda@celeiroadministradora.com.br>'
  const texto =
    'Olá, ' + v.nome + '.\n\nSeu código de verificação na ' + v.empresa + ' é: ' + v.codigo +
    '\n\nPara confirmar este e-mail, abra o link abaixo e digite o código:\n' + link +
    '\n\nO código vale por 24 horas. Se você não reconhece este cadastro, ignore esta mensagem.'
  const html =
    '<div style="font-family:Arial,sans-serif;color:#0F3D2E;max-width:520px">' +
    '<p>Olá, ' + esc(v.nome) + '.</p>' +
    '<p>Seu código de verificação na ' + esc(v.empresa) + ' é:</p>' +
    '<p style="font-size:32px;font-weight:700;letter-spacing:6px;margin:16px 0">' + esc(v.codigo) + '</p>' +
    '<p>Para confirmar este e-mail, abra a página abaixo e digite o código:</p>' +
    '<p><a href="' + esc(link) + '" style="display:inline-block;background:#0F3D2E;color:#F4F6F3;padding:12px 20px;border-radius:8px;text-decoration:none;font-weight:600">Confirmar meu e-mail</a></p>' +
    '<p style="font-size:13px;color:#44564E">O código vale por 24 horas. Se você não reconhece este cadastro, ignore esta mensagem.</p></div>'
  try {
    const r = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { authorization: 'Bearer ' + chave, 'content-type': 'application/json' },
      body: JSON.stringify({ from: de, to: [v.destino], subject: 'Seu código de verificação: ' + v.codigo, text: texto, html: html }),
    })
    if (!r.ok) console.error('Resend recusou o envio:', r.status, (await r.text()).slice(0, 300))
    return r.ok ? 'enviado' : 'falhou'
  } catch (e) {
    console.error('Resend indisponível:', e && e.message)
    return 'falhou'
  }
}

async function enviarWhatsApp(v, link) {
  const instancia = segredo('ZAPI_INSTANCE_ID')
  const token = segredo('ZAPI_TOKEN')
  const cliente = segredo('ZAPI_CLIENT_TOKEN')
  if (!instancia || !token || !cliente) return 'nao_configurado'
  const mensagem =
    'Olá, ' + v.nome + '. Seu código de verificação na ' + v.empresa + ' é *' + v.codigo + '*.\n\n' +
    'Para confirmar este número, abra o link e digite o código:\n' + link +
    '\n\nVale por 24 horas. Se você não reconhece este cadastro, ignore esta mensagem.'
  try {
    const r = await fetch(
      'https://api.z-api.io/instances/' + encodeURIComponent(instancia) + '/token/' + encodeURIComponent(token) + '/send-text',
      {
        method: 'POST',
        headers: { 'client-token': cliente, 'content-type': 'application/json' },
        body: JSON.stringify({ phone: v.destino, message: mensagem }),
      },
    )
    if (!r.ok) console.error('Z-API recusou o envio:', r.status, (await r.text()).slice(0, 300))
    return r.ok ? 'enviado' : 'falhou'
  } catch (e) {
    console.error('Z-API indisponível:', e && e.message)
    return 'falhou'
  }
}

export default {
  fetch: withSupabase({ auth: 'user' }, async (req, ctx) => {
    if (req.method !== 'POST') return resposta({ erro: 'Método não permitido.' }, 405)
    let dados
    try {
      dados = await req.json()
    } catch (_e) {
      return resposta({ erro: 'Dados inválidos.' }, 400)
    }
    const tipo = String((dados && dados.alvo_tipo) || '')
    const id = String((dados && dados.alvo_id) || '')
    const canais = Array.isArray(dados && dados.canais) ? dados.canais.filter((c) => CANAIS.indexOf(c) >= 0) : CANAIS
    const telefone = dados && dados.telefone ? String(dados.telefone).slice(0, 30) : null
    if ((tipo !== 'cadastro_pf' && tipo !== 'usuario') || !UUID.test(id) || !canais.length) {
      return resposta({ erro: 'Dados inválidos.' }, 400)
    }

    // Quem chama pode mexer neste registro? (exige segundo fator)
    const pode = await ctx.supabase.rpc('verificacao_pode', { p_alvo_tipo: tipo, p_alvo_id: id })
    if (pode.error) return resposta({ erro: 'Não foi possível conferir sua permissão: ' + pode.error.message }, 400)
    if (pode.data !== true) return resposta({ erro: 'Você não pode enviar a verificação deste registro.' }, 403)

    const base = segredo('VERIFICACAO_URL') || 'https://office.celeiroadministradora.com.br/verificar/'
    const autor = ctx.userClaims && ctx.userClaims.id ? ctx.userClaims.id : null
    const resultados = []
    for (const canal of Array.from(new Set(canais))) {
      const c = await ctx.supabaseAdmin.rpc('verificacao_criar', {
        p_autor: autor, p_alvo_tipo: tipo, p_alvo_id: id, p_canal: canal,
        p_telefone: tipo === 'usuario' && canal === 'whatsapp' ? telefone : null,
      })
      if (c.error || !c.data) {
        console.error('verificacao_criar falhou:', c.error && c.error.message)
        resultados.push({ canal: canal, situacao: 'falhou' })
        continue
      }
      const v = c.data
      if (!v.ok) {
        resultados.push({ canal: canal, situacao: v.situacao, destino: v.destino || null })
        continue
      }
      const link = base + '?t=' + v.token
      const envio = canal === 'email' ? await enviarEmail(v, link) : await enviarWhatsApp(v, link)
      await ctx.supabaseAdmin.rpc('verificacao_envio', { p_id: v.id, p_envio: envio })
      // O código e o link não voltam para o navegador
      resultados.push({ canal: canal, situacao: envio })
    }
    return resposta({ resultados: resultados })
  }),
}
