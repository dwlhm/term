import {
  ALLOWED, BEST_KEY, CHARS, DEFAULT_FADE_MS, MAX_FRAME_MS, MAX_LIVES, PHASE, levelConfig,
} from './config.js';
import { clean, cleanChar, createState, expire, fitDirty, spawn, step } from './model.js';
import { draw, measureCanvas } from './render.js';

const root = document.getElementById('play');
const el = (id) => root?.querySelector(id);
const [canvas, board, overlay, overlayText, button, live] = [
  '#game-canvas', '#game-board', '#game-overlay', '#game-overlay-text', '#game-play', '#game-live',
].map(el);
const hud = {
  score: el('#game-score'), streak: el('#game-streak'), level: el('#game-level'),
  best: el('#game-best'), livesText: el('#game-lives-text'),
  lives: root?.querySelectorAll('.game-life') ?? null,
};
const nodes = [canvas, board, overlay, overlayText, button, live, ...Object.values(hud)];
const ctx = nodes.every(Boolean) ? canvas.getContext('2d') : null;
const wideQuery = window.matchMedia('(min-width: 48rem)');
const motionQuery = window.matchMedia('(prefers-reduced-motion: reduce)');
const schemeQueries = ['(prefers-color-scheme: dark)', '(prefers-color-scheme: light)']
  .map((query) => window.matchMedia(query));
const state = createState(readBest());
let tokens = {};
let reduced = motionQuery.matches;
let boardRatio = 1;

function readBest() {
  try {
    const value = Number.parseInt(window.localStorage.getItem(BEST_KEY) || '', 10);
    return Number.isFinite(value) && value > 0 ? value : 0;
  } catch { return 0; }
}
function saveBest(value) {
  try {
    window.localStorage.setItem(BEST_KEY, String(value));
  } catch { /* storage unavailable: best score stays in memory */ }
}
function parseMs(value) {
  const text = String(value).trim();
  const number = Number.parseFloat(text);
  return Number.isFinite(number) ? (text.includes('ms') ? number : number * 1000) : DEFAULT_FADE_MS;
}
function readTokens() {
  const style = getComputedStyle(document.documentElement);
  const get = (name) => style.getPropertyValue(name).trim();
  tokens = {
    surface: get('--surface-1'), line: get('--line'), text3: get('--text-3'),
    accent: get('--accent'), accentStrong: get('--accent-strong'),
    accentSoft: get('--accent-soft'), mono: get('--font-mono') || 'monospace',
    weight: get('--weight-strong') || '650', fade: parseMs(get('--dur-fast')),
  };
  redraw();
}
function redraw(now = performance.now()) {
  draw(ctx, state, tokens, now, reduced);
}
function setPhase(next) {
  if (!ALLOWED[state.phase].includes(next)) return false;
  state.phase = next;
  return true;
}
function cancelRaf() {
  if (state.rafId) cancelAnimationFrame(state.rafId);
  state.rafId = 0;
}
function measure() {
  if (!measureCanvas(ctx, canvas, state, wideQuery.matches)) return;
  fitDirty(state);
  redraw();
}

function startGame() {
  if (state.phase === PHASE.PLAYING) return;
  if (state.phase === PHASE.PAUSED) { resume(); return; }
  if (state.phase === PHASE.OVER) setPhase(PHASE.IDLE);
  if (!setPhase(PHASE.PLAYING)) return;
  Object.assign(state, { score: 0, streak: 0, lives: MAX_LIVES, cleans: 0, level: 1,
    dirty: [], fades: [], spawnAcc: 0 });
  overlay.hidden = true;
  button.textContent = 'Play';
  board.classList.remove('game-shake');
  bindKeys(onPlayingKey);
  state.lastNow = performance.now();
  spawn(state, state.lastNow, levelConfig(1).spawn);
  cancelRaf();
  state.rafId = requestAnimationFrame(loop);
  updateHud();
  updateLabel();
  redraw(state.lastNow);
  if (boardRatio < 0.25) pause();
}
function pause() {
  if (state.phase !== PHASE.PLAYING) return;
  setPhase(PHASE.PAUSED);
  state.pausedAt = performance.now();
  cancelRaf();
  bindKeys(onPausedKey);
  board.classList.remove('game-shake');
  overlayText.textContent = 'Paused — press Space or tap to resume';
  overlay.hidden = false;
  updateLabel();
  redraw(state.pausedAt);
}
function resume() {
  if (state.phase !== PHASE.PAUSED) return;
  const now = performance.now();
  for (const cell of state.dirty) cell.deadline += Math.max(0, now - state.pausedAt);
  state.fades = [];
  setPhase(PHASE.PLAYING);
  state.lastNow = now;
  overlay.hidden = true;
  bindKeys(onPlayingKey);
  cancelRaf();
  state.rafId = requestAnimationFrame(loop);
  updateLabel();
  redraw(now);
  if (boardRatio < 0.25) pause();
}
function gameOver() {
  setPhase(PHASE.OVER);
  cancelRaf();
  bindKeys(null);
  state.fades = [];
  if (state.score > state.best) { state.best = state.score; saveBest(state.best); }
  button.textContent = 'Play again';
  overlayText.textContent = `Frame dropped. Score ${state.score}`;
  overlay.hidden = false;
  updateHud();
  updateLabel();
  announce(overlayText.textContent);
  redraw();
}
function update(now, dt) {
  if (expire(state, now)) {
    updateHud();
    updateLabel();
    if (state.lives === 0) { gameOver(); return; }
  }
  if (state.phase !== PHASE.PLAYING) return;
  step(state, now, dt, reduced, tokens.fade);
}
function loop(now) {
  if (state.phase !== PHASE.PLAYING) return;
  const dt = Math.max(0, Math.min(now - state.lastNow, MAX_FRAME_MS));
  state.lastNow = now;
  state.rafId = requestAnimationFrame(loop);
  update(now, dt);
  if (state.phase === PHASE.PLAYING) redraw(now);
}
function doClean(cell) {
  const result = clean(state, cell, performance.now(), reduced);
  if (!result.cleaned) return;
  if (result.leveled) announce(`Level up. ${levelConfig(state.level).name}.`);
  updateHud();
  updateLabel();
  redraw();
}
function onChar(char) {
  const result = cleanChar(state, char, performance.now(), reduced);
  if (!result.target) { updateHud(); updateLabel(); shake(); return; }
  if (result.leveled) announce(`Level up. ${levelConfig(state.level).name}.`);
  updateHud();
  updateLabel();
  redraw();
}
function shake() {
  if (reduced) return;
  board.classList.remove('game-shake');
  void board.offsetWidth;
  board.classList.add('game-shake');
}

