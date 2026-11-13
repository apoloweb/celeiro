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
| Workflow: tarefas em lista e em quadro, responsável, envolvidos, prazo, comentários com @, anexos, confidenciais | Pronto |
| Botão "Nova tarefa" em todas as telas, guardando a tela de origem | Pronto |
| Dashboard: tarefas vencidas, urgentes, suas e não lidas, gráfico de 15 dias e pendências | Pronto (arrecadação e inadimplentes vêm do Financeiro; energia sem dados) |
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
| `supabase/functions/mcp/index.ts` | Servidor MCP do backoffice (para publicar no Supabase, com "Verify JWT" desligado) |
| `indicacao/index.html` | Página pública do link de indicação (registro de interesse, sem login) |
| `verificar/index.html` | Página pública onde a pessoa digita o código de verificação |
| `supabase/functions/enviar-verificacao/index.ts` | Função do servidor que envia o código por e-mail (Resend) e WhatsApp (Z-API) |
| `supabase/functions/financeiro-integracao/index.ts` | Função do servidor que leva boleto, Pix e nota fiscal ao provedor e recebe o aviso de pagamento (provedor ainda a escolher) |
| `supabase/functions/avisar-mencao/index.ts` | Função do servidor que envia o e-mail a quem foi marcado com @ em um comentário (Resend) |
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

- **Marcar com @ no comentário.** Digite `@` e o começo do nome: aparece a lista de quem pode ser marcado. Quem é
  marcado passa a ser envolvido na tarefa (por isso enxerga também as confidenciais) e vê o selo "@ Marcaram você"
  até abrir a tarefa. Ela também recebe um **e-mail** com quem marcou, a tarefa, o comentário e o botão para
  abrir o Workflow (função `avisar-mencao`, que usa a mesma chave da Resend da verificação de contatos). Cada
  pessoa é avisada uma vez por comentário; quem marca a si mesmo não recebe.
- **Anexos.** Na criação da tarefa, escolha os arquivos no campo Anexos: eles sobem quando a tarefa é criada.
  Em uma tarefa já criada, escolha os arquivos e clique em Anexar. Aceita PDF, imagem, Word, Excel,
  PowerPoint, CSV e TXT, até 10 MB cada e 30 por tarefa. Clicar no nome do anexo (ou em Ver) abre imagem, PDF e texto dentro do sistema, sem baixar; Word, Excel
  e PowerPoint não abrem no navegador e continuam pelo botão Baixar. Quem vê a tarefa vê e baixa os anexos; excluir é para quem
  enviou, quem criou a tarefa, o Master e o Corporativo master da organização. Os arquivos ficam no Storage do
  Supabase, em um bucket privado (`workflow-anexos`) criado pelo `supabase.sql`; o download usa um link que vale
  1 minuto. O registro (quem enviou, nome, tipo, tamanho) fica na tabela `workflow_anexos` e na Auditoria.

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

## Consulta oficial de CNPJ (Receita Federal)

A função `consulta-cnpj` (em `supabase/functions/consulta-cnpj/index.ts`) consulta a empresa e o quadro de sócios na API Consulta CNPJ da Receita, operada pelo Serpro, seguindo a especificação "APIs CNPJ (Básica, QSA e Empresa)" versão 2 publicada no catálogo Conecta gov.br. O botão **Buscar dados pelo CNPJ** tenta primeiro essa consulta; se ela não estiver configurada, usa a base pública BrasilAPI e avisa na tela qual fonte foi usada.

**Situação: código pronto, sem acesso contratado.**

- O acesso descrito no catálogo Conecta gov.br é para órgãos públicos (federais e estaduais), com adesão formal e cadastro prévio dos endereços IP de origem no Serpro. Uma empresa privada, como a Celeiro, não se enquadra nessa adesão.
- Para empresa privada, o caminho é contratar a Consulta CNPJ na loja do Serpro. O endereço e o formato da resposta precisam ser conferidos na documentação do produto contratado; a função aceita outro endereço pelos segredos abaixo.
- As funções do Supabase não saem por um IP fixo. Se o fornecedor exigir IP cadastrado, será preciso um servidor intermediário com IP fixo.

**Para ligar, quando houver credenciais** (painel do Supabase do backoffice > Edge Functions):

