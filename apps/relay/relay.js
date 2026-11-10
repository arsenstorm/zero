// Zero's relay: one Durable Object per Mac, holding the Mac's WebSocket and its phones'. It passes frames both ways
// and can read none of them: each phone and the Mac speak Noise end to end (apps/macos/Sources/ZeroCore/Noise.swift).
//
//   wss://<relay>/mac/<mac id>     the Mac, with "Authorization: Bearer <token>": the first token a Mac id is used with
//                                  is the only one it takes from then on (its hash kept, nothing else)
//   wss://<relay>/phone/<mac id>   a phone; refused while its Mac isn't connected
//   https://<relay>/status         {"open": true}, or {"open": false, "message"} once it's closed (below)
//   POST https://<relay>/push/<mac id>  a notification for one of the Mac's phones, with the Mac's token, as
//                                  {token, payload, collapse, quiet}: signed and sent to Apple (APNs, below)
//
// Closing it: set the CLOSED variable (`npx wrangler secret put CLOSED`, or in the dashboard) to what Zero should tell its
// users, such as where to run their own. Every connection is then refused with 410 and that message, and Zero shows it
// in Settings › Phone and stops trying.
//
// Between the relay and the Mac, text frames of JSON: {"conn","open"}, {"conn","data"} (base64), {"conn","close"}, and
// the Mac's {"push": [tokens]}, its phones' push tokens: the only ones /push sends to.
// Between the relay and a phone, the binary frames themselves.
//
// Pushes: the payload is sealed for the phone already (its Notify extension opens it), so the relay passes it on unread.
// It needs an APNs key in its secrets (README); without one /push answers 501 and the Mac sends with its own key.
// Kept short of a free push service: phones the Mac registered (up to 10), 30 a minute and 1000 a day per Mac, 4 KB.

import { DurableObject } from "cloudflare:workers";

export default {
  async fetch(request, env) {
    const [, side, mac] = new URL(request.url).pathname.split("/");
    const closed = env.CLOSED
      ? { open: false, message: String(env.CLOSED) }
      : null;
    if (side === "status")
      return Response.json(closed ?? { open: true }, {
        headers: { "Cache-Control": "max-age=300" },
      });
    if (closed) return Response.json(closed, { status: 410 });
    if (
      !["mac", "phone", "push"].includes(side) ||
      !/^[A-Za-z0-9_-]{16,64}$/.test(mac ?? "")
    )
      return new Response("Zero's relay", { status: 404 });
    if (side === "push") {
      if (request.method !== "POST")
        return new Response("POST only", { status: 405 });
      if (
        !(env.APNS_KEY && env.APNS_KEY_ID && env.APNS_TEAM_ID && env.APNS_TOPIC)
      )
        return new Response("This relay doesn't send pushes", { status: 501 });
    } else if (request.headers.get("Upgrade") !== "websocket")
      return new Response("WebSocket only", { status: 426 });
    return env.MACS.get(env.MACS.idFromName(mac)).fetch(request);
  },
};

// In slices: a frame is up to 64 KB, more arguments than a call takes at once.
const base64 = (bytes) => {
  let text = "";
  for (let i = 0; i < bytes.length; i += 0x8000)
    text += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(text);
};
const sha256 = async (text) =>
  base64(
    new Uint8Array(
      await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text))
    )
  );

export const limits = { phones: 10, minute: 30, day: 1000, payload: 4096 };

// The provider token Apple takes for an hour: made again after fifty minutes.
let made;
async function providerToken(env) {
  if (made && Date.now() - made.at < 50 * 60 * 1000) return made.jwt;
  // The .p8 as it is, or base64 of it.
  const pem = env.APNS_KEY.includes("BEGIN")
    ? env.APNS_KEY
    : atob(env.APNS_KEY);
  const der = Uint8Array.from(
    atob(pem.replace(/-----[^-]+-----|\s/g, "")),
    (c) => c.charCodeAt(0)
  );
  const key = await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  );
  const url = (bytes) =>
    base64(bytes).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  const part = (json) => url(new TextEncoder().encode(JSON.stringify(json)));
  const input = `${part({ alg: "ES256", kid: env.APNS_KEY_ID })}.${part({
    iss: env.APNS_TEAM_ID,
    iat: Math.floor(Date.now() / 1000),
  })}`;
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(input)
  );
  made = { jwt: `${input}.${url(new Uint8Array(signature))}`, at: Date.now() };
  return made.jwt;
}

