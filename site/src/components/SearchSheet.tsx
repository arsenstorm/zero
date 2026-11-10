// Search on phones: a Search button in the header that opens a sheet from the foot of the screen, on Vaul, so it drags
// down to close and follows the finger, as iOS sheets do. Loaded only on phone-sized screens (Base.astro's
// client:media), so wider screens, which have the header's pill instead, load none of it. The search itself is the
// pill's (src/lib/search.ts). Anywhere on the page can open it with the "zero:search-sheet" event (⌘K, the 404).
import { useEffect, useRef, useState } from "react";
import { Drawer } from "vaul";
import magnifier from "../../../apps/macos/Resources/nucleo/magnifier-outline.svg?raw";
import { emptyText, highlight, load, search, snippet, words, type Section } from "../lib/search";

const icon = (size: number) => magnifier.replace('width="18" height="18"', `width="${size}" height="${size}"`).replace("<svg ", '<svg aria-hidden="true" ');

export default function SearchSheet() {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<Section[]>([]);
  const [active, setActive] = useState(0);
  const list = useRef<HTMLUListElement>(null);
  const field = useRef<HTMLInputElement>(null);

  useEffect(() => {
    const show = () => setOpen(true);
    document.addEventListener("zero:search-sheet", show);
    return () => document.removeEventListener("zero:search-sheet", show);
  }, []);

  async function change(value: string) {
    setQuery(value);
    await load();
    setResults(search(value));
    setActive(0);
  }

  // Open: the cursor goes in the box, so you type straight away (left on the button, a space pressed it again).
  useEffect(() => {
    if (!open) return;
    load().then(() => setResults(search(query)));
    requestAnimationFrame(() => field.current?.focus());
  }, [open]);

  useEffect(() => {
    list.current?.children[active]?.scrollIntoView({ block: "nearest" });
  }, [active]);

  function key(event: React.KeyboardEvent) {
    if (!results.length) return;
    if (event.key === "ArrowDown") { event.preventDefault(); setActive((active + 1) % results.length); }
    if (event.key === "ArrowUp") { event.preventDefault(); setActive((active - 1 + results.length) % results.length); }
    if (event.key === "Enter") { event.preventDefault(); location.href = results[active].href; setOpen(false); }
  }

  const ws = words(query);
  return (
    <Drawer.Root open={open} onOpenChange={setOpen} autoFocus>
      <Drawer.Trigger className="sm:hidden h-9 px-3 flex items-center gap-1.5 rounded-[8px] font-medium text-muted hover:bg-hover hover:text-ink transition-colors duration-150">
        <span className="grid" dangerouslySetInnerHTML={{ __html: icon(14) }} />
        Search
      </Drawer.Trigger>
      <Drawer.Portal>
        <Drawer.Overlay className="search-sheet-overlay fixed inset-0 z-40 bg-black/25" />
        {/* 18 px top corners; most of the screen tall, its box at the top where the keyboard leaves it in view. */}
        <Drawer.Content aria-describedby={undefined} className="search-sheet fixed inset-x-0 bottom-0 z-50 h-[85dvh] flex flex-col rounded-t-[18px] border border-b-0 border-stroke bg-card text-ink outline-none">
          <div aria-hidden="true" className="mx-auto mt-2 h-1 w-9 shrink-0 rounded-full bg-hairline" />
          <Drawer.Title className="sr-only">Search the docs</Drawer.Title>
          <div className="flex items-center gap-2 px-3 pt-2 pb-2">
            <label className="flex-1 h-10 pl-3 pr-3 flex items-center gap-2 rounded-full border border-stroke bg-card text-muted focus-within:border-hairline">
              <span className="grid" dangerouslySetInnerHTML={{ __html: icon(15) }} />
              <input
                ref={field}
                type="text"
                role="combobox"
                aria-label="Search the docs"
                aria-autocomplete="list"
                aria-expanded={results.length > 0}
                aria-controls="search-results-sheet"
                aria-activedescendant={results.length ? `search-results-sheet-${active}` : undefined}
                enterKeyHint="search"
                placeholder="Search docs"
                autoComplete="off"
                spellCheck={false}
                value={query}
                onChange={(e) => change(e.target.value)}
                onKeyDown={key}
                className="flex-1 min-w-0 h-full bg-transparent text-[16px] text-ink outline-none placeholder:text-muted"
              />
            </label>
            <Drawer.Close className="h-10 px-2 text-[15px] font-medium">Cancel</Drawer.Close>
          </div>
          <div className="flex-1 min-h-0 flex flex-col border-t border-stroke" data-search-surface-root>
            {results.length > 0 ? (
              <ul ref={list} id="search-results-sheet" role="listbox" aria-label="Results" className="flex-1 min-h-0 overflow-y-auto p-1.5">
                {results.map((r, i) => (
                  <li key={r.href} role="option" id={`search-results-sheet-${i}`} aria-selected={i === active}>
                    <a href={r.href} tabIndex={-1} onClick={() => setOpen(false)} className={`block rounded-[10px] px-3 py-2 ${i === active ? "bg-hover" : ""}`}>
                      <span className="block text-[13px] text-muted">
                        {r.page}
                        {r.heading ? " › " : ""}
                        <span className="text-ink font-medium" dangerouslySetInnerHTML={{ __html: highlight(r.heading, ws) }} />
                      </span>
                      <span className="mt-0.5 text-[13px] leading-[1.45] text-muted line-clamp-2" dangerouslySetInnerHTML={{ __html: highlight(snippet(r.text, ws), ws) }} />
                    </a>
                  </li>
                ))}
              </ul>
            ) : (
              <p className="h-[72px] grid place-items-center px-4 text-center text-[14px] text-muted">{emptyText(query)}</p>
            )}
            <p className="sr-only" aria-live="polite">{ws.length ? `${results.length} ${results.length === 1 ? "result" : "results"}` : ""}</p>
          </div>
        </Drawer.Content>
      </Drawer.Portal>
    </Drawer.Root>
  );
}