1. Publique a função com o nome exato `consulta-cnpj`, colando o conteúdo do arquivo.
2. Em Secrets, cadastre:
   - `RECEITA_CNPJ_CLIENT_ID` e `RECEITA_CNPJ_CLIENT_SECRET` (obrigatórios)
   - `RECEITA_CNPJ_TOKEN_URL` e `RECEITA_CNPJ_BASE_URL` (se o endereço for diferente do gateway do Conecta)
   - `RECEITA_CPF_USUARIO` (CPF enviado no cabeçalho `x-cpf-usuario`, exigido pelo Conecta)

Cada consulta oficial fica registrada na Auditoria. O token é obtido por credenciais de cliente (Basic + `grant_type=client_credentials`), que é o padrão do gateway do Serpro, mas esse detalhe não está escrito na especificação e precisa ser confirmado no primeiro uso real.

Validação de CPF na Receita ainda não tem função: depende da mesma contratação.

## Financeiro

Menus internos: Dashboard, Contas a receber, Contas a pagar, Fluxo projetado, Fluxo realizado, DRE, Balanço,
Balancete e Plano de contas. Todos (menos o plano) têm pesquisa por período, com datas livres e períodos prontos.

- **Livros separados**: cada organização tem os próprios livros. A equipe Celeiro escolhe em "Livros de" entre
  a própria Celeiro e cada cliente; o cliente só vê os dele.
- **Plano de contas**: criado sozinho na primeira abertura (33 contas: ativo, passivo, patrimônio, receitas,
  custos e despesas) e pode ser ajustado. Contas com movimento não mudam de tipo.
- **Contas a pagar e a receber**: título com descrição, cliente ou fornecedor (do Cadastro ou avulso), categoria,
  competência, vencimento e valor. Baixa pelo valor integral, com data, conta de caixa ou banco e forma.
  Estorno devolve o título para "em aberto". Nada é apagado: título é cancelado.
- **Fatura**: em Contas a receber → "Emitir fatura". Cliente, itens (quantidade × valor), vencimento, categoria e
  forma de cobrança. Ao emitir, o título é lançado automaticamente em contas a receber, com o mesmo valor e
  vencimento. A fatura pode ser impressa ou salva em PDF. Cancelar a fatura cancela o título (se já foi
  recebido, é preciso estornar antes). Título de fatura não é alterado à mão.
- **Contabilidade**: por partidas dobradas, geradas dos títulos (na competência e no pagamento) e dos lançamentos
  manuais (saldo inicial, capital, transferências, ajustes; ficam no Balancete). DRE por competência; fluxo
  realizado pela data do pagamento; fluxo projetado parte do saldo de hoje e soma os títulos em aberto;
  balanço mostra o resultado ainda não encerrado dentro do patrimônio líquido.
- **Segurança**: as tabelas do Financeiro não são lidas direto pelo navegador; tudo passa por operações que
  conferem o módulo, o segundo fator e a organização. Tudo vai para a Auditoria.

### Cobranças (boleto e Pix) e nota fiscal

Tudo está pronto, menos a escolha da API (banco, gateway de pagamento e emissor de notas).

- **Boleto e Pix:** em Contas a receber, botão **Cobrar** no título em aberto. **Nota fiscal de serviço:** na
  fatura, botão **Pedir nota fiscal** (usa os dados fiscais do emitente).
- **Cobranças e notas** (menu interno): mostra se a API está ligada, o andamento de cada pedido, os botões de
  copiar linha digitável e Pix copia e cola, abrir PDF/XML, enviar de novo e cancelar, e o formulário dos
  **dados fiscais do emitente** (CNPJ, inscrição municipal, código do serviço, alíquota de ISS).
- **Enquanto a API não é definida**, cada pedido fica guardado como "Aguardando a API" e nada é enviado ao
  cliente. Quando a API for ligada, o botão "Enviar agora" emite os pedidos guardados.
- **Baixa automática:** quando o provedor avisa que a cobrança foi paga, o título é baixado sozinho na conta
  de banco, com registro na Auditoria.
- **Para ligar a API:** publicar a função `financeiro-integracao` (com "Verify JWT" desligado), escrever o
  adaptador do provedor escolhido dentro dela (o formato está no topo do arquivo) e criar os segredos
  `FIN_COBRANCA_PROVEDOR`, `FIN_NOTA_PROVEDOR` e `FIN_WEBHOOK_SEGREDO`, além das chaves do provedor. O endereço
  do aviso de pagamento é `.../functions/v1/financeiro-integracao?aviso=<provedor>`. Existe um provedor
  `simulado`, só para ensaiar o fluxo: ele não gera cobrança nem nota de verdade.

### Ligação com Investimentos

