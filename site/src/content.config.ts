import { defineCollection } from "astro:content";
import { z } from "astro/zod";
import { glob } from "astro/loaders";

// The docs live outside the site, in docs/guide, so the app can bundle the same files for its help agent.
const docs = defineCollection({
  loader: glob({ pattern: "*.md", base: "../docs/guide" }),
  schema: z.object({ title: z.string(), description: z.string(), order: z.number() }),
});

export const collections = { docs };
