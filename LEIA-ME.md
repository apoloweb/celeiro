# Site Celeiro Administradora — versão para hospedagem (Supabase)

Site institucional com login em duas etapas (senha + Google Authenticator) e área administrativa.

## Arquivos

| Arquivo | Para que serve |
|---|---|
| `index.html` | O site, a tela de acesso e a área administrativa |
| `config.js` | Endereço e chave pública do projeto Supabase (já preenchidos) |
| `supabase.sql` | Tabelas e regras de segurança, para rodar no painel do Supabase |
| `assets/` | Logo e favicon |

## Configuração no Supabase (uma vez)

1. **Rodar o SQL.** Painel > SQL Editor > New query > cole o conteúdo de `supabase.sql` > Run.
2. **Criar o usuário.** Painel > Authentication > Users > Add user > Create new user. Informe e-mail e senha e marque "Auto Confirm User".
3. **Tornar o usuário administrador.** No SQL Editor, rode (trocando o e-mail):
   ```sql
   insert into public.administradores (user_id)
   select id from auth.users where email = 'seu-email@empresa.com.br'
   on conflict do nothing;
   ```
4. **Fechar o cadastro público.** Painel > Authentication > Sign In / Providers > desligue "Allow new users to sign up". Assim só entra quem você criar.
5. **Conferir a verificação por aplicativo.** Painel > Authentication > Multi-Factor: a opção de aplicativo autenticador (TOTP) deve estar ligada. Ela vem ligada por padrão.

## Hospedagem

Envie a pasta inteira para qualquer hospedagem de arquivos estáticos (Vercel, Netlify, Cloudflare Pages ou o servidor do domínio). O site precisa abrir em `https://`.

Depois de publicar, em Painel > Authentication > URL Configuration, coloque o endereço do site em "Site URL".

## Roteiro de teste

1. Abra o site e clique em **Entrar**.
2. Digite e-mail e uma senha errada: deve aparecer "E-mail ou senha incorretos".
3. Digite a senha certa: no primeiro acesso aparece o código QR. Leia com o Google Authenticator.
4. Digite um código errado: deve recusar. Digite o código do aplicativo: deve abrir a área administrativa.
5. Mude o telefone, salve e clique em **Ver o site**: o rodapé deve mostrar o novo número.
6. Clique em **Sair**, entre de novo: agora pede só senha e código, sem QR.
7. Abra o site em uma janela anônima e vá direto para `#admin`: deve cair na tela de acesso.

## Como a segurança funciona

- A senha e o código são conferidos pelo Supabase, não pelo navegador.
- As regras no banco (`supabase.sql`) só aceitam gravação de quem está na tabela `administradores` **e** entrou com as duas etapas. Quem entrou só com a senha não grava nada.
- Visitantes leem os textos do site; a lista de conexões MCP só aparece para administradores.
- `config.js` leva apenas a chave pública. A chave secret (service_role) nunca deve ir para o site.

## O que ainda não existe

- **Recuperação de senha pelo próprio usuário.** Hoje a troca é feita no painel do Supabase (Authentication > Users).
- **Códigos de recuperação.** O Supabase não gera. Se alguém perder o celular, apague o fator do usuário no painel (Authentication > Users > usuário > Factors) e ele cadastra de novo no próximo acesso.
- **Formulário de contato.** Continua sem canal de envio.
- **Conexões MCP.** O cadastro guarda a configuração; não liga a plataforma aos servidores.

## Situação dos testes

Testado com um Supabase simulado: login, senha errada, cadastro do autenticador, código errado, entrada, salvar conteúdo, cadastrar conexão, sair e segundo acesso. **Não foi testado contra o projeto real** — siga o roteiro acima.
