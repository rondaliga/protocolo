# Guia — e-mails confiáveis com o domínio da instituição (sem custo)

Hoje o remetente é um Gmail/Hotmail. O Brevo envia, mas os provedores (Gmail, Hotmail, Yahoo) exigem que o e-mail seja assinado pelo **domínio do remetente**, e o Brevo não pode assinar em nome do `gmail.com`. Por isso parte dos avisos pode cair no spam.

**A solução gratuita:** usar um endereço do domínio que a **instituição já possui** (ex.: `avisos@suainstituicao.org`) e autenticar esse domínio no Brevo. O plano gratuito do Brevo aceita isso. O único passo que depende de outra pessoa é cadastrar três registros no DNS do domínio, tarefa de poucos minutos da **TI** (ou de quem administra o site/e-mail da instituição).

> Se a instituição não tem domínio, ou a TI não consegue ajudar: continue com o Gmail. Funciona, mas peça a quem recebe para marcar "não é spam" e mantenha o volume baixo. Não há como autenticar `gmail.com`.

---

## Passo 1 — Pedir à TI um endereço e acesso ao DNS

Envie à TI a mensagem abaixo (copie e cole):

> Olá! Estamos usando um sistema interno de protocolo que envia avisos por e-mail por meio do serviço Brevo (plano gratuito). Para os e-mails não caírem no spam, preciso que:
> 1. Seja criado um endereço de remetente no nosso domínio, por exemplo **avisos@(nosso-domínio)**. Ele não precisa ter caixa de entrada, mas preciso conseguir **abrir o e-mail** dele uma vez para confirmar um código (pode ser um apelido/alias encaminhado para mim).
> 2. Depois que eu enviar, sejam cadastrados no DNS do domínio os registros que o Brevo informar (um TXT de autenticação, dois CNAME de DKIM e um TXT de DMARC). Vou mandar os valores exatos.
> Isso não afeta o e-mail atual da instituição.

## Passo 2 — Adicionar o domínio no Brevo

1. No Brevo: seu nome (canto superior direito) → **Remetentes, domínios e IPs dedicados** → aba **Domínios** → **Adicionar um domínio**.
2. Digite o domínio (ex.: `suainstituicao.org`) e confirme.
3. O Brevo mostra os registros DNS, em uma tabela com **Tipo**, **Nome/Host** e **Valor**. Normalmente:
   - um **TXT** `brevo-code:...` (autenticação do domínio);
   - dois **CNAME** de **DKIM** (`brevo1._domainkey` e `brevo2._domainkey`);
   - um **TXT** de **DMARC** (`_dmarc`, algo como `v=DMARC1; p=none; rua=mailto:seu-email@...`).
4. Copie **exatamente** esses valores (use o botão de copiar) e envie à TI. No campo do DMARC, use um e-mail que alguém leia, para receber relatórios.

## Passo 3 — A TI cadastra no DNS

A TI entra no painel onde o domínio é gerenciado (registro.br, Cloudflare, provedor de hospedagem etc.) e cria os registros exatamente como o Brevo mostrou. Dois cuidados que a TI conhece:

- Alguns painéis acrescentam o domínio sozinhos ao campo "Nome": se o Brevo diz `brevo1._domainkey`, o painel pode querer só isso, sem repetir o domínio no final.
- Se já existir um registro DMARC (`_dmarc`), não crie outro: edite o existente.

A propagação costuma levar de minutos a algumas horas.

## Passo 4 — Autenticar no Brevo

1. Volte ao Brevo → **Domínios** e clique em **Autenticar este domínio**.
2. Quando todos os itens ficarem **verdes** (autenticado), pronto. Se algum ficar vermelho, aguarde um pouco e tente de novo, ou peça à TI para conferir o valor digitado.

## Passo 5 — Cadastrar o remetente e confirmar

1. Brevo → **Remetentes** → **Adicionar um remetente** → informe o nome (`Livro de Protocolo CECAN`) e o e-mail `avisos@suainstituicao.org`.
2. Como o domínio está autenticado, o Brevo **não pede verificação** do endereço (conforme a própria tela informa). Se pedir, use o código enviado ao alias combinado no passo 1.

## Passo 6 — Trocar o remetente no sistema

No **SQL Editor** do Supabase, rode (com a mesma chave de API do Brevo, que continua valendo):

```sql
select public.admin_configurar_brevo(
  'COLE-AQUI-A-CHAVE-xkeysib-',
  'avisos@suainstituicao.org',
  'Livro de Protocolo CECAN'
);
```

Resultado esperado: `OK: Brevo configurado. Remetente: avisos@suainstituicao.org`. Apague a chave do texto depois.

## Passo 7 — Testar

1. No sistema, como gestor: **Painel → Sistema → Enviar e-mail de teste**.
2. No Gmail, abra o e-mail → três pontos → **Mostrar original**: devem aparecer **SPF: PASS**, **DKIM: PASS** e **DMARC: PASS**.
3. Se chegou na caixa de entrada, está concluído. Você pode desativar o Gmail antigo no Brevo.

## Dicas para manter a boa entrega

- Mantenha o remetente sempre o mesmo e o assunto objetivo (o sistema já faz isso).
- Se vier a receber e-mails de **bounce/bloqueio** no Brevo (menu **Transacional → Logs**), corrija o e-mail do usuário no perfil.
- Depois de algumas semanas sem problemas, a TI pode endurecer o DMARC de `p=none` para `p=quarantine`.
