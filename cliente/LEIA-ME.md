# Área do cliente (experiência web do aplicativo)

Página em `celeiroadministradora.com.br/cliente/`, só para quem tem cadastro. Traz as mesmas telas e os mesmos módulos do app, em formato responsivo: no celular, abas embaixo como no app; no computador, as mesmas abas viram o menu do topo.

Diferente do protótipo em `app/`, aqui a conta é de verdade: cadastro, senha e confirmação do e-mail são conferidos pelo Supabase do site.

## Arquivos

| Arquivo | Para que serve |
|---|---|
| `cliente/index.html` | A área do cliente (telas, estilo e comportamento) |
| `cliente/config.js` | Endereço e chave pública do Office (para leads, solicitações e módulos) |
| `cliente/termos.html` | Termos de Uso e Política de Privacidade (versão 1.0) |
| `supabase-cliente.sql` (raiz) | Tabelas e regras de acesso, para rodar no Supabase **do site** |

O endereço e a chave pública do Supabase do site vêm do `config.js` da raiz.

## Configuração no Supabase do site (uma vez)

1. **Rodar o SQL.** SQL Editor > New query > cole `supabase-cliente.sql` > Run. Pode rodar mais de uma vez.
2. **Abrir o cadastro.** Authentication > Sign In / Providers > ligue "Allow new users to sign up". (Hoje está desligado, do tempo em que só existia o administrador.)
3. **Exigir e-mail confirmado.** Na mesma tela, em Email, deixe "Confirm email" ligado.
4. **Enviar código em vez de link.** Authentication > Emails > Templates. Em **Confirm signup** e em **Reset password**, troque o corpo para mostrar o código. Exemplo para Confirm signup:

   ```html
   <h2>Confirme o seu e-mail</h2>
   <p>Use este código na área do cliente da Celeiro Administradora:</p>
   <p style="font-size:28px;letter-spacing:6px"><b>{{ .Token }}</b></p>
   <p>Se você não criou uma conta, ignore este e-mail.</p>
   ```

   Para Reset password, o mesmo com o título "Crie uma senha nova". Sem `{{ .Token }}` no modelo, o e-mail chega com link e a tela do código não tem o que receber.
5. **Conferir o envio.** O e-mail sai pelo SMTP configurado no projeto (Resend). Authentication > Emails > SMTP Settings deve estar ligado; sem SMTP próprio o Supabase limita a poucos e-mails por hora.
6. **Conferir as pastas de arquivos.** Storage deve mostrar `videos` e `faturas`, as duas privadas (o SQL cria).
7. **Liberar o endereço de retorno.** Authentication > URL Configuration > Redirect URLs: acrescente `https://www.celeiroadministradora.com.br/cliente/` e `https://celeiroadministradora.com.br/cliente/`. É para onde o Google e a Apple devolvem a pessoa depois do login.

## Entrar com Google e com Apple (opcional)

Os botões aparecem sozinhos na tela de entrada quando o provedor está ligado no Supabase; enquanto estiver desligado, o botão não aparece. Não é preciso mexer no código.

- **Google:** crie uma credencial OAuth (tipo "Aplicativo da Web") no Google Cloud Console, com o endereço de retorno que o Supabase mostra em Authentication > Sign In / Providers > Google. Cole o Client ID e o Client Secret nessa mesma tela e ligue o provedor.
- **Apple:** exige conta paga no Apple Developer Program. Crie um Services ID e uma chave de "Sign in with Apple", e preencha em Authentication > Sign In / Providers > Apple.

Quem entra com Google ou Apple não tem senha na Celeiro: assina abaixo-assinados só com o CPF e não vê a opção "Trocar senha". Se a Apple não informar o nome, a página pede nome e celular no primeiro acesso.

## Termos de Uso e Política de Privacidade

`cliente/termos.html` traz os dois documentos, versão 1.0. O cadastro só segue com o aceite, e a versão aceita e a data ficam gravadas no cadastro do cliente (`termos_versao`, `termos_aceitos_em`).

- **Preencher os dados da empresa:** no fim do arquivo há o bloco `EMPRESA` (razão social, CNPJ, endereço, e-mail de contato e encarregado de dados). O que ficar vazio não aparece na página.
- **É um texto padrão.** Foi escrito a partir do que o sistema realmente faz, mas não substitui a revisão de um advogado, principalmente nos itens de responsabilidade, foro, prazos de guarda e entrega da lista de assinantes.
- **Ao mudar o texto:** troque a versão e a data no cabeçalho do documento e a constante `TERMOS_VERSAO` em `cliente/index.html`.

## Como a segurança funciona

