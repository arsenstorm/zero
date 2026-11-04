// In every page, in the extension's own world: the page as a tree of elements with refs (ref_12), and what the tools
// do with a ref. A ref stays the same element for as long as the page has it, however often the page is read.

(() => {
  if (globalThis.__zero) return;
  const elements = new Map(); // ref → WeakRef(element)
  const refs = new WeakMap(); // element → ref
  let counter = 0;

  const TAG_ROLES = {
    a: (e) => (e.hasAttribute("href") ? "link" : null), button: () => "button", select: (e) => (e.multiple ? "listbox" : "combobox"), textarea: () => "textbox",
    img: () => "img", nav: () => "navigation", main: () => "main", header: () => "banner", footer: () => "contentinfo", aside: () => "complementary",
    form: () => "form", ul: () => "list", ol: () => "list", li: () => "listitem", table: () => "table", tr: () => "row", td: () => "cell", th: () => "columnheader",
    dialog: () => "dialog", h1: () => "heading", h2: () => "heading", h3: () => "heading", h4: () => "heading", h5: () => "heading", h6: () => "heading",
    option: () => "option", summary: () => "button", details: () => "group", label: () => "label", p: () => "paragraph", iframe: () => "iframe", video: () => "video",
    section: (e) => (e.hasAttribute("aria-label") || e.hasAttribute("aria-labelledby") ? "region" : null), article: () => "article", fieldset: () => "group",
    input: (e) => ({ checkbox: "checkbox", radio: "radio", range: "slider", button: "button", submit: "button", reset: "button", image: "button",
                     search: "searchbox", file: "button", hidden: null }[(e.type || "text").toLowerCase()] ?? "textbox"),
  };
  const INTERACTIVE = new Set(["link", "button", "textbox", "searchbox", "checkbox", "radio", "combobox", "listbox", "slider", "switch", "tab", "menuitem",
    "menuitemcheckbox", "menuitemradio", "option", "spinbutton", "treeitem"]);

  function role(e) {
    const explicit = e.getAttribute("role");
    if (explicit) return explicit.split(" ")[0];
    const implied = TAG_ROLES[e.tagName.toLowerCase()];
    if (implied) return implied(e);
    if (e.isContentEditable && e.getAttribute("contenteditable") !== "false") return "textbox";
    if (e.hasAttribute("onclick") || (e.tabIndex >= 0 && e.hasAttribute("tabindex"))) return "generic-clickable";
    return null;
  }

  function hidden(e) {
    if (e.hidden || e.getAttribute("aria-hidden") === "true") return true;
    const style = getComputedStyle(e);
    if (style.display === "none" || style.visibility === "hidden" || style.visibility === "collapse") return true;
    const box = e.getBoundingClientRect();
    return box.width === 0 && box.height === 0 && style.overflow !== "visible";
  }

  function secret(e) {
    const type = (e.type || "").toLowerCase();
    const complete = (e.getAttribute("autocomplete") || "").toLowerCase();
    return type === "password" || type === "hidden" || /cc-|one-time-code|current-password|new-password/.test(complete);
  }

  const squash = (s, n = 80) => { const t = String(s || "").replace(/\s+/g, " ").trim(); return t.length > n ? t.slice(0, n - 1) + "…" : t };

  function name(e) {
    const labelled = e.getAttribute("aria-labelledby");
    if (labelled) {
      const words = labelled.split(" ").map((id) => document.getElementById(id)?.innerText || "").join(" ");
      if (words.trim()) return squash(words);
    }
    for (const attribute of ["aria-label", "alt", "title", "placeholder"]) if (e.getAttribute(attribute)) return squash(e.getAttribute(attribute));
    if (e.id) { const label = document.querySelector(`label[for="${CSS.escape(e.id)}"]`); if (label?.innerText) return squash(label.innerText) }
    const wrapping = e.closest("label");
    if (wrapping && wrapping !== e && wrapping.innerText) return squash(wrapping.innerText);
    if (["INPUT", "SELECT", "TEXTAREA"].includes(e.tagName)) return "";
    const words = squash(e.innerText || e.textContent);
    if (words) return words;
    // A link or button that is only a picture: the picture's own name.
    const picture = e.querySelector("img[alt], svg title, [aria-label]");
    return squash(picture?.getAttribute("alt") || picture?.getAttribute("aria-label") || picture?.textContent || "");
  }

  function refOf(e) {
    let ref = refs.get(e);
    if (!ref) { ref = `ref_${++counter}`; refs.set(e, ref); elements.set(ref, new WeakRef(e)) }
    return ref;
  }

  /** An element by its ref, or by a CSS selector (its first match): a selector finds the same element in every
   * browser, where refs are each page's own. */
  function element(ref) {
    if (!/^ref_\d+$/.test(ref)) {
      const found = document.querySelector(ref);
      if (!found) throw new Error(`Nothing on the page matches ${ref}`);
      return found;
    }
    const e = elements.get(ref)?.deref();
    if (!e || !e.isConnected) throw new Error(`${ref} isn't on the page any more: read the page again`);
    return e;
  }

  function line(e, r) {
    const parts = [r === "generic-clickable" ? "clickable" : r];
    const n = name(e);
    if (n) parts.push(JSON.stringify(n));
    parts.push(`[${refOf(e)}]`);
    if (r === "link" && e.getAttribute("href")) parts.push(`href="${squash(e.getAttribute("href"), 120)}"`);
    if (e.tagName === "INPUT") {
      parts.push(`type=${e.type}`);
      if (e.type === "checkbox" || e.type === "radio") parts.push(e.checked ? "checked" : "unchecked");
      else if (e.value) parts.push(`value=${secret(e) ? "[value redacted]" : JSON.stringify(squash(e.value, 60))}`);
    }
    if (e.tagName === "TEXTAREA" && e.value) parts.push(`value=${JSON.stringify(squash(e.value, 60))}`);
    if (e.tagName === "SELECT") parts.push(`value=${JSON.stringify(squash(e.selectedOptions[0]?.text || "", 60))}`);
    if (/^H[1-6]$/.test(e.tagName)) parts.push(`level=${e.tagName[1]}`);
    if (e.disabled || e.getAttribute("aria-disabled") === "true") parts.push("disabled");
    if (e.getAttribute("aria-expanded")) parts.push(`expanded=${e.getAttribute("aria-expanded")}`);
    return parts.join(" ");
  }

  function onScreen(e) {
    const box = e.getBoundingClientRect();
    return box.bottom > 0 && box.right > 0 && box.top < innerHeight && box.left < innerWidth;
  }

  function tree({ filter = "all", depth = 15, ref, maxChars = 50000 } = {}) {
    const root = ref ? element(ref) : document.body || document.documentElement;
    const lines = [];
    const started = performance.now();
    let seen = 0;
    const interactive = filter === "interactive";
    const walk = (e, level, indent) => {
      if (++seen > 10000 || performance.now() - started > 1500 || level > depth) return;
      if (e.nodeType !== 1 || ["SCRIPT", "STYLE", "NOSCRIPT", "TEMPLATE", "SVG"].includes(e.tagName.toUpperCase())) return;
      if (hidden(e)) return;
      const r = role(e);
      let shown = false;
      if (r && (!interactive || INTERACTIVE.has(r) || r === "generic-clickable") && (!interactive || onScreen(e) || ref)) {
        lines.push("  ".repeat(indent) + line(e, r));
        shown = true;
        if (e.tagName === "SELECT") for (const o of e.options) lines.push("  ".repeat(indent + 1) + `option ${JSON.stringify(squash(o.text, 60))}${o.selected ? " selected" : ""}`);
        // Text on its own inside a container is said once, by the container's line.
        if (["link", "button", "heading", "option", "label", "paragraph", "cell", "columnheader", "listitem", "textbox"].includes(r) && !e.querySelector("a,button,input,select,textarea,[role]")) return;
      } else if (!r && !interactive) {
        const own = [...e.childNodes].filter((n) => n.nodeType === 3).map((n) => n.textContent).join(" ").trim();
        if (own) { lines.push("  ".repeat(indent) + `text ${JSON.stringify(squash(own, 120))}`) }
      }
      for (const child of e.shadowRoot ? [...e.shadowRoot.children, ...e.children] : e.children) walk(child, level + 1, indent + (shown ? 1 : 0));
    };
    walk(root, 0, 0);
    let out = lines.join("\n");
    if (seen > 10000 || performance.now() - started > 1500) out += "\n… (the page is large: read part of it with ref_id or a smaller depth)";
    if (out.length > maxChars) {
      const cut = out.lastIndexOf("\n", maxChars);
      out = out.slice(0, cut > 0 ? cut : maxChars) + `\n… (${out.length} characters in all: pass a larger max_chars, or read part with ref_id or depth)`;
    }
    return out || "(nothing on the page)";
  }

  /** The element's centre in the viewport, scrolled into view first. */
  function center(ref) {
    const e = element(ref);
    e.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
    const box = e.getBoundingClientRect();
    return { x: box.left + box.width / 2, y: box.top + box.height / 2 };
  }

  /** A click from inside the page, for when Chrome won't let the debugger near the tab (below, tools.js). */
  function press(ref) {
    const e = element(ref);
    e.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
    const box = e.getBoundingClientRect();
    const at = { bubbles: true, cancelable: true, view: window, clientX: box.left + box.width / 2, clientY: box.top + box.height / 2, button: 0 };
    e.dispatchEvent(new PointerEvent("pointerdown", { ...at, buttons: 1 }));
    e.dispatchEvent(new MouseEvent("mousedown", { ...at, buttons: 1 }));
    e.focus?.();
    e.dispatchEvent(new PointerEvent("pointerup", at));
    e.dispatchEvent(new MouseEvent("mouseup", at));
    e.click();
  }

  const LANDMARKS = new Set(["banner", "main", "form", "group", "region", "navigation", "list", "listitem", "contentinfo", "complementary", "article", "search", "table", "row", "dialog"]);
  const SYNONYMS = {
    button: ["button"], link: ["link"], search: ["searchbox", "textbox", "combobox"], field: ["textbox", "searchbox", "combobox"], input: ["textbox", "searchbox", "combobox"],
    box: ["textbox", "searchbox", "checkbox", "combobox"], bar: ["searchbox", "textbox", "combobox"], textbox: ["textbox"], dropdown: ["combobox", "listbox"], select: ["combobox", "listbox"], menu: ["menuitem", "combobox"],
    checkbox: ["checkbox"], check: ["checkbox"], radio: ["radio"], tab: ["tab"], heading: ["heading"], title: ["heading"], image: ["img"], picture: ["img"], slider: ["slider"],
  };

  /** Elements matching the words, best first: by role, name, text, placeholder, id, test id and the text around them. */
  function find(query) {
    const words = String(query).toLowerCase().split(/[^\p{L}\p{N}#@._-]+/u).filter((w) => w.length > 1);
    const roles = new Set(words.flatMap((w) => SYNONYMS[w] || []));
    const scored = [];
    for (const e of document.querySelectorAll("body *")) {
      const r = role(e);
      if (!r || hidden(e)) continue;
      const own = [name(e), e.id, e.getAttribute("data-testid"), e.getAttribute("name"), e.getAttribute("placeholder"), e.getAttribute("href")].filter(Boolean).join(" ").toLowerCase();
      const around = (e.closest("label,li,tr,section,form,article,[role=group]")?.innerText || "").slice(0, 300).toLowerCase();
      let score = roles.has(r) ? 3 : 0;
      for (const w of words) {
        if (own.includes(w)) score += own.split(/[^\p{L}\p{N}#@._-]+/u).includes(w) ? 4 : 2;
        else if (around.includes(w)) score += 1;
      }
      // What one acts on before what holds it: a field before the form, a button before the banner.
      if (INTERACTIVE.has(r) || r === "generic-clickable") score += 1.5;
      if (LANDMARKS.has(r)) score -= 2.5;
      if (score > 1) scored.push([score, e, r]);
    }
    scored.sort((a, b) => b[0] - a[0]);
    if (!scored.length) return `Nothing matches “${query}”: say what the element says, or read the page`;
    const lines = scored.slice(0, 20).map(([, e, r]) => line(e, r));
    return lines.join("\n") + (scored.length > 20 ? `\n… ${scored.length - 20} more: say more about the one you mean` : "");
  }

  function text(maxChars = 50000) {
    const candidates = [...document.querySelectorAll("article, main, [role=main], #content, .content, #main")].filter((e) => !hidden(e));
    const best = candidates.sort((a, b) => b.innerText.length - a.innerText.length)[0];
    let words = ((best && best.innerText.length > 400 ? best : document.body)?.innerText || "").replace(/\n{3,}/g, "\n\n").trim();
    if (words.length > maxChars) words = words.slice(0, maxChars) + `\n… (${words.length} characters in all)`;
    return `${document.title}\n\n${words}`;
  }

  function setValue(e, value) {
    const proto = e.tagName === "TEXTAREA" ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
    // The prototype's setter, so pages that wrap value (React and the like) see the change.
    Object.getOwnPropertyDescriptor(proto, "value").set.call(e, value);
    e.dispatchEvent(new Event("input", { bubbles: true }));
    e.dispatchEvent(new Event("change", { bubbles: true }));
  }

  function form(ref, value) {
    const e = element(ref);
    e.scrollIntoView({ block: "center", behavior: "instant" });
    if (e.tagName === "SELECT") {
      const option = [...e.options].find((o) => o.value === String(value)) || [...e.options].find((o) => o.text.trim().toLowerCase() === String(value).trim().toLowerCase());
      if (!option) throw new Error(`${ref} has no option ${JSON.stringify(value)}: its options are ${[...e.options].map((o) => JSON.stringify(o.text.trim())).join(", ")}`);
      e.value = option.value;
      e.dispatchEvent(new Event("input", { bubbles: true }));
      e.dispatchEvent(new Event("change", { bubbles: true }));
      return `Chose ${JSON.stringify(option.text.trim())} in ${ref}.`;
    }
    if (e.type === "checkbox" || e.type === "radio") {
      if (typeof value !== "boolean") throw new Error(`${ref} is a ${e.type}: give true or false`);
      if (e.checked !== value) e.click();
      return `${ref} is ${e.checked ? "checked" : "unchecked"}.`;
    }
    if (e.isContentEditable) {
      e.focus();
      e.textContent = String(value);
      e.dispatchEvent(new InputEvent("input", { bubbles: true }));
      return `Set ${ref}.`;
    }
    if (!("value" in e)) throw new Error(`${ref} isn't a form field`);
    e.focus();
    setValue(e, String(value));
    return `Set ${ref}${secret(e) ? "" : ` to ${JSON.stringify(squash(value, 60))}`}.`;
  }

  function upload(ref, at, files) {
    const transfer = new DataTransfer();
    for (const f of files) {
      const bytes = Uint8Array.from(atob(f.data), (c) => c.charCodeAt(0));
      transfer.items.add(new File([bytes], f.name, { type: f.mimeType || "application/octet-stream" }));
    }
    const names = files.map((f) => f.name).join(", ");
    if (ref) {
      const e = element(ref);
      if (e.tagName !== "INPUT" || e.type !== "file") throw new Error(`${ref} isn't a file field: find the input itself (it may be hidden)`);
      e.files = transfer.files;
      e.dispatchEvent(new Event("input", { bubbles: true }));
      e.dispatchEvent(new Event("change", { bubbles: true }));
      return `Put ${names} into ${ref}.`;
    }
    const target = document.elementFromPoint(at.x, at.y);
    if (!target) throw new Error("Nothing is at that point");
    for (const type of ["dragenter", "dragover", "drop"]) {
      target.dispatchEvent(new DragEvent(type, { bubbles: true, cancelable: true, clientX: at.x, clientY: at.y, dataTransfer: transfer }));
    }
    return `Dropped ${names} on the page.`;
  }

  globalThis.__zero = { tree, center, press, find, text, form, upload };
})();
