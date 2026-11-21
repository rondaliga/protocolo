# Livro de Protocolo Eletrônico — CECAN - LNRCC

Recebimento e tramitação de **demandas judiciais e correspondências**, em substituição ao livro físico.
Três etapas obrigatórias, em ordem rígida: **Portaria → ADM → Super/Setor**.

Hospedagem **100% gratuita**: site estático no **GitHub Pages** + **Supabase** (Auth + PostgreSQL + RLS).
Não existe servidor próprio para manter.

```
 Navegador ── HTML/CSS/JS puros (GitHub Pages) ──► Supabase Auth  (login e senha)
                                               └─► Supabase PostgREST ─► PostgreSQL
                                                     ├─ RLS: quem lê o quê
                                                     ├─ RPC (SECURITY DEFINER): única porta de escrita
                                                     └─ Triggers: sequência, imutabilidade, auditoria
```

---

## 1. Diagnóstico da base anterior (Python/Flask/SQLite)

| Arquivo | Situação | Destino |
|---|---|---|
| `schema.sql` (SQLite) | Regras sólidas (triggers, auditoria encadeada), mas em SQLite | **Reescrito** para PostgreSQL em `supabase/schema.sql`, com RLS e RPCs |
| `app.py`, `core.py` | Regras de negócio e segurança no servidor Python — **não roda no GitHub Pages** | Regras **migradas para o banco** (funções RPC + triggers); o servidor deixa de existir |
| `pdf_export.py` | PDF gerado no servidor (ReportLab) | Substituído por **impressão do navegador** com CSS dedicado (`@media print`) |
| `manage.py` | CLI de usuários | Substituído por Supabase Auth + funções `admin_*` no SQL Editor |
| `static/*` | Front falava com a API Flask | **Reescrito** em `web/`, falando direto com o Supabase |
| `test_fluxo.py` | 16 testes da API Flask | Mantido só no legado; novos testes cobrem o SQL e o navegador (seção 7) |

O código antigo continua em [`legacy/`](legacy/README-legado.md), **somente como referência** (ou para uso local
sem internet). Ele **não é usado** pela publicação no GitHub Pages.

### Estrutura

```
web/                       site estático (é o que vai ao GitHub Pages)
  index.html  style.css  app.js  config.example.js  assets/ (coloque logo.png aqui)
supabase/
  schema.sql               rodar UMA vez no SQL Editor do Supabase
  tests/                   58 testes do schema (PostgreSQL local descartável)
scripts/build_site.py      gera dist/ (config.js + CSP) — usado pelo workflow
.github/workflows/deploy.yml
tests/e2e/                 teste no navegador contra o schema real (opcional)
legacy/                    versão Python anterior (referência)
```

---

## 2. Passo a passo — Supabase

1. Crie uma conta em <https://supabase.com> e um **New project**. Escolha a região **South America (São Paulo)**
   e guarde a senha do banco num gerenciador de senhas.
2. Abra **SQL Editor → New query**, cole **todo** o arquivo `supabase/schema.sql` e clique **Run**.
   (Cria tabelas, triggers, RPCs, RLS e alguns setores de exemplo.)
   **Logo em seguida, rode também `supabase/02_prazos_alertas.sql`** (prazos, tempos máximos, foto, destino e alertas —
   veja a seção 4B). Pode rodar de novo sem problema.
3. **Authentication → Sign In / Providers → Email**: mantenha *Email* ligado e **desligue "Allow new users to sign up"**
   (cadastro público desabilitado — só o administrador cria usuários). Defina senha mínima de 10 caracteres.
4. **Setores** (SQL Editor): ajuste à sua unidade.
   ```sql
   insert into public.setores (nome) values ('Compras'), ('Enfermagem') on conflict do nothing;
   ```
