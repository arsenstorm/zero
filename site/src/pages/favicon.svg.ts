import mark from "../../../apps/macos/Resources/logo/mark-small.svg?raw";

// The favicon: Zero's mark in black on a white sticker of its own shape, so one icon reads on light tabs and dark ones
// alike. An outline alone fills the mark's narrow gaps with white and smudges at 16 px; the sticker is the mark's outer
// contour (its path's first subpath) filled and stroked white, the view widened by the stroke's half so it isn't cut.
const d = mark.match(/ d="([^"]+)"/)?.[1] ?? "";
const outer = d.slice(0, d.indexOf("M", 1));

export function GET() {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="118 -14 1107 1204"><path fill="#fff" stroke="#fff" stroke-width="90" stroke-linejoin="round" d="${outer}"/><path fill-rule="evenodd" d="${d}"/></svg>`;
  return new Response(svg, { headers: { "Content-Type": "image/svg+xml" } });
}
