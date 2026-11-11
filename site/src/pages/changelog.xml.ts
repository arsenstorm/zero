import { releases } from "../lib/releases";
import { site } from "../lib/site";

const escape = (text: string) =>
  text
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");

// The changelog as RSS 2.0: a release an item, its changes as a list.
export async function GET() {
  const items = (await releases())
    .map((release) => {
      const link = new URL(`/changelog#${release.tag}`, site.url).href;
      const list = release.changes
        .map(
          (c) =>
            `<li>${c.kind === "feat" ? "New" : "Fixed"}: ${escape(c.text)}.</li>`
        )
        .join("");
      const description = release.first
        ? `<p>The first release of ${site.name}.</p>`
        : `<ul>${list}</ul>`;
      return `    <item>
      <title>${escape(`${site.name} ${release.version}`)}</title>
      <link>${link}</link>
      <guid isPermaLink="false">${escape(release.tag)}</guid>
      <pubDate>${release.date.toUTCString()}</pubDate>
      <description>${escape(description)}</description>
    </item>`;
    })
    .join("\n");
  return new Response(
    `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>${escape(site.name)} changelog</title>
    <link>${new URL("/changelog", site.url).href}</link>
    <description>What changed in each release of ${escape(site.name)}.</description>
${items}
  </channel>
</rss>
`,
    { headers: { "Content-Type": "application/rss+xml; charset=utf-8" } }
  );
}
