# Celeiro Office — backoffice (fase 1)

Sistema de gestão da Celeiro Administradora, para publicar em `office.celeiroadministradora.com.br`.
Login próprio, Google Authenticator obrigatório, perfis, módulos e auditoria.

## O que esta fase entrega

| Parte | Situação |
|---|---|
| Login com e-mail e senha | Pronto |
| Google Authenticator obrigatório (cadastro no primeiro acesso, código nos seguintes) | Pronto |
| Perfis: Master, Gerencial, Corporativo master, Corporativo operador | Pronto |
| Organizações (clientes corporativos) | Pronto |
| Usuários: vincular acesso a perfil, editar, ativar e desativar | Pronto |
| Habilitação de módulos por perfil e por organização | Pronto |
| Auditoria: registro de todas as ações, consulta com filtros, exportação | Pronto |
| Dashboard, Workflow, Cadastro, Financeiro, Investimentos, Conexão MCP, Conteúdo | Aparecem no menu quando habilitados, com aviso da fase em que serão construídos |

## Arquivos

| Arquivo | Para que serve |
|---|---|
| `index.html` | O sistema inteiro (telas de acesso e área interna) |
| `config.js` | Endereço e chave pública do projeto Supabase do backoffice (**preencher**) |
| `supabase.sql` | Tabelas, regras de segurança e auditoria, para rodar no painel do Supabase |
| `assets/` | Logo e favicon |

## Configuração (uma vez)

1. **Criar o projeto Supabase do backoffice.** É um projeto novo, separado do projeto do site.
2. **Rodar o SQL.** Painel > SQL Editor > New query > cole o conteúdo de `supabase.sql` > Run.
3. **Criar o primeiro usuário.** Painel > Authentication > Users > Add user > Create new user. Informe e-mail e senha e marque "Auto Confirm User".
4. **Tornar esse usuário Master.** No SQL Editor, rode (trocando nome e e-mail):
   ```sql
   insert into public.usuarios (user_id, nome, email, perfil)
   select id, 'Seu nome', email, 'master' from auth.users where email = 'seu-email@empresa.com.br'
   on conflict (user_id) do nothing;
   ```
5. **Fechar o cadastro público.** Painel > Authentication > Sign In / Providers > desligue "Allow new users to sign up".
6. **Conferir o autenticador.** Painel > Authentication > Multi-Factor: a opção de aplicativo autenticador (TOTP) deve estar ligada.
7. **Preencher `config.js`.** Painel > Project Settings > API: copie o endereço do projeto e a chave pública (publishable ou anon). Nunca use a chave secret / service_role.
8. **Publicar.** Envie a pasta `office/` para uma hospedagem de arquivos estáticos (Vercel, Netlify, Cloudflare Pages ou o servidor do domínio) e aponte o subdomínio `office.celeiroadministradora.com.br` para ela. Precisa abrir em `https://`.
9. **Informar o endereço ao Supabase.** Painel > Authentication > URL Configuration: coloque `https://office.celeiroadministradora.com.br` em "Site URL".

## Como criar os demais usuários

1. Crie o acesso (e-mail e senha) no painel do Supabase, em Authentication > Users.
2. No Celeiro Office, em **Usuários**, vincule o e-mail a um nome, perfil e organização.
3. No primeiro acesso a pessoa cadastra o próprio Google Authenticator.

O Corporativo master faz o passo 2 sozinho para os operadores da própria organização. O passo 1 hoje é feito por quem tem acesso ao painel do Supabase.

## Como a segurança funciona

- Senha e código são conferidos pelo Supabase, não pelo navegador.
- As regras ficam no banco (`supabase.sql`). Quem entrou só com a senha, sem o código, não lê nem grava nada.
- Cada cliente corporativo só enxerga os dados da própria organização.
- Master tem todos os módulos. Os demais perfis só têm o que foi habilitado.
- O Corporativo master só libera para os operadores módulos que ele próprio tem.
- Desativar um usuário ou uma organização corta o acesso na hora.
- A sessão é encerrada depois de 15 minutos sem uso, e depois de 5 códigos errados seguidos.
- `config.js` leva apenas a chave pública.

