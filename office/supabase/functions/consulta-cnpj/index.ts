// Celeiro Office · função "consulta-cnpj" (Supabase Edge Function)
//
// Consulta os dados de uma empresa e o quadro de sócios (QSA) na API Consulta CNPJ
// da Receita Federal, operada pelo Serpro (especificação "APIs CNPJ (Básica, QSA e Empresa)" v2:
// GET {base}/v2/empresa/{cnpj}, token JWT obtido no endpoint de access token).
//
// Só atende quem está logado com o segundo fator e tem o módulo Cadastro.
// As credenciais ficam em segredos do projeto (Edge Functions > Secrets), nunca no navegador:
//
//   RECEITA_CNPJ_CLIENT_ID      chave de acesso (obrigatório)
//   RECEITA_CNPJ_CLIENT_SECRET  segredo da chave (obrigatório)
//   RECEITA_CNPJ_TOKEN_URL      endereço que emite o token   (padrão: gateway do Conecta gov.br)
//   RECEITA_CNPJ_BASE_URL       endereço da consulta Empresa (padrão: gateway do Conecta gov.br, produção)
//   RECEITA_CPF_USUARIO         CPF enviado no cabeçalho x-cpf-usuario, exigido pelo Conecta gov.br (opcional)
//
// Sem as duas credenciais obrigatórias a função responde "nao_configurada" e a tela usa a base pública.

import { withSupabase } from 'npm:@supabase/server@1'

const TOKEN_PADRAO = 'https://apigateway.conectagov.estaleiro.serpro.gov.br/oauth2/jwt-token'
const BASE_PADRAO = 'https://apigateway.conectagov.estaleiro.serpro.gov.br/api-cnpj-empresa'

const SITUACOES = { '1': 'NULA', '2': 'ATIVA', '3': 'SUSPENSA', '4': 'INAPTA', '8': 'BAIXADA' }
const QUALIFICACOES = {
  '05': 'Administrador', '08': 'Conselheiro de Administração', '10': 'Diretor', '16': 'Presidente',
  '17': 'Procurador', '18': 'Secretário', '20': 'Sociedade Consorciada', '21': 'Sociedade Filiada',
  '22': 'Sócio', '23': 'Sócio Capitalista', '24': 'Sócio Comanditado', '25': 'Sócio Comanditário',
  '26': 'Sócio de Indústria', '28': 'Sócio-Gerente', '29': 'Sócio Incapaz ou Relativamente Incapaz (exceto menor)',
  '30': 'Sócio Menor (Assistido/Representado)', '31': 'Sócio Ostensivo', '33': 'Tesoureiro',
  '37': 'Sócio Pessoa Jurídica Domiciliado no Exterior', '38': 'Sócio Pessoa Física Residente ou Domiciliado no Exterior',
  '47': 'Sócio Pessoa Física Residente no Brasil', '48': 'Sócio Pessoa Jurídica Domiciliado no Brasil',
  '49': 'Sócio-Administrador', '52': 'Sócio com Capital', '53': 'Sócio sem Capital', '54': 'Fundador',
  '55': 'Sócio Comanditado Residente no Exterior', '56': 'Sócio Comanditário Pessoa Física Residente no Exterior',
  '57': 'Sócio Comanditário Pessoa Jurídica Domiciliado no Exterior', '58': 'Sócio Comanditário Incapaz',
  '59': 'Produtor Rural', '63': 'Cotas em Tesouraria', '65': 'Titular Pessoa Física Residente ou Domiciliado no Brasil',
  '66': 'Titular Pessoa Física Residente ou Domiciliado no Exterior',
  '67': 'Titular Pessoa Física Incapaz ou Relativamente Incapaz (exceto menor)',
  '68': 'Titular Pessoa Física Menor (Assistido/Representado)', '70': 'Administrador Residente ou Domiciliado no Exterior',
  '71': 'Conselheiro de Administração Residente ou Domiciliado no Exterior', '72': 'Diretor Residente ou Domiciliado no Exterior',
}

let tokenGuardado = null // { valor, expiraEm }

function ambiente(nome) {
  const d = globalThis.Deno
  if (d && d.env) return d.env.get(nome) || ''
  const p = globalThis.process
  return (p && p.env && p.env[nome]) || ''
}

function resposta(corpo, status) {
  return Response.json(corpo, { status: status || 200 })
}

function texto(v) {
  return v === null || v === undefined ? '' : String(v).trim()
}

function cnpjValido(n) {
  if (!/^\d{14}$/.test(n) || /^(\d)\1+$/.test(n)) return false
  const dv = (base) => {
    let p = base.length - 7
    let s = 0
    for (let i = 0; i < base.length; i++) {
      s += Number(base[i]) * p
      p = p === 2 ? 9 : p - 1
    }
    const r = s % 11
    return r < 2 ? 0 : 11 - r
  }
  return dv(n.slice(0, 12)) === Number(n[12]) && dv(n.slice(0, 13)) === Number(n[13])
}

