> **Versão legada (referência).** A versão de produção é a do diretório raiz (GitHub Pages + Supabase) — veja `../README.md`. Este código Python **não é usado** na publicação.

# Livro de Protocolo Eletrônico — Demandas Judiciais e Correspondências

MVP para substituir o livro de protocolo físico (CECAN – LNRCC). Espelha as 3 etapas do livro:
**Portaria → ADM → Super/Setor**, com data/horário gerados pelo servidor, trilha de auditoria e exportação em PDF.

## 1. Arquitetura

```
Navegador (HTML + CSS + JS puros, sem CDN)         ← funciona em rede interna sem internet
   │  JSON / HTTPS + cookie de sessão + token CSRF
   ▼
Flask (app.py)  ── regras de negócio, perfis, validações, PDF
   │   core.py (banco, relógio, auditoria, credenciais)   pdf_export.py (ReportLab)
   ▼
SQLite (instance/protocolo.db) ── triggers garantem sequência e imutabilidade
```

**Por que esta pilha:** 2 dependências (Flask, ReportLab), sem build, sem Node, banco em um único arquivo
(fácil de fazer backup). Em vez de Tailwind via CDN, o CSS é próprio — redes hospitalares costumam
bloquear a internet. Se a unidade crescer, o SQL é simples de migrar para PostgreSQL.

```
protocolo-eletronico/
├── app.py            API Flask (rotas, perfis, CSRF, cabeçalhos de segurança)
├── core.py           banco, relógio do servidor, auditoria encadeada, PIN/senha, validações
├── pdf_export.py     listagem (espelha o livro) e ficha individual em PDF
├── manage.py         CLI: criar banco, setores, usuários, desbloquear, dados de demonstração
├── schema.sql        tabelas + triggers de imutabilidade e sequência
├── test_fluxo.py     16 testes de ponta a ponta
└── static/           index.html, style.css, app.js  (coloque o logotipo em static/logo.png)
```

## 2. Como executar

```bash
python -m venv .venv
.venv\Scripts\activate            # Windows   (Linux/macOS: source .venv/bin/activate)
pip install -r requirements.txt

python manage.py demo             # só para TESTAR: cria setores e usuários de exemplo
python app.py                     # abre em http://127.0.0.1:5000
```

Usuários de demonstração (senha **Trocar@123**; PIN entre parênteses): `portaria` (1111), `adm` (2222),
`juridico` (3333), `farmacia` (4444), `gestor` (5555). **Não use em produção.**

**Produção** — crie os dados reais em vez do `demo`:

```bash
python manage.py criar-setor "Jurídico"
python manage.py criar-usuario maria.silva "Maria Silva" PORTARIA      # pede senha e PIN sem eco
python manage.py criar-usuario ana.souza "Ana Souza" SETOR --setor "Jurídico"
python manage.py desbloquear maria.silva                                # após bloqueio por tentativas
```

Servidor: `pip install waitress` e `waitress-serve --listen=0.0.0.0:8080 app:app`, **atrás de HTTPS**
(Nginx/IIS/Caddy). Com HTTPS ative `COOKIE_SEGURO=1`.

| Variável | Padrão | Função |
|---|---|---|
| `PROTOCOLO_DB` | `instance/protocolo.db` | caminho do banco |
| `UNIDADE` | `CECAN - LNRCC` | texto do cabeçalho (tela e PDF) |
| `APP_TZ` | `America/Fortaleza` | fuso do relógio do servidor |
| `SECRET_KEY` | gerada em `instance/secret.key` | chave das sessões |
| `COOKIE_SEGURO` | `0` | `1` quando houver HTTPS |
| `SESSAO_MINUTOS` | `30` | expiração por inatividade |
| `ASSINATURA_OBRIGATORIA` | `0` | `1` exige o desenho no quadro além do PIN |
| `SEGREGACAO_FUNCOES` | `1` | a mesma pessoa não assina duas etapas do mesmo protocolo |

## 3. Perfis e fluxo

| Perfil | Pode |
|---|---|
| `PORTARIA` | criar protocolo (1ª etapa); corrigir descrição |
| `ADM` | confirmar 2ª etapa; corrigir descrição |
| `SETOR` | confirmar 3ª etapa (no **seu** setor); vê só o que aguarda recebimento ou foi recebido no seu setor |
| `GESTOR` | consultar tudo, exportar, corrigir descrição, ver/verificar a auditoria |

