/* Tema claro/escuro: Automático (segue o sistema), Claro ou Escuro. A escolha fica só neste navegador.
   Carregado no <head> para aplicar o tema antes da primeira pintura (sem "piscar"). */
(() => {
  'use strict';
  const CHAVE = 'tema', ORDEM = ['auto', 'claro', 'escuro'];
  const ROTULO = { auto: 'Tema: Automático', claro: 'Tema: Claro', escuro: 'Tema: Escuro' };
  const ler = () => { try { const v = localStorage.getItem(CHAVE); return ORDEM.includes(v) ? v : 'auto'; } catch (e) { return 'auto'; } };
  const gravar = (v) => { try { localStorage.setItem(CHAVE, v); } catch (e) { /* navegação privada: vale só nesta sessão */ } };
  const escuroAgora = (t) => t === 'escuro' || (t === 'auto' && window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches);

  function aplicar(t) {
    const raiz = document.documentElement;
    if (t === 'auto') delete raiz.dataset.tema; else raiz.dataset.tema = t;
    const meta = document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute('content', escuroAgora(t) ? '#0e151d' : '#1f4e6e');
    const ic = { auto: 'tela', claro: 'sol', escuro: 'lua' }[t];
    document.querySelectorAll('[data-tema-btn]').forEach((b) => { b.innerHTML = (window.ico ? window.ico(ic) : '') + '<span>' + ROTULO[t] + '</span>'; b.setAttribute('aria-label', `${ROTULO[t]}. Clique para alternar.`); });
  }
  let atual = ler();
  aplicar(atual);
  document.addEventListener('DOMContentLoaded', () => {
    aplicar(atual);
    document.querySelectorAll('[data-tema-btn]').forEach((b) => b.addEventListener('click', (ev) => {
      ev.stopPropagation(); atual = ORDEM[(ORDEM.indexOf(atual) + 1) % ORDEM.length]; gravar(atual); aplicar(atual);
    }));
    if (window.matchMedia) window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => { if (atual === 'auto') aplicar('auto'); });
  });
  window.__tema = { atual: () => atual };
})();
