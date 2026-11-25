# Guia — avisos no celular e no computador (gratuito, sem prompt de comando)

Com isso, quando um protocolo chega para alguém, o aparelho dela mostra um aviso **mesmo com o sistema fechado**, como um aplicativo de mensagens. O aviso traz só o **número do protocolo**, nunca a descrição do documento.

**Custo: zero.** Usa o serviço de notificação do próprio navegador (Google, Mozilla, Apple) e uma função gratuita do Supabase (o plano gratuito inclui 500 mil chamadas por mês).

> **WhatsApp e SMS não são gratuitos** (dependem de contratos e cobrança por mensagem), por isso este guia usa notificações do navegador. O e-mail pelo Brevo continua funcionando junto.

**O que cada usuário precisa**

- **Android:** Chrome, Edge ou Firefox atualizados. Funciona direto, sem instalar nada.
- **Computador:** Chrome, Edge ou Firefox.
- **iPhone/iPad (iOS 16.4 ou mais novo):** primeiro instalar o sistema na tela inicial (Safari → Compartilhar → **Adicionar à Tela de Início**) e abrir pelo ícone criado. Só então os avisos podem ser ativados.

Tempo estimado: 15 minutos, uma única vez. Tudo é feito no navegador, no **Supabase**.

---

## Passo 1 — Atualizar o banco

1. No Supabase, abra o **SQL Editor** → **New query**.
2. Cole todo o `supabase/instalacao_completa.sql` do projeto atualizado e clique em **Run**. Pode rodar mais de uma vez.
3. Confirme que **pg_net** está ativada (Database → Extensions), igual ao guia do Brevo.

## Passo 2 — Gerar as chaves (no próprio sistema)

1. Entre como **gestor** → **Painel de controle** → **Sistema**.
2. Role até **Avisos no celular (gratuito)** e clique em **Gerar chaves**.
3. Aparecem três campos: **VAPID_PUBLIC**, **VAPID_PRIVATE** e **PUSH_SECRET**. Copie os três para um bloco de notas **agora**: a chave privada não é guardada em lugar nenhum e não aparece de novo. Se perder, é só gerar novas e refazer os passos 3 a 5.

> Não envie essas chaves por e-mail ou chat. A privada e o segredo só vão no Supabase (passo 3).

## Passo 3 — Criar a função de envio no Supabase

1. No Supabase: menu **Edge Functions** → **Deploy a new function** → **Via Editor**.
2. Nome da função: `enviar-push` (exatamente assim).
3. Apague o código de exemplo e cole todo o conteúdo do arquivo `supabase/functions/enviar-push/index.ts` do projeto.
   > No editor do Supabase o arquivo precisa se chamar exatamente `index.ts` (se aparecer "Entrypoint path does not exist", renomeie o arquivo para `index.ts`). O nome da função deve ser `enviar-push`.
4. Clique em **Deploy**.
5. Abra a função → **Details** (ou **Settings**) e **desligue** a opção **Verify JWT / Enforce JWT Verification**. Isso é necessário porque quem chama é o banco de dados, e a função se protege pelo segredo (`PUSH_SECRET`). Salve.
6. Anote o endereço da função, no formato `https://SEU-PROJETO.supabase.co/functions/v1/enviar-push`.

## Passo 4 — Guardar as chaves na função

1. Em **Edge Functions** → **Secrets** (ou **Manage secrets**), adicione quatro segredos (nome → valor):
   - `VAPID_PUBLIC` → a chave pública do passo 2
   - `VAPID_PRIVATE` → a chave privada do passo 2
   - `PUSH_SECRET` → o segredo do passo 2
   - `VAPID_SUBJECT` → `mailto:` seguido de um e-mail seu (ex.: `mailto:rauancostadev@gmail.com`)
2. Salve. Se a tela pedir, faça **Deploy** da função de novo.

## Passo 5 — Ligar o banco à função

No **SQL Editor** (nova consulta), cole o comando abaixo trocando os três textos entre aspas e clique em **Run**:

```sql
select public.admin_configurar_push(
  'https://SEU-PROJETO.supabase.co/functions/v1/enviar-push',
  'COLE-AQUI-O-PUSH_SECRET',
  'COLE-AQUI-A-VAPID_PUBLIC'
);
```

O resultado deve ser `OK: avisos no aparelho configurados...`. Depois **apague o segredo do texto da consulta**.

Para desligar: `select public.admin_desativar_push();`

## Passo 6 — Cada usuário ativa no seu aparelho

1. Abrir o sistema → **Minha conta** → **Avisos neste aparelho** (ou o sino → **Avisos neste aparelho**).
2. Tocar em **Ativar avisos neste aparelho** e **permitir** quando o navegador perguntar.
3. Pronto. Quem usa mais de um aparelho ativa em cada um (até 5 por pessoa).

Ao **sair** do sistema, o aparelho deixa de receber avisos daquele usuário, para o próximo que usar o mesmo aparelho não ver avisos alheios. Ao entrar de novo, volta sozinho.

## Passo 7 — Testar

1. Como gestor, vá em **Painel de controle** → **Sistema** → **Enviar e-mail de teste**. O e-mail de teste também dispara o aviso no aparelho do gestor.
2. Feche o sistema (ou bloqueie a tela) e aguarde alguns segundos: o aviso aparece.
3. Em **Sistema**, o cartão **Avisos no celular** informa quantos aparelhos estão ativados, e **Verificar instalação** mostra o item **Notificações no celular**.

---

## Se algo não funcionar

| Sintoma | O que fazer |
|---|---|
| O botão "Ativar" diz que o gestor ainda não ativou | Faça o passo 5 e peça para o usuário abrir de novo a janela. |
| "Notificações bloqueadas" | No cadeado ao lado do endereço, mude Notificações para **Permitir**. |
| No iPhone não aparece a opção | O sistema precisa estar instalado na tela inicial e aberto por lá (iOS 16.4+). |
| Nada chega com o sistema fechado | Confira o passo 3.5 (Verify JWT desligado), o endereço do passo 5 e os segredos do passo 4. Em Edge Functions → `enviar-push` → **Logs**, veja a resposta de cada envio (`401` = segredo diferente). |
| Chega com atraso no Android | O modo de economia de bateria pode adiar notificações. Em Configurações do aparelho, desative a otimização de bateria para o navegador. |
| Quer parar de receber | **Minha conta → Avisos neste aparelho → Desativar**. |

**Importante:** esta função foi testada aqui apenas até a entrega ao serviço do navegador (com simulação). A entrega real depende do seu Supabase e dos navegadores; faça o teste do passo 7 e me conte o resultado.
