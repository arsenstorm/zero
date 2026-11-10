import { site } from "../lib/site";

export const GET = () => new Response(`User-agent: *\nAllow: /\n\nSitemap: ${new URL("/sitemap.xml", site.url).href}\n`, { headers: { "Content-Type": "text/plain" } });
