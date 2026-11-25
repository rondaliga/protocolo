# Guia — enviar os avisos por e-mail pelo Brevo (sem prompt de comando)

Tudo é feito pelo navegador: no site do **Brevo**, no **SQL Editor do Supabase** e, se quiser o plano B, no **site do GitHub**. Nenhum programa precisa ser instalado.

**Como funciona depois de pronto**

- Quando a Portaria registra um protocolo, o **ADM recebe o e-mail na hora**.
- Quando o ADM encaminha ao setor (ou reencaminha, ou o setor devolve), **o responsável recebe o e-mail na hora**.
- O e-mail **nunca traz a descrição do documento** (LGPD): só número, tipo, prazo e o link do sistema.
- Se o Brevo falhar ou estiver desligado, o aviso continua indo para o sino do sistema, e a rotina do GitHub (plano B, passo 7) tenta de novo.

Tempo estimado: 20 a 30 minutos. O plano gratuito do Brevo (cerca de 300 e-mails por dia) é suficiente para este uso.

---

## Antes de começar

Tenha em mãos:

1. Um e-mail institucional que será o **remetente** (ex.: `avisos@suainstituicao.org`) e acesso à caixa dele, para confirmar o cadastro.
2. Acesso ao **Supabase** do projeto (o mesmo onde você rodou os arquivos SQL).
3. Os usuários do sistema com **e-mail cadastrado no perfil**. Quem não tem e-mail não recebe aviso (o painel mostra "Sem e-mail no perfil").

> Atenção: o remetente precisa ser um endereço **que você controla**. Endereços gratuitos (Gmail, Outlook, Yahoo) costumam ter os e-mails marcados como spam. Se a instituição tem domínio próprio, use um endereço dele (passo 3).

---

## Parte A — Brevo

### Passo 1 — Criar a conta

1. Acesse **https://www.brevo.com** e clique em **Sign up free** (Cadastre-se grátis).
2. Preencha nome, e-mail e senha. Confirme o e-mail pelo link que o Brevo enviar.
3. Responda as perguntas iniciais (empresa, país etc.) e conclua. Escolha o plano **Free**.

### Passo 2 — Cadastrar o remetente

1. No Brevo, clique no seu nome (canto superior direito) → **Senders, Domains & Dedicated IPs** (Remetentes, domínios e IPs dedicados).
2. Aba **Senders** → **Add a sender** (Adicionar remetente).
3. Informe o **nome** (ex.: `Livro de Protocolo CECAN`) e o **e-mail** (ex.: `avisos@suainstituicao.org`).
4. O Brevo envia um código/link para esse e-mail. Abra a caixa dele e **confirme**. O remetente deve ficar com o status **Verified** (verificado).

### Passo 3 — Autenticar o domínio (recomendado, evita spam)

Só é possível se a instituição tem domínio próprio e alguém (TI) consegue editar o DNS dele.

1. Na mesma tela, aba **Domains** → **Add a domain** → digite o domínio (ex.: `suainstituicao.org`).
2. O Brevo mostra alguns registros (**DKIM**, **DMARC** e um código de autenticação). Envie esses valores para quem administra o DNS do domínio.
3. Depois que o responsável cadastrar, volte e clique em **Authenticate this domain**. Quando ficar verde, está pronto.

Se não tiver acesso ao DNS, pule este passo: os e-mails saem, mas podem cair no spam no começo. Peça aos usuários para marcar "não é spam" na primeira vez.

### Passo 3.1 — Se o remetente for Gmail/Outlook

Funciona para testes, mas o Brevo pode recusar ou os e-mails irem para o spam. Prefira um endereço do domínio da instituição.

### Passo 4 — Criar a chave de API

1. No Brevo, clique no seu nome → **SMTP & API**.
2. Aba **API Keys** → **Generate a new API key**.
3. Dê um nome (ex.: `livro-protocolo`) e clique em **Generate**.
4. **Copie a chave agora** (começa com `xkeysib-`). O Brevo mostra a chave completa só uma vez. Guarde num lugar seguro (gerenciador de senhas).

> Nunca cole essa chave em e-mails, chats, no GitHub ou em arquivos do site. Ela só vai no Supabase, no passo 6.

---

## Parte B — Supabase

### Passo 5 — Ativar a extensão que faz o envio na hora

1. Abra o projeto no **Supabase** → menu **Database** → **Extensions**.
2. Procure por **pg_net** e ligue a chave (**Enable**). Se já estiver ativada, siga em frente.

### Passo 6 — Atualizar o banco e registrar a chave do Brevo

1. No Supabase, abra o **SQL Editor** → **New query**.
2. Se ainda não rodou a versão 9 do banco: cole o conteúdo de `supabase/instalacao_completa.sql` (ou só o de `supabase/09_alertas_imediatos.sql`) e clique em **Run**. Pode rodar mais de uma vez sem problema.
3. Abra uma **nova consulta** e cole o comando abaixo, trocando os três textos entre aspas simples:

```sql
select public.admin_configurar_brevo(
  'COLE-AQUI-A-CHAVE-xkeysib-DO-BREVO',
  'avisos@suainstituicao.org',
  'Livro de Protocolo CECAN'
);
```

   - 1º texto: a chave de API do passo 4.
   - 2º texto: o e-mail do remetente **exatamente como foi verificado** no passo 2.
   - 3º texto: o nome que aparece como remetente.