5. **Usuários**: *Authentication → Users → Add user → Create new user* (e-mail + senha, marque *Auto Confirm User*).
   Depois cadastre o **perfil e o PIN** de cada um no SQL Editor:
   ```sql
   -- papel: portaria | adm | super_setor | gestor     (setor só para super_setor)
   select public.admin_cadastrar_perfil('maria@hospital.org', 'Maria Silva', 'portaria',   null,       '4821');
   select public.admin_cadastrar_perfil('joao@hospital.org',  'João Souza',  'adm',        null,       '7390');
   select public.admin_cadastrar_perfil('ana@hospital.org',   'Ana Lima',    'super_setor','Jurídico', '1957');
   select public.admin_cadastrar_perfil('paula@hospital.org', 'Paula Reis',  'gestor',     null,       '6084');
   ```
   O PIN (4 a 6 dígitos) é a **assinatura/ciência** de cada recebimento; cada pessoa pode trocá-lo no sistema
   (*Alterar PIN*). Desativar/desbloquear: `select public.admin_desativar_perfil('x@y.org');` e
   `select public.admin_desbloquear_pin('x@y.org');`
6. **Project Settings → API** (ou *Connect*): copie a **Project URL** (`https://xxxx.supabase.co`) e a chave
   **anon / publishable** (pública). ⚠️ **Nunca** use a `service_role` / `secret` — o build recusa essa chave.

## 3. Passo a passo — GitHub Pages

1. Crie um repositório e envie este projeto (`git push` na branch `main`).
   > Em contas gratuitas o GitHub Pages exige repositório **público**. Não há segredos no código
   > (a URL e a chave *anon* são públicas por desenho), mas **nunca** commite dados reais, senhas ou PINs.
2. **Settings → Pages → Build and deployment → Source: GitHub Actions**.
3. **Settings → Secrets and variables → Actions → aba Variables → New repository variable**:

   | Variável | Valor |
   |---|---|
   | `SUPABASE_URL` | `https://xxxx.supabase.co` |
   | `SUPABASE_ANON_KEY` | chave anon/publishable |
   | `UNIDADE` *(opcional)* | `CECAN - LNRCC` |
   | `IDLE_MINUTES` *(opcional)* | minutos de inatividade até o logout (padrão 30) |
   | `ASSINATURA_OBRIGATORIA` *(opcional)* | `true` exige também o desenho no quadro |

4. Faça um *push* em `main` (ou **Actions → Publicar no GitHub Pages → Run workflow**). O workflow:
   **(a)** roda os testes do schema num PostgreSQL descartável, **(b)** gera o site injetando a configuração e
   a CSP com o seu domínio Supabase, **(c)** publica. O endereço aparece no resumo do job
   (`https://SEU-USUARIO.github.io/SEU-REPO/`).
5. **Logotipo**: salve o arquivo como `web/assets/logo.png` e faça *push*. Aparece no login, no topo e nas impressões.

### Testar localmente
```bash
SUPABASE_URL=https://xxxx.supabase.co SUPABASE_ANON_KEY=sua-chave-anon python3 scripts/build_site.py
python3 -m http.server 8080 --directory dist        # http://localhost:8080
```

---

## 4. Perfis e regras de negócio

| Papel | Pode |
|---|---|
| `portaria` | Registrar protocolo (1ª etapa) com tipo, urgência e foto; corrigir descrição |
| `adm` | Confirmar a 2ª etapa **escolhendo o setor de destino**; ajustar prazo; corrigir descrição |
| `super_setor` | Confirmar a 3ª etapa **no seu setor**; vê só o que o ADM encaminhou a ele (ou já recebeu) |
| `gestor` | Consultar tudo, imprimir, corrigir descrição, ver e verificar a auditoria |

Status: `Pendente ADM` → `Pendente Setor Final` → `Concluído / Entregue` (derivado por trigger).

