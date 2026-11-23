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
  schema.sql, 02…07_*.sql  migrações, em ordem; instalacao_completa.sql reúne todas
  tests/                   58 testes do schema (PostgreSQL local descartável)
scripts/build_site.py      gera dist/ (config.js + CSP, CSS enxuto, versão por conteúdo) — usado pelo workflow
scripts/gerar_instalacao.py  gera supabase/instalacao_completa.sql
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
   **Depois rode `supabase/03_painel_gestor.sql`** (painel de controle, gestor com acesso total, assinatura digitada,
   trilha organizada — seção 4C).
   **Por fim, rode `supabase/04_logo_horas_exclusoes.sql`** (logo, formatos de hora, salvar parâmetros de uma vez e exclusões — seção 4D).
   **Depois rode `supabase/05_melhorias.sql`** (versão do banco, índices, backup e retenção — seção 4E).
   **Por fim, rode `supabase/06_inatividade.sql`** (tempo de inatividade ajustável — seção 4E).
   **Depois rode `supabase/07_mfa.sql`** (verificação em duas etapas — seção 4F) **e `supabase/08_fluxo.sql`** (devolução, reencaminhamento, atalhos e lembretes em escada — seção 4G).
   **Ordem obrigatória: schema.sql → 02 → 03 → 04 → 05 → 06 → 07.** Se rodar um arquivo antigo de novo, rode os seguintes em seguida.
   **Atalho:** cole `supabase/instalacao_completa.sql` (os oito arquivos na ordem certa, gerado por `scripts/gerar_instalacao.py`).
   Serve para instalação nova **e** para atualização, e pode ser executado quantas vezes quiser.
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
   **Dica (v3):** depois do primeiro gestor cadastrado, os demais usuários são criados pelo **Painel de controle**, sem SQL.
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
   | `IDLE_MINUTES` *(opcional)* | reserva (padrão 360 = 6 h) usada só se o banco não responder; o tempo real é ajustado em **Prazos e regras → Segurança da sessão** |
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
select public.admin_definir_parametro('sla_adm_min', '1h30');       -- tempo máximo do ADM (aceita 90min, 1:30, 1h30, 1d…)
select public.admin_definir_parametro('expediente_inicio', '7h30'); -- hora do início do expediente (HH:MM)
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

## 4C. Versão 3 — painel de controle, gestor total, assinatura digitada, trilha organizada

**Painel de controle (aba exclusiva do gestor)** — sub-abas:
- **Usuários**: criar (e-mail, nome, papel, setor; senha e PIN provisórios gerados na tela), editar, **desativar/reativar**
  (encerra as sessões e bloqueia o login), **nova senha**, **novo PIN**, desbloquear PIN. Ações sensíveis pedem o **PIN do gestor**.
  Proteções: não é possível desativar/rebaixar a si mesmo nem o último gestor ativo.
- Duas abas: **Usuários** e **Sistema**. A aba **Sistema** reúne, em sequência e com um índice "Ir para": Prazos e regras (parâmetros validados), Setores, Feriados (contam no cálculo de horas úteis), Identidade visual, Backup e retenção e Uso do sistema.
- Tudo é gravado na trilha de auditoria.

**Primeiro acesso**: o usuário entra com a senha provisória e é obrigado a definir a **própria senha** (10–72 caracteres, com letra
e número) e o **próprio PIN** (não pode ser o provisório nem um PIN fraco). A senha provisória deixa de valer.

**Gestor com acesso total**: registra protocolos, recebe como ADM e confirma em nome de qualquer setor, vê todas as pendências.
O parâmetro `gestor_ignora_segregacao` (padrão `true`) permite que o gestor assine várias etapas do mesmo protocolo;
mude para `false` em *Prazos e regras* se quiser a segregação de funções também para ele.

**Assinatura**: três modos — **Digitar** (escreve o nome e escolhe entre 6 estilos de fonte: Clássica, Elegante, Manuscrita, Formal,
Moderna, Rubrica), **Desenhar** (mouse, dedo ou caneta) e **Só o PIN** (apenas se a assinatura visual não for obrigatória).
A imagem é gerada no navegador no instante da assinatura e gravada como PNG; assim, o registro não depende das fontes de quem abrir depois.
As fontes usadas são as **instaladas no aparelho** (nada é baixado); em aparelhos sem a fonte, cai numa alternativa parecida.

