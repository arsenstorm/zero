// The relay's pushes without Apple: `node --test apps/relay`. Apple's answers are faked, everything else is relay.js.
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { registerHooks } from "node:module";
import { test } from "node:test";

registerHooks({
  resolve: (specifier, context, next) =>
    specifier === "cloudflare:workers"
      ? {
          shortCircuit: true,
          url: "data:text/javascript,export class DurableObject { constructor(ctx, env) { this.ctx = ctx; this.env = env; } }",
        }
      : next(specifier, context),
});
const { default: worker, Mac, limits } = await import("./relay.js");

const keys = await crypto.subtle.generateKey(
  { name: "ECDSA", namedCurve: "P-256" },
  true,
  ["sign", "verify"]
);
const pkcs8 = Buffer.from(
  await crypto.subtle.exportKey("pkcs8", keys.privateKey)
).toString("base64");
const p8 = `-----BEGIN PRIVATE KEY-----\n${pkcs8}\n-----END PRIVATE KEY-----\n`;
const secrets = {
  APNS_KEY: btoa(p8),
  APNS_KEY_ID: "KEY1234567",
  APNS_TEAM_ID: "TEAM123456",
  APNS_TOPIC: "dev.example.zero",
};
const TOKEN = "t".repeat(40);
const PHONE = "ab".repeat(32);

/** A relay with one Mac (its token taken), its storage in memory, and Apple answering `apple(host)`. */
function relay(env = secrets, apple = () => new Response("", { status: 200 })) {
  const macs = new Map();
  env = {
    ...env,
    MACS: {
      idFromName: (name) => name,
      get: (id) => {
        if (!macs.has(id)) {
          const kept = new Map();
          const storage = {
            get: async (key) => structuredClone(kept.get(key)),
            put: async (key, value) => kept.set(key, structuredClone(value)),
          };
          macs.set(id, new Mac({ storage, getWebSockets: () => [] }, env));
        }
        return macs.get(id);
      },
    },
  };
  const sent = [];
  globalThis.fetch = async (url, init) => {
    sent.push({ url, ...init });
    return apple(new URL(url).host);
  };
  return { env, mac: env.MACS.get("macmacmacmacmacmac"), sent };
}

/** The Mac's token taken, as its first connection does. */
const claim = (mac) =>
  mac.ctx.storage.put(
    "token",
    createHash("sha256").update(TOKEN).digest("base64")
  );

const push = (env, body, token = TOKEN) =>
  worker.fetch(
    new Request("https://relay.test/push/macmacmacmacmacmac", {
      method: "POST",
      headers: { Authorization: `Bearer ${token}` },
      body: typeof body === "string" ? body : JSON.stringify(body),
    }),
    env
  );

const register = (mac, tokens) =>
  mac.webSocketMessage(
    { deserializeAttachment: () => ({ mac: 1 }) },
    JSON.stringify({ push: tokens })
  );

test("a relay without an APNs key says so, for the Mac to send itself", async () => {
  const { env } = relay({});
  assert.equal((await push(env, {})).status, 501);
});

test("closed, it refuses pushes as everything else", async () => {
  const { env } = relay({ ...secrets, CLOSED: "Run your own" });
  assert.equal((await push(env, {})).status, 410);
});

test("only the Mac's own token, and never claimed by a push", async () => {
  const { env, mac } = relay();
  assert.equal((await push(env, { token: PHONE })).status, 403);
  assert.equal(await mac.ctx.storage.get("token"), undefined);
  await claim(mac);
  assert.equal((await push(env, { token: PHONE }, "x".repeat(40))).status, 403);
  assert.equal((await push(env, { token: PHONE }, "short")).status, 401);
});

test("only to phones the Mac registered, the list replaced each time", async () => {
  const { env, mac, sent } = relay();
  await claim(mac);
  assert.equal((await push(env, { token: PHONE })).status, 403);
  await register(mac, [PHONE, "not hex", 42]);
  assert.deepEqual(Object.keys(await mac.ctx.storage.get("phones")), [PHONE]);
  assert.equal((await push(env, { token: PHONE })).status, 200);
  await register(mac, []);
  assert.equal((await push(env, { token: PHONE })).status, 403);
  assert.equal(sent.length, 1);
  await register(
    mac,
    Array.from({ length: 20 }, (_, i) => i.toString(16).padStart(64, "0"))
  );
  assert.equal(
    Object.keys(await mac.ctx.storage.get("phones")).length,
    limits.phones
  );
});