Status: `Pendente ADM` → `Pendente Setor Final` → `Concluído / Entregue` (derivado por trigger).
Todo aceite exige o **PIN** do usuário logado; o desenho da assinatura no canvas é opcional (ou obrigatório via variável).

## 4. Regras garantidas

- **Sequência rígida** — validada na API **e** por trigger no banco.
- **Imutabilidade** — triggers bloqueiam `UPDATE`/`DELETE` em etapas, correções, auditoria, e nos campos originais do protocolo.
- **Data/horário/usuário** só do servidor; o cliente não consegue enviá-los.
- **Correção de descrição** — exige justificativa (≥10 caracteres) + PIN; a original fica preservada e a correção aparece na ficha e no PDF.
- **Numeração** `AAAA-NNNN` sem lacunas (gerada na mesma transação que cria o registro).
- **LGPD** — aviso no cadastro; bloqueio de CPF na descrição; visibilidade mínima para `SETOR`; exportações são auditadas.
- **Auditoria encadeada** — cada evento guarda o hash do anterior; o botão *Verificar integridade* detecta alteração/remoção.
- Cada etapa tem um **selo SHA-256** (nº, etapa, usuário, instante, setor e imagem da assinatura), impresso na ficha.

## 5. API resumida

| Método e rota | Perfil | Descrição |
|---|---|---|
| `POST /api/login`, `/api/logout`, `GET /api/me` | — | sessão |
| `GET /api/resumo` | todos | contadores do dashboard |
| `GET /api/protocolos?q=&status=&data_ini=&data_fim=&pagina=` | todos | listar/filtrar |
| `GET /api/protocolos/<id>` | todos | ficha completa |
| `POST /api/protocolos` | PORTARIA | 1ª etapa `{descricao, pin, assinatura_png?}` |
| `POST /api/protocolos/<id>/adm` | ADM | 2ª etapa `{pin, assinatura_png?}` |
| `POST /api/protocolos/<id>/setor` | SETOR | 3ª etapa `{pin, assinatura_png?}` |
| `POST /api/protocolos/<id>/correcao` | PORTARIA/ADM/GESTOR | `{descricao_nova, justificativa, pin}` |
| `GET /api/protocolos/<id>/pdf` | todos | ficha individual |
| `GET /api/relatorio/pdf?…mesmos filtros…` | todos | listagem no formato do livro |
| `GET /api/auditoria`, `/api/auditoria/verificar` | GESTOR | trilha e verificação |

## 6. Segurança implementada

Senha e PIN com hash (scrypt, via Werkzeug); bloqueio de 5 min após 5 erros; sessão HttpOnly + SameSite + expiração por
inatividade; token CSRF; CSP restritiva (sem scripts/estilos inline); `X-Frame-Options: DENY`; `Cache-Control: no-store` na API;
consultas parametrizadas; todo texto exibido é escapado; limite de tamanho de requisição.

## 7. Limites conhecidos e próximos passos

- **Valor jurídico da assinatura:** PIN + desenho é um *aceite formal interno*, não assinatura ICP-Brasil. Se o jurídico exigir
  validade ampla, integre certificado digital.
- **Auditoria:** a cadeia de hash detecta alterações parciais; quem tiver acesso total ao arquivo do banco poderia recalcular tudo.
  Mitigue com permissões do SO e cópia periódica do último hash para outro local.
- **Setor final:** nesta versão é o setor do usuário que recebe (travado). Para um recebedor que entrega a vários setores, ou para o
  ADM indicar o destino já na 2ª etapa, é uma alteração pequena.
- **Backup:** copie o banco com `sqlite3 instance/protocolo.db ".backup copia.db"` (não copie o arquivo com o sistema escrevendo).
- Sugestões futuras: formulário em branco para contingência (sistema fora do ar), gestão de usuários pela interface,
  troca de senha/PIN pelo próprio usuário, notificações de pendências antigas.
- A regra de CPF é uma heurística de minimização; recomenda-se validação do encarregado de dados (DPO).

## 8. Testes

`python test_fluxo.py` — cobre numeração, perfis, sequência, imutabilidade no banco, correção, auditoria adulterada,
filtros, PDFs, CSRF, bloqueio por tentativas e cabeçalhos de segurança.
