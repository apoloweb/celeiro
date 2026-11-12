// Celeiro Office · função "criar-usuario" (Supabase Edge Function)
//
// Cria o acesso (e-mail e senha) de um novo usuário do backoffice.
// Só atende quem está logado com o segundo fator e tem permissão para criar
// aquele tipo de usuário (a regra fica no banco, em public.pode_criar_usuario).
// O vínculo do acesso ao perfil, à organização e ao nível é feito em seguida
// pela própria tela, com public.vincular_usuario, para a auditoria registrar
// quem criou e de qual IP.
//
// A chave secreta do projeto fica só aqui no servidor; nunca vai para o navegador.

import { withSupabase } from 'npm:@supabase/server@1'

const PERFIS = ['master', 'gerencial', 'corp_master', 'corp_operador']
const SENHA_MINIMA = 10

function resposta(corpo, status) {
  return Response.json(corpo, { status: status || 200 })
}

export default {
  fetch: withSupabase({ auth: 'user' }, async (req, ctx) => {
    if (req.method !== 'POST') {
      return resposta({ erro: 'Método não permitido.' }, 405)
    }

    let dados
    try {
      dados = await req.json()
    } catch (_e) {
      return resposta({ erro: 'Dados inválidos.' }, 400)
    }

    const email = String((dados && dados.email) || '').trim().toLowerCase()
    const senha = String((dados && dados.senha) || '')
    const perfil = String((dados && dados.perfil) || '')
    const org = dados && dados.organizacao_id ? String(dados.organizacao_id) : null

    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 254) {
      return resposta({ erro: 'E-mail inválido.' }, 400)
    }
    if (senha.length < SENHA_MINIMA || senha.length > 72) {
      return resposta({ erro: 'A senha inicial precisa ter de ' + SENHA_MINIMA + ' a 72 caracteres.' }, 400)
    }
    if (PERFIS.indexOf(perfil) < 0) {
      return resposta({ erro: 'Perfil inválido.' }, 400)
    }

    // Quem chama pode criar este tipo de usuário? (exige segundo fator)
    const permissao = await ctx.supabase.rpc('pode_criar_usuario', { p_perfil: perfil, p_org: org })
    if (permissao.error) {
      return resposta({ erro: 'Não foi possível conferir sua permissão: ' + permissao.error.message }, 400)
    }
    if (permissao.data !== true) {
      return resposta({ erro: 'Seu perfil não pode criar este tipo de usuário.' }, 403)
    }

    const criado = await ctx.supabaseAdmin.auth.admin.createUser({
      email: email,
      password: senha,
      email_confirm: true,
    })
    if (criado.error) {
      const jaExiste = /already|registered|exists/i.test(criado.error.message || '')
      return resposta(
        jaExiste
          ? { erro: 'Já existe um acesso com este e-mail. Use "Vincular acesso existente".', codigo: 'ja_existe' }
          : { erro: 'Não foi possível criar o acesso: ' + criado.error.message, codigo: 'falha' },
        jaExiste ? 409 : 400,
      )
    }

    return resposta({ user_id: criado.data.user.id, email: email })
  }),
}
