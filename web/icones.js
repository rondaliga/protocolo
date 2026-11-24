/* Ícones de interface (traço 24×24, estilo linear). Sem bibliotecas: cada ícone é só o desenho (atributo "d").
   Uso em HTML:  <span data-ico="livro"></span>  (o ícone é inserido no início do elemento)
   Uso em JS:    window.ico('livro')  →  string <svg> pronta. Os ícones são decorativos (aria-hidden). */
(() => {
  'use strict';
  const D = {
    livro: 'M2 4h6a4 4 0 0 1 4 4v12a3 3 0 0 0-3-3H2z M22 4h-6a4 4 0 0 0-4 4v12a3 3 0 0 1 3-3h7z',
    escudo: 'M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z M9 12l2 2 4-4',
    painel: 'M3 3h8v8H3z M13 3h8v5h-8z M13 12h8v9h-8z M3 15h8v6H3z',
    sino: 'M6 8a6 6 0 0 1 12 0c0 7 3 9 3 9H3s3-2 3-9 M10 21a2 2 0 0 0 4 0',
    mais: 'M12 5v14 M5 12h14',
    imprimir: 'M6 9V3h12v6 M6 18H4v-7h16v7h-2 M6 14h12v7H6z',
    baixar: 'M12 3v12 M7 10l5 5 5-5 M4 21h16',
    usuario: 'M20 21a8 8 0 0 0-16 0 M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8',
    seta: 'M6 9l6 6 6-6',
    sair: 'M9 21H5V3h4 M16 17l5-5-5-5 M21 12H9',
    cadeado: 'M5 11h14v10H5z M8 11V7a4 4 0 0 1 8 0v4',
    pin: 'M4 8h16 M4 16h16 M9 3L7 21 M17 3l-2 18',
    camadas: 'M12 3l9 5-9 5-9-5z M3 13l9 5 9-5',
    relogio: 'M12 7v5l3 2 M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18z',
    ok: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18z M8 12l3 3 5-6',
    alerta: 'M12 3l10 18H2z M12 10v5 M12 18h.01',
    cronometro: 'M12 8v5l3 2 M12 4a8 8 0 1 0 0 16 8 8 0 0 0 0-16z M9 2h6',
    sol: 'M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8z M12 2v2 M12 20v2 M4.9 4.9l1.4 1.4 M17.7 17.7l1.4 1.4 M2 12h2 M20 12h2 M4.9 19.1l1.4-1.4 M17.7 6.3l1.4-1.4',
    lua: 'M21 12.8A9 9 0 1 1 11.2 3 7 7 0 0 0 21 12.8z',
    tela: 'M3 4h18v12H3z M8 20h8 M12 16v4',
    busca: 'M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14z M21 21l-4.3-4.3',
    fechar: 'M6 6l12 12 M18 6L6 18',
    volta: 'M3 12a9 9 0 1 0 3-6.7 M3 4v5h5',
    editar: 'M4 20h4L19 9l-4-4L4 16z M13.5 6.5l4 4',
    lixeira: 'M4 7h16 M9 7V4h6v3 M6 7l1 14h10l1-14 M10 11v6 M14 11v6',
    salvar: 'M5 3h12l4 4v14H3V3z M7 3v5h8V3 M7 21v-7h10v7',
    camera: 'M4 7h3l2-3h6l2 3h3v13H4z M12 10a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7z',
    galeria: 'M3 4h18v16H3z M3 16l5-5 4 4 3-3 6 6 M8.5 8.5h.01',
    calendario: 'M3 5h18v16H3z M3 10h18 M8 3v4 M16 3v4',
    predio: 'M5 21V3h10v18 M15 9h4v12 M9 7h2 M9 11h2 M9 15h2 M3 21h18',
    info: 'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18z M12 11v6 M12 7.5h.01',
    esq: 'M15 6l-6 6 6 6',
    dir: 'M9 6l6 6-6 6',
    filtro: 'M3 5h18l-7 8v6l-4 2v-8z',
    upload: 'M12 17V5 M7 10l5-5 5 5 M4 21h16',
    arquivo: 'M6 3h8l5 5v13H6z M14 3v5h5 M9 13h7 M9 17h7',
    raio: 'M13 2L4 14h7l-1 8 9-12h-7z',
    usuariomais: 'M16 21a7 7 0 0 0-14 0 M9 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8 M19 8v6 M16 11h6',
    planilha: 'M4 3h16v18H4z M4 9h16 M4 15h16 M10 3v18',
    copiar: 'M9 9h11v12H9z M5 15H4V3h11v2',
    chave: 'M14 10a5 5 0 1 0-4 4.9L10 17h3v3h3v-3l5-5V9h-3z',
    tabela: 'M3 5h18v14H3z M3 10h18 M9 5v14',
    seguir: 'M5 12h14 M13 6l6 6-6 6',
    encaminhar: 'M4 12h12 M12 6l6 6-6 6 M4 5v14',
    devolver: 'M20 12H8 M12 6l-6 6 6 6',
    nuvem: 'M7 18a4 4 0 0 1-.5-8A6 6 0 0 1 18 9a4.5 4.5 0 0 1 0 9z',
    olho: 'M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12z M12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6z',
    gerar: 'M3 12a9 9 0 0 1 15-6.7L21 8 M21 3v5h-5 M21 12a9 9 0 0 1-15 6.7L3 16 M3 21v-5h5',
    palette: 'M12 3a9 9 0 0 0 0 18c1.5 0 2-1 1.5-2-.6-1.2.2-2.5 1.6-2.5H17a4 4 0 0 0 4-4C21 6.5 17 3 12 3z M7.5 11h.01 M10 7.5h.01 M14.5 7.5h.01',
    sliders: 'M4 6h10 M18 6h2 M4 12h4 M12 12h8 M4 18h12 M20 18h0 M16 4v4 M10 10v4 M18 16v4',
    grafico: 'M4 20V4 M4 20h16 M8 16v-5 M13 16V8 M18 16v-3',
    pessoas: 'M16 21a6 6 0 0 0-12 0 M10 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8 M22 21a5 5 0 0 0-4-4.9 M16 4.2a4 4 0 0 1 0 7.6',
    verificar: 'M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z M9 12l2 2 4-4',
  };
  const svg = (n) => `<svg class="ico" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="${D[n] || ''}"/></svg>`;
  window.ico = svg;
  window.icoComTexto = (n, t) => `${svg(n)}<span>${t}</span>`;
  const aplicar = (raiz) => (raiz || document).querySelectorAll('[data-ico]').forEach((el) => {
    if (el.firstElementChild && el.firstElementChild.classList.contains('ico')) return;
    el.insertAdjacentHTML('afterbegin', svg(el.dataset.ico));
  });
  window.aplicarIcones = aplicar;
  document.addEventListener('DOMContentLoaded', () => {
    aplicar(document);
    // Conteúdo montado depois (tabelas, gaveta de detalhes, avisos) também recebe os ícones.
    new MutationObserver((muts) => muts.forEach((m) => m.addedNodes.forEach((n) => {
      if (n.nodeType !== 1) return;
      if (n.matches && n.matches('[data-ico]')) aplicar({ querySelectorAll: () => [n] });
      aplicar(n);
    }))).observe(document.body, { childList: true, subtree: true });
  });
})();
