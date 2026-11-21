-- =====================================================================
-- Livro de Protocolo Eletrônico — Esquema do banco (SQLite)
-- Demandas judiciais e correspondências — CECAN / LNRCC
--
-- Princípios:
--   * Etapas já registradas (tramites_historico), correções e auditoria
--     são APPEND-ONLY: triggers bloqueiam UPDATE e DELETE.
--   * A sequência Portaria -> ADM -> Setor é garantida no próprio banco
--     (trigger), além da validação na aplicação (defesa em profundidade).
--   * O status do protocolo é derivado das etapas por trigger.
-- =====================================================================

PRAGMA foreign_keys = ON;

-- ---------------------------------------------------------------------
-- Setores de destino final (3ª etapa)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS setores (
    id     INTEGER PRIMARY KEY AUTOINCREMENT,
    nome   TEXT NOT NULL UNIQUE,
    ativo  INTEGER NOT NULL DEFAULT 1
);

-- ---------------------------------------------------------------------
-- Usuários. Senha de login e PIN de assinatura são guardados só como hash.
-- Perfis: PORTARIA (1ª etapa), ADM (2ª), SETOR (3ª), GESTOR (consulta/auditoria)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS usuarios (
    id                  INTEGER PRIMARY KEY AUTOINCREMENT,
    nome                TEXT NOT NULL,
    login               TEXT NOT NULL UNIQUE COLLATE NOCASE,
    senha_hash          TEXT NOT NULL,
    pin_hash            TEXT NOT NULL,
    perfil              TEXT NOT NULL CHECK (perfil IN ('PORTARIA','ADM','SETOR','GESTOR')),
    setor_id            INTEGER REFERENCES setores(id),
    ativo               INTEGER NOT NULL DEFAULT 1,
    falhas_consecutivas INTEGER NOT NULL DEFAULT 0,
    bloqueado_ate       TEXT,
    criado_em           TEXT NOT NULL,
    CHECK (perfil <> 'SETOR' OR setor_id IS NOT NULL)
);

-- ---------------------------------------------------------------------
-- Numeração sequencial por ano (2026-0001, 2026-0002, ...)
-- Atualizada dentro da mesma transação que cria o protocolo: sem lacunas.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sequencias (
    ano     INTEGER PRIMARY KEY,
    ultimo  INTEGER NOT NULL
);

-- ---------------------------------------------------------------------
-- Protocolos (campos gerais do registro)
-- numero, descricao (original), criado_em e criado_por são imutáveis.
-- Só "status" pode mudar (e apenas via trigger das etapas).
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS protocolos (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    numero     TEXT NOT NULL UNIQUE,
    descricao  TEXT NOT NULL CHECK (length(descricao) BETWEEN 5 AND 300),
    status     TEXT NOT NULL CHECK (status IN ('PENDENTE_ADM','PENDENTE_SETOR','CONCLUIDO')),
    criado_em  TEXT NOT NULL,                       -- relógio do servidor (ISO 8601 com fuso)
    criado_por INTEGER NOT NULL REFERENCES usuarios(id)
);
CREATE INDEX IF NOT EXISTS ix_protocolos_status ON protocolos(status);
CREATE INDEX IF NOT EXISTS ix_protocolos_criado ON protocolos(criado_em);

-- ---------------------------------------------------------------------
-- Histórico de trâmite: 1 linha por etapa concluída (1=Portaria, 2=ADM, 3=Setor)
-- Data/horário vêm SEMPRE do servidor. Nunca editável.
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS tramites_historico (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    protocolo_id    INTEGER NOT NULL REFERENCES protocolos(id),
    etapa           INTEGER NOT NULL CHECK (etapa IN (1,2,3)),
    recebido_em     TEXT NOT NULL,                  -- data + horário (servidor)
    usuario_id      INTEGER NOT NULL REFERENCES usuarios(id),
    usuario_nome    TEXT NOT NULL,                  -- cópia (snapshot) do nome na data
    setor_id        INTEGER REFERENCES setores(id), -- só na etapa 3
    setor_nome      TEXT,
    assinatura_tipo TEXT NOT NULL CHECK (assinatura_tipo IN ('PIN','PIN_CANVAS')),
    assinatura_png  BLOB,                           -- desenho do canvas (opcional)
    selo            TEXT NOT NULL,                  -- SHA-256 de integridade do registro
    ip              TEXT,
    UNIQUE (protocolo_id, etapa),
    CHECK ((etapa = 3) = (setor_id IS NOT NULL))
);

