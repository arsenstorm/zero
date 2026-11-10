import type { APIRoute } from "astro";
import { docPages, docMarkdown } from "../../lib/docs";

// Every page as Markdown at /docs/<page>.md, for people to copy and for agents to read.
export async function getStaticPaths() {
  return (await docPages()).map((page) => ({
    params: { slug: page.id },
    props: { page },
  }));
}

export const GET: APIRoute = ({ props }) =>
  new Response(docMarkdown(props.page), {
    headers: { "Content-Type": "text/markdown; charset=utf-8" },
  });
