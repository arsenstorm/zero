// A control bar button's outline at a progress from in (0, a thin arc facing the bar) to out (1, the whole disc), as
// the app's BarSeed draws it (BarKnob.swift): the arc's ends close the ring by 0.6 while its stroke thickens inward
// from 0.1 on, its outer edge fixed at the button's radius. Drawn as a dashed circle so the same shape serves every
// progress, a full ring included.

export const KNOB = 32;

export function knob(open: number, top: boolean) {
  const clamp = (v: number) => Math.min(1, Math.max(0, v));
  const sweep = clamp(open / 0.6);
  const fill = clamp((open - 0.1) / 0.9);
  const radius = KNOB / 2;
  const width = 3 + (radius - 3) * fill;
  const half = 50 + 130 * sweep;
  const r = radius - width / 2;
  const length = 2 * Math.PI * r;
  return {
    r,
    width,
    dash: `${(length * half) / 180} ${length}`,
    rotate: (top ? 45 : -45) - half,
  };
}

/** The icon carried by the same progress: fades in over the first half, grows from 0.8, and drifts 5 pt in from the
 * arc's side to the middle. */
export function carried(open: number, top: boolean) {
  const drift = (5 / Math.SQRT2) * (1 - open);
  return {
    opacity: Math.min(1, open / 0.5),
    transform: `translate(${drift}px, ${top ? drift : -drift}px) scale(${0.8 + 0.2 * open})`,
  };
}