**Trilha de auditoria reorganizada**: colunas Data/hora · Tipo · Usuário · Ação · Protocolo · O que aconteceu (texto legível, sem JSON);
filtros por busca, tipo de evento, usuário e período; paginação; **Exportar Excel (.xlsx)** (datas e horas reais, colunas já dimensionadas, cabeçalho fixo e filtro; recomendado) e **Exportar CSV** (até 5.000 linhas, protegido contra injeção de
fórmula) e **Imprimir/PDF**. Exportações e impressões também ficam registradas.

### Limites honestos da versão 3
- A criação de usuários grava direto nas tabelas de autenticação do Supabase (`auth.users`/`auth.identities`) por SQL. Isso depende
  da estrutura interna do Supabase; se uma atualização dele mudar isso e a criação falhar, crie o usuário em
  *Authentication → Users* e vincule o perfil no painel (ou por `admin_cadastrar_perfil`).
- Teste no seu projeto real: crie um usuário pelo painel e entre com ele em outra janela.
- As ressalvas de e-mail/sino/horário do GitHub Actions da versão 2 continuam valendo.

## 4D. Versão 4 — logo, parâmetros, exclusões, detalhe do protocolo e câmera

- **Logo do sistema**: *Painel de controle → Sistema → Identidade visual*. Escolha PNG, JPEG ou WebP (reduzida automaticamente), informe o PIN
  do gestor e salve. O logo vale para o cabeçalho, a tela de login, a aba do navegador e **todas as impressões** (ficha, livro, trilha).
  *Restaurar padrão* volta ao ícone original. Fica no banco (tabela `identidade`), então vale para todos os computadores.
- **Prazos e regras**: tela única, com **um só botão "Salvar alterações"** (tudo ou nada). Expediente em HH:MM; tempos máximos aceitam
  `4h30`, `4:30`, `90min`, `1,5` (horas) e `1d` (uma jornada), com prévia do valor entendido. Os valores antigos em horas foram convertidos
  sozinhos (`sla_adm_horas` → `sla_adm_min`, etc.).
- **Exclusões (somente gestor, com PIN e justificativa obrigatória)**:
  - *Excluir protocolo* (no detalhe do protocolo): remove o protocolo, etapas, assinaturas, correções, histórico de prazo e a foto
    (inclusive do armazenamento); opcionalmente remove também os eventos anteriores dele na trilha.
  - *Excluir registros da trilha* (aba Trilha de auditoria): por período ou toda a trilha. **Exporte o CSV antes.**
  - Toda exclusão gera um registro permanente na trilha (quem, quando, quantos itens, justificativa). Depois de apagar registros da trilha, a
    verificação de integridade passa a atestar apenas os registros que restaram — por isso o ato fica registrado.
  - Os demais caminhos continuam imutáveis: ninguém consegue apagar ou alterar registros pelo navegador sem passar por essas funções.
- **Detalhe do protocolo reorganizado**: documento, ficha de dados (tipo, prazo, onde está, destino, registro), foto com legenda, linha do tempo
  das etapas (data, responsável, setor, selo e **caixa de assinatura**) e histórico de alterações; botões de ação fixos no rodapé.
- **Foto pelo celular**: "📷 Tirar foto" abre a câmera do aparelho; no computador abre a webcam numa janela; "🖼 Escolher da galeria" usa um arquivo.
- **Assinatura**: a ordem agora é **Desenhar** (padrão) → **Digitar** → **Só o PIN**.
- **Textos revisados** (aprovados por você): "Recebimento" por extenso, "Setor de destino" no lugar de "Super/Setor" e "Setor Final",
  "Aguardando ADM", "tempo máximo" no lugar de "SLA", "Perfil" no lugar de "Papel", "logotipo", "avisos", "acesso/entrada" no lugar de "login",
  plurais corretos, "Data e hora" e travessão em "CECAN – LNRCC". Se você definiu o nome da unidade no GitHub (variável `UNIDADE`),
  atualize-o para o travessão; o padrão do projeto já foi trocado.

## 4E. Versão 5 — padronização, desempenho, retenção e usabilidade

