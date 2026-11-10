import { docPages, docHref } from "../lib/docs";
import { site } from "../lib/site";

// Every page people read: the home page and each page of the docs.
export async function GET() {
  const paths = ["/", ...(await docPages()).map((page) => docHref(page.id))];
  const urls = paths
    .map((path) => `  <url><loc>${new URL(path, site.url).href}</loc></url>`)
    .join("\n");
  return new Response(
    `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${urls}\n</urlset>\n`,
    {
      headers: { "Content-Type": "application/xml" },
    }
  );
}
