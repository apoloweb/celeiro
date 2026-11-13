// Celeiro Office · função "avisar-mencao" (Supabase Edge Function)
//
// Envia um e-mail (Resend) a cada pessoa marcada com @ em um comentário do Workflow.
// A tela chama esta função logo depois de publicar o comentário.
//
// Só atende quem está logado com o segundo fator e escreveu o comentário
// (a regra fica no banco, em public.workflow_mencao_pode). Cada pessoa é avisada
// uma vez só por comentário.
//
// Segredos (Edge Functions → Secrets). Sem a chave, responde "nao_configurado":
//   RESEND_API_KEY           chave da Resend (a mesma da verificação de contatos)
//   VERIFICACAO_REMETENTE    opcional. Padrão: Celeiro Administradora <nao-responda@celeiroadministradora.com.br>
//   OFFICE_URL               opcional. Padrão: https://office.celeiroadministradora.com.br/

import { withSupabase } from 'npm:@supabase/server@1'

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

async function enviar(chave, d, pessoa, link) {
  const de = segredo('VERIFICACAO_REMETENTE') || 'Celeiro Administradora <nao-responda@celeiroadministradora.com.br>'
  const trecho = d.texto.length > 600 ? d.texto.slice(0, 600) + '…' : d.texto
  const texto =
    'Olá, ' + pessoa.nome + '.\n\n' + d.autor + ' marcou você em um comentário da tarefa ' + d.codigo + ' · ' + d.titulo + ':\n\n"' + trecho + '"\n\n' +
    'Para ver a tarefa e responder, entre no sistema:\n' + link + '\n\nVocê recebeu este aviso porque foi marcado com @ no Workflow da ' + d.empresa + '.'
  const html =
    '<div style="font-family:Arial,sans-serif;color:#0F3D2E;max-width:520px">' +
    '<p>Olá, ' + esc(pessoa.nome) + '.</p>' +
    '<p><strong>' + esc(d.autor) + '</strong> marcou você em um comentário da tarefa <strong>' + esc(d.codigo) + '</strong> · ' + esc(d.titulo) + ':</p>' +
    '<blockquote style="margin:16px 0;padding:12px 16px;background:#F4F6F3;border-left:4px solid #E3A72F;border-radius:6px;white-space:pre-wrap">' + esc(trecho) + '</blockquote>' +
    '<p><a href="' + esc(link) + '" style="display:inline-block;background:#0F3D2E;color:#F4F6F3;padding:12px 20px;border-radius:8px;text-decoration:none;font-weight:600">Abrir o Workflow</a></p>' +
    '<p style="font-size:13px;color:#44564E">Você recebeu este aviso porque foi marcado com @ no Workflow da ' + esc(d.empresa) + '.</p></div>'
  try {
    const r = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: { authorization: 'Bearer ' + chave, 'content-type': 'application/json' },
      body: JSON.stringify({ from: de, to: [pessoa.email], subject: d.autor + ' marcou você na tarefa ' + d.codigo, text: texto, html: html }),
    })
    if (!r.ok) console.error('Resend recusou o envio:', r.status, (await r.text()).slice(0, 300))
    return r.ok
  } catch (e) {
    console.error('Resend indisponível:', e && e.message)
    return false
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
    const id = String((dados && dados.comentario_id) || '')
    if (!UUID.test(id)) return resposta({ erro: 'Dados inválidos.' }, 400)

    const pode = await ctx.supabase.rpc('workflow_mencao_pode', { p_comentario: id })
    if (pode.error) return resposta({ erro: 'Não foi possível conferir sua permissão: ' + pode.error.message }, 400)
    if (pode.data !== true) return resposta({ erro: 'Só quem escreveu o comentário dispara o aviso.' }, 403)

    const lido = await ctx.supabaseAdmin.rpc('workflow_mencao_dados', { p_comentario: id })
    if (lido.error || !lido.data) return resposta({ erro: 'Comentário não encontrado.' }, 404)
    const d = lido.data
    const pessoas = Array.isArray(d.destinatarios) ? d.destinatarios : []
    if (!pessoas.length) return resposta({ situacao: 'ninguem', enviados: 0, falhas: 0 })
    const chave = segredo('RESEND_API_KEY')
    if (!chave) return resposta({ situacao: 'nao_configurado', enviados: 0, falhas: pessoas.length })

    const link = (segredo('OFFICE_URL') || 'https://office.celeiroadministradora.com.br/') + '#workflow'
    let enviados = 0, falhas = 0
    for (const p of pessoas) {
      if (await enviar(chave, d, p, link)) {
        enviados++
        const g = await ctx.supabaseAdmin.rpc('workflow_mencao_avisada', { p_comentario: id, p_user: p.user_id })
        if (g.error) console.error('Aviso enviado, mas não marcado:', g.error.message)
      } else {
        falhas++
      }
    }
    return resposta({ situacao: falhas ? (enviados ? 'parcial' : 'falhou') : 'enviado', enviados: enviados, falhas: falhas })
  }),
}
