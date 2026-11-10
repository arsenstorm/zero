import { docPages, docMarkdown } from "../lib/docs";

// All of the docs as one Markdown file, in the sidebar's order: for an agent to read in one go.
export async function GET() {
  const pages = await docPages();
  return new Response(pages.map(docMarkdown).join("\n---\n\n"), {
    headers: { "Content-Type": "text/markdown; charset=utf-8" },
  });
}
