/* Gerador de QR Code em JavaScript puro (sem bibliotecas, sem rede). Modo byte (UTF-8), correção de erros M, versões 1 a 10
   (até 213 bytes). Uso: window.QR.svg('https://...') devolve o texto de um <svg> pronto (só atributos, compatível com a CSP). */
(() => {
  'use strict';
  // por versão (1..10), nível M: [codewords de correção por bloco, [[nº de blocos, codewords de dados por bloco], ...]]
  const BLOCOS = [null, [10, [[1, 16]]], [16, [[1, 28]]], [26, [[1, 44]]], [18, [[2, 32]]], [24, [[2, 43]]], [16, [[4, 27]]],
    [18, [[4, 31]]], [22, [[2, 38], [2, 39]]], [22, [[3, 36], [2, 37]]], [26, [[4, 43], [1, 44]]]];
  const ALINHA = [null, [], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34], [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50]];

  // corpo de Galois GF(256), polinômio 0x11d
  const EXP = new Array(512), LOG = new Array(256);
  (() => { let x = 1; for (let i = 0; i < 255; i += 1) { EXP[i] = x; LOG[x] = i; x <<= 1; if (x & 256) x ^= 0x11d; } for (let i = 255; i < 512; i += 1) EXP[i] = EXP[i - 255]; })();
  const mul = (a, b) => (a && b ? EXP[LOG[a] + LOG[b]] : 0);
  function geradora(n) {
    let p = [1];
    for (let i = 0; i < n; i += 1) { const q = new Array(p.length + 1).fill(0); p.forEach((c, j) => { q[j] ^= c; q[j + 1] ^= mul(c, EXP[i]); }); p = q; }
    return p;
  }
  function correcao(dados, n) {
    const g = geradora(n), r = new Array(n).fill(0);
    dados.forEach((d) => { const f = d ^ r[0]; r.shift(); r.push(0); if (f) g.slice(1).forEach((c, i) => { r[i] ^= mul(c, f); }); });
    return r;
  }
  const totalDados = (v) => BLOCOS[v][1].reduce((s, [n, d]) => s + n * d, 0);

  function codewords(bytes, v) {
    const bits = [];
    const put = (val, len) => { for (let i = len - 1; i >= 0; i -= 1) bits.push((val >>> i) & 1); };
    put(4, 4); put(bytes.length, v < 10 ? 8 : 16); bytes.forEach((b) => put(b, 8));
    const cap = totalDados(v) * 8;
    put(0, Math.min(4, cap - bits.length));
    while (bits.length % 8) bits.push(0);
    const out = []; for (let i = 0; i < bits.length; i += 8) out.push(parseInt(bits.slice(i, i + 8).join(''), 2));
    for (let pad = 0; out.length < totalDados(v); pad += 1) out.push(pad % 2 ? 0x11 : 0xec);
    // blocos + intercalação
    const [ne, grupos] = BLOCOS[v]; const blocos = []; let pos = 0;
    grupos.forEach(([n, d]) => { for (let i = 0; i < n; i += 1) { const dd = out.slice(pos, pos + d); pos += d; blocos.push({ dd, ec: correcao(dd, ne) }); } });
    const fim = []; const maxD = Math.max(...blocos.map((b) => b.dd.length));
    for (let i = 0; i < maxD; i += 1) blocos.forEach((b) => { if (i < b.dd.length) fim.push(b.dd[i]); });
    for (let i = 0; i < ne; i += 1) blocos.forEach((b) => fim.push(b.ec[i]));
    return fim;
  }

  const compr = (x) => x.toString(2).length;
  const resto = (valor, gen, grau) => { let r = valor << grau; while (compr(r) > grau) r ^= gen << (compr(r) - compr(gen)); return r; };
  function formato(mask) { return (((mask) << 10) | resto(mask, 0x537, 10)) ^ 0x5412; }   // nível M = 00
  function versaoInfo(v) { return (v << 12) | resto(v, 0x1f25, 12); }

  function montar(v, cw, mask) {
    const n = 17 + 4 * v; const m = Array.from({ length: n }, () => new Array(n).fill(null)); const fixo = Array.from({ length: n }, () => new Array(n).fill(false));
    const set = (x, y, val, f = true) => { if (x < 0 || y < 0 || x >= n || y >= n) return; m[y][x] = val; if (f) fixo[y][x] = true; };
    const localizador = (cx, cy) => { for (let dy = -4; dy <= 4; dy += 1) for (let dx = -4; dx <= 4; dx += 1) {
      const d = Math.max(Math.abs(dx), Math.abs(dy)); set(cx + dx, cy + dy, d !== 2 && d !== 4); } };
    localizador(3, 3); localizador(n - 4, 3); localizador(3, n - 4);
    const al = ALINHA[v];
    al.forEach((ay) => al.forEach((ax) => {
      if ((ax === 6 && ay === 6) || (ax === 6 && ay === al[al.length - 1]) || (ax === al[al.length - 1] && ay === 6)) return;
      for (let dy = -2; dy <= 2; dy += 1) for (let dx = -2; dx <= 2; dx += 1) set(ax + dx, ay + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
    }));
    for (let i = 8; i < n - 8; i += 1) { set(i, 6, i % 2 === 0); set(6, i, i % 2 === 0); }
    set(8, n - 8, true);
    // áreas reservadas do formato e da versão
    for (let i = 0; i < 9; i += 1) { if (i !== 6) { set(8, i, false); set(i, 8, false); } }
    for (let i = 0; i < 8; i += 1) { set(n - 1 - i, 8, false); set(8, n - 1 - i, false); }
    set(8, n - 8, true);
    if (v >= 7) for (let i = 0; i < 18; i += 1) { set(Math.floor(i / 3), n - 11 + (i % 3), false); set(n - 11 + (i % 3), Math.floor(i / 3), false); }
    // dados em zigue-zague
    const bits = []; cw.forEach((b) => { for (let i = 7; i >= 0; i -= 1) bits.push((b >> i) & 1); });
    let k = 0, sobe = true;
    for (let x = n - 1; x > 0; x -= 2) {
      if (x === 6) x -= 1;
      for (let i = 0; i < n; i += 1) {
        const y = sobe ? n - 1 - i : i;
        for (let c = 0; c < 2; c += 1) {
          const xx = x - c; if (fixo[y][xx]) continue;
          let bit = k < bits.length ? bits[k] : 0; k += 1;
          const inv = [(xx + y) % 2 === 0, y % 2 === 0, xx % 3 === 0, (xx + y) % 3 === 0, (Math.floor(y / 2) + Math.floor(xx / 3)) % 2 === 0,
            ((xx * y) % 2) + ((xx * y) % 3) === 0, (((xx * y) % 2) + ((xx * y) % 3)) % 2 === 0, (((xx + y) % 2) + ((xx * y) % 3)) % 2 === 0][mask];
          if (inv) bit ^= 1;
          m[y][xx] = bit === 1;
        }
      }
      sobe = !sobe;
    }
    // formato (nível M = 00) e versão
    const f = formato(mask); const bit = (i) => ((f >> i) & 1) === 1;
    for (let i = 0; i <= 5; i += 1) m[i][8] = bit(i);
    m[7][8] = bit(6); m[8][8] = bit(7); m[8][7] = bit(8);
    for (let i = 9; i < 15; i += 1) m[8][14 - i] = bit(i);
    for (let i = 0; i < 8; i += 1) m[8][n - 1 - i] = bit(i);
    for (let i = 8; i < 15; i += 1) m[n - 15 + i][8] = bit(i);
    m[n - 8][8] = true;
    if (v >= 7) { const vi = versaoInfo(v); for (let i = 0; i < 18; i += 1) { const b = ((vi >> i) & 1) === 1; m[n - 11 + (i % 3)][Math.floor(i / 3)] = b; m[Math.floor(i / 3)][n - 11 + (i % 3)] = b; } }
    return m;
  }

  function penalidade(m) {
    const n = m.length; let p = 0;
    for (let t = 0; t < 2; t += 1) for (let a = 0; a < n; a += 1) {
      let run = 1;
      for (let b = 1; b < n; b += 1) {
        const x = t ? m[b][a] : m[a][b], y = t ? m[b - 1][a] : m[a][b - 1];
        if (x === y) { run += 1; if (run === 5) p += 3; else if (run > 5) p += 1; } else run = 1;
      }
    }
    for (let y = 0; y < n - 1; y += 1) for (let x = 0; x < n - 1; x += 1) if (m[y][x] === m[y][x + 1] && m[y][x] === m[y + 1][x] && m[y][x] === m[y + 1][x + 1]) p += 3;
    const pad = [true, false, true, true, true, false, true, false, false, false, false], pad2 = pad.slice().reverse();
    const casa = (arr, ini, ler) => pad.every((v, i) => ler(ini + i) === v) || pad2.every((v, i) => ler(ini + i) === v);
    for (let a = 0; a < n; a += 1) for (let b = 0; b <= n - 11; b += 1) { if (casa(pad, b, (i) => m[a][i])) p += 40; if (casa(pad, b, (i) => m[i][a])) p += 40; }
    const escuros = m.reduce((s, l) => s + l.filter(Boolean).length, 0);
    p += Math.floor(Math.abs((escuros * 100) / (n * n) - 50) / 5) * 10;
    return p;
  }

  function matriz(texto) {
    const bytes = Array.from(new TextEncoder().encode(String(texto)));
    let v = 1;
    while (v <= 10 && bytes.length + (v < 10 ? 2 : 3) > totalDados(v)) v += 1;
    if (v > 10) throw new Error('Texto longo demais para o QR Code.');
    const cw = codewords(bytes, v);
    let melhor = null, pm = Infinity;
    for (let mask = 0; mask < 8; mask += 1) { const m = montar(v, cw, mask); const p = penalidade(m); if (p < pm) { pm = p; melhor = m; } }
    return melhor;
  }

  // SVG apenas com atributos (sem style) e com margem ("quiet zone") de 4 módulos
  function svg(texto, opc = {}) {
    const m = matriz(texto), n = m.length, q = 4, lado = n + q * 2; let d = '';
    m.forEach((l, y) => { let x = 0; while (x < n) { if (l[x]) { let f = x; while (f < n && l[f]) f += 1; d += `M${x + q} ${y + q}h${f - x}v1h-${f - x}z`; x = f; } else x += 1; } });
    const tam = opc.tamanho || 120;
    return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${lado} ${lado}" width="${tam}" height="${tam}" role="img" aria-label="${opc.rotulo || 'QR Code'}" shape-rendering="crispEdges">`
      + `<rect width="${lado}" height="${lado}" fill="#ffffff"/><path d="${d}" fill="#000000"/></svg>`;
  }
  window.QR = Object.freeze({ matriz, svg });
})();