4. Clique em **Run**. O resultado deve ser: `OK: Brevo configurado. Remetente: ...`
5. **Apague o texto da consulta** (a chave ficou na tela) e não salve essa consulta com o nome padrão do histórico. Se o SQL Editor tiver salvo, exclua o item do histórico.

Para **trocar a chave** no futuro, repita este passo com a chave nova. Para **desligar** o envio imediato: `select public.admin_desativar_brevo();`

---

## Parte C — Testar

### Passo 7 — Enviar um e-mail de teste

1. Entre no sistema como **gestor** → **Painel de controle** → **Sistema**.
2. Confira o cartão **Envio imediato (Brevo): Ativo**.
3. Clique em **Enviar e-mail de teste**. Em alguns segundos o e-mail chega na caixa do **seu próprio usuário** (veja também o spam).
4. O cartão **E-mails enviados** sobe em uma unidade. Se aparecer **E-mails com erro**, a mensagem logo abaixo informa o motivo.

### Passo 8 — Teste real

1. Com um usuário da **Portaria**, registre um protocolo de teste.
2. O **ADM** deve receber o e-mail em instantes e o sino do sistema acende em até 10 segundos.
3. Com o ADM, confirme o recebimento e escolha o setor: o **setor de destino** recebe e-mail e sino na hora.
4. Se for protocolo de teste, o gestor pode excluí-lo depois (Detalhes → Excluir protocolo).

---

## Plano B opcional — GitHub Actions (SMTP do Brevo)

Serve como reserva: se o envio imediato falhar, a rotina tenta enviar a cada ~15 minutos pelo SMTP do Brevo. Pode pular se o teste do passo 7 funcionou, mas é recomendado.

1. No Brevo: **SMTP & API** → aba **SMTP**. Anote **Servidor** (`smtp-relay.brevo.com`), **Porta** (`587`), **Login** (o e-mail da conta) e clique em **Generate a new SMTP key** para criar a **senha SMTP**.
2. No GitHub, no repositório do site: **Settings** → **Secrets and variables** → **Actions**.
3. Em **Secrets** → **New repository secret**, crie (nome → valor):
   - `SMTP_HOST` → `smtp-relay.brevo.com`
   - `SMTP_USER` → o login SMTP do Brevo
   - `SMTP_PASS` → a senha SMTP gerada no item 1
   - `INTEGRACAO_SEGREDO` → um texto longo e aleatório (32 caracteres ou mais)
   - `SUPABASE_URL` e `SUPABASE_ANON_KEY` → os mesmos usados no site (se ainda não existirem)
4. Em **Variables** → **New repository variable**: `SMTP_FROM` → o e-mail do remetente verificado.
5. No SQL Editor do Supabase, registre o mesmo segredo do item 3:
   ```sql
   select public.admin_definir_segredo_integracao('O-MESMO-TEXTO-DO-INTEGRACAO_SEGREDO');
   ```
6. Em **Actions** → fluxo **Avisos por e-mail** → **Run workflow** para testar. O resultado deve ficar verde.

---

## Se algo não funcionar

| Sintoma | O que fazer |
|---|---|
| Cartão "Envio imediato" mostra **Inativo** | Refaça o passo 6.3 (a configuração não foi salva) e confira se o resultado começou com `OK:`. |
| "E-mails com erro" com `Brevo 401` | A chave de API está errada ou foi revogada. Gere outra (passo 4) e refaça o passo 6.3. |
| Erro com `Brevo 400` e fala do remetente | O e-mail do remetente não está **verificado** no Brevo (passo 2) ou foi digitado diferente. |
| O teste fica em "na fila" e não envia | A extensão **pg_net** não está ativa (passo 5) ou o Brevo está inativo. O plano B enviará na próxima rodada. |
| Chega no spam | Autentique o domínio (passo 3) e peça para marcar "não é spam". |
| Alguém não recebe | O perfil do usuário não tem e-mail (Painel → Usuários → Editar). |
| Limite diário atingido | O plano gratuito do Brevo tem limite diário; os itens ficam na fila e saem no dia seguinte pelo plano B. |

**Segurança:** a chave do Brevo fica guardada somente no banco de dados do Supabase, numa tabela que o navegador não consegue ler, e não entra no backup do sistema. Se suspeitar de vazamento, revogue a chave no Brevo e gere outra.

---

## Logo da Liga no e-mail de boas-vindas

O e-mail de acesso dos novos usuários é visual (HTML). Para a **logo da Liga Contra o Câncer** aparecer no topo:

1. No GitHub, abra a pasta `web/assets` do repositório → **Add file** → **Upload files**.
2. Envie a logo com o nome exato **`logo.png`** (fundo transparente, cerca de 400 px de largura) e confirme (**Commit changes**).
3. Aguarde o site ser publicado de novo (1 a 2 minutos).

Sem o arquivo, o e-mail mostra o texto "LIGA CONTRA O CÂNCER" no lugar da logo. A logo enviada pelo painel (Sistema → Identidade) aparece no site e nas impressões, mas **não** nos e-mails, pois os programas de e-mail só carregam imagens de um endereço público.