export class Mac extends DurableObject {
  async fetch(request) {
    // What threw, in the answer: the relay keeps no logs of its own.
    try {
      if (new URL(request.url).pathname.split("/")[1] === "push")
        return await this.push(request);
      return await this.open(request);
    } catch (error) {
      return new Response(`Zero's relay failed: ${error?.stack ?? error}`, {
        status: 500,
      });
    }
  }

  async open(request) {
    const side = new URL(request.url).pathname.split("/")[1];
    const [client, server] = Object.values(new WebSocketPair());
    if (side === "mac") {
      const refused = await this.refused(request, true);
      if (refused) return refused;
      // One Mac at a time: a new connection (after a restart, a network change) takes over. A Mac that was killed
      // never closed its end, and its socket can linger in the list: each is stamped, and the newest open one is used.
      for (const old of this.ctx.getWebSockets("mac")) {
        try {
          old.close(1012, "Replaced");
        } catch {}
      }
      this.ctx.acceptWebSocket(server, ["mac"]);
      server.serializeAttachment({ mac: Date.now() });
      // Phones connected meanwhile start again with it.
      for (const phone of this.ctx.getWebSockets("phone"))
        phone.close(1012, "Mac reconnected");
    } else {
      const mac = this.mac();
      if (!mac) return new Response("The Mac isn't connected", { status: 503 });
      const conn = crypto.randomUUID();
      this.ctx.acceptWebSocket(server, ["phone", conn]);
      server.serializeAttachment({ conn });
      mac.send(JSON.stringify({ conn, open: true }));
    }
    return new Response(null, { status: 101, webSocket: client });
  }

  /** Why the Mac's token isn't taken (null when it is). `claim`: the first token a Mac id sees becomes its own. */
  async refused(request, claim) {
    const token = (request.headers.get("Authorization") ?? "").replace(
      /^Bearer /,
      ""
    );
    if (token.length < 32)
      return new Response("A token, please", { status: 401 });
    const kept = await this.ctx.storage.get("token");
    const hash = await sha256(token);
    if (kept ? kept !== hash : !claim)
      return new Response("Not this Mac's token", { status: 403 });
    if (!kept) await this.ctx.storage.put("token", hash);
    return null;
  }

