# Roteiro de validação no Supabase real

Os testes automáticos rodam em um banco local e com simulações. Este roteiro confere o **seu** projeto de verdade, em cerca de 40 minutos, com usuários de teste. Marque cada linha. Se algo falhar, anote o passo e a mensagem de erro (ou tire uma imagem) e me envie.

> Use **protocolos de teste** (descrição como "TESTE - apagar"). No final, o gestor exclui os testes (Detalhes → Excluir protocolo).

## 0. Preparação (5 min)

- [ ] SQL Editor do Supabase: rodou o `instalacao_completa.sql` mais recente (pode rodar de novo).
- [ ] Database → Extensions: **pg_net** ativada.
- [ ] Site publicado atualizado (GitHub Actions concluído em verde).
- [ ] Existem 4 usuários de teste com e-mail real seu (pode usar `+` no Gmail: `voce+portaria@gmail.com`, `voce+adm@gmail.com`, `voce+setor@gmail.com`): **Portaria**, **ADM**, **Responsável de setor**, e o **Gestor**.
- [ ] O gestor entrou, trocou a senha e o PIN do primeiro acesso.

## 1. Verificação automática (2 min)

- [ ] Gestor → **Painel → Sistema → Verificar instalação**. O resumo deve dizer **Instalação em ordem**. Qualquer item vermelho (**erro**) precisa ser corrigido antes de seguir; os amarelos (**aviso**) são sugestões (ex.: avisos no celular não configurados).
- [ ] **Painel → Sistema → Enviar e-mail de teste** chega na sua caixa (veja o spam).

## 2. Fluxo completo (15 min)

Use dois navegadores (ou uma janela anônima) para ver os usuários ao mesmo tempo.

1. **Portaria**
   - [ ] Registrar um protocolo **judicial urgente** com foto do envelope (teste a câmera no celular Android, se possível).
   - [ ] O protocolo aparece no livro com o número do ano.
2. **ADM**
   - [ ] Recebe o **e-mail** em instantes e o **sino** acende em até 10 segundos.
   - [ ] Abre o protocolo, **confirma o recebimento** com o PIN, escolhe o setor.
3. **Setor**
   - [ ] Recebe e-mail e sino na hora. Confirma o recebimento com o PIN (e, se usar, assinatura).
   - [ ] O protocolo passa a **Concluído** para todos.
4. **Devolução e reencaminhamento** (novo protocolo de teste)
   - [ ] ADM encaminha ao setor A; o responsável do setor A **devolve** com justificativa. O ADM vê "Devolvido ao ADM".
   - [ ] O ADM **reencaminha** ao setor B. O setor A deixa de ver o protocolo.
5. **Prazo**
   - [ ] O ADM **ajusta o prazo** (justificativa + PIN). O gestor vê o prazo novo no livro.

## 3. Segurança e acesso (10 min)

- [ ] Um usuário de um setor **não vê** protocolos de outro setor.
- [ ] A Portaria **não vê** o painel nem a trilha.
- [ ] PIN errado 5 vezes **bloqueia** o usuário; o gestor desbloqueia no painel.
- [ ] Gestor → **Trilha de auditoria → Verificar trilha**: resultado "íntegra".
- [ ] Deixe um usuário **sem mexer** até o aviso de inatividade aparecer (ou reduza o tempo em Prazos e regras para testar).
- [ ] (Se ativou) **Verificação em duas etapas** pede o código no próximo acesso do gestor.

## 4. Relatórios e backup (5 min)

- [ ] **Painel → Relatórios**: gere 30 dias; os números batem com o livro (registrados, concluídos, em andamento).
- [ ] **Exportar Excel** abre no Excel/LibreOffice com as seções (Totais, Tempo médio, Por setor…).
- [ ] **Backup e retenção → Gerar backup** baixa o arquivo.

## 5. Avisos no celular (opcional, 10 min — veja GUIA_AVISOS_NO_CELULAR.md)

- [ ] **Minha conta → Avisos neste aparelho → Ativar** e permitir.
- [ ] Com o sistema **fechado**, o gestor envia o e-mail de teste: o aviso aparece no aparelho.

## 6. Encerramento

- [ ] O gestor **exclui os protocolos de teste**.
- [ ] Rode **Verificar instalação** de novo: deve estar em ordem.
- [ ] Anote o que falhou (se algo) e me envie.