- **Sem conta, nada aparece.** A página abre só a tela de acesso; vídeos, abaixo-assinados e solicitações são entregues pelo banco apenas a quem entrou e confirmou o e-mail.
- **Cada cliente vê só o que é seu:** cadastro, solicitações e assinatura. Os outros assinantes aparecem só com primeiro nome e inicial.
- **Senha e código são conferidos pelo Supabase**, não pelo navegador. A página leva só chaves públicas.
- **Saída automática** depois de 30 minutos sem uso.
- **Conteúdo** (vídeos e abaixo-assinados) só é gravado por administrador do site que entrou com senha **e** autenticador. Quem é administrador mas entrou só com a senha vê a área como um cliente comum.
- **Assinatura de abaixo-assinado:** pede CPF válido e a senha de novo. Grava nome, CPF, data, hora, IP e protocolo. Uma assinatura por conta e por CPF. Ninguém altera nem apaga, nem o administrador.

## Ligação com o Office

- Cadastro novo vira **lead**; os três serviços viram **cotação veicular**, **migração de energia** e **abertura de conta**. Tudo chega na tela Aplicativo do Office, com `canal: web`.
- O que não for entregue na hora fica marcado e é reenviado na próxima entrada do cliente.
- **Fatura de energia:** o arquivo fica na pasta privada `faturas` do Supabase do site, dentro da pasta do próprio cliente. O Office recebe um link temporário ("Abrir a fatura"), válido por 30 dias. Depois disso, o arquivo continua guardado e pode ser aberto pelo painel do Supabase do site, em Storage.
- Os **módulos** ligados ou desligados na tela Aplicativo do Office valem aqui também.
- `teste` no `cliente/config.js` está em `false`: os registros contam nos totais. Registros feitos em teste podem ser marcados como "Descartado" no Office.

## Como administrar o conteúdo

1. Entre pelo login do site (senha + autenticador).
2. Abra `/cliente/`. Na primeira vez a página pede nome e celular.
3. Perfil > **Administrar conteúdo**: publicar vídeo (link do YouTube, do Vimeo ou arquivo de até 50 MB) e criar ou encerrar abaixo-assinados, ver e baixar a lista de assinantes.

## Diferenças em relação ao app

| No app (protótipo) | Aqui |
|---|---|
| Entrar com Google, gov.br e Apple | E-mail e senha com código por e-mail; Google e Apple quando ligados no Supabase; sem gov.br |
| Assinatura reconhecida pelo gov.br | Assinatura com CPF e confirmação da senha (assinatura eletrônica simples) |
| Explorar sem cadastro | Não existe: área só para cadastrados |
| Anexo da fatura de energia (só simulado) | Envio real da cópia da fatura, PDF ou foto de até 10 MB |
| Solicitações e módulos na área administrativa | Ficam no Office |

O gov.br não entrou porque a própria página de dúvidas do gov.br informa que o setor privado não pode se integrar ao login nem à assinatura: https://www.gov.br/governodigital/pt-br/identidade/identidade-digital-para-gestores-publicos/duvidas-frequentes-do-ecossistema-da-identidade-digital-gov-br

## Roteiro de teste

1. Abra `/cliente/` em janela anônima: deve aparecer só a tela de acesso.
2. Crie uma conta com um e-mail seu. Deve chegar um e-mail com código.
3. Digite um código errado (recusa) e depois o certo (abre o início).
4. No Office, tela Aplicativo: deve aparecer um lead novo.
5. Faça uma solicitação de Aquisição Veicular: aparece o protocolo; no Office, a cotação.
6. Saia, clique em "Esqueci minha senha", troque a senha com o código e entre.
7. Como administrador (login do site com autenticador), publique um vídeo e crie um abaixo-assinado.
8. Com a conta de cliente, assista ao vídeo e assine. Confira o protocolo e, como administrador, a lista de assinantes.
9. No Office, desligue um módulo do app e recarregue `/cliente/`: o módulo deve sumir.

## Situação dos testes

- Banco: `supabase-cliente.sql` rodado duas vezes em Postgres local sobre o `supabase.sql` do site; 58 verificações de acesso aprovadas.
- Telas: 47 verificações em navegador (celular e computador), com Supabase e Office simulados.
- **Não testado contra o Supabase real.** Em especial: chegada do e-mail com código, login com Google e Apple, envio de arquivos (vídeo e fatura) e gravação do IP na assinatura.

## Limites conhecidos

1. Os Termos de Uso e a Política de Privacidade são um texto padrão, ainda sem os dados da empresa e sem revisão jurídica.
2. Troca de e-mail da conta não está disponível para o cliente.
3. A solicitação de conta digital fica em "Em análise"; não há retorno automático de status.
4. O vídeo enviado por arquivo não tem imagem de capa; o do YouTube e do Vimeo toca dentro da página.
5. O cliente não consegue retirar a própria assinatura nem excluir a própria conta pela página (pedido de exclusão, pela LGPD, precisa de um canal).
6. Quem assina com a senha, sendo administrador, volta ao nível "só senha" e precisa entrar de novo pelo site para administrar.
7. O login dos administradores do site saiu do menu. O endereço continua o mesmo: `https://www.celeiroadministradora.com.br/#entrar`.
8. O link da fatura enviado ao Office vale 30 dias e abre o arquivo para quem tiver o link.
