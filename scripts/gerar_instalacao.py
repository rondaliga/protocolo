#!/usr/bin/env python3
"""
Gera supabase/instalacao_completa.sql: schema.sql + 02 + 03 + 04 + 05, na ordem certa, num único arquivo.
Cole esse arquivo inteiro no SQL Editor do Supabase (instalação nova OU atualização: é idempotente).

  python3 scripts/gerar_instalacao.py            grava o arquivo
  python3 scripts/gerar_instalacao.py --check    só confere se o arquivo está atualizado (usado no CI)
"""
import sys
from pathlib import Path

SQL = Path(__file__).resolve().parent.parent / "supabase"
ARQUIVOS = ["schema.sql", "02_prazos_alertas.sql", "03_painel_gestor.sql", "04_logo_horas_exclusoes.sql", "05_melhorias.sql", "06_inatividade.sql", "07_mfa.sql"]
SAIDA = SQL / "instalacao_completa.sql"


def montar() -> str:
    partes = ["-- =====================================================================\n"
              "-- INSTALAÇÃO COMPLETA (gerado por scripts/gerar_instalacao.py — não edite à mão)\n"
              f"-- Ordem: {' → '.join(ARQUIVOS)}\n"
              "-- =====================================================================\n"]
    for nome in ARQUIVOS:
        partes.append(f"\n-- >>>>>>>>>> {nome} >>>>>>>>>>\n{(SQL / nome).read_text(encoding='utf-8').rstrip()}\n")
    return "".join(partes)


if __name__ == "__main__":
    novo = montar()
    if "--check" in sys.argv:
        if not SAIDA.exists() or SAIDA.read_text(encoding="utf-8") != novo:
            print("ERRO: supabase/instalacao_completa.sql está desatualizado. Rode: python3 scripts/gerar_instalacao.py", file=sys.stderr)
            sys.exit(1)
        print("instalacao_completa.sql está atualizado.")
    else:
        SAIDA.write_text(novo, encoding="utf-8")
        print(f"gerado: {SAIDA} ({len(novo.splitlines())} linhas)")
