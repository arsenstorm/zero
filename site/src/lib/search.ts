// The docs' search, shared by the header's pill (Search.astro) and the phone's sheet (SearchSheet.tsx): the index
// (/docs/search.json, built with the site), loaded the first time either is used, and how a query is matched.

export type Section = {
  page: string;
  title: string;
  heading: string;
  href: string;
  text: string;
};

let sections: Section[] | undefined;
export let failed = false;

export async function load() {
  try {
    sections ??= await (await fetch("/docs/search.json")).json();
  } catch {
    failed = true;
  }
}

export const words = (query: string) =>
  query.toLowerCase().split(/\s+/).filter(Boolean);

// Every word has to appear somewhere in the section; a word in its heading or page title counts for more.
export function search(query: string): Section[] {
  const ws = words(query);
  if (!ws.length || !sections) return [];
  return sections
    .map((s) => {
      const head = `${s.title} ${s.heading}`.toLowerCase();
      const body = s.text.toLowerCase();
      if (!ws.every((w) => head.includes(w) || body.includes(w))) return null;
      const phrase = ws.join(" ");
      const exact =
        (head.includes(phrase) ? 4 : 0) + (body.includes(phrase) ? 2 : 0);
      return {
        s,
        score:
          exact +
          ws.reduce(
            (n, w) =>
              n + (head.includes(w) ? 3 : 0) + (body.includes(w) ? 1 : 0),
            0
          ),
      };
    })
    .filter((r) => r !== null)
    .sort((a, b) => b.score - a.score)
    .slice(0, 12)
    .map((r) => r.s);
}

// A line of the section around the first word found, from the start of a word, so you can see why it matched.
export function snippet(text: string, ws: string[]) {
  const at = Math.max(
    0,
    ...ws
      .map((w) => text.toLowerCase().indexOf(w))
      .filter((i) => i >= 0)
      .slice(0, 1)
  );
  const start = at > 40 ? text.lastIndexOf(" ", at - 40) + 1 : 0;
  return (
    (start > 0 ? "…" : "") +
    text.slice(start, start + 140) +
    (start + 140 < text.length ? "…" : "")
  );
}

export const escape = (s: string) =>
  s.replace(
    /[&<>"]/g,
    (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!
  );
export const highlight = (s: string, ws: string[]) =>
  ws.reduce(
    (html, w) =>
      html.replace(
        new RegExp(`(${w.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")})`, "gi"),
        "<mark>$1</mark>"
      ),
    escape(s)
  );

export const emptyText = (query: string) =>
  failed
    ? "Search couldn’t load. Reload the page and try again."
    : words(query).length
      ? "Nothing in the docs matches that."
      : "Type to search every page of the docs.";
