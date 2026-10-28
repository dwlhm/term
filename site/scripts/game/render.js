import { DEMO, PHASE } from './config.js';

export function draw(ctx, state, tokens, now = performance.now(), reduced = false) {
  if (!state.cellW || !state.cellH) return;
  const width = state.cols * state.cellW;
  const height = state.rows * state.cellH;
  ctx.clearRect(0, 0, width, height);
  ctx.fillStyle = tokens.surface;
  ctx.fillRect(0, 0, width, height);
  drawGrid(ctx, state, tokens, width, height);
  drawDots(ctx, state, tokens);
  if (state.phase === PHASE.IDLE) {
    drawDemo(ctx, state, tokens);
    return;
  }
  drawFades(ctx, state, tokens, now);
  drawDirty(ctx, state, tokens, now, reduced);
}

export function measureCanvas(ctx, canvas, state, wide) {
  const rect = canvas.getBoundingClientRect();
  if (!rect.width || !rect.height) return false;
  state.cols = wide ? 32 : 16;
  state.rows = wide ? 12 : 10;
  state.cellW = rect.width / state.cols;
  state.cellH = rect.height / state.rows;
  const dpr = window.devicePixelRatio || 1;
  const width = Math.max(1, Math.round(rect.width * dpr));
  const height = Math.max(1, Math.round(rect.height * dpr));
  if (canvas.width !== width) canvas.width = width;
  if (canvas.height !== height) canvas.height = height;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  return true;
}

function drawGrid(ctx, state, tokens, width, height) {
  const { cols, rows, cellW, cellH } = state;
  ctx.strokeStyle = tokens.line;
  ctx.lineWidth = 1;
  ctx.beginPath();
  for (let col = 1; col < cols; col += 1) {
    const x = Math.round(col * cellW) + 0.5;
    ctx.moveTo(x, 0);
    ctx.lineTo(x, height);
  }
  for (let row = 1; row < rows; row += 1) {
    const y = Math.round(row * cellH) + 0.5;
    ctx.moveTo(0, y);
    ctx.lineTo(width, y);
  }
  ctx.stroke();
}

function occupiedCells(state) {
  const taken = new Set();
  const mark = (cell) => taken.add(cell.row * state.cols + cell.col);
  state.dirty.forEach(mark);
  state.fades.forEach(mark);
  if (state.phase === PHASE.IDLE) {
    DEMO.forEach(([x, y]) => {
      mark({ col: Math.floor(x * state.cols), row: Math.floor(y * state.rows) });
    });
  }
  return taken;
}

function drawDots(ctx, state, tokens) {
  const taken = occupiedCells(state);
  const { cols, rows, cellW, cellH } = state;
  const radius = Math.max(0.6, Math.min(cellW, cellH) * 0.035);
  ctx.fillStyle = tokens.text3;
  ctx.globalAlpha = 0.45;
  ctx.beginPath();
  for (let row = 0; row < rows; row += 1) {
    for (let col = 0; col < cols; col += 1) {
      if (taken.has(row * cols + col)) continue;
      const x = col * cellW + cellW / 2;
      const y = row * cellH + cellH / 2;
      ctx.moveTo(x + radius, y);
      ctx.arc(x, y, radius, 0, Math.PI * 2);
    }
  }
  ctx.fill();
  ctx.globalAlpha = 1;
}

function beginText(ctx, state, tokens) {
  const fontSize = Math.max(10, Math.min(state.cellH * 0.56, state.cellW * 1.15));
  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';
  ctx.font = `${tokens.weight} ${fontSize}px ${tokens.mono}`;
}

function paintCell(ctx, state, tokens, col, row, char, alpha, color) {
  const { cellW, cellH } = state;
  if (col < 0 || row < 0 || col >= state.cols || row >= state.rows) return;
  const x = col * cellW;
  const y = row * cellH;
  const inset = Math.max(2, Math.min(cellW, cellH) * 0.08);
  ctx.globalAlpha = alpha;
  ctx.fillStyle = tokens.accentSoft;
  ctx.fillRect(x + inset, y + inset, cellW - inset * 2, cellH - inset * 2);
  ctx.fillStyle = color;
  ctx.fillText(char, x + cellW / 2, y + cellH / 2 + 1);
  ctx.globalAlpha = 1;
}

function drawDemo(ctx, state, tokens) {
  beginText(ctx, state, tokens);
  for (const [x, y, char] of DEMO) {
    const col = Math.floor(x * state.cols);
    const row = Math.floor(y * state.rows);
    paintCell(ctx, state, tokens, col, row, char, 1, tokens.accent);
  }
}

function drawFades(ctx, state, tokens, now) {
  if (!state.fades.length) return;
  beginText(ctx, state, tokens);
  const duration = Math.max(1, tokens.fade);
  for (const fade of state.fades) {
    const progress = Math.min(1, (now - fade.start) / duration);
    paintCell(ctx, state, tokens, fade.col, fade.row, fade.char, 1 - progress, tokens.accent);
  }
}

function drawDirty(ctx, state, tokens, now, reduced) {
  if (!state.dirty.length) return;
  beginText(ctx, state, tokens);
  for (const cell of state.dirty) {
    const remaining = (cell.deadline - now) / cell.life;
    const urgent = remaining < 0.3;
    let alpha = 1;
    if (urgent && !reduced) {
      alpha = 0.55 + 0.45 * (0.5 + 0.5 * Math.sin(now / 90));
    }
    const color = urgent ? tokens.accentStrong : tokens.accent;
    paintCell(ctx, state, tokens, cell.col, cell.row, cell.char, alpha, color);
  }
}
