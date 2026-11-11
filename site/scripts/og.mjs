// Renders the share images with headless Chrome from the running dev server: public/og.png from /og, and
// public/og/<page>.png from /og/<page> for each docs page. Run it after changing og.astro, og/[page].astro or a docs
// page's title or description: `bun run og`.
import { execFileSync } from "node:child_process";
import { readdirSync } from "node:fs";

const chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const base = "http://localhost:4321";
const shot = (path, file) =>
  execFileSync(
    chrome,
    [
      "--headless",
      "--hide-scrollbars",
      "--force-device-scale-factor=1",
      "--window-size=1200,630",
      "--virtual-time-budget=3000",
      "--use-angle=swiftshader",
      "--enable-unsafe-swiftshader",
      `--screenshot=${file}`,
      base + path,
    ],
    { stdio: "ignore" }
  );

shot("/og", "public/og.png");
for (const name of readdirSync("../docs/guide").filter((f) =>
  f.endsWith(".md")
)) {
  const page = name.replace(/\.md$/, "");
  shot(`/og/${page}`, `public/og/${page}.png`);
  console.log(page);
}