- **Nº** `AAAA-NNNN`, sequencial, sem lacunas (linha de sequência travada na mesma transação).
- **Data e horário** sempre do relógio do servidor (`now()`), exibidos no fuso `America/Fortaleza`.
- **Ordem rígida** garantida em três camadas: RPC, trigger `_tramite_sequencia` e transições de status.
- **Segregação de funções**: a mesma pessoa não assina duas etapas do mesmo protocolo.
- **Correção de descrição**: exige justificativa (≥ 10 caracteres) + PIN; a original é preservada e aparece na ficha/impressão.
- **Orientação de preenchimento** (texto do livro) fixa no formulário de cadastro, mais bloqueio de CPF na descrição.

## 4B. Versão 2 — alinhando o processo (prazo, chegada, "onde está agora")

**Problema real:** uma demanda judicial com prazo de 10 dias ficou parada na portaria, ninguém sabia onde estava, chegou ao
ADM depois do prazo e só então foi para a superintendência. A versão 2 ataca cada ponto:

| Falha do processo | O que o sistema faz agora |
|---|---|
| Ninguém sabia que tinha chegado | A Portaria registra **no ato**, com **foto** do envelope/capa (obrigatória para judiciais). O ADM recebe **sino + som + aviso do navegador + e-mail** na hora. |
| Ninguém sabia o prazo | Todo judicial nasce com **prazo padrão** (5 dias úteis; o ADM ajusta ao prazo real do documento, com justificativa e PIN). Coluna **Prazo** com semáforo: No prazo · Atenção (≤ 5 dias) · Vence em breve (≤ 2) · **VENCIDO**. |
| Ninguém sabia onde estava | Coluna **Onde está agora**: "Aguardando o ADM · há 3 h 20 min" / "Aguardando Superintendência · há 1 dia". |
| Ficou parado numa etapa | **Tempo máximo (SLA) por etapa**, contado só em **horas úteis** (08h–17h, seg–sex): ADM 4 h (2 h se urgente); setor 9 h = 1 dia útil (4 h se urgente). Estourou → e-mail ao responsável **e ao gestor**, registro na auditoria e destaque no painel. |
| Foi para o setor errado / passou por todos | O **ADM escolhe o setor de destino** ao receber (ex.: Superintendência). Só esse setor enxerga e recebe. |
| Sem cobrança por etapa | Cada etapa mostra quem recebeu, quando e quanto tempo levou; KPIs "Prazo vencido" e "Parados além do tempo" no painel. |

**Fluxo ideal:** chegou → Portaria fotografa e registra (1 min) → ADM é avisado na hora, recebe e escolhe o destino → o setor
é avisado na hora e confirma → concluído. Se alguém não agir no tempo, o gestor é avisado automaticamente.

### Ativar os e-mails (uma vez)
O e-mail sai por uma rotina agendada do GitHub Actions (`.github/workflows/notificacoes.yml`, a cada 15 min em horário
comercial), usando o SMTP que você já tem (e-mail institucional, Gmail com *senha de app*, Brevo/Mailjet no plano gratuito).
1. Gere um segredo longo (no seu computador: `openssl rand -hex 32`) e grave no banco (SQL Editor):
   ```sql
   select public.admin_definir_segredo_integracao('COLE_AQUI_O_SEGREDO_GERADO');
   select public.admin_definir_parametro('url_sistema', 'https://SEU-USUARIO.github.io/SEU-REPO/');
   ```
2. No GitHub: **Settings → Secrets and variables → Actions → Secrets**: `INTEGRACAO_SEGREDO` (o mesmo valor),
   `SMTP_HOST`, `SMTP_USER`, `SMTP_PASS`. Em **Variables** (opcionais): `SMTP_PORT` (587), `SMTP_FROM`, `SMTP_SSL` (`true` para a porta 465).
   `SUPABASE_URL` e `SUPABASE_ANON_KEY` já existem do deploy.
3. **Actions → Avisos por e-mail → Run workflow** para testar. Os usuários precisam ter e-mail no perfil (o
   `admin_cadastrar_perfil` já grava; perfis antigos são preenchidos pela migração).

A rotina **não usa a chave `service_role`**: o segredo só permite verificar SLA e ler/marcar a fila de e-mails.

