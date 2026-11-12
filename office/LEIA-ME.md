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
| Workflow: tarefas em lista e em quadro, responsável, envolvidos, prazo, comentários, confidenciais | Pronto |
| Botão "Nova tarefa" em todas as telas, guardando a tela de origem | Pronto |
| Dashboard: tarefas vencidas, urgentes, suas e não lidas, gráfico de 15 dias e pendências | Pronto (arrecadação, inadimplentes e energia sem dados até o Financeiro existir) |
| Cadastro de pessoas físicas: dados pessoais, contatos, endereço, profissional e financeiro | Pronto |
| Cadastro de pessoas jurídicas: empresa, quadro de sócios (QSA), representante e responsável financeiro | Pronto |
| Financeiro, Investimentos, Conexão MCP, Conteúdo | Aparecem no menu quando habilitados, com aviso da fase em que serão construídos |

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

## Workflow

- **Lista e Quadro.** A mesma tarefa aparece nas duas formas. No quadro, arraste o cartão ou use os botões de mover.
- **Filtros:** Todas, Pra mim (você é o responsável), Aguardando (você criou e está com outra pessoa), Não lidas (mudou desde a última vez que você abriu), Vencidas, Urgentes e Mencionado (você foi marcado como envolvido).
- **Busca** por título ou pelo código (WF-0001). **Agrupar por** status ou por origem (módulo).
- **Nova tarefa** em qualquer tela, pelo botão do topo: a tarefa guarda o módulo e a tela de onde foi criada.
- **Quem vê:** quem tem o módulo Workflow. A equipe Celeiro vê as tarefas da Celeiro e de todos os clientes; cada cliente vê só as da própria organização.
- **Confidencial:** só quem criou, o responsável e os envolvidos veem. Nem o Master vê uma tarefa confidencial de que não participa.
- **Quem altera:** qualquer pessoa que vê a tarefa pode editar, mover e comentar. Excluir é só para quem criou, o Master e o Corporativo master da organização.
- **Quem pode ser marcado:** pessoas com o módulo Workflow, da mesma organização da tarefa. Só a equipe Celeiro marca pessoas da Celeiro em tarefas de clientes.

Para os clientes usarem, habilite o módulo Workflow para os perfis deles em **Módulos e permissões**.

## Cadastro

**Pessoas físicas**
- Seções: dados pessoais, contatos, endereço, profissional e financeiro (profissão, fonte de renda, renda mensal, MEI, isento de IR, PEP, FATCA e CRS).
- Obrigatórios: nome completo e CPF. O CPF é conferido pelos dígitos verificadores e não pode repetir dentro da mesma origem (Celeiro ou a mesma organização).
- O CEP preenche o endereço pela base pública ViaCEP, quando ela responde.
- "Verificado" em celular e e-mail é uma marcação manual de quem preenche. Não há confirmação automática por código.

**Pessoas jurídicas**
- Aba **Empresa**: razão social, nome fantasia, CNPJ, situação cadastral, contatos, endereço e responsável financeiro.
- **Buscar dados pelo CNPJ** consulta a base pública BrasilAPI e preenche empresa, endereço e quadro societário. Fica registrado quando isso foi feito ("enriquecimento"). Não é a validação oficial contratada da Receita.
- Aba **Representantes**: quadro de sócios e administradores (QSA), com a escolha do responsável, e os dados completos do representante.
- O representante é um cadastro de pessoa física ligado à empresa. Se já existir uma pessoa com o mesmo CPF, o cadastro dela é atualizado e reaproveitado.

**Regras**
- Quem tem o módulo Cadastro vê e altera. A equipe Celeiro vê todos; cada cliente vê só os da própria organização.
- Cadastro não é apagado: é inativado e pode ser reativado.
- Toda inclusão e alteração fica na Auditoria, com os valores de antes e depois.

## Dashboard

- Primeira linha: tarefas vencidas, urgentes, sob sua responsabilidade e não lidas, cada uma com "Ver tudo" que abre a lista já filtrada.
- Segunda linha: tarefas em aberto, concluídas em 15 dias, usuários ativos e organizações.
- Gráfico de tarefas criadas e concluídas por dia nos últimos 15 dias, e a lista de pendências com responsável e prazo.
- Arrecadação, inadimplentes e economia de energia aparecem como "Sem dados": dependem do módulo Financeiro e de uma fonte de dados de energia, que ainda não existem.

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
- **Workflow sem times e sem @.** O responsável é uma pessoa; ainda não há "time" como responsável, nem menção com @ no texto. Marcar alguém é feito pela lista de Envolvidos.
- **Workflow sem aviso por e-mail.** Prazos e marcações aparecem só dentro do sistema (filtros e Dashboard).
- **Tarefa ligada a um registro.** Hoje a tarefa guarda o módulo e a tela de origem. A ligação a um registro específico (um cadastro, uma fatura) entra quando esses módulos existirem.
- **Cadastro sem arquivos.** O envio de documentos (RG, contrato social) ainda não existe.
- **Cadastro sem validação oficial.** CPF e CNPJ são conferidos pelos dígitos. A consulta de CNPJ e de CEP usa bases públicas gratuitas (BrasilAPI e ViaCEP), que podem ficar fora do ar; a consulta contratada à Receita (CPF, situação) não foi feita.
- **Auditoria guarda dados pessoais.** Cada alteração de cadastro registra os valores de antes e depois, inclusive CPF e renda. Considere isso na política de retenção.
- **Cadastro de produtos** (Energia, Financiamento, Captação) ainda não foi construído.
- **Permissão dentro do módulo.** Os níveis definem a quais módulos a pessoa tem acesso. Ainda não há separação entre ver, criar, editar e excluir dentro de cada módulo; isso entra junto com a construção dos módulos.

