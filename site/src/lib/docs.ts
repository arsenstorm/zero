import { getCollection } from "astro:content";

/** The docs' pages in the sidebar's order. */
export const docPages = async () => (await getCollection("docs")).sort((a, b) => a.data.order - b.data.order);

/** A page's address: the introduction is /docs itself. */
export const docHref = (id: string) => (id === "index" ? "/docs" : `/docs/${id}`);

/** A page's Markdown as the agent reads it: its title and description, then the body. */
export const docMarkdown = (page: { data: { title: string; description: string }; body?: string }) =>
  `# ${page.data.title}\n\n${page.data.description}\n\n${(page.body ?? "").trim()}\n`;

/** Each page's icon in the docs sidebar: the app's own where the page matches one of its places (its Settings pages and
 *  rail), one each, none shared. And the sidebar's groups. Site-only: the Markdown stays as the help agent reads it. */
export const docIcons: Record<string, string> = {
  index: "book",
  "getting-started": "rocket",
  "tasks-and-workers": "list-checkbox",
  "inbox-and-asks": "inbox",
  "control-bar": "layout-top",
  "accounts-and-models": "circle-user",
  "workspaces-and-folders": "suitcase",
  "later-scratchpads-loops": "bookmark",
  "following-and-integrations": "eye",
  "browsers-and-mcp": "globe",
  settings: "gear",
  "keyboard-shortcuts": "keyboard",
  iphone: "mobile",
  cli: "terminal",
  troubleshooting: "circle-question",
};
export const docGroups: { title: string; ids: string[] }[] = [
  { title: "Start", ids: ["index", "getting-started"] },
  { title: "Use Zero", ids: ["tasks-and-workers", "inbox-and-asks", "control-bar", "accounts-and-models", "workspaces-and-folders", "later-scratchpads-loops", "following-and-integrations", "browsers-and-mcp"] },
  { title: "Reference", ids: ["settings", "keyboard-shortcuts", "iphone", "cli", "troubleshooting"] },
];
