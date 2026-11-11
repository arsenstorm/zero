// The relay without Cloudflare or Apple: `node --test apps/relay/relay.test.js`. Sockets, storage and Apple's answers
// are faked, everything else is relay.js.
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

/** A WebSocket as the Durable Object sees it: what it was sent, how it was closed. */
const socket = () => ({
  readyState: 1,
  sent: [],
  closed: null,
  send(message) {
    this.sent.push(message);
  },
  close(code, reason) {
    this.closed = { code, reason };
    this.readyState = 3;
  },
  accept() {},
  serializeAttachment(value) {
    this.attachment = value;
  },
  deserializeAttachment() {
    return this.attachment;
  },
});
globalThis.WebSocketPair = class {
  constructor() {
    const [client, server] = [socket(), socket()];
    client.server = server;
    return { 0: client, 1: server };
  }
};
// Node's Response refuses 101, the Workers runtime's answer to an upgrade.
const NodeResponse = Response;
globalThis.Response = class extends NodeResponse {
  constructor(body, init) {
    super(body, init?.status === 101 ? undefined : init);
    if (init?.status === 101) this.webSocket = init.webSocket;
  }
};

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
          const sockets = [];
          const ctx = {
            storage,
            acceptWebSocket: (ws, tags) =>
              sockets.push(Object.assign(ws, { tags })),
            getWebSockets: (tag) =>
              sockets.filter((ws) => ws.tags.includes(tag)),
          };
          macs.set(id, new Mac(ctx, env));
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

/** A connection to the relay: the server's end of its socket, as the Durable Object holds it. */
const connect = async (env, side, token = TOKEN) =>
  (
    await worker.fetch(
      new Request(`https://relay.test/${side}/macmacmacmacmacmac`, {
        headers: { Upgrade: "websocket", Authorization: `Bearer ${token}` },
      }),
      env
    )
  ).webSocket.server;

const fromPhone = (mac, phone, size) =>
  mac.webSocketMessage(phone, new Uint8Array(size).buffer);
const toPhone = (mac, from, phone, size) =>
  mac.webSocketMessage(
    from,
    JSON.stringify({
      conn: phone.attachment.conn,
      data: Buffer.alloc(size).toString("base64"),
    })
  );

test("one Mac, which a new connection replaces, and ten phones at once", async () => {
  const { env, mac } = relay();
  const first = await connect(env, "mac");
  const second = await connect(env, "mac");
  assert.equal(first.closed?.code, 1012);
  assert.equal(second.closed, null);
  const phones = [];
  for (let i = 0; i < limits.phones; i++)
    phones.push(await connect(env, "phone"));
  assert.ok(phones.every((phone) => phone.closed === null));
  const more = await connect(env, "phone");
  assert.equal(more.closed?.code, 1008);
  assert.match(more.closed.reason, /10 phones/);
  assert.equal(mac.ctx.getWebSockets("phone").length, limits.phones);
  phones[0].close(1000, "");
  assert.equal((await connect(env, "phone")).closed, null);
});

test("a frame over the most closes its socket, unpassed", async () => {
  const { env, mac } = relay();
  const macSocket = await connect(env, "mac");
  const phone = await connect(env, "phone");
  // Noise's largest frame, 64 KB, and the Mac's base64 of it.
  await fromPhone(mac, phone, 65535);
  await toPhone(mac, macSocket, phone, 65535);
  assert.equal(macSocket.sent.length, 2);
  assert.equal(phone.sent.length, 1);
  await fromPhone(mac, phone, limits.frame + 1);
  assert.equal(phone.closed?.code, 1009);
  assert.equal(macSocket.sent.length, 2);
  const other = await connect(env, "phone");
  await mac.webSocketMessage(macSocket, "x".repeat(limits.frame + 1));
  assert.equal(macSocket.closed?.code, 1009);
  assert.equal(other.sent.length, 0);
});

test("a day's bytes both ways, then nothing passed until the next UTC day", async (t) => {
  t.mock.timers.enable({
    apis: ["Date"],
    now: Date.parse("2026-11-10T12:00:00Z"),
  });
  const { env, mac } = relay();
  await mac.ctx.storage.put("relayed", {
    day: "2026-11-10",
    bytes: limits.daily - 2000,
  });
  const macSocket = await connect(env, "mac");
  const phone = await connect(env, "phone");
  await fromPhone(mac, phone, 1000);
  await toPhone(mac, macSocket, phone, 1000);
  assert.equal(macSocket.sent.length, 2);
  assert.equal(phone.sent.length, 1);

  // Spent: the frame isn't passed, the Mac is told why and its phones are closed with it.
  await fromPhone(mac, phone, 1000);
  assert.equal(macSocket.sent.length, 3);
  const { limit } = JSON.parse(macSocket.sent[2]);
  assert.match(limit, /Today/);
  assert.deepEqual(phone.closed, { code: 1008, reason: limit });
  assert.equal(macSocket.closed, null);
  const refused = await connect(env, "phone");
  assert.deepEqual(refused.closed, { code: 1008, reason: limit });
  // Said again to a Mac that connects, and kept through the object's eviction.
  const again = await connect(env, "mac");
  assert.deepEqual(JSON.parse(again.sent[0]), { limit });
  await new Mac(mac.ctx, env).webSocketMessage(
    phone,
    new Uint8Array(10).buffer
  );
  assert.deepEqual(JSON.parse(again.sent[1]), { limit });

  t.mock.timers.tick(12 * 3600_000);
  const tomorrow = await connect(env, "phone");
  assert.equal(tomorrow.closed, null);
  await fromPhone(mac, tomorrow, 1000);
  assert.equal(JSON.parse(again.sent.at(-1)).data.length, 1336);
});

test("a burst passes, a flood is cut off", async (t) => {
  t.mock.timers.enable({
    apis: ["Date"],
    now: Date.parse("2026-11-10T12:00:00Z"),
  });
  const { env, mac } = relay();
  const macSocket = await connect(env, "mac");
  const phone = await connect(env, "phone");
  for (let i = 0; i < limits.burst; i++) await fromPhone(mac, phone, 100);
  assert.equal(phone.closed, null);
  assert.equal(macSocket.sent.length, 1 + limits.burst);
  await fromPhone(mac, phone, 100);
  assert.equal(phone.closed?.code, 1008);
  assert.match(phone.closed.reason, /frames/);
  assert.equal(macSocket.sent.length, 1 + limits.burst);

  // Refilled at the rate: a second on, that many more.
  t.mock.timers.tick(1000);
  const next = await connect(env, "phone");
  for (let i = 0; i < limits.rate; i++)
    await toPhone(mac, macSocket, next, 100);
  assert.equal(next.sent.length, limits.rate);
  await toPhone(mac, macSocket, next, 100);
  assert.equal(macSocket.closed?.code, 1008);
});