**Instalação e manutenção**
- `supabase/05_melhorias.sql` cria a tabela `schema_versao` (o painel mostra "Versão do banco de dados: 8 de 8") e é idempotente.
- `supabase/instalacao_completa.sql` instala ou atualiza tudo de uma vez. Regere com `python3 scripts/gerar_instalacao.py`; o CI recusa a publicação se ele estiver desatualizado.

**Inatividade**
- O tempo para o logout automático agora é **ajustável** em Painel → Sistema → Prazos e regras → *Segurança da sessão* (de 5 min a 24 h; aceita `6h`, `6:00`, `90min`, `1,5`). O **padrão passou de 30 min para 6 horas** (`06_inatividade.sql`).
- Vale para todos os perfis no próximo login (o gestor que altera já o recebe na hora). A mudança fica na trilha. Ao voltar de suspensão do computador, o navegador confere o tempo imediatamente.
- A contagem é feita no navegador (cliques, teclas e rolagem reiniciam). `IDLE_MINUTES` no `config.js` virou apenas reserva caso o banco não responda.
- Atenção: quanto maior o tempo, maior a janela em que um computador deixado aberto continua logado. Em computador compartilhado (portaria), considere um valor menor.

**Desempenho**
- Novos índices (setor de destino, criador, etapas, fotos, trilha por data e por ação). A listagem do livro e da trilha já era paginada no servidor.
- O build minifica o CSS e acrescenta `?v=<hash>` aos arquivos: o navegador só baixa o que mudou. O logotipo fica em cache na sessão.

**Padronização**
- O semáforo "vence em breve", o card do painel e o filtro agora seguem o parâmetro **Avisar com antecedência (dias)** (antes era fixo em 2).
- Datas em `dd/mm/aaaa` e horas em `HH:MM`, no fuso da unidade, em telas, impressões e CSV; cabeçalho e rodapé únicos em todas as impressões (livro, ficha, trilha). O rodapé “PROTOCOLO INTERNO” e a numeração de páginas saem do próprio `@page`; se o navegador também imprimir data/URL nas margens, desmarque “Cabeçalhos e rodapés” na janela de impressão.

**Segurança e LGPD**
- Ao abrir a trilha, o selo "Trilha íntegra" aparece sozinho (o botão continua para refazer).
- Aba Painel → Sistema → **Dados, backup e retenção**: baixa o backup JSON (protocolos, etapas e trilha, sem as imagens das assinaturas; o ato fica na trilha como "Backup exportado") e consulta quantos protocolos concluídos passaram do prazo de guarda. A consulta só informa; excluir continua exigindo justificativa e PIN do gestor.
- Freio de tentativas no login: 5 erros seguidos bloqueiam novas tentativas por 60 s **neste navegador**. É uma barreira de conveniência; a proteção real contra força bruta é o limite de taxa do próprio Supabase (Authentication → Rate Limits).

**Usabilidade**
- Link "Ir para o conteúdo" (teclado), foco visível em links e respeito a "reduzir movimento".
- Os filtros de status, alerta e ordem são lembrados por usuário neste navegador (busca e datas, não).
- Instalável no celular ("Adicionar à tela inicial") por `manifest.webmanifest`. O ícone do atalho é o padrão (`assets/icone.svg`): o logotipo trocado no painel vale para o sistema e as impressões, mas não para o ícone do atalho. Não há modo offline.

### Guia rápido por perfil
| Perfil | O que faz |
|---|---|
| Portaria | Registra o protocolo (foto, descrição, assinatura Desenhar/Digitar/PIN) e imprime a ficha. |
| ADM | Recebe, ajusta prazo com justificativa e PIN, encaminha ao setor. |
| Setor | Confirma o recebimento do que foi destinado ao seu setor. |
| Gestor | Tudo acima, mais painel (usuários, setores, regras, feriados, logotipo), trilha, backup, retenção e exclusões. |