- Cada **aporte** gera um lançamento: entrada em banco contra a conta "Recursos de investidores" (passivo).
- Cada **comissão** gera uma conta a pagar ao indicador, com vencimento 30 dias depois do aporte. Pagar no
  Financeiro marca a comissão como paga em Investimentos, e o contrário também.
- Cada **retorno distribuído** gera um lançamento de saída de banco em "Remuneração de investidores".
- Cancelar o aporte ou excluir o retorno desfaz o lançamento. No Financeiro esses itens aparecem marcados como
  vindos de Investimentos e não são alterados nem excluídos por lá.
- As contas novas são criadas sozinhas no plano (primeiro código livre). O dinheiro entra e sai pela conta
  "Banco conta movimento"; a tela de aporte ainda não deixa escolher outra conta.

Limites desta versão: boleto, Pix e nota fiscal dependem da API a escolher (acima); sem baixa parcial, juros, multa ou desconto; sem parcelamento nem títulos
recorrentes; sem conciliação bancária; sem encerramento de exercício; pagar aceita só categorias de custo e
despesa (compra de imobilizado e empréstimos entram por lançamento manual). O MCP ainda não tem ferramentas
do Financeiro. Cobrança emitida cujo título é baixado à mão continua viva no provedor até ser cancelada. Os demonstrativos são
gerenciais: não substituem a escrituração feita pela contabilidade.

## Endereço

O Office é publicado em `https://office.celeiroadministradora.com.br/` por um segundo projeto na Vercel, do mesmo
repositório, com a pasta `office` como raiz. O endereço antigo `https://www.celeiroadministradora.com.br/office/`
redireciona para o subdomínio (regra no `vercel.json` da raiz do repositório), mantendo o caminho e os parâmetros,
de modo que links antigos de indicação continuam valendo. No Supabase do Office, o Site URL é o subdomínio e as
Redirect URLs aceitam os dois endereços. Como a sessão do navegador é por endereço, quem estava logado no
endereço antigo entra de novo no subdomínio.

## Verificação de contatos por código (e-mail e WhatsApp)

Ao cadastrar uma pessoa física no Cadastro, ou ao criar um usuário do sistema, o Office envia um código de
6 números para o e-mail e para o WhatsApp informados. A mensagem leva o código e um link para a página pública
`verificar/`. A própria pessoa abre a página, digita o código e o contato passa a constar como verificado.

- **Cadastro**: o envio sai sozinho ao cadastrar uma pessoa nova (para os contatos preenchidos e ainda não
  conferidos). Na ficha, cada contato mostra a situação e o botão "Enviar código" ou "Reenviar código".
  As caixas "Celular conferido" e "E-mail conferido" continuam existindo para a equipe marcar à mão.
  Trocar o e-mail ou o celular derruba a marca de verificado daquele contato.
- **Usuários**: o formulário de novo usuário ganhou o campo WhatsApp (opcional). Ao criar ou vincular, o código
  vai para o e-mail e, se informado, para o WhatsApp. A lista mostra "verificado" ou "não verificado" e o botão
  "Enviar verificação".
- **Regras do código**: vale 24 horas, aceita até 5 tentativas, um novo envio invalida o anterior, no máximo
  um envio por minuto e 5 por dia para cada contato. O banco guarda só o resumo do código. Quem está logado
  não consegue ler o código: ele só passa pela função do servidor que faz o envio.
- **Página pública**: mostra apenas o canal, o contato mascarado (a***@dominio, (11) *****-1234) e o nome da
  empresa. Não devolve dados do cadastro.

Para publicar:

1. Rodar o `supabase.sql` atualizado.
2. Criar a função `enviar-verificacao` em Edge Functions com o conteúdo de
   `supabase/functions/enviar-verificacao/index.ts` (pode ficar com "Verify JWT" ligado ou desligado; ela mesma
   confere a sessão).
3. Em Edge Functions → Secrets, criar (quem faz é o dono da conta; as chaves não passam pelo código):
   - `RESEND_API_KEY`: chave da Resend. Opcional `VERIFICACAO_REMETENTE`, no formato
     `Nome <endereco@dominio-verificado>`; o padrão é `nao-responda@celeiroadministradora.com.br`.
   - `ZAPI_INSTANCE_ID`, `ZAPI_TOKEN` e `ZAPI_CLIENT_TOKEN`: dados da instância e o token de segurança da conta
     na Z-API, com o número já conectado por QR code.
   Sem esses segredos, o canal responde "envio ainda não configurado" e nada é enviado.

