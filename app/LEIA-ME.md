# App Celeiro (protótipo navegável)

Protótipo do aplicativo da Celeiro Administradora, versão 1 do planejamento ("Software e App Celeiro", item 4), já com a identidade do manual de marca.

## O que é

Um único arquivo, `index.html`, com as telas, o estilo e o comportamento. Abre em qualquer navegador, sem instalação e sem servidor.

- **É um protótipo, não o app das lojas.** Os dados ficam só na sessão e somem ao recarregar.
- **Logins e gov.br são simulados.** Qualquer e-mail e senha entram.
- **O conteúdo é de exemplo** (vídeos, abaixo-assinados, nomes).

Prévia publicada: https://claude.ai/artifact/6d8m9JTGmcEo5pqNesaf9p (a prévia não é atualizada sozinha quando este arquivo muda).

## Módulos

| Código | Tela | Envia ao Office |
|---|---|---|
| `videos` | Vídeos | nada |
| `assinaturas` | Abaixo-assinados (assinatura com gov.br) | nada |
| `veicular` | Aquisição Veicular | `cotacao_veicular` |
| `energia` | Energia com Desconto | `migracao_energia` |
| `conta` | Conta digital | `conta_digital` |

Na área administrativa do app (Perfil > ligar "Demonstração: perfil administrador") ficam: Módulos, Vídeos, Abaixo-assinados, Solicitações e Integração Office.

## Onde mexer no `index.html`

| Para mudar | Procure por |
|---|---|
| Cores, fontes, raios | bloco `:root` no início do `<style>` |
| Marca (monograma e assinaturas) | `const mono`, `assH`, `assV` |
| Dados de exemplo | `const S={` |
| Lista de módulos | `const MODS=[` |
| Envio ao Office | `const Office={` |
| Conta digital (ponto de integração com a instituição financeira) | `const ContaDigital={` |
| Uma tela | `const T={` e o nome da tela (`inicio`, `videos`, `peticao`, `veicular`, `energia`, `conta`, `admin`...) |
| O que um botão faz | `const A={` (ações) e `const F={` (formulários) |

## Integração com o Office

O app chama a função `app_registrar` do banco do Office com a chave pública. O combinado completo (tipos, campos, limites) está em `office/LEIA-ME.md`, seção "Integração com o aplicativo".

- `Office.teste` está em `true`: tudo o que o protótipo envia chega marcado como teste e fica fora dos totais do Office. Trocar para `false` só no app publicado.
- Aberto direto no navegador (fora da prévia do Claude), o protótipo **envia de verdade** esses registros de teste ao Office.

## Publicação

Esta pasta **não** é publicada com o site: o arquivo `.vercelignore` na raiz do repositório a deixa de fora, para o protótipo com logins simulados não aparecer em `celeiroadministradora.com.br/app`. Para publicá-lo em um endereço próprio, criar um projeto na Vercel com a pasta `app` como raiz.

## Limites conhecidos

1. Sem servidor próprio: cadastro de usuário, vídeos e abaixo-assinados não são gravados em lugar nenhum.
2. Vídeo por link externo mostra um tocador simulado; só o arquivo enviado na sessão toca.
3. A chave de módulos da área administrativa vale só para a sessão; o protótipo ainda não lê `app_config` do Office.
4. O arquivo da fatura de energia não é enviado, só a indicação de anexo.
5. Textos e campos de Aquisição Veicular e Energia com Desconto são provisórios; as regras dos produtos ainda não foram definidas.