### Checklist de implantação
1. Projeto Supabase criado (São Paulo) e cadastro público desligado.
2. `instalacao_completa.sql` executado; painel mostra "8 de 8".
3. Variáveis do GitHub (`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `UNIDADE`, `TIMEZONE`) e Pages em "GitHub Actions".
4. Primeiro gestor criado e senha/PIN trocados no primeiro acesso.
5. Rate limits do Supabase revisados; baixar um backup e conferir a trilha ("Trilha íntegra").
5b. Segredos `SUPABASE_DB_URL` e `BACKUP_PASSPHRASE` cadastrados e um backup de teste rodado em *Actions*; o gestor ativou as **2 etapas** (e há pelo menos dois gestores antes de ligar a exigência).
6. Fazer um protocolo de teste com os quatro perfis.

## 4G. Devolução, reencaminhamento, atalhos e lembretes em escada (migração 08)

- **Devolver ao ADM** (botão no detalhe, para o setor de destino ou o gestor): o documento não é do setor. Exige justificativa (10 a 500 caracteres) e PIN; o destino é zerado, o ADM é avisado e o protocolo aparece como *Devolvido ao ADM* nas pendências dele. Nenhum setor consegue receber um protocolo devolvido.
- **Reencaminhar** (ADM ou gestor, enquanto o protocolo aguarda o setor): troca o setor de destino com justificativa e PIN, avisa o novo setor e reinicia o tempo máximo. O setor anterior deixa de ver o protocolo.
- Cada movimentação fica em histórico imutável (tabela `movimentacoes`), aparece no *Histórico de alterações* do protocolo, na trilha (`PROTOCOLO_DEVOLVIDO`, `PROTOCOLO_REENCAMINHADO`) e no backup.
- **Atalhos da lista:** Todos · Meus pendentes · Urgentes · Vencem em 7 dias · Devolvidos. O último filtro usado é lembrado por usuário, neste navegador.
- **Lembretes em escada** (Sistema → Prazos e regras → *Lembretes quando o tempo máximo é ultrapassado*): 1º aviso ao responsável quando o tempo estoura; 2º aviso após `sla_lembrete_min` (padrão 4 h úteis); aviso também ao gestor após `sla_escalada_min` (padrão 8 h úteis). Sem e-mail cadastrado no responsável, o aviso vai direto ao gestor. A escada recomeça a cada novo encaminhamento.

## 4F. Versão 6 — backup agendado, verificação em duas etapas, aviso de logout e rascunho

### Backup agendado e cifrado (`.github/workflows/backup.yml`)
Todo domingo às 03:00 (Fortaleza) — ou quando você clicar em *Actions → Backup semanal do banco → Run workflow* — o GitHub gera um `pg_dump` do schema `public` (protocolos, etapas, trilha, parâmetros, perfis, setores, logotipo), **cifra com AES-256** e guarda como artefato por 90 dias. O script confere que o dump é legível e que as tabelas principais estão dentro, e testa a decifragem antes de terminar.

Para ligar (uma vez), em *Settings → Secrets and variables → Actions → Secrets*:
| Segredo | O que é |
|---|---|
| `SUPABASE_DB_URL` | String de conexão do banco (Supabase → Connect → *Session pooler*, formato `postgresql://postgres.xxxx:SENHA@aws-0-….pooler.supabase.com:5432/postgres`). Use o pooler: a conexão direta costuma ser só IPv6, que o GitHub não alcança. |
| `BACKUP_PASSPHRASE` | Frase longa (16+ caracteres) para cifrar. **Guarde-a fora do GitHub**: sem ela o backup não abre. |

Variáveis opcionais: `BACKUP_PG_VERSION` (padrão 17; use a versão do seu projeto Supabase) e `BACKUP_RETENCAO_DIAS` (padrão 90). Sem os segredos o fluxo só avisa e não falha.

**Restaurar** (num banco novo com o `instalacao_completa.sql` já aplicado, ou vazio):
```bash
gpg --output backup.dump --decrypt protocolo-AAAAMMDD-HHMM.dump.gpg
pg_restore --no-owner --clean --if-exists --dbname "$SUPABASE_DB_URL" backup.dump
```
**O que o backup NÃO cobre:** as **fotos** (ficam no Storage, fora do `pg_dump`) e as **contas de login** (schema `auth`, com as senhas). Para as contas, recadastre os usuários pelo painel; para as fotos, use o backup do próprio Supabase ou copie o bucket `protocolo-fotos`. O repositório deve ser **privado**: mesmo cifrado, o arquivo contém dados pessoais (LGPD).
O botão "Baixar backup (JSON)" do painel continua útil para uma cópia imediata.

### Verificação em duas etapas (TOTP) — recomendada ao gestor
- Qualquer usuário pode ativar em **2 etapas** (botão no topo): escaneia o QR Code num aplicativo autenticador (Google/Microsoft Authenticator, Authy, 2FAS…) e confirma com o primeiro código. Depois, todo login pede a senha **e** o código.
- **Exigência para o gestor:** Painel → Sistema → Prazos e regras → *Regras gerais* → "Exigir verificação em duas etapas…". Ao ligar, cada gestor é obrigado a cadastrar no próximo acesso (e não consegue desativar).
- **Proteção no servidor, não só na tela:** quem tem o fator ativo e ainda não digitou o código (sessão `aal1`) é tratado como não autenticado pelo banco — a função `public._uid()` (que substitui `auth.uid()` em todas as políticas e funções) devolve vazio. Mesmo chamando a API direto com a senha, nada é lido nem alterado. O teste automatizado prova isso.
- Cadastro, QR e conferência do código são do **Supabase Auth (MFA/TOTP)**: nenhum segredo passa pelo nosso código. No painel do Supabase, confira *Authentication → Sign In / Providers → Multi-Factor Authentication* com **TOTP** ativado (padrão).
- **Perdeu o celular?** Outro gestor usa Painel → Usuários → **Redefinir 2 etapas** (pede o PIN do gestor; derruba as sessões; fica na trilha). Se o único gestor perdeu o aparelho, rode no SQL Editor: `select public.admin_resetar_mfa('gestor@exemplo.com');` e entre só com a senha. **Ao ligar a exigência, garanta que existe mais de um gestor.**
- Eventos na trilha: *Verificação em 2 etapas ativada / desativada / redefinida*.

### Aviso antes do logout e rascunho
- No último minuto de inatividade aparece "Você ainda está aí?" com contagem regressiva; *Continuar conectado* reinicia o tempo.
- O formulário de **novo protocolo** guarda um rascunho (tipo, urgência, descrição e foto) no navegador a cada alteração. Fica em `sessionStorage` (some ao fechar a aba), por usuário, por 24 h. **Assinatura e PIN nunca são guardados.** Sair voluntariamente apaga o rascunho; o logout por inatividade o mantém para a pessoa retomar. Há o botão *Descartar rascunho*.

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

# (o run_local.sh aplica schema.sql + 02 + 03 + 04 + 05 + 06 + 07 (do 05 em diante, cada um duas vezes, para provar a idempotência) e roda 300 verificações: horas úteis e formatos de hora, SLA, foto, e-mails, painel, primeiro acesso, trilha, exportação, logo e exclusões)

# Navegador de ponta a ponta (opcional; precisa de Playwright e Pillow): site real + schema real
bash tests/e2e/preparar_db.sh && SUPABASE_URL=http://127.0.0.1:5057 SUPABASE_ANON_KEY=chave-de-teste-0000000000 python3 scripts/build_site.py \
  && python3 tests/e2e/run_e2e.py ./saida-e2e
```
O workflow executa os testes do schema, confere se `instalacao_completa.sql` está atualizado e a instala duas vezes num banco novo antes de cada publicação. O E2E usa um *mini-PostgREST* de teste
(`tests/e2e/mock_supabase.py`) que repassa as chamadas ao PostgreSQL sob o papel `authenticated` — RLS e RPCs são as reais;
só o transporte HTTP é simulado. **Valide também no seu projeto Supabase real** após publicar (faça um protocolo de teste
com os quatro perfis).

## 8. Próximos passos sugeridos
Cadastro de MFA (TOTP); relatório mensal de
cumprimento de prazos por setor; push com o navegador fechado; funcionamento offline (service worker).


## Nota: reexecutar o schema.sql
Se o `schema.sql` for executado novamente em um banco já migrado, rode em seguida `02_prazos_alertas.sql`, `03_painel_gestor.sql`, `04_logo_horas_exclusoes.sql`, `05_melhorias.sql`, `06_inatividade.sql` e `07_mfa.sql`, nesta ordem (ou apenas `instalacao_completa.sql`), para restaurar a visão `v_livro` ampliada, as funções e as permissões. O erro `42P16: cannot drop columns from view` ocorria porque `create or replace view` não pode remover colunas; o `schema.sql` agora recria a visão com `drop view if exists`.