-- ---------------------------------------------------------------------
-- Correções de descrição: a original permanece intacta em protocolos.descricao
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS correcoes_descricao (
    id                 INTEGER PRIMARY KEY AUTOINCREMENT,
    protocolo_id       INTEGER NOT NULL REFERENCES protocolos(id),
    descricao_anterior TEXT NOT NULL,
    descricao_nova     TEXT NOT NULL CHECK (length(descricao_nova) BETWEEN 5 AND 300),
    justificativa      TEXT NOT NULL CHECK (length(justificativa) >= 10),
    usuario_id         INTEGER NOT NULL REFERENCES usuarios(id),
    usuario_nome       TEXT NOT NULL,
    corrigido_em       TEXT NOT NULL
);

-- ---------------------------------------------------------------------
-- Trilha de auditoria com encadeamento de hash (qualquer adulteração
-- ou remoção de linha quebra a cadeia e é detectada em /api/auditoria/verificar)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS auditoria (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    ocorrido_em   TEXT NOT NULL,
    usuario_id    INTEGER,
    usuario_nome  TEXT,
    acao          TEXT NOT NULL,
    protocolo_id  INTEGER,
    detalhes      TEXT NOT NULL,                    -- JSON
    ip            TEXT,
    hash_anterior TEXT NOT NULL,
    hash          TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS ix_auditoria_protocolo ON auditoria(protocolo_id);

-- =====================================================================
-- TRIGGERS DE IMUTABILIDADE E SEQUÊNCIA
-- =====================================================================

CREATE TRIGGER IF NOT EXISTS trg_protocolos_campos_imutaveis
BEFORE UPDATE ON protocolos
WHEN NEW.id <> OLD.id OR NEW.numero <> OLD.numero OR NEW.descricao <> OLD.descricao
  OR NEW.criado_em <> OLD.criado_em OR NEW.criado_por <> OLD.criado_por
BEGIN
    SELECT RAISE(ABORT, 'Campos originais do protocolo são imutáveis. Use a correção com justificativa.');
END;

CREATE TRIGGER IF NOT EXISTS trg_protocolos_sem_delete
BEFORE DELETE ON protocolos
BEGIN
    SELECT RAISE(ABORT, 'Protocolos não podem ser excluídos.');
END;

CREATE TRIGGER IF NOT EXISTS trg_tramites_sem_update
BEFORE UPDATE ON tramites_historico
BEGIN
    SELECT RAISE(ABORT, 'Registros de trâmite são imutáveis.');
END;

CREATE TRIGGER IF NOT EXISTS trg_tramites_sem_delete
BEFORE DELETE ON tramites_historico
BEGIN
    SELECT RAISE(ABORT, 'Registros de trâmite não podem ser excluídos.');
END;

-- Sequência rígida: etapa N só entra se a etapa N-1 já existe
CREATE TRIGGER IF NOT EXISTS trg_tramites_sequencia
BEFORE INSERT ON tramites_historico
WHEN NEW.etapa > 1 AND NOT EXISTS (
    SELECT 1 FROM tramites_historico
    WHERE protocolo_id = NEW.protocolo_id AND etapa = NEW.etapa - 1)
BEGIN
    SELECT RAISE(ABORT, 'Etapa anterior ainda não foi registrada.');
END;

-- Status derivado das etapas
CREATE TRIGGER IF NOT EXISTS trg_tramites_atualiza_status
AFTER INSERT ON tramites_historico
BEGIN
    UPDATE protocolos
       SET status = CASE NEW.etapa
                        WHEN 1 THEN 'PENDENTE_ADM'
                        WHEN 2 THEN 'PENDENTE_SETOR'
                        WHEN 3 THEN 'CONCLUIDO'
                    END
     WHERE id = NEW.protocolo_id;
END;

CREATE TRIGGER IF NOT EXISTS trg_correcoes_sem_update
BEFORE UPDATE ON correcoes_descricao
BEGIN SELECT RAISE(ABORT, 'Correções são imutáveis.'); END;

CREATE TRIGGER IF NOT EXISTS trg_correcoes_sem_delete
BEFORE DELETE ON correcoes_descricao
BEGIN SELECT RAISE(ABORT, 'Correções não podem ser excluídas.'); END;

CREATE TRIGGER IF NOT EXISTS trg_auditoria_sem_update
BEFORE UPDATE ON auditoria
BEGIN SELECT RAISE(ABORT, 'A trilha de auditoria é imutável.'); END;

CREATE TRIGGER IF NOT EXISTS trg_auditoria_sem_delete
BEFORE DELETE ON auditoria
BEGIN SELECT RAISE(ABORT, 'A trilha de auditoria não pode ser excluída.'); END;