async function obterToken(id, segredo) {
  if (tokenGuardado && tokenGuardado.expiraEm > Date.now() + 30000) return tokenGuardado.valor
  const r = await fetch(ambiente('RECEITA_CNPJ_TOKEN_URL') || TOKEN_PADRAO, {
    method: 'POST',
    headers: {
      Authorization: 'Basic ' + btoa(id + ':' + segredo),
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: 'grant_type=client_credentials',
  })
  if (!r.ok) throw new Error('token:' + r.status)
  const j = await r.json()
  if (!j || !j.access_token) throw new Error('token:sem_token')
  const segundos = Number(j.expires_in) > 0 ? Number(j.expires_in) : 300
  tokenGuardado = { valor: j.access_token, expiraEm: Date.now() + segundos * 1000 }
  return tokenGuardado.valor
}

// Converte a resposta da Receita para os campos do cadastro
function normalizar(d) {
  const e = d.endereco || {}
  const sit = d.situacaoCadastral || {}
  const tel = Array.isArray(d.telefone) ? d.telefone[0] : Array.isArray(d.telefones) ? d.telefones[0] : null
  const info = d.informacoesAdicionais || {}
  const capital = texto(d.capitalSocial)
  return {
    fonte: 'receita',
    cnpj: texto(d.ni),
    razao_social: texto(d.nomeEmpresarial),
    nome_fantasia: texto(d.nomefantasia || d.nomeFantasia),
    situacao_cadastral: SITUACOES[texto(sit.codigo)] || texto(sit.motivo) || texto(sit.codigo),
    situacao_data: texto(sit.data),
    cep: texto(e.cep),
    logradouro: [texto(e.tipoLogradouro), texto(e.logradouro)].filter(Boolean).join(' '),
    numero: texto(e.numero),
    complemento: texto(e.complemento),
    bairro: texto(e.bairro),
    cidade: texto(e.municipio && e.municipio.descricao),
    uf: texto(e.uf).toUpperCase(),
    telefone: tel ? texto(tel.ddd) + texto(tel.numero) : '',
    email: texto(d.correioEletronico).toLowerCase(),
    natureza_juridica: texto(d.naturezaJuridica && d.naturezaJuridica.descricao),
    data_abertura: texto(d.dataAbertura),
    cnae_principal: texto(d.cnaePrincipal && d.cnaePrincipal.descricao),
    capital_social: /^\d+$/.test(capital) ? Number(capital) / 100 : null,
    optante_simples: texto(info.optanteSimples),
    optante_mei: texto(info.optanteMei),
    socios: (Array.isArray(d.socios) ? d.socios : [])
      .map((s) => {
        const q = texto(s.qualificacao)
        return {
          nome: texto(s.nome),
          documento: texto(s.cpf || s.cnpj).slice(0, 20),
          qualificacao: QUALIFICACOES[q.length === 1 ? '0' + q : q] || (q ? 'Qualificação ' + q : ''),
          selecionado: false,
        }
      })
      .filter((s) => s.nome),
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
    const cnpj = texto(dados && dados.cnpj).replace(/\D/g, '')
    if (!cnpjValido(cnpj)) return resposta({ erro: 'CNPJ inválido. Confira os números.' }, 400)

    // Quem chama tem o módulo Cadastro? (exige segundo fator)
    const permissao = await ctx.supabase.rpc('pode_modulo', { p_modulo: 'cadastro' })
    if (permissao.error) {
      return resposta({ erro: 'Não foi possível conferir sua permissão: ' + permissao.error.message }, 400)
    }
    if (permissao.data !== true) return resposta({ erro: 'Seu acesso não inclui o módulo Cadastro.' }, 403)

    const id = ambiente('RECEITA_CNPJ_CLIENT_ID')
    const segredo = ambiente('RECEITA_CNPJ_CLIENT_SECRET')
    if (!id || !segredo) {
      return resposta({ erro: 'A consulta oficial de CNPJ ainda não foi configurada.', codigo: 'nao_configurada' }, 503)
    }

    let r
    try {
      const token = await obterToken(id, segredo)
      const cabecalhos = { Authorization: 'Bearer ' + token, Accept: 'application/json' }
      const cpfUsuario = ambiente('RECEITA_CPF_USUARIO').replace(/\D/g, '')
      if (cpfUsuario) cabecalhos['x-cpf-usuario'] = cpfUsuario
      const base = (ambiente('RECEITA_CNPJ_BASE_URL') || BASE_PADRAO).replace(/\/+$/, '')
      r = await fetch(base + '/v2/empresa/' + cnpj, { headers: cabecalhos })
      if (r.status === 401) tokenGuardado = null
    } catch (e) {
      const m = String((e && e.message) || e)
      return resposta(
        {
          erro: m.indexOf('token:') === 0
            ? 'A Receita não aceitou as credenciais configuradas (falha ao obter o token).'
            : 'Não foi possível falar com a Receita agora.',
          codigo: m.indexOf('token:') === 0 ? 'credenciais' : 'indisponivel',
        },
        502,
      )
    }

    if (r.status === 404) return resposta({ erro: 'Não existe CNPJ com este número na Receita.', codigo: 'nao_encontrado' }, 404)
    if (r.status === 400) return resposta({ erro: 'A Receita recusou este número de CNPJ.', codigo: 'invalido' }, 400)
    if (r.status === 401 || r.status === 403) {
      return resposta({ erro: 'A Receita recusou o acesso (credenciais, CPF do usuário ou endereço de origem não autorizado).', codigo: 'credenciais' }, 502)
    }
    if (!r.ok) return resposta({ erro: 'A Receita respondeu com erro (' + r.status + ').', codigo: 'indisponivel' }, 502)

    let bruto
    try {
      bruto = await r.json()
    } catch (_e) {
      return resposta({ erro: 'A Receita devolveu uma resposta que não foi possível ler.', codigo: 'indisponivel' }, 502)
    }
    const empresa = normalizar(bruto || {})
    if (!empresa.razao_social) {
      return resposta({ erro: 'A Receita devolveu uma resposta sem os dados da empresa.', codigo: 'indisponivel' }, 502)
    }

    // Registro para auditoria e controle de consumo (o IP gravado aqui é o do servidor da função)
    await ctx.supabase.rpc('registrar_evento', {
      p_acao: 'Consultou CNPJ na base oficial da Receita',
      p_modulo: 'Cadastro',
      p_detalhes: { cnpj: cnpj, socios: empresa.socios.length },
    })

    return resposta(empresa)
  }),
}