**Entrada só com o e-mail confirmado.** Usuário criado ou vinculado pelo sistema só entra depois de confirmar o
e-mail. Até lá, depois da senha e do autenticador, ele vê a tela "Confirme seu e-mail para entrar", com os botões
"Já confirmei, entrar" e "Reenviar o código", e o banco não entrega nenhum dado a ele. Na lista de Usuários a
situação aparece como "Aguardando confirmar o e-mail". O Master pode usar "Liberar sem confirmar" (por exemplo,
se o e-mail não chegar). Trocar o e-mail de um usuário que exige confirmação bloqueia a entrada até confirmar de
novo. Quem já existia antes desta regra continua entrando normalmente, e usuários inseridos direto pelo SQL Editor
(como o primeiro Master) não exigem confirmação. A confirmação do WhatsApp não bloqueia a entrada.

Limites: só celular brasileiro (DDD + 9 dígitos); a Z-API não é a API oficial do WhatsApp, então o número
conectado pode ser bloqueado pelo WhatsApp se houver muitos envios ou denúncias; o cadastro de empresa (PJ) não
tem verificação própria, só a pessoa do representante.

## Investimentos

Menus internos: Dashboard, Projetos, Investidores, Retorno esperado × real, Indicadores, Links e interesses, Comissões.

- **Projetos de captação**: nome, produto, situação, valor a ser arrecadado, taxa de retorno esperada (% ao ano),
  prazo, datas da captação, descrição e a lista de **quem está envolvido** (nome, papel e contato). O valor já
  arrecadado é a soma dos aportes ativos. A página do projeto mostra os investidores, os retornos e o andamento.
- **Investidores**: são pessoas do Cadastro (física ou jurídica) da mesma origem. "Vincular investidor" registra o
  aporte: data, valor, retorno esperado (herda o do projeto, pode mudar) e, se houver, o indicador e a comissão.
- **Retorno esperado × real**: o esperado aplica a taxa anual de cada aporte em juros simples, da data do aporte
  até a data escolhida. O real soma os retornos lançados no projeto ("Lançar retorno"). As taxas ao ano dividem
  o retorno pelo capital investido e pelo tempo, e a tela mostra a diferença em pontos percentuais.
- **Indicadores**: o indicador é escolhido entre as pessoas físicas e jurídicas ativas do Cadastro (nome e CPF ou CNPJ vêm de lá; e-mail e telefone são sugeridos e podem ser trocados), com comissão padrão e chave Pix. Se a pessoa ainda não tem cadastro, o botão **Novo cadastro** abre o formulário do Cadastro. Uma pessoa só pode ser indicador uma vez por organização.
- **Link de indicação**: criado em Indicadores → "Criar link", geral ou de um projeto, com o percentual de
  comissão do link. O link abre a página pública `indicacao/` (sem login), que mostra só o primeiro nome de quem
  indicou, o projeto e o nome da empresa, e recolhe nome, e-mail, telefone, valor pretendido e a autorização de
  contato. O interesse chega em "Links e interesses" com o indicador e a comissão do link. A comissão e as taxas
  não aparecem na página pública. Ao virar investidor, a pessoa é cadastrada no Cadastro e vinculada ao projeto
  com o indicador.
- **Comissões**: calculadas em cada aporte (valor × percentual). O relatório por período agrupa por indicador,
  marca como paga ou a pagar e pode ser impresso ou salvo em PDF. Os totais aparecem no Dashboard.
- **Segurança**: as tabelas não são lidas direto pelo navegador. As duas operações da página pública são as
  únicas do sistema que funcionam sem login; elas não devolvem dados internos e têm freio contra abuso
  (5 envios por endereço e 20 por link a cada hora, 500 por dia no total).

Pontos de atenção: (1) divulgar captação de investimentos ao público pode exigir registro ou dispensa na CVM;
a página pública foi feita só como registro de interesse, sem taxas nem promessa de retorno, mas o uso dos links
deve ser validado com o jurídico; (2) a página pública recolhe dados pessoais: incluir no aviso de privacidade;
(3) aporte, comissão e retorno entram sozinhos no Financeiro (ver "Ligação com Investimentos"); o tratamento
contábil adotado (aporte como passivo, retorno como despesa) deve ser confirmado com a contabilidade; (4) o retorno real é lançado por projeto, não por investidor; (5) o banco usa o horário
universal: entre 21h e meia-noite de Brasília, "hoje" no banco já é o dia seguinte (afeta só o que conta como
vencido ou futuro nessas três horas).

## Conexão MCP

