// Celeiro Office · função "mcp" (Supabase Edge Function)
//
// Servidor MCP do backoffice (transporte HTTP, sem estado). Assistentes de IA
// se conectam aqui com o token de uma conexão criada na tela "Conexão MCP":
//
//   Authorization: Bearer clro_...
//
// A função não decide nada sozinha: ela só repassa cada chamada para
// public.mcp_chamar, no banco, que confere o token, aplica as permissões do
// usuário dono da conexão (as mesmas da tela), executa a ferramenta e grava
// tudo na Auditoria com origem "mcp".
//
// Esta função precisa ficar com "Verify JWT" DESLIGADO, porque quem chama
// apresenta o token da conexão, não uma sessão do Supabase.
// A chave secreta do projeto fica só aqui no servidor.

import { withSupabase } from 'npm:@supabase/server@1'

const VERSOES = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05']
const NOME = 'celeiro-office'
const VERSAO = '1.0.0'
const TAMANHO_MAXIMO = 64 * 1024
const INSTRUCOES =
  'Servidor do Celeiro Office (backoffice da Celeiro Administradora). Você atua em nome de um usuário e só ' +
  'alcança o que ele alcança na tela. Comece por quem_sou_eu. Os dados são reais e incluem dados pessoais: ' +
  'use apenas o necessário para o pedido. Antes de qualquer ferramenta que grava (criar, mover, comentar), ' +
  'confirme com a pessoa. Todas as chamadas ficam registradas na Auditoria.'

const CORS = {
  'access-control-allow-origin': '*',
  'access-control-allow-methods': 'POST, OPTIONS',
  'access-control-allow-headers': 'authorization, content-type, accept, mcp-protocol-version, mcp-session-id',
  'access-control-max-age': '86400',
}

function json(corpo, status, extra) {
  return new Response(JSON.stringify(corpo), {
    status: status || 200,
    headers: Object.assign({ 'content-type': 'application/json', 'cache-control': 'no-store' }, CORS, extra || {}),
  })
}

function rpcErro(id, codigo, mensagem) {
  return { jsonrpc: '2.0', id: id === undefined ? null : id, error: { code: codigo, message: mensagem } }
}

function rpcOk(id, resultado) {
  return { jsonrpc: '2.0', id: id, result: resultado }
}

function naoAutorizado(mensagem) {
  return json(rpcErro(null, -32001, mensagem), 401, {
    'www-authenticate': 'Bearer realm="Celeiro Office MCP", error="invalid_token"',
  })
}

async function resumo(texto) {
  const bytes = new TextEncoder().encode(texto)
  const d = await crypto.subtle.digest('SHA-256', bytes)
  return Array.from(new Uint8Array(d)).map((b) => b.toString(16).padStart(2, '0')).join('')
}

function cabecalho(req, nome) {
  return (req.headers.get(nome) || '').trim()
}

