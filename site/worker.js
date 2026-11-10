// The site's Worker: www.withzero.dev goes to withzero.dev, keeping the path; everything else is the built site
// (dist/, served by Workers static assets), with its own 404 page.
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.hostname === "www.withzero.dev") {
      url.hostname = "withzero.dev";
      return Response.redirect(url.toString(), 301);
    }
    return env.ASSETS.fetch(request);
  },
};