O backoffice tem um servidor MCP próprio: a função `mcp` (`supabase/functions/mcp/index.ts`), no endereço
`https://<projeto>.supabase.co/functions/v1/mcp`. Assistentes de IA se ligam a ele e passam a consultar
(e, se liberado, gravar) no sistema em nome de um usuário.

Regras, todas aplicadas no banco (`supabase.sql`, seção 11):

- Cada conexão pertence a um usuário e alcança só o que ele alcança na tela (perfil, organização, módulos e nível).
- Nada funciona até o Master liberar, na tela **Conexão MCP**: por organização e módulo (leitura e, à parte, escrita)
  e por usuário. O Master não precisa de liberação individual. O usuário também precisa ter o módulo Conexão MCP.
- Somente leitura por padrão. Gravar exige as duas coisas: escrita liberada pelo Master no módulo e a opção
  "Permitir gravação" marcada ao criar a conexão.
- O token (`clro_…`) aparece uma única vez; o banco guarda só o resumo SHA-256. Validade de 30 dias a 1 ano,
  no máximo 5 conexões ativas por usuário, 120 chamadas por minuto por conexão.
- Revogar (o dono, o Master ou o Corporativo master da organização), bloquear o usuário, desativar o usuário
  ou desligar o módulo corta o acesso na chamada seguinte.
- Toda chamada entra na Auditoria com origem `mcp`, o IP de quem chamou e o nome da conexão. O token nunca é gravado.

Ferramentas desta versão: quem sou eu; resumo do dashboard; listar, ver, criar, mover e comentar tarefas;
buscar cadastros (documento mascarado), ver pessoa física e ver empresa; consultar auditoria.
Cadastro e Auditoria não têm ferramentas de gravação.

Para publicar:

1. Rodar o `supabase.sql` atualizado no SQL Editor.
2. Criar a função `mcp` em Edge Functions com o conteúdo de `supabase/functions/mcp/index.ts` e
   **desligar "Verify JWT"** nela (quem chama apresenta o token da conexão, não uma sessão do Supabase).
3. No sistema: Módulos e permissões → habilitar "Conexão MCP" para os perfis que vão usar; depois, em
   Conexão MCP, liberar módulos e usuários e criar a conexão.

Para conectar um assistente: servidor MCP do tipo HTTP, com o endereço acima e o cabeçalho
`Authorization: Bearer <token>`. No Claude Code:
`claude mcp add --transport http celeiro-office <endereço> --header "Authorization: Bearer <token>"`.

No Hermes (`~/.hermes/config.yaml`): entrada em `mcp_servers` com `url` e `headers: Authorization: "Bearer <token>"`.
No Codex (`~/.codex/config.toml`): `[mcp_servers.celeiro_office]` com `url` e `bearer_token_env_var`.
A tela Conexão MCP mostra os três exemplos já com o endereço certo.

Limites: o acesso é por token no cabeçalho. Assistentes que só aceitam login por OAuth (caso do conector
personalizado do aplicativo Claude, a confirmar) precisam de uma segunda etapa: ligar o servidor OAuth 2.1 do
Supabase e criar a tela de consentimento no backoffice. Os dados lidos pelo assistente passam a ser tratados
pelo serviço de IA conectado (LGPD): liberar só o necessário. Testado em simulação (banco, função e tela);
falta o teste com um assistente real depois de publicado.

## Dashboard

- Primeira linha: tarefas vencidas, urgentes, sob sua responsabilidade e não lidas, cada uma com "Ver tudo" que abre a lista já filtrada.
- Segunda linha: tarefas em aberto, concluídas em 15 dias, usuários ativos e organizações.
- Gráfico de tarefas criadas e concluídas por dia nos últimos 15 dias, e a lista de pendências com responsável e prazo.
- **Arrecadação** mostra o que foi recebido no mês corrente e quanto ainda está a receber; **Inadimplentes** mostra o valor e a quantidade de contas a receber vencidas. Os dois vêm do Financeiro (livros da Celeiro para a equipe, da própria organização para o cliente) e aparecem para quem tem o módulo Financeiro.
- **Economia de energia** continua "Sem dados": falta definir a fonte.

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
- **Workflow sem times.** O responsável é uma pessoa; ainda não há "time" como responsável.
- **Anexos de tarefa excluída.** Ao excluir uma tarefa pela tela, os arquivos são apagados antes. Se a tarefa for apagada por outro caminho, os arquivos ficam no Storage sem registro.
- **Avisos do Workflow.** Só a marcação com @ gera e-mail. Prazos, mudança de responsável e inclusão como envolvido pela lista aparecem só dentro do sistema. Não há aviso por WhatsApp.
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
