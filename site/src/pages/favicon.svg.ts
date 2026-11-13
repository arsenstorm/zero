import mark from "../../../apps/macos/Resources/logo/mark-small.svg?raw";

// The favicon: Zero's mark as Chrome's extension draws it, black with a white outline, so one icon reads on light tabs
// and dark ones alike. The outline is the path's own stroke, painted under its fill (paint-order), the view widened by
// the stroke's half so it isn't cut.
export function GET() {
  const svg = mark
    .replace(/<title>.*?<\/title>/, "")
    .replace('viewBox="173 41 997 1094"', 'viewBox="133 1 1077 1174"')
    .replace(
      / fill="#000000"/g,
      ' fill="#000" stroke="#fff" stroke-width="72" stroke-linejoin="round" paint-order="stroke"'
    );
  return new Response(svg, { headers: { "Content-Type": "image/svg+xml" } });
}