function onPlayingKey(event) {
  if (event.metaKey || event.ctrlKey || event.altKey) return;
  if (event.key === 'Escape') { pause(); return; }
  if (event.code === 'Space') { event.preventDefault(); if (!event.repeat) pause(); return; }
  if (event.key.length !== 1) return;
  const char = event.key.toLowerCase();
  if (!CHARS.includes(char)) return;
  event.preventDefault();
  if (!event.repeat) onChar(char);
}
function onPausedKey(event) {
  if (event.metaKey || event.ctrlKey || event.altKey) return;
  if (event.code !== 'Space' || boardRatio < 0.25) return;
  event.preventDefault();
  if (!event.repeat) resume();
}
function bindKeys(handler) {
  document.removeEventListener('keydown', onPlayingKey);
  document.removeEventListener('keydown', onPausedKey);
  if (handler) document.addEventListener('keydown', handler);
}
function onPointerDown(event) {
  if (state.phase === PHASE.PAUSED) { resume(); return; }
  if (state.phase !== PHASE.PLAYING) return;
  const rect = canvas.getBoundingClientRect();
  if (!rect.width || !rect.height) return;
  const col = Math.floor(((event.clientX - rect.left) / rect.width) * state.cols);
  const row = Math.floor(((event.clientY - rect.top) / rect.height) * state.rows);
  if (col < 0 || row < 0 || col >= state.cols || row >= state.rows) return;
  const cell = state.dirty.find((item) => item.col === col && item.row === row);
  if (cell) doClean(cell);
}
function updateHud() {
  hud.score.textContent = String(state.score);
  hud.streak.textContent = String(state.streak);
  hud.level.textContent = levelConfig(state.level).name;
  hud.best.textContent = String(state.best);
  hud.livesText.textContent = `${state.lives} of ${MAX_LIVES} lives`;
  hud.lives.forEach((node, index) => node.classList.toggle('game-life-lost', index >= state.lives));
}
function updateLabel() {
  let label = `Dirty Cells board. Score ${state.score}, streak ${state.streak}, ` +
    `${state.lives} of ${MAX_LIVES} lives.`;
  if (state.phase === PHASE.IDLE) label = 'Dirty Cells board. Press Play to start.';
  else if (state.phase === PHASE.PAUSED) label += ' Paused.';
  else if (state.phase === PHASE.OVER) label += ' Game over.';
  canvas.setAttribute('aria-label', label);
}
function announce(message) {
  live.textContent = message;
}

function init() {
  readTokens(); updateHud(); updateLabel(); measure();
  button.addEventListener('click', () => {
    if (state.phase === PHASE.PAUSED) resume();
    else startGame();
  });
  canvas.addEventListener('pointerdown', onPointerDown);
  document.addEventListener('visibilitychange', () => { if (document.hidden) pause(); });
  board.addEventListener('animationend', () => board.classList.remove('game-shake'));
  new ResizeObserver(measure).observe(canvas);
  new IntersectionObserver((entries) => {
    boardRatio = entries[entries.length - 1].intersectionRatio;
    if (boardRatio < 0.25) pause();
  }, { threshold: [0, 0.25, 1] }).observe(board);
  wideQuery.addEventListener('change', measure);
  schemeQueries.forEach((query) => query.addEventListener('change', readTokens));
  motionQuery.addEventListener('change', (event) => {
    reduced = event.matches;
    if (reduced) board.classList.remove('game-shake');
    redraw();
  });
}

if (ctx) init();
