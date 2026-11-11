// Zero's releases, read from GitHub as the site builds, for the changelog. Each
// release's changes are its commits since the release before, the ones people notice: features and fixes in the app
// and the daemon (`feat(app): …`, `fix(zerod): …`), written as the commit says them. The first release has none.
// No network (a build offline): no releases, and the pages say where to find them instead.

const REPO = "arsenstorm/zero";
const USER_FACING = new Set(["app", "zerod", "ios"]);

export type Change = { kind: "feat" | "fix"; text: string };
export type Release = {
  tag: string;
  version: string;
  date: Date;
  url: string;
  changes: Change[];
  first: boolean;
};

async function github<T>(
  path: string,
  accept = "application/vnd.github+json"
): Promise<T | undefined> {
  const headers: Record<string, string> = {
    Accept: accept,
    "User-Agent": "withzero.dev build",
  };
  // In CI the workflow's token lifts GitHub's limit for unsigned requests.
  if (process.env.GITHUB_TOKEN)
    headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`;
  try {
    const response = await fetch(
      `https://api.github.com/repos/${REPO}/${path}`,
      { headers }
    );
    if (!response.ok && process.env.GITHUB_TOKEN)
      throw new Error(`GitHub answered ${response.status} for ${path}`);
    return response.ok ? ((await response.json()) as T) : undefined;
  } catch (error) {
    // The deploy (which has a token) mustn't ship a changelog without its releases; any other build may go without.
    if (process.env.GITHUB_TOKEN) throw error;
    return undefined;
  }
}

/** "feat(app): change a task's status from its menu" → a feature: "Change a task's status from its menu". */
export function change(message: string): Change | undefined {
  const match = message.split("\n")[0].match(/^(feat|fix)\(([^)]*)\): (.+)$/);
  if (!match || !USER_FACING.has(match[2])) return undefined;
  const text = match[3].trim();
  return {
    kind: match[1] as Change["kind"],
    text: text[0].toUpperCase() + text.slice(1),
  };
}

let cached: Promise<Release[]> | undefined;

/** Newest first; drafts and pre-releases left out. */
export function releases(): Promise<Release[]> {
  cached ??= (async () => {
    type Raw = {
      tag_name: string;
      published_at: string;
      html_url: string;
      draft: boolean;
      prerelease: boolean;
    };
    const raw = ((await github<Raw[]>("releases?per_page=50")) ?? []).filter(
      (r) => !r.draft && !r.prerelease
    );
    return Promise.all(
      raw.map(async (r, i) => {
        const previous = raw[i + 1];
        let changes: Change[] = [];
        if (previous) {
          type Compare = { commits: { commit: { message: string } }[] };
          const compare = await github<Compare>(
            `compare/${previous.tag_name}...${r.tag_name}`
          );
          changes = (compare?.commits ?? [])
            .map((c) => change(c.commit.message))
            .filter((c): c is Change => !!c)
            .reverse();
        }
        return {
          tag: r.tag_name,
          version: r.tag_name.replace(/^v/, ""),
          date: new Date(r.published_at),
          url: r.html_url,
          changes,
          first: !previous,
        };
      })
    );
  })();
  return cached;
}
