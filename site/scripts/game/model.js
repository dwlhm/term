import {
  CHARS, CLEANS_PER_LEVEL, MAX_LIVES, PHASE,
  SPAWN_BASE, SPAWN_MIN, SPAWN_STEP, levelConfig,
} from './config.js';

export function createState(best) {
  return {
    phase: PHASE.IDLE,
    cols: 16,
    rows: 10,
    cellW: 0,
    cellH: 0,
    score: 0,
    streak: 0,
    best,
    lives: MAX_LIVES,
    cleans: 0,
    level: 1,
    dirty: [],
    fades: [],
    rafId: 0,
    lastNow: 0,
    spawnAcc: 0,
    pausedAt: 0,
  };
}

export function freeCells(state) {
  const { cols, rows } = state;
  const taken = new Uint8Array(cols * rows);
  const mark = (cell) => {
    if (cell.col >= 0 && cell.col < cols && cell.row >= 0 && cell.row < rows) {
      taken[cell.row * cols + cell.col] = 1;
    }
  };
  state.dirty.forEach(mark);
  state.fades.forEach(mark);
  const free = [];
  for (let row = 0; row < rows; row += 1) {
    for (let col = 0; col < cols; col += 1) {
      if (!taken[row * cols + col]) free.push({ col, row });
    }
  }
  return free;
}

export function fitDirty(state) {
  const moved = [];
  state.dirty = state.dirty.filter((cell) => {
    if (cell.col < state.cols && cell.row < state.rows) return true;
    moved.push(cell);
    return false;
  });
  for (const cell of moved) {
    const free = freeCells(state);
    if (!free.length) break;
    const spot = free[Math.floor(Math.random() * free.length)];
    cell.col = spot.col;
    cell.row = spot.row;
    state.dirty.push(cell);
  }
  state.fades.length = 0;
}

export function spawn(state, now, count) {
  const config = levelConfig(state.level);
  const free = freeCells(state);
  for (let index = 0; index < count && free.length > 0; index += 1) {
    const spot = free.splice(Math.floor(Math.random() * free.length), 1)[0];
    state.dirty.push({
      col: spot.col,
      row: spot.row,
      char: CHARS[Math.floor(Math.random() * CHARS.length)],
      birth: now,
      deadline: now + config.deadline,
      life: config.deadline,
    });
  }
}

export function expire(state, now) {
  if (!state.dirty.length) return 0;
  let dropped = 0;
  state.dirty = state.dirty.filter((cell) => {
    if (cell.deadline > now) return true;
    dropped += 1;
    return false;
  });
  if (dropped) state.lives = Math.max(0, state.lives - dropped);
  return dropped;
}

export function clean(state, cell, now, reduced) {
  const index = state.dirty.indexOf(cell);
  if (index === -1) return { cleaned: false, leveled: false };
  state.dirty.splice(index, 1);
  state.score += 10 * state.level;
  state.streak += 1;
  state.cleans += 1;
  if (!reduced) {
    state.fades.push({ col: cell.col, row: cell.row, char: cell.char, start: now });
  }
  const nextLevel = Math.floor(state.cleans / CLEANS_PER_LEVEL) + 1;
  const leveled = nextLevel > state.level;
  if (leveled) state.level = nextLevel;
  return { cleaned: true, leveled };
}

export function cleanChar(state, char, now, reduced) {
  let target = null;
  for (const cell of state.dirty) {
    if (cell.char !== char) continue;
    if (!target || cell.birth < target.birth) target = cell;
  }
  if (!target) {
    state.streak = 0;
    return { target: null, cleaned: false, leveled: false };
  }
  return { target, ...clean(state, target, now, reduced) };
}

export function step(state, now, dt, reduced, fade) {
  const interval = Math.max(SPAWN_MIN, SPAWN_BASE - (state.level - 1) * SPAWN_STEP);
  state.spawnAcc += dt;
  while (state.spawnAcc >= interval) {
    state.spawnAcc -= interval;
    spawn(state, now, levelConfig(state.level).spawn);
  }
  if (reduced) state.fades.length = 0;
  else state.fades = state.fades.filter((cell) => now - cell.start < fade);
}
