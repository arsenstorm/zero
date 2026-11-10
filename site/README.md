# Zero's website

The home page and Zero's docs. Static pages built with [Astro](https://astro.build) and Tailwind v4. There's no server and no database.

## Run it

```sh
cd site
bun install
bun run dev        # http://localhost:4321 (stop it with: bunx astro dev stop)
```

## Build it

```sh
bun run build      # static files in site/dist
bun run preview    # serve dist to check the build
```

Every page builds to a file of its own name (`docs.html`, `docs/settings.html`), so URLs have no trailing slash: `/docs`, `/docs/settings`. The host has to serve `x.html` at `/x`. Most static hosts do this.

## Deploy it

Pushing to `main` with changes in `site/` or `docs/guide/` deploys the site to withzero.dev
(`.github/workflows/deploy-site.yml`). `wrangler.toml` serves `dist/` as Workers static assets; `worker.js` only sends
www.withzero.dev to withzero.dev. By hand: `bun run build && npx wrangler deploy`.

## The name and the address

The product's name and the site's address are in `src/lib/site.ts`: the header, footer, titles, share tags, sitemap and `robots.txt` all read them. The page copy and the docs also say Zero, so a rename means a search through `src/pages` and `../docs/guide` too.

## The share image

`public/og.png` (1200×630) is rendered from `src/pages/og.astro`. After changing that page, render it again with the dev server running:

```sh
bun run og
```

## Where things are

| Path | What |
|---|---|
| `../docs/guide/*.md` | The docs, one page per file. The site reads it from there, and the app can bundle the same files for its help agent. Front matter: `title`, `description`, `order` (the sidebar's order). `index.md` is `/docs`. |
| `src/pages/index.astro` | The home page, with HTML recreations of the app's window, inbox, control bar and iPhone. |
| `src/pages/docs/[...slug].astro` | A docs page: the pages and its headings on either side, both in view as you scroll; copy buttons on code. |
| `src/pages/docs/[slug].md.ts`, `src/pages/docs.md.ts` | Each page as Markdown at `/docs/<page>.md`, and all of them at `/docs.md`, for people to copy and agents to read. |
| `src/pages/docs/search.json.ts`, `src/components/Search.astro` | Search: an index of every section, built with the site, and the dialog that searches it (⌘K, or Search docs in the header). |
| `astro.config.mjs` | Addresses without trailing slashes, plain code blocks, and a Markdown step that puts each table in a box that scrolls sideways on narrow screens. |
| `src/layouts/Base.astro` | The rail, the panel and the footer under it. |
| `src/styles/global.css` | The app's colours from `apps/macos/Sources/ZeroApp/Theme.swift`, for both light and dark. These are the only colours Tailwind offers. |
| `src/components/Icon.astro` | The app's Nucleo icons, read from `apps/macos/Resources/nucleo` at build time. |
| `src/components/Mark.astro` | Zero's mark, from `apps/macos/Resources/logo`. |

## Writing a docs page

- Plain, short sentences. Say where things are: **Settings › Control bar › Placement**.
- Check every claim against the code or the running app.
- Each page stands on its own, because the help agent may read only one.
- Link to other pages as `/docs/<file name without .md>`.
- Quote any front matter value that has a colon in it.
- No parentheses: simplify, or split into two sentences.
- Start instructions with the action or the reader's situation, never "If you …" or "You can …".
- End every sentence and bullet with punctuation. No italics, no horizontal lines, no bold on links.
- Put a full command the reader runs in a code block, not inline; it gets a copy button there.
- Every sentence tells the reader something they need. Cut sentences about the page itself ("This page describes…",
  "This page is a reference"), facts nobody asked for (the app's name on the home screen is Zero), hedges and filler
  ("It's worth noting", "simply", "in order to"). The page's title and first sentence already say what it's about.
- Lead with what the reader can do or must know, not with caveats. "Coming soon" goes once, where it matters, not as a
  page's opening line.
- Describe what a feature does; don't praise it ("powerful", "seamless", "easily").
- One term per thing, the app's own names, used the same way on every page (task, worker, ask, account, workspace,
  project). Define a new term where it first appears, in the same sentence.
- One idea per sentence, under 25 words. Two to four sentences a paragraph. Steps as numbered lists.
- Address the reader as "you", in the active voice: name who does what ("Zero archives done tasks", not "done tasks
  are archived").
- British spelling and contractions, used correctly: "you're" only where "you are" fits ("where you are", never
  "where you're").
- Headings say what the reader gets, in direct voice and sentence case: "Pair your iPhone", not "Pairing".