## Situação dos testes

Testado antes da entrega, fora do Supabase:

- `supabase.sql` rodado em um Postgres local, tanto em banco novo quanto por cima da versão anterior, e as regras conferidas com cada perfil (segundo fator, organizações diferentes, usuário inativo, níveis, auditoria imutável).
- As telas percorridas em navegador gravando nesse banco, incluindo criar nível, criar usuário com senha inicial e nível, entrar como esse usuário, trocar a senha, criar, mover, comentar, concluir e excluir tarefas, e conferir o Dashboard.
- A função `criar-usuario` executada localmente contra um Supabase simulado: recusa sem sessão, sem segundo fator, com perfil sem permissão, com dados inválidos e com e-mail repetido; cria quando permitido.

Testado no projeto Supabase real pelo Paulo em 12/11/2026: `supabase.sql` da primeira versão, login com senha e tela de cadastro do autenticador.

No projeto real, em 12/11/2026, também foram conferidos: a versão com níveis de permissão rodada sem erro, a função `criar-usuario` publicada e respondendo, e a auditoria gravando IP e país.

**Ainda não exercitado pela tela no projeto real:** criar usuário pela função publicada, níveis de permissão, Workflow e Dashboard.

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
13. Clique em **Nova tarefa** no topo, crie uma tarefa com prazo e confira que ela aparece em **Workflow** e nas pendências do **Dashboard**.

## Integração com o aplicativo (módulo Aplicativo)

O app Celeiro envia para o backoffice: instalações, leads (cadastros), solicitações de abertura de conta, cotações veiculares e pedidos de migração de energia. O backoffice também controla quais módulos do app estão ligados.

**Para ativar:** rode `supabase-app.sql` no SQL Editor do projeto do backoffice, depois do `supabase.sql`. Sempre que o `supabase.sql` mudar no repositório, rode-o de novo: telas novas (Workflow, Dashboard, edição de usuários) dependem dele. Pode ser rodado mais de uma vez. Em seguida, em Módulos e permissões, habilite "Aplicativo" para o perfil Gerencial, se a equipe for usar (o Master já vê).

**Como o app envia:** chama a função `app_registrar` com a chave pública do projeto, sem login.

    POST https://<projeto>.supabase.co/rest/v1/rpc/app_registrar
    cabeçalhos: apikey e Authorization: Bearer <chave pública>
    corpo: {"p_tipo": "...", "p_dispositivo": "...", "p_dados": {...}}

| `p_tipo` | Quando | Campos em `p_dados` |
|---|---|---|
| `instalacao` | Primeira abertura do app no aparelho | plataforma, versao |
| `lead` | Cadastro de usuário no app | nome, email, telefone, metodo |
| `conta_digital` | Pedido de abertura de conta | nome, telefone, email, documento, tipo_pessoa, nascimento, responsavel, protocolo |
| `cotacao_veicular` | Formulário de Aquisição Veicular | nome, telefone, veiculo, condicao, valor, cidade |
| `migracao_energia` | Formulário de Energia com Desconto | nome, telefone, unidade, distribuidora, valor_fatura, fatura_anexada |

`"teste": true` em `p_dados` marca o registro como teste: ele fica fora dos totais e só aparece com o filtro "Mostrar registros de teste".

O app lê os módulos ligados pela função `app_config` (mesmo endereço, `rpc/app_config`, corpo vazio).

**Segurança:** o app só consegue gravar por `app_registrar`; não lê nada do backoffice. A leitura exige login com as duas etapas, perfil Master ou Gerencial e o módulo Aplicativo habilitado. Só o Master liga e desliga módulos do app. Mudanças de situação e de módulos entram na auditoria. Há um freio de 20 registros por aparelho por hora.

**Limites:**
- "Instalações" conta aparelhos que abriram o app pela primeira vez. O número de downloads das lojas vem dos painéis da App Store e do Google Play.
- Como o endereço é público, alguém pode enviar registros falsos. O freio por aparelho reduz o volume, mas não impede; antes do lançamento vale acrescentar verificação do aparelho (App Attest / Play Integrity) ou captcha.
- O arquivo da fatura de energia ainda não é enviado, só a indicação de que foi anexado.
- CPF e CNPJ chegam em texto. Definir prazo de retenção e incluir no aviso de privacidade do app.

**Testes:** `supabase-app.sql` rodou duas vezes em Postgres local sobre o `supabase.sql`; 38 verificações de acesso aprovadas (app sem login, Master com e sem segundo fator, Gerencial com e sem o módulo, módulo desligado, freio). A tela foi aberta em navegador com dados de exemplo. Não testado contra o projeto Supabase real.

## Troca de e-mail de um usuário

Em **Usuários > Editar**, o campo E-mail agora pode ser alterado. A troca muda o e-mail de login no Supabase e o cadastro do backoffice, e entra na auditoria. Quem pode: Master (qualquer usuário) e Corporativo master (operadores da própria organização). Regras conferidas em Postgres local (8 verificações); não testado contra o projeto Supabase real.
14. Em **Cadastro**, crie uma pessoa física (teste o CEP) e uma pessoa jurídica (teste "Buscar dados pelo CNPJ"), escolha o responsável no quadro de sócios e informe os dados do representante.
