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
| Usuários: criar dentro do sistema (e-mail e senha inicial), editar, ativar e desativar | Pronto (depende de publicar a função `criar-usuario`) |
| Níveis de permissão: conjuntos de módulos com nome, atribuídos a cada usuário | Pronto |
| Lista de usuários mostrando o nível e os módulos que cada um acessa | Pronto |
| Trocar a própria senha | Pronto |
| Habilitação de módulos por perfil e por organização | Pronto |
| Auditoria: registro de todas as ações, consulta com filtros, exportação | Pronto |
| Dashboard, Workflow, Cadastro, Financeiro, Investimentos, Conexão MCP, Conteúdo | Aparecem no menu quando habilitados, com aviso da fase em que serão construídos |

## Arquivos

| Arquivo | Para que serve |
|---|---|
| `index.html` | O sistema inteiro (telas de acesso e área interna) |
| `config.js` | Endereço e chave pública do projeto Supabase do backoffice (já preenchidos) |
| `supabase.sql` | Tabelas, regras de segurança e auditoria, para rodar no painel do Supabase |
| `supabase/functions/criar-usuario/index.ts` | Função do servidor que cria o acesso de um novo usuário (para publicar no Supabase) |
| `assets/` | Logo e favicon |

## Configuração (uma vez)

1. **Projeto Supabase do backoffice.** Já criado (`wvvounloqtucagerizct`), separado do projeto do site.
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
7. **Conferir `config.js`.** Já está com o endereço e a chave pública do projeto. Nunca use a chave secret / service_role.
8. **Publicar.** Envie a pasta `office/` para uma hospedagem de arquivos estáticos (Vercel, Netlify, Cloudflare Pages ou o servidor do domínio) e aponte o subdomínio `office.celeiroadministradora.com.br` para ela. Precisa abrir em `https://`.
9. **Informar o endereço ao Supabase.** Painel > Authentication > URL Configuration: coloque `https://office.celeiroadministradora.com.br` em "Site URL".

## Atualização: criação de usuários e níveis de permissão

Quem já tinha rodado o `supabase.sql` antes desta versão precisa de dois passos:

1. **Rodar o `supabase.sql` de novo**, inteiro, no SQL Editor. Ele só acrescenta o que falta e não apaga dados.
2. **Publicar a função `criar-usuario`** (abaixo).

## Publicar a função criar-usuario

A criação do acesso (e-mail e senha) precisa de uma chave que não pode ir para o navegador, por isso roda no servidor do Supabase.

1. Painel do Supabase (projeto do backoffice) > **Edge Functions**.
2. Crie uma função nova pelo editor do próprio painel.
3. Dê o nome exato **`criar-usuario`**.
4. Apague o código de exemplo e cole o conteúdo de `supabase/functions/criar-usuario/index.ts`.
5. Publique (Deploy). Mantenha ligada a verificação de JWT, que é o padrão.

Os nomes dos botões do painel podem variar um pouco. Quem usa a linha de comando pode publicar com `supabase functions deploy criar-usuario`, a partir da pasta `office/`.

Enquanto a função não estiver publicada, o botão **Criar usuário** avisa que ela falta, e o caminho "Vincular acesso existente" continua funcionando.

## Como criar usuários

1. Em **Usuários**, preencha nome, e-mail e uma senha inicial (o botão **Gerar** cria uma).
2. Escolha o perfil, a organização e, se quiser, um nível de permissão. A tela mostra na hora os módulos que a pessoa vai acessar.
3. Clique em **Criar usuário**. A senha inicial aparece uma única vez: anote e passe à pessoa por um canal seguro.
4. No primeiro acesso a pessoa cadastra o próprio Google Authenticator e pode trocar a senha em **Trocar senha**.

O Corporativo master cria apenas operadores da própria organização.

## Níveis de permissão

- Um nível é um conjunto de módulos com nome (por exemplo, "Financeiro"), criado na tela **Usuários**.
- Cada nível pertence à equipe Celeiro (usuários Gerenciais) ou a uma organização (usuários corporativos dela).
- Usuário **com** nível acessa só os módulos do nível. Usuário **sem** nível segue o padrão do perfil.
- O nível não passa por cima de **Módulos e permissões**: um módulo do nível que não esteja habilitado para o perfil aparece na lista como "bloqueado" e não é liberado.
- Master tem sempre todos os módulos e não recebe nível.
- Um nível em uso não pode ser excluído; troque antes o nível dos usuários.

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
- **Convite por e-mail** ainda não existe: quem cria o usuário define a senha inicial e a repassa. O sistema não obriga a troca no primeiro acesso.
- **Acesso criado sem vínculo.** Se a criação do acesso der certo e o vínculo ao perfil falhar, o e-mail fica criado sem perfil (não entra no sistema). Conclua por "Vincular acesso existente".
- **Perda do celular.** Apague o autenticador da pessoa no painel (Authentication > Users > usuário > Factors). Ela cadastra de novo no acesso seguinte.
- **Redefinição de senha por e-mail.** A tela existe, mas depende do envio de e-mails do Supabase estar configurado. Não foi testada.
- **Permissão dentro do módulo.** Os níveis definem a quais módulos a pessoa tem acesso. Ainda não há separação entre ver, criar, editar e excluir dentro de cada módulo; isso entra junto com a construção dos módulos.

## Situação dos testes

Testado antes da entrega, fora do Supabase:

- `supabase.sql` rodado em um Postgres local, tanto em banco novo quanto por cima da versão anterior, e as regras conferidas com cada perfil (segundo fator, organizações diferentes, usuário inativo, níveis, auditoria imutável).
- As telas percorridas em navegador gravando nesse banco, incluindo criar nível, criar usuário com senha inicial e nível, entrar como esse usuário e trocar a senha.
- A função `criar-usuario` executada localmente contra um Supabase simulado: recusa sem sessão, sem segundo fator, com perfil sem permissão, com dados inválidos e com e-mail repetido; cria quando permitido.

Testado no projeto Supabase real pelo Paulo em 12/11/2026: `supabase.sql` da primeira versão, login com senha e tela de cadastro do autenticador.

**Ainda não testado no projeto real:** a função `criar-usuario` publicada, os níveis de permissão e a coluna IP da auditoria.

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
11. Em **Usuários**, crie um nível com um ou dois módulos e depois um usuário novo com esse nível. Confira os módulos mostrados na lista.
12. Entre com o usuário novo (senha inicial), cadastre o autenticador e confira que o menu mostra só os módulos esperados.
