/*
 * Avisos no aparelho (Web Push) — gratuito.
 * O navegador cria uma "inscrição" (endereço do serviço de push do próprio navegador + chaves públicas)
 * e o sistema a guarda no Supabase. O envio é feito por uma Edge Function do Supabase (veja GUIA_AVISOS_NO_CELULAR.md).
 * Nenhuma descrição de documento viaja nos avisos.
 */
(() => {
  'use strict';
  window.criarAvisos = (LP) => {
    const { $, rpc, toast } = LP;
    const CHAVE = 'lp_push_ativo';
    const lerFlag = () => { try { return localStorage.getItem(CHAVE) === '1'; } catch { return false; } };
    const gravarFlag = (v) => { try { if (v) localStorage.setItem(CHAVE, '1'); else localStorage.removeItem(CHAVE); } catch { /* ignora */ } };
    const suportado = () => 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;
    const ios = () => /iphone|ipad|ipod/i.test(navigator.userAgent);
    const instalado = () => (window.matchMedia && window.matchMedia('(display-mode: standalone)').matches) || navigator.standalone === true;

    const b64 = (s) => {
      const t = (s + '='.repeat((4 - (s.length % 4)) % 4)).replace(/-/g, '+').replace(/_/g, '/');
      return Uint8Array.from(atob(t), (c) => c.charCodeAt(0));
    };
    const igual = (a, b) => a && b && a.byteLength === b.byteLength && new Uint8Array(a).every((v, i) => v === new Uint8Array(b)[i]);

    async function registro() {
      await navigator.serviceWorker.register('sw.js', { scope: './' });
      return navigator.serviceWorker.ready;
    }
    async function inscricaoAtual() {
      if (!suportado()) return null;
      const r = await navigator.serviceWorker.getRegistration();
      return r ? r.pushManager.getSubscription() : null;
    }
    async function enviarAoServidor(sub) {
      const j = sub.toJSON();
      await rpc('push_registrar', { p_endpoint: j.endpoint, p_p256dh: j.keys.p256dh, p_auth: j.keys.auth, p_agente: navigator.userAgent.slice(0, 150) });
    }

    async function ativar() {
      if (!suportado()) throw new Error(ios() && !instalado()
        ? 'No iPhone, instale o sistema na tela inicial (Compartilhar > Adicionar à Tela de Início) e abra por lá para ativar os avisos.'
        : 'Este navegador não oferece avisos no aparelho.');
      const chave = await rpc('push_chave_publica');
      const perm = await Notification.requestPermission();
      if (perm !== 'granted') throw new Error('As notificações estão bloqueadas neste navegador. Libere no cadeado do endereço e tente de novo.');
      if (!chave) return 'local';           // o gestor ainda não ativou o envio com o sistema fechado: vale só com o sistema aberto
      const reg = await registro();
      const alvo = b64(chave);
      let sub = await reg.pushManager.getSubscription();
      if (sub && !igual(sub.options && sub.options.applicationServerKey, alvo.buffer)) { await sub.unsubscribe(); sub = null; }
      if (!sub) sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: alvo });
      await enviarAoServidor(sub);
      gravarFlag(true);
      return 'push';
    }
    async function desativar() {
      const sub = await inscricaoAtual();
      if (sub) { try { await rpc('push_remover', { p_endpoint: sub.endpoint }); } catch { /* ignora */ } await sub.unsubscribe().catch(() => {}); }
      gravarFlag(false);
    }
    // ao entrar: se este aparelho já tinha avisos, vincula ao usuário que acabou de entrar
    async function sincronizar() {
      if (!lerFlag() || !suportado() || Notification.permission !== 'granted') return;
      try { const sub = await inscricaoAtual(); if (sub) await enviarAoServidor(sub); } catch { /* sem aviso: não atrapalha o acesso */ }
    }
    // ao sair: o aparelho deixa de avisar o usuário anterior (a inscrição do navegador continua para o próximo)
    async function aoSair() {
      try { const sub = await inscricaoAtual(); if (sub) await rpc('push_remover', { p_endpoint: sub.endpoint }); } catch { /* ignora */ }
    }

    async function descrever() {
      const dica = $('#avisos-estado'), bAt = $('#avisos-ativar'), bDes = $('#avisos-desativar');
      bAt.hidden = bDes.hidden = true;
      if (!suportado()) {
        dica.textContent = ios() && !instalado()
          ? 'No iPhone, os avisos só funcionam depois de instalar o sistema na tela inicial: toque em Compartilhar e em “Adicionar à Tela de Início”. Abra por esse ícone e volte aqui.'
          : 'Este navegador não oferece avisos no aparelho. Use o Chrome, Edge ou Firefox (no iPhone, o Safari com o sistema instalado na tela inicial).';
        return;
      }
      if (Notification.permission === 'denied') { dica.textContent = 'As notificações estão bloqueadas neste navegador. Libere no cadeado ao lado do endereço e abra esta janela de novo.'; return; }
      const sub = await inscricaoAtual().catch(() => null);
      if (sub && lerFlag()) { dica.textContent = 'Ativado neste aparelho: você recebe um aviso quando um protocolo chegar para você, mesmo com o sistema fechado.'; bDes.hidden = false; }
      else if (Notification.permission === 'granted') { dica.textContent = 'Ativado enquanto o sistema estiver aberto. Para receber com o sistema fechado, o gestor precisa ativar o envio de avisos no aparelho (GUIA_AVISOS_NO_CELULAR.md).'; bAt.hidden = false; }
      else { dica.textContent = 'Desativado neste aparelho. Ative para receber um aviso no celular ou no computador assim que um protocolo chegar para você.'; bAt.hidden = false; }
    }
    async function abrir() {
      const dlg = $('#dlg-avisos'); $('#avisos-erro').hidden = true; dlg.showModal(); await descrever();
    }
    function ligar() {
      const erro = (e) => { const p = $('#avisos-erro'); p.textContent = e.message; p.hidden = false; };
      $('#avisos-ativar').addEventListener('click', async () => {
        const b = $('#avisos-ativar'); b.disabled = true; $('#avisos-erro').hidden = true;
        try { const m = await ativar(); toast(m === 'push' ? 'Avisos ativados neste aparelho.' : 'Avisos ativados enquanto o sistema estiver aberto.'); } catch (e) { erro(e); } finally { b.disabled = false; await descrever(); }
      });
      $('#avisos-desativar').addEventListener('click', async () => {
        const b = $('#avisos-desativar'); b.disabled = true;
        try { await desativar(); toast('Avisos desativados neste aparelho.'); } catch (e) { erro(e); } finally { b.disabled = false; await descrever(); }
      });
    }
    return { abrir, ligar, sincronizar, aoSair, ativoNesteAparelho: lerFlag };
  };
})();
