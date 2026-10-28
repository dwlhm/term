export const PHASE = Object.freeze({
  IDLE: 'idle',
  PLAYING: 'playing',
  PAUSED: 'paused',
  OVER: 'over',
});

export const ALLOWED = Object.freeze({
  [PHASE.IDLE]: Object.freeze([PHASE.PLAYING]),
  [PHASE.PLAYING]: Object.freeze([PHASE.PAUSED, PHASE.OVER]),
  [PHASE.PAUSED]: Object.freeze([PHASE.PLAYING]),
  [PHASE.OVER]: Object.freeze([PHASE.IDLE, PHASE.PLAYING]),
});

export const CHARS = 'abcdefghijklmnopqrstuvwxyz0123456789;:/-_[]{}';
export const BEST_KEY = 'term.dirtycells.best';
export const MAX_LIVES = 3;
export const CLEANS_PER_LEVEL = 15;
export const MIN_DEADLINE = 900;
export const DEADLINE_STEP = 150;
export const SPAWN_BASE = 900;
export const SPAWN_MIN = 500;
export const SPAWN_STEP = 50;
export const MAX_FRAME_MS = 250;
export const DEFAULT_FADE_MS = 150;

export const LEVELS = Object.freeze([
  Object.freeze({ name: 'sparse', spawn: 1, deadline: 3000 }),
  Object.freeze({ name: 'dense', spawn: 2, deadline: 2400 }),
  Object.freeze({ name: 'fullscreen', spawn: 3, deadline: 1800 }),
]);

export const DEMO = Object.freeze([
  Object.freeze([0.10, 0.18, 't']),
  Object.freeze([0.32, 0.55, 'e']),
  Object.freeze([0.55, 0.14, 'r']),
  Object.freeze([0.78, 0.62, 'm']),
  Object.freeze([0.44, 0.80, '7']),
  Object.freeze([0.90, 0.28, ';']),
  Object.freeze([0.20, 0.70, '/']),
  Object.freeze([0.66, 0.36, '_']),
  Object.freeze([0.04, 0.48, '{']),
  Object.freeze([0.58, 0.86, '9']),
]);

export function levelConfig(level) {
  if (level <= LEVELS.length) return LEVELS[level - 1];
  const base = LEVELS[LEVELS.length - 1];
  return Object.freeze({
    name: `fullscreen +${level - LEVELS.length}`,
    spawn: base.spawn,
    deadline: Math.max(MIN_DEADLINE, base.deadline - DEADLINE_STEP * (level - LEVELS.length)),
  });
}