test("signed for Apple, the payload passed on as it came", async () => {
  const { env, mac, sent } = relay();
  await claim(mac);
  await register(mac, [PHONE]);
  const payload = { aps: { alert: { title: "Zero" } }, zero: "c2VhbGVk" };
  await push(env, { token: PHONE, payload, collapse: "task-1" });
  await push(env, { token: PHONE, payload: { clear: ["a"] }, quiet: true });
  const [alert, quiet] = sent;
  assert.equal(alert.url, `https://api.push.apple.com/3/device/${PHONE}`);
  assert.equal(alert.body, JSON.stringify(payload));
  assert.equal(alert.headers["apns-topic"], secrets.APNS_TOPIC);
  assert.equal(alert.headers["apns-push-type"], "alert");
  assert.equal(alert.headers["apns-collapse-id"], "task-1");
  assert.equal(quiet.headers["apns-push-type"], "background");
  assert.equal(quiet.headers["apns-priority"], "5");
  assert.equal(quiet.headers["apns-collapse-id"], undefined);

  const jwt = alert.headers.authorization.replace("bearer ", "");
  assert.equal(quiet.headers.authorization, alert.headers.authorization);
  const [header, claims, signature] = jwt.split(".");
  const json = (part) => JSON.parse(Buffer.from(part, "base64url"));
  assert.deepEqual(json(header), { alg: "ES256", kid: secrets.APNS_KEY_ID });
  assert.equal(json(claims).iss, secrets.APNS_TEAM_ID);
  assert.ok(
    await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      keys.publicKey,
      Buffer.from(signature, "base64url"),
      new TextEncoder().encode(`${header}.${claims}`)
    )
  );
});

test("a development build's token: the sandbox, then remembered", async () => {
  const { env, mac, sent } = relay(secrets, (host) =>
    host === "api.push.apple.com"
      ? Response.json({ reason: "BadDeviceToken" }, { status: 400 })
      : new Response("", { status: 200 })
  );
  await claim(mac);
  await register(mac, [PHONE]);
  assert.equal((await push(env, { token: PHONE })).status, 200);
  assert.deepEqual(
    sent.map((s) => new URL(s.url).host),
    ["api.push.apple.com", "api.sandbox.push.apple.com"]
  );
  await push(env, { token: PHONE });
  assert.equal(new URL(sent[2].url).host, "api.sandbox.push.apple.com");
  // Registered again, the phone keeps where it was found.
  await register(mac, [PHONE]);
  assert.equal((await mac.ctx.storage.get("phones"))[PHONE], "sandbox");
});

test("payloads over 4 KB are refused", async () => {
  const { env, mac, sent } = relay();
  await claim(mac);
  await register(mac, [PHONE]);
  const big = { zero: "x".repeat(limits.payload) };
  assert.equal((await push(env, { token: PHONE, payload: big })).status, 413);
  assert.equal(sent.length, 0);
});

test("30 a minute and 1000 a day per Mac", async (t) => {
  const { env, mac, sent } = relay();
  await claim(mac);
  await register(mac, [PHONE]);
  t.mock.timers.enable({
    apis: ["Date"],
    now: Date.parse("2026-11-10T12:00:00Z"),
  });
  for (let i = 0; i < limits.minute; i++)
    assert.equal((await push(env, { token: PHONE })).status, 200);
  assert.equal((await push(env, { token: PHONE })).status, 429);
  t.mock.timers.tick(60_000);
  assert.equal((await push(env, { token: PHONE })).status, 200);

  await mac.ctx.storage.put("pushes", {
    ...(await mac.ctx.storage.get("pushes")),
    inDay: limits.day,
  });
  t.mock.timers.tick(60_000);
  assert.equal((await push(env, { token: PHONE })).status, 429);
  t.mock.timers.tick(24 * 3600_000);
  assert.equal((await push(env, { token: PHONE })).status, 200);
  assert.equal(sent.length, limits.minute + 2);
});
