"""
Administração via linha de comando.

  python manage.py init-db                       cria o banco e as tabelas
  python manage.py criar-setor "Jurídico"        cadastra um setor de destino
  python manage.py criar-usuario LOGIN "Nome" PERFIL [--setor "Jurídico"]
                                                 (senha e PIN são pedidos sem eco)
  python manage.py desbloquear LOGIN             remove bloqueio por tentativas
  python manage.py demo                          dados de DEMONSTRAÇÃO (senhas conhecidas!)

PERFIL: PORTARIA | ADM | SETOR | GESTOR
"""
import argparse
import getpass
import sys

from werkzeug.security import generate_password_hash

import core


def _setor_id(db, nome):
    r = db.execute("SELECT id FROM setores WHERE nome = ?", (nome,)).fetchone()
    if not r:
        sys.exit(f"Setor '{nome}' não existe. Cadastre com: python manage.py criar-setor \"{nome}\"")
    return r["id"]


def criar_setor(db, nome):
    db.execute("INSERT OR IGNORE INTO setores (nome) VALUES (?)", (nome.strip(),))
    print(f"Setor '{nome}' ok.")


def criar_usuario(db, login, nome, perfil, setor, senha, pin):
    if perfil not in core.PERFIS:
        sys.exit(f"Perfil inválido. Use: {', '.join(core.PERFIS)}")
    if len(senha) < 8:
        sys.exit("A senha precisa ter ao menos 8 caracteres.")
    if not (pin.isdigit() and 4 <= len(pin) <= 6):
        sys.exit("O PIN precisa ter de 4 a 6 dígitos numéricos.")
    setor_id = _setor_id(db, setor) if setor else None
    if perfil == "SETOR" and not setor_id:
        sys.exit("Perfil SETOR exige --setor.")
    db.execute("INSERT INTO usuarios (nome, login, senha_hash, pin_hash, perfil, setor_id, criado_em)"
               " VALUES (?,?,?,?,?,?,?)",
               (nome, login, generate_password_hash(senha), generate_password_hash(pin),
                perfil, setor_id, core.agora_iso()))
    print(f"Usuário '{login}' ({perfil}) criado.")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("init-db")
    sub.add_parser("demo")
    s = sub.add_parser("criar-setor"); s.add_argument("nome")
    u = sub.add_parser("criar-usuario")
    u.add_argument("login"); u.add_argument("nome"); u.add_argument("perfil"); u.add_argument("--setor")
    d = sub.add_parser("desbloquear"); d.add_argument("login")
    a = ap.parse_args()

    core.iniciar_banco()
    db = core.conectar()

    if a.cmd == "init-db":
        print(f"Banco pronto em {core.DB_PATH}")
    elif a.cmd == "criar-setor":
        criar_setor(db, a.nome)
    elif a.cmd == "criar-usuario":
        senha = getpass.getpass("Senha (mín. 8 caracteres): ")
        if senha != getpass.getpass("Repita a senha: "):
            sys.exit("As senhas não conferem.")
        pin = getpass.getpass("PIN de assinatura (4 a 6 dígitos): ")
        criar_usuario(db, a.login, a.nome, a.perfil.upper(), a.setor, senha, pin)
    elif a.cmd == "desbloquear":
        db.execute("UPDATE usuarios SET falhas_consecutivas = 0, bloqueado_ate = NULL WHERE login = ?", (a.login,))
        print("Bloqueio removido.")
    elif a.cmd == "demo":
        for nome in ("Jurídico", "Farmácia", "Diretoria"):
            criar_setor(db, nome)
        base = [("portaria", "Maria (Portaria)", "PORTARIA", None, "1111"),
                ("adm", "João (Administração)", "ADM", None, "2222"),
                ("juridico", "Ana (Jurídico)", "SETOR", "Jurídico", "3333"),
                ("farmacia", "Carlos (Farmácia)", "SETOR", "Farmácia", "4444"),
                ("gestor", "Paula (Gestão)", "GESTOR", None, "5555")]
        for login, nome, perfil, setor, pin in base:
            if not db.execute("SELECT 1 FROM usuarios WHERE login = ?", (login,)).fetchone():
                criar_usuario(db, login, nome, perfil, setor, "Trocar@123", pin)
        print("\n*** DEMONSTRAÇÃO: senha de todos = Trocar@123 | PINs: portaria 1111, adm 2222, "
              "juridico 3333, farmacia 4444, gestor 5555 ***\n*** NUNCA use estes dados em produção. ***")
    db.close()


if __name__ == "__main__":
    main()
