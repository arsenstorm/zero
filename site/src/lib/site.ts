/** The product's name, the site's address and its code: change them here when Zero is renamed or moves. */
export const site = {
  name: "Zero",
  url: "https://withzero.dev",
  repo: "https://github.com/arsenstorm/zero",
  /** Always the newest release's app: GitHub sends this address to the latest release's disk image. */
  download:
    "https://github.com/arsenstorm/zero/releases/latest/download/Zero.dmg",
  releases: "https://github.com/arsenstorm/zero/releases",
};

/** Zero as search engines read an app: for the home page and Download. `version`: the newest release's. */
export const appData = (version?: string) => ({
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  name: site.name,
  description:
    "A Mac workspace for coding agents. It runs Claude Code, Codex and OpenCode, and you answer them in one inbox.",
  applicationCategory: "DeveloperApplication",
  operatingSystem: "macOS 26 or later",
  url: site.url,
  downloadUrl: site.download,
  license: "https://www.gnu.org/licenses/gpl-3.0.html",
  isAccessibleForFree: true,
  offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
  ...(version && { softwareVersion: version }),
});
