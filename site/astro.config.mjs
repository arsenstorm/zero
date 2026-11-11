import { defineConfig } from "astro/config";
import tailwindcss from "@tailwindcss/vite";
import { satteri } from "@astrojs/markdown-satteri";
import react from "@astrojs/react";

import { site } from "./src/lib/site";

// Each Markdown table in <div class="table-scroll">, which scrolls sideways when the table is wider than the column.
// (Not "table": that's a Tailwind utility, display: table, and a table box doesn't scroll.)
const wrapTables = {
  name: "wrap-tables",
  element: {
    filter: ["table"],
    visit: (node, ctx) =>
      ctx.wrapNode(node, {
        type: "element",
        tagName: "div",
        // Focusable and named, so a keyboard can scroll a wide table sideways on a phone.
        properties: {
          className: ["table-scroll"],
          tabIndex: 0,
          role: "region",
          ariaLabel: "Table",
        },
        children: [],
      }),
  },
};

// A code block can be wider than a phone: focusable and named, so a keyboard can scroll it sideways.
const scrollableCode = {
  name: "scrollable-code",
  element: {
    filter: ["pre"],
    visit: (node, ctx) =>
      ctx.setField(node, "properties", {
        ...node.properties,
        tabIndex: 0,
        role: "region",
        ariaLabel: "Code",
      }),
  },
};

// Each word of inline code in its own <span class="word">, which doesn't break: --permissions stays whole, never
// - / -permissions. Lines break between words. Words over 24 characters (a long path) are left free to break.
const keepWords = {
  name: "keep-words",
  element: {
    filter: ["code"],
    visit: (node, ctx) => {
      const parts = ctx.textContent(node).split(/(\s+)/).filter(Boolean);
      const word = (text) => ({
        type: "element",
        tagName: "span",
        properties: { className: ["word"] },
        children: [{ type: "text", value: text }],
      });
      ctx.setField(
        node,
        "children",
        parts.map((text) =>
          /\s/.test(text) || text.length > 24
            ? { type: "text", value: text }
            : word(text)
        )
      );
    },
  },
};

export default defineConfig({
  site: site.url,
  // /docs, never /docs/: every page builds to a file of its own name (docs.html, docs/settings.html).
  trailingSlash: "never",
  build: { format: "file" },
  // React only for the phone's search sheet (Vaul), loaded only on phone-sized screens.
  integrations: [react()],
  vite: { plugins: [tailwindcss()] },
  devToolbar: { enabled: false },
  // Plain code blocks on the app's own surface: a syntax theme sets its own background in one appearance only.
  markdown: {
    syntaxHighlight: false,
    processor: satteri({
      hastPlugins: [wrapTables, scrollableCode, keepWords],
    }),
  },
});