export default {
  fetch: withSupabase({ auth: 'none', cors: { headers: CORS } }, async (req, ctx) => {
    if (req.method === 'OPTIONS') {
      return new Response(null, { status: 204, headers: CORS })
    }
    if (req.method !== 'POST') {
      // Sem fluxo aberto pelo servidor (SSE) nem sessão para encerrar.
      return json(rpcErro(null, -32000, 'Use POST.'), 405, { allow: 'POST, OPTIONS' })
    }

    const m = /^Bearer\s+(clro_[a-f0-9]{64})$/i.exec(cabecalho(req, 'authorization'))
    if (!m) {
      return naoAutorizado('Informe o token da conexão no cabeçalho Authorization: Bearer clro_...')
    }
    const hash = await resumo(m[1])

    const bruto = await req.text()
    if (bruto.length > TAMANHO_MAXIMO) {
      return json(rpcErro(null, -32600, 'Pedido grande demais.'), 413)
    }
    let pedido
    try {
      pedido = JSON.parse(bruto)
    } catch (_e) {
      return json(rpcErro(null, -32700, 'JSON inválido.'), 400)
    }
    if (Array.isArray(pedido) || !pedido || pedido.jsonrpc !== '2.0' || typeof pedido.method !== 'string') {
      return json(rpcErro(null, -32600, 'Pedido inválido: envie uma mensagem JSON-RPC 2.0 por vez.'), 400)
    }

    const ip = cabecalho(req, 'x-forwarded-for').split(',')[0].trim() || cabecalho(req, 'cf-connecting-ip')
    const pais = cabecalho(req, 'cf-ipcountry') || cabecalho(req, 'x-country')
    let agente = cabecalho(req, 'user-agent')

    async function banco(metodo, ferramenta, args) {
      const r = await ctx.supabaseAdmin.rpc('mcp_chamar', {
        p_hash: hash,
        p_metodo: metodo,
        p_ferramenta: ferramenta || null,
        p_args: args || {},
        p_ip: ip,
        p_pais: pais,
        p_agente: agente.slice(0, 200),
      })
      if (r.error) {
        console.error('mcp_chamar falhou:', r.error.message)
        return { ok: false, codigo: 'indisponivel', erro: 'Serviço indisponível no momento.' }
      }
      return r.data || { ok: false, codigo: 'indisponivel', erro: 'Serviço indisponível no momento.' }
    }

    const id = pedido.id
    const notificacao = id === undefined || id === null
    const metodo = pedido.method
    const params = pedido.params && typeof pedido.params === 'object' ? pedido.params : {}

    // Notificações (sem id) não têm resposta, mas o token é conferido do mesmo jeito.
    if (notificacao) {
      const r = await banco('ferramentas')
      if (!r.ok && r.codigo === 'token_invalido') return naoAutorizado(r.erro)
      return new Response(null, { status: 202, headers: CORS })
    }

    if (metodo === 'initialize') {
      const cliente = params.clientInfo && typeof params.clientInfo === 'object' ? params.clientInfo : {}
      if (cliente.name) agente = String(cliente.name) + (cliente.version ? '/' + String(cliente.version) : '')
      const r = await banco('iniciar')
      if (!r.ok) {
        return r.codigo === 'token_invalido' ? naoAutorizado(r.erro) : json(rpcErro(id, -32002, r.erro), 403)
      }
      const pedida = String(params.protocolVersion || '')
      return json(rpcOk(id, {
        protocolVersion: VERSOES.indexOf(pedida) >= 0 ? pedida : VERSOES[0],
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: NOME, title: 'Celeiro Office', version: VERSAO },
        instructions: INSTRUCOES + ' Conexão em nome de: ' + (r.usuario || 'usuário') + '.',
      }))
    }

    if (metodo === 'ping') {
      const r = await banco('ferramentas')
      if (!r.ok && r.codigo === 'token_invalido') return naoAutorizado(r.erro)
      return json(rpcOk(id, {}))
    }

    if (metodo === 'tools/list') {
      const r = await banco('ferramentas')
      if (!r.ok) {
        return r.codigo === 'token_invalido' ? naoAutorizado(r.erro) : json(rpcErro(id, -32002, r.erro), 403)
      }
      return json(rpcOk(id, {
        tools: (r.ferramentas || []).map((f) => ({
          name: f.nome,
          title: f.titulo,
          description: f.descricao,
          inputSchema: f.parametros,
          annotations: {
            title: f.titulo,
            readOnlyHint: !f.escrita,
            destructiveHint: false,
            idempotentHint: !f.escrita,
            openWorldHint: false,
          },
        })),
      }))
    }

    if (metodo === 'tools/call') {
      const nome = typeof params.name === 'string' ? params.name : ''
      const args = params.arguments && typeof params.arguments === 'object' && !Array.isArray(params.arguments)
        ? params.arguments
        : {}
      if (!nome) return json(rpcErro(id, -32602, 'Informe o nome da ferramenta.'))
      const r = await banco('chamar', nome, args)
      if (!r.ok) {
        if (r.codigo === 'token_invalido') return naoAutorizado(r.erro)
        if (r.codigo === 'ferramenta_desconhecida') return json(rpcErro(id, -32602, 'Ferramenta desconhecida: ' + nome))
        // Erros de uso voltam como resultado com isError, para o assistente poder se corrigir.
        return json(rpcOk(id, { content: [{ type: 'text', text: r.erro || 'Não foi possível concluir.' }], isError: true }))
      }
      return json(rpcOk(id, {
        content: [{ type: 'text', text: JSON.stringify(r.resultado === undefined ? null : r.resultado, null, 2) }],
        isError: false,
      }))
    }

    if (metodo === 'resources/list') return json(rpcOk(id, { resources: [] }))
    if (metodo === 'prompts/list') return json(rpcOk(id, { prompts: [] }))

    return json(rpcErro(id, -32601, 'Método não disponível: ' + metodo))
  }),
}