## Como a auditoria funciona

- **Inclusões, alterações e exclusões** são gravadas pelo próprio banco, com o valor de antes e de depois. Não dependem da tela e não podem ser puladas.
- **Entradas, saídas, códigos recusados e telas abertas** são enviados pela tela a cada ação.
- Cada linha guarda usuário, perfil, organização, ação, módulo, IP, país, navegador, data e hora.
- A auditoria não pode ser alterada nem apagada pelo sistema, nem pelo Master. Só alguém com acesso de administrador ao banco conseguiria, desligando a proteção.
- Master vê tudo. Gerencial vê tudo se o módulo Auditoria estiver habilitado. Corporativo master vê só a própria organização, se habilitado.

## Limites conhecidos

- **Local.** A tela mostra o país informado pela rede. Cidade depende de um serviço de localização por IP, que ainda não foi escolhido. Mesmo com ele, é uma estimativa pelo IP, não a posição exata do equipamento.
- **Senha errada no login** não entra na Auditoria do sistema, porque ainda não há usuário identificado. Essas tentativas ficam nos registros do próprio Supabase (painel > Logs > Auth). Códigos do autenticador recusados entram na Auditoria.
- **Telas abertas** são registradas pelo navegador. Alguém com conhecimento técnico poderia ler dados pela API sem abrir a tela; nesse caso a leitura não fica registrada (as gravações ficam sempre).
- **Ações feitas direto no painel do Supabase** aparecem na auditoria sem usuário e sem IP.
- **Convite por e-mail** de dentro do sistema ainda não existe; o acesso é criado no painel do Supabase.
- **Perda do celular.** Apague o autenticador da pessoa no painel (Authentication > Users > usuário > Factors). Ela cadastra de novo no acesso seguinte.
- **Redefinição de senha por e-mail.** A tela existe, mas depende do envio de e-mails do Supabase estar configurado. Não foi testada.
- **Permissão por operador.** Hoje a habilitação é por perfil dentro da organização, não pessoa a pessoa.

## Situação dos testes

Testado aqui, antes da entrega:

- `supabase.sql` rodou duas vezes seguidas, sem erro, em um Postgres local, e as regras de acesso foram conferidas com cada perfil (com e sem segundo fator, organização diferente, usuário inativo, auditoria imutável).
- As telas foram percorridas em um navegador de verdade, gravando nesse mesmo banco: login, senha errada, cadastro do autenticador, código errado, organizações, usuários, módulos, auditoria com filtro e exportação, saída, bloqueio por 5 códigos, acesso de cliente corporativo, usuário sem perfil e organização desativada.

**Não foi testado contra um projeto Supabase real.** O serviço de login e de autenticador foi simulado no teste. No primeiro uso, siga o roteiro abaixo e confira em especial se a coluna IP aparece preenchida.

## Roteiro de teste no projeto real

1. Abra o endereço: deve aparecer a tela **Entrar**.
2. Senha errada: "E-mail ou senha incorretos".
3. Senha certa: no primeiro acesso aparece o QR code. Leia com o Google Authenticator e digite o código.
4. Código errado é recusado; código certo abre o sistema.
5. Em **Organizações**, cadastre uma organização.
6. Em **Usuários**, vincule um segundo acesso como Corporativo master dessa organização.
7. Em **Módulos e permissões**, escolha a organização e habilite Auditoria para o Corporativo master.
8. Em **Auditoria**, confira que as ações acima aparecem com IP, data e hora.
9. Saia, entre com o segundo acesso e confira que ele vê só a própria organização.
10. Em janela anônima, abra o endereço terminado em `#auditoria`: deve cair na tela de acesso.