### Ajustes pelo SQL Editor
```sql
select * from public.parametros;                                   -- veja todos os valores
select public.admin_definir_parametro('prazo_judicial_dias', '10'); -- prazo padrão dos judiciais (dias úteis)
select public.admin_definir_parametro('sla_adm_horas', '2');        -- tempo máximo do ADM
select public.admin_definir_parametro('foto_obrigatoria_judicial', 'false');
select public.admin_cadastrar_feriado('2027-02-09', 'Carnaval');    -- feriados móveis/estaduais/municipais
select public.admin_cadastrar_perfil('x@y.org','Fulano','super_setor','Superintendência','4455');
```

### Limites honestos da versão 2
- **Sino, som e aviso do navegador só funcionam com o sistema aberto** em alguma aba (verificação a cada 30 s). Fora disso
  valem os **e-mails**. Notificação push com o navegador fechado exigiria serviço externo (não incluído, para manter 100% gratuito).
- **GitHub Actions agendado não é relógio exato**: pode atrasar alguns minutos em horários de pico e é **desativado após 60 dias
  sem atividade** no repositório (um commit ou execução manual reativa). Para a chegada e o encaminhamento o e-mail é enfileirado
  na hora, mas só **sai no próximo ciclo da rotina** (até ~15 min); o aviso imediato é o do sistema.
- **Feriados**: os nacionais de data fixa (2026–2027) vêm cadastrados; **cadastre os móveis e os locais**, senão contam como dia útil.
- **Os e-mails nunca trazem a descrição do documento** (LGPD): só nº, tipo, prazo e link.
- **Foto**: fica em bucket privado do Supabase (só quem pode ver o protocolo vê a foto; não há link público), é reduzida
  no navegador (≤ 1600 px, JPEG ≤ 1,5 MB) e é imutável. O plano gratuito do Supabase tem 1 GB de armazenamento (≈ milhares de fotos).
  Oriente a Portaria a fotografar **só a capa/envelope**, não o conteúdo.
- O prazo padrão é uma **estimativa** para não ficar sem controle; o prazo legal real é o do documento — o ADM deve ajustá-lo.
- Se alguém trocar de setor ou sair, ajuste o perfil (`admin_cadastrar_perfil` / `admin_desativar_perfil`) para que os avisos cheguem à pessoa certa.

## 5. Segurança — decisões adotadas

| Tema | Como foi resolvido |
|---|---|
| Autenticação | Supabase Auth (e-mail + senha). Sem cadastro público. Sessão em `sessionStorage` + logout por inatividade |
| Escrita | **Nenhum** `INSERT/UPDATE/DELETE` direto para `anon`/`authenticated` (sem policy e sem GRANT). Tudo via RPC `SECURITY DEFINER` com `search_path` fixo |
| Leitura (RLS) | Policies por papel; `super_setor` só enxerga o que é do seu setor (minimização LGPD). `anon` não acessa nada |
| `pin_hash` | bcrypt (pgcrypto). `GRANT SELECT` **por coluna** em `perfis`: o cliente nunca lê o hash nem os contadores |
| Força bruta do PIN | 5 erros → bloqueio de 5 min (a falha é gravada porque a RPC devolve `ok:false` em vez de abortar a transação) |
| Imutabilidade | Triggers bloqueiam `UPDATE/DELETE/TRUNCATE` em etapas, correções e auditoria, e alterar nº/descrição/data originais — valem até para a `service_role` |
| Auditoria | Cadeia de hash SHA-256 verificável (botão *Verificar integridade*); registra login/logout, criação, aceites, correções, falhas de PIN e **cada impressão** |
| Selo por etapa | SHA-256 de nº, etapa, usuário, instante, setor e imagem da assinatura, impresso na ficha |
| Chaves | Só a chave pública no cliente. `build_site.py` **aborta** se detectar `service_role` / `sb_secret_`. Nada sensível no repositório (`.gitignore` cobre `config.js`/`.env`) |
| XSS | Todo texto do banco passa por `esc()`; CSP `script-src 'self'; style-src 'self'` sem `unsafe-inline`; sem bibliotecas de terceiros (sem CDN) |
| Entradas | `CHECK` no banco (tamanhos, PNG da assinatura), validação na RPC e curingas de busca tratados como texto |