  async push(request) {
    const refused = await this.refused(request, false);
    if (refused) return refused;
    const text = await request.text();
    if (text.length > 2 * limits.payload)
      return new Response("Over APNs' 4 KB", { status: 413 });
    let ask;
    try {
      ask = JSON.parse(text);
    } catch {
      return new Response("JSON, please", { status: 400 });
    }
    const phones = (await this.ctx.storage.get("phones")) ?? {};
    if (typeof ask?.token !== "string" || !(ask.token in phones))
      return new Response("Not a phone this Mac registered", { status: 403 });
    const payload = JSON.stringify(ask.payload ?? {});
    if (new TextEncoder().encode(payload).length > limits.payload)
      return new Response("Over APNs' 4 KB", { status: 413 });
    const minute = Math.floor(Date.now() / 60000);
    const day = new Date().toISOString().slice(0, 10);
    const count = (await this.ctx.storage.get("pushes")) ?? {};
    if (count.minute !== minute) Object.assign(count, { minute, inMinute: 0 });
    if (count.day !== day) Object.assign(count, { day, inDay: 0 });
    if (count.inMinute >= limits.minute || count.inDay >= limits.day)
      return new Response("Too many pushes", {
        status: 429,
        headers: { "Retry-After": count.inDay >= limits.day ? "3600" : "60" },
      });
    count.inMinute++;
    count.inDay++;
    await this.ctx.storage.put("pushes", count);

    // Development builds of the phone app have sandbox tokens, the rest production ones, and the Mac can't tell which:
    // Apple says BadDeviceToken to the wrong one, so the other is tried and the one that took is kept with the token.
    const send = async (sandbox) => {
      const headers = {
        authorization: `bearer ${await providerToken(this.env)}`,
        "apns-topic": this.env.APNS_TOPIC,
        "apns-push-type": ask.quiet ? "background" : "alert",
        "apns-priority": ask.quiet ? "5" : "10",
      };
      if (typeof ask.collapse === "string")
        headers["apns-collapse-id"] = ask.collapse.slice(0, 64);
      const host = sandbox
        ? "api.sandbox.push.apple.com"
        : "api.push.apple.com";
      const answer = await fetch(`https://${host}/3/device/${ask.token}`, {
        method: "POST",
        headers,
        body: payload,
      });
      return { status: answer.status, body: await answer.text() };
    };
    const sandbox = phones[ask.token] === "sandbox";
    let answer = await send(sandbox);
    if (answer.status === 400 && answer.body.includes("BadDeviceToken")) {
      const other = await send(!sandbox);
      if (other.status === 200) {
        phones[ask.token] = sandbox ? "production" : "sandbox";
        await this.ctx.storage.put("phones", phones);
      }
      answer = other;
    }
    return new Response(answer.body, { status: answer.status });
  }

  phone(conn) {
    return this.ctx.getWebSockets(conn)[0];
  }

  /** The Mac's newest open connection; one that can't say (closed, from before its stamp) is passed over. */
  mac() {
    let newest,
      at = -1;
    for (const ws of this.ctx.getWebSockets("mac")) {
      let stamp;
      try {
        if (ws.readyState !== 1) continue;
        stamp = ws.deserializeAttachment()?.mac ?? 0;
      } catch {
        continue;
      }
      if (stamp > at) {
        newest = ws;
        at = stamp;
      }
    }
    return newest;
  }

  async webSocketMessage(ws, message) {
    const from = ws.deserializeAttachment();
    if (from?.conn) {
      // A phone's frame, for the Mac.
      if (typeof message === "string") return;
      const mac = this.mac();
      if (!mac) return ws.close(1013, "The Mac went away");
      mac.send(
        JSON.stringify({
          conn: from.conn,
          data: base64(new Uint8Array(message)),
        })
      );
      return;
    }
    // The Mac's, for a phone.
    let frame;
    try {
      frame = JSON.parse(message);
    } catch {
      return;
    }
    if (Array.isArray(frame.push)) {
      // Its phones' tokens, all of them: one no longer there is forgotten, the rest keep what they were found to be.
      const kept = (await this.ctx.storage.get("phones")) ?? {};
      const phones = {};
      for (const token of frame.push.slice(0, limits.phones))
        if (typeof token === "string" && /^[0-9a-fA-F]{32,200}$/.test(token))
          phones[token] = kept[token] ?? null;
      await this.ctx.storage.put("phones", phones);
      return;
    }
    const phone = frame.conn && this.phone(frame.conn);
    if (!phone) return;
    if (frame.close) return phone.close(1000, "Closed by the Mac");
    if (frame.data)
      phone.send(Uint8Array.from(atob(frame.data), (c) => c.charCodeAt(0)));
  }

  async webSocketClose(ws) {
    const from = ws.deserializeAttachment();
    if (from?.conn) {
      this.mac()?.send(JSON.stringify({ conn: from.conn, close: true }));
    } else if (!this.mac()) {
      // The Mac gone (not replaced by a newer connection): its phones with it.
      for (const phone of this.ctx.getWebSockets("phone"))
        phone.close(1001, "The Mac went away");
    }
  }

  async webSocketError(ws) {
    await this.webSocketClose(ws);
  }
}
