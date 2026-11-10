import mark from "../../../apps/macos/Resources/logo/mark-small.svg?raw";

// The favicon: Zero's mark, black on light tabs and white on dark ones.
export function GET() {
  const svg = mark
    .replace(
      /<title>.*?<\/title>/,
      "<style>path{fill:#000}@media (prefers-color-scheme:dark){path{fill:#fff}}</style>"
    )
    .replace(/ fill="#000000"/g, "");
  return new Response(svg, { headers: { "Content-Type": "image/svg+xml" } });
}
