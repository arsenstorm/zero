import { render } from "astro:content";
import { docPages, docHref } from "../../lib/docs";

// Tags taken out until none is left: one pass over "<<b>script>" leaves "<script>".
const untagged = (text: string) => {
  let out = text;
  let before: string;
  do {
    before = out;
    out = out.replace(/<[^>]*>/g, "");
  } while (out !== before);
  return out;
};

// The search index: one entry per section (a page's opening, then each ## heading), as plain text.
const plain = (md: string) =>
  untagged(md.replace(/```[\s\S]*?```/g, " "))
    // Any angle bracket left (a "<" with no ">"), so none survives into the index.
    .replace(/[<>]/g, " ")
    .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
    .replace(/^[\s|:-]+$/gm, " ")
    .replace(/[*_`#>|]/g, " ")
    .replace(/^-{3,}$/gm, " ")
    // A list's markers ("- ", "1. ") at a line's start are Markdown, not words.
    .replace(/^\s*(?:[-+*]|\d+\.)\s+/gm, "")
    .replace(/\s+/g, " ")
    // A colon or comma left after a removed mark joins its word again ("Account : a sign-in").
    .replace(/\s+([:;,.])/g, "$1")
    .trim();

export async function GET() {
  const sections = [];
  for (const page of await docPages()) {
    const { headings } = await render(page);
    const slugs = headings.filter((h) => h.depth === 2);
    const parts = (page.body ?? "").split(/^## +/m);
    const href = docHref(page.id);
    sections.push({
      page: page.data.title,
      title: page.data.title,
      heading: "",
      href,
      text: plain(`${page.data.description} ${parts[0]}`),
    });
    parts.slice(1).forEach((part, i) => {
      const [line, ...rest] = part.split("\n");
      sections.push({
        page: page.data.title,
        title: page.data.title,
        heading: line.trim(),
        href: `${href}#${slugs[i]?.slug ?? ""}`,
        text: plain(rest.join("\n")),
      });
    });
  }
  return new Response(JSON.stringify(sections), {
    headers: { "Content-Type": "application/json" },
  });
}
