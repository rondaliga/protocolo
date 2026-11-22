/* Assinatura / ciência de quem recebe — três modos:
 *   • Desenhada : quadro (mouse, dedo ou caneta) — é a opção inicial;
 *   • Digitada  : o nome é "escrito" em fontes de assinatura (sem precisar desenhar) — escolha entre 6 estilos;
 *   • Somente PIN (quando a assinatura visual não é obrigatória).
 * O resultado é sempre um PNG gerado no navegador no instante da assinatura; por isso a imagem gravada
 * é exatamente a que o usuário viu, mesmo que outro computador não tenha as mesmas fontes.
 * Só fontes já instaladas no sistema são usadas (nada é baixado: a CSP bloqueia fontes externas).
 */
(() => {
  'use strict';
  const TINTA = '#10243e';
  const LARG = 480, ALT = 150;

  const ESTILOS = [
    { id: 'classica', nome: 'Clássica', fonte: '"Snell Roundhand","Segoe Script","Brush Script MT","Lucida Handwriting",cursive', est: 'italic', peso: 400, tam: 58, rot: -2, traco: true },
    { id: 'elegante', nome: 'Elegante', fonte: '"Apple Chancery","Monotype Corsiva","URW Chancery L","Z003","Palatino Linotype",serif', est: 'italic', peso: 400, tam: 54, rot: -3, traco: false },
    { id: 'rapida', nome: 'Manuscrita', fonte: '"Segoe Print","Bradley Hand","Noteworthy","Comic Sans MS","Comic Neue",cursive', est: 'normal', peso: 400, tam: 44, rot: -4, traco: true },
    { id: 'formal', nome: 'Formal', fonte: 'Georgia,"Times New Roman",serif', est: 'italic', peso: 400, tam: 48, rot: 0, traco: false },
    { id: 'moderna', nome: 'Moderna', fonte: '"Segoe UI","Helvetica Neue",Arial,sans-serif', est: 'italic', peso: 600, tam: 46, rot: -1, traco: true },
    { id: 'rubrica', nome: 'Rubrica', fonte: '"Snell Roundhand","Segoe Script","Brush Script MT","Lucida Handwriting",cursive', est: 'italic', peso: 400, tam: 84, rot: -6, traco: true, iniciais: true },
  ];

  const iniciais = (t) => t.split(/\s+/).filter((p) => p.length > 2 || /^[A-Za-zÀ-ú]$/.test(p)).slice(0, 3)
    .map((p) => p[0].toUpperCase()).join('.') + '.';

  // desenha o texto assinado dentro do canvas (fundo transparente)
  function desenharTexto(canvas, texto, estilo) {
    const w = canvas.width, h = canvas.height, x = canvas.getContext('2d');
    x.clearRect(0, 0, w, h);
    const t = (estilo.iniciais ? iniciais(texto) : texto).trim();
    if (!t) return;
    const escala = h / ALT;
    let tam = estilo.tam * escala;
    const montar = () => { x.font = `${estilo.est} ${estilo.peso} ${tam}px ${estilo.fonte}`; };
    montar();
    while (x.measureText(t).width > w - 40 * escala && tam > 12) { tam -= 2; montar(); }
    const larg = x.measureText(t).width;
    x.save();
    x.translate(w / 2, h * 0.58);
    x.rotate((estilo.rot * Math.PI) / 180);
    x.fillStyle = TINTA; x.strokeStyle = TINTA; x.textAlign = 'center'; x.textBaseline = 'alphabetic';
    x.fillText(t, 0, 0);
    if (estilo.traco) {
      x.lineWidth = Math.max(1.5, 2.4 * escala); x.lineCap = 'round';
      x.beginPath(); x.moveTo(-larg / 2 - 6 * escala, 14 * escala);
      x.quadraticCurveTo(0, 30 * escala, larg / 2 + 10 * escala, 6 * escala); x.stroke();
    }
    x.restore();
  }

  // quadro de desenho
  class Quadro {
    constructor(c) {
      this.c = c; this.x = c.getContext('2d'); this.vazio = true; this.on = false;
      Object.assign(this.x, { lineWidth: 2.4, lineCap: 'round', lineJoin: 'round', strokeStyle: '#111' });
      c.addEventListener('pointerdown', (e) => { e.preventDefault(); c.setPointerCapture(e.pointerId); this.on = true;
        const p = this.p(e); this.x.beginPath(); this.x.moveTo(p.x, p.y); this.x.lineTo(p.x + .1, p.y + .1); this.x.stroke(); this.vazio = false; });
      c.addEventListener('pointermove', (e) => { if (!this.on) return; e.preventDefault(); const p = this.p(e); this.x.lineTo(p.x, p.y); this.x.stroke(); });
      ['pointerup', 'pointerleave', 'pointercancel'].forEach((ev) => c.addEventListener(ev, () => { this.on = false; }));
    }
    p(e) { const r = this.c.getBoundingClientRect(); return { x: (e.clientX - r.left) * this.c.width / r.width, y: (e.clientY - r.top) * this.c.height / r.height }; }
    limpar() { this.x.clearRect(0, 0, this.c.width, this.c.height); this.vazio = true; }
    png() { return this.vazio ? null : this.c.toDataURL('image/png'); }
  }

  const HTML = (obrigatoria) => `
    <legend>Assinatura / ciência de quem recebe</legend>
    <label>PIN de <strong class="eu"></strong>
      <input class="pin" name="pin" type="password" inputmode="numeric" pattern="[0-9]*" minlength="4" maxlength="6" required autocomplete="off">
    </label>
    <div class="modos" role="group" aria-label="Forma de assinatura">
      <button type="button" class="modo" data-modo="desenhada" aria-pressed="true">✍ Desenhar</button>
      <button type="button" class="modo" data-modo="digitada" aria-pressed="false">⌨ Digitar</button>
      ${obrigatoria ? '' : '<button type="button" class="modo" data-modo="pin" aria-pressed="false">🔒 Só o PIN</button>'}
    </div>
    <div class="painel-modo pad-wrap" data-painel="desenhada">
      <canvas class="quadro" width="${LARG}" height="${ALT}" aria-label="Quadro de assinatura"></canvas>
      <button type="button" class="btn sec mini" data-limpar-quadro>Limpar assinatura</button>
    </div>
    <div class="painel-modo" data-painel="digitada" hidden>
      <label>Nome que aparecerá na assinatura
        <input type="text" class="assin-texto" maxlength="60" autocomplete="off" spellcheck="false">
      </label>
      <div class="estilos" role="radiogroup" aria-label="Estilo da assinatura">
        ${ESTILOS.map((e) => `<button type="button" class="estilo" role="radio" aria-checked="false" data-estilo="${e.id}" title="${e.nome}">
          <canvas width="300" height="94"></canvas><span>${e.nome}</span></button>`).join('')}
      </div>
    </div>
    <div class="painel-modo" data-painel="pin" hidden><p class="dica">Será registrada apenas a ciência por PIN (sem imagem de assinatura).</p></div>
    <small class="dica" data-dica></small>`;

  function montar(fieldset, { obrigatoria = false } = {}) {
    fieldset.classList.add('assinatura');
    fieldset.innerHTML = HTML(obrigatoria);
    const $ = (s) => fieldset.querySelector(s);
    const estado = { modo: 'desenhada', estilo: ESTILOS[0].id, texto: '' };
    const quadro = new Quadro($('canvas.quadro'));
    const campo = $('.assin-texto');

    const pintarPrevias = () => {
      const texto = campo.value.trim() || 'Seu nome';
      fieldset.querySelectorAll('.estilo').forEach((b) => {
        const e = ESTILOS.find((s) => s.id === b.dataset.estilo);
        desenharTexto(b.querySelector('canvas'), texto, e);
        b.setAttribute('aria-checked', String(e.id === estado.estilo)); b.classList.toggle('sel', e.id === estado.estilo);
      });
    };
    const trocarModo = (m) => {
      estado.modo = m;
      fieldset.querySelectorAll('.modo').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.modo === m)));
      fieldset.querySelectorAll('[data-painel]').forEach((p) => { p.hidden = p.dataset.painel !== m; });
      $('[data-dica]').textContent = m === 'digitada' ? 'Escolha o estilo. A assinatura digitada tem o mesmo valor da desenhada: o que vale é o seu PIN.'
        : m === 'desenhada' ? 'Use o mouse, o dedo ou a caneta no quadro.' : '';
      if (m === 'digitada') pintarPrevias();
    };
    fieldset.addEventListener('click', (ev) => {
      const m = ev.target.closest('.modo'); if (m) trocarModo(m.dataset.modo);
      const e = ev.target.closest('.estilo'); if (e) { estado.estilo = e.dataset.estilo; pintarPrevias(); }
      if (ev.target.closest('[data-limpar-quadro]')) quadro.limpar();
    });
    campo.addEventListener('input', pintarPrevias);

    return {
      reiniciar(nome) {
        campo.value = (nome || '').slice(0, 60); quadro.limpar(); estado.estilo = ESTILOS[0].id; trocarModo('desenhada');
      },
      // devolve { png, modo } ou lança Error com a mensagem para o usuário
      obter() {
        if (estado.modo === 'pin') return { png: null, modo: null };
        if (estado.modo === 'desenhada') {
          const png = quadro.png();
          if (!png) throw new Error('Desenhe a assinatura no quadro ou escolha "Digitar".');
          return { png, modo: 'desenhada' };
        }
        const texto = campo.value.replace(/\s+/g, ' ').trim();
        if (texto.length < 2) throw new Error('Digite o nome que aparecerá na assinatura.');
        const c = document.createElement('canvas'); c.width = LARG; c.height = ALT;
        desenharTexto(c, texto, ESTILOS.find((s) => s.id === estado.estilo));
        return { png: c.toDataURL('image/png'), modo: 'digitada' };
      },
    };
  }

  window.Assinatura = Object.freeze({ montar });
})();