### Limites que você deve conhecer
- **GitHub Pages não permite cabeçalhos HTTP próprios**: a CSP vai em `<meta>` (não cobre `frame-ancestors`; proteção
  contra *clickjacking* é parcial). Para cabeçalhos completos, use Cloudflare Pages/Netlify (também gratuitos) com o mesmo `dist/`.
- **Assinatura**: PIN + desenho é uma *ciência formal interna*, sem validade de assinatura ICP-Brasil.
- **Auditoria**: a cadeia detecta adulteração parcial; quem tem acesso de administrador ao banco poderia refazê-la.
  Restrinja o acesso ao painel Supabase e exporte periodicamente o último hash/auditoria.
- **Plano gratuito do Supabase**: costuma pausar projetos inativos e não incluir backups automáticos — confira a política
  vigente em supabase.com/pricing. Faça `pg_dump`/exportação periódica e acesse o sistema com frequência.
- **MFA**: o Supabase oferece TOTP gratuito, mas esta versão não tem tela de cadastro de MFA (próximo passo recomendado).
- IP de acesso **não** é gravado (minimização); falhas de login ficam nos logs do próprio Supabase Auth.
- A regra de CPF é heurística de minimização; valide o processo com o encarregado de dados (DPO).

## 6. Impressão e PDF

- **Imprimir livro / PDF** (barra de ações): respeita os filtros atuais; layout **A4 paisagem** com as colunas do livro
  físico (*Nº, 1º Receb. Portaria Data/Horário, Descrição, Assinatura Portaria, 2º Receb. ADM…, 3º Receb. Super/Setor…*),
  cabeçalho institucional, *Finalidade* e *Orientação*, e imagem das assinaturas. Imprime até 300 registros por vez.
- **Imprimir ficha** (dentro do protocolo): **A4 retrato**, 3 etapas, correções e selos.
- No diálogo de impressão escolha **Salvar como PDF**. Botões e menus não aparecem na impressão.
- Toda impressão é registrada na auditoria.

## 7. Testes

```bash
# Schema (RLS, sequência, imutabilidade, PIN, auditoria) — precisa de psql e um PostgreSQL 15+
PGHOST=localhost PGUSER=postgres bash supabase/tests/run_local.sh        # banco descartável "protocolo_teste"

# (o run_local.sh aplica schema.sql + 02_prazos_alertas.sql e roda 120 verificações, incluindo horas úteis, SLA, foto e e-mails)

# Navegador de ponta a ponta (opcional; precisa de Playwright e Pillow): site real + schema real
bash tests/e2e/preparar_db.sh && SUPABASE_URL=http://127.0.0.1:5057 SUPABASE_ANON_KEY=chave-de-teste-0000000000 python3 scripts/build_site.py \
  && python3 tests/e2e/run_e2e.py ./saida-e2e
```
O workflow executa os testes do schema antes de cada publicação. O E2E usa um *mini-PostgREST* de teste
(`tests/e2e/mock_supabase.py`) que repassa as chamadas ao PostgreSQL sob o papel `authenticated` — RLS e RPCs são as reais;
só o transporte HTTP é simulado. **Valide também no seu projeto Supabase real** após publicar (faça um protocolo de teste
com os quatro perfis).

## 8. Próximos passos sugeridos
Cadastro de MFA (TOTP); gestão de usuários, setores, feriados e parâmetros pela interface (hoje via SQL); relatório mensal de
cumprimento de prazos por setor; push com o navegador fechado; rotina de backup automatizada (GitHub Actions + `pg_dump`).
