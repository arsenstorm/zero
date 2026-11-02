// Zero's relay: one Durable Object per Mac, holding the Mac's WebSocket and its phones'. It passes frames both ways
// and can read none of them: each phone and the Mac speak Noise end to end (apps/macos/Sources/ZeroCore/Noise.swift).
//
//   wss://<relay>/mac/<mac id>     the Mac, with "Authorization: Bearer <token>": the first token a Mac id is used with
//                                  is the only one it takes from then on (its hash kept, nothing else)
//   wss://<relay>/phone/<mac id>   a phone; refused while its Mac isn't connected
//
// Between the relay and the Mac, text frames of JSON: {"conn","open"}, {"conn","data"} (base64), {"conn","close"}.
// Between the relay and a phone, the binary frames themselves.

import { DurableObject } from "cloudflare:workers";

export default {
  async fetch(request, env) {
    const [, side, mac] = new URL(request.url).pathname.split("/");
    if (!["mac", "phone"].includes(side) || !/^[A-Za-z0-9_-]{16,64}$/.test(mac ?? "")) return new Response("Zero's relay", { status: 404 });
    if (request.headers.get("Upgrade") !== "websocket") return new Response("WebSocket only", { status: 426 });
    return env.MACS.get(env.MACS.idFromName(mac)).fetch(request);
  },
};

// In slices: a frame is up to 64 KB, more arguments than a call takes at once.
const base64 = (bytes) => {
  let text = "";
  for (let i = 0; i < bytes.length; i += 0x8000) text += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(text);
};
const sha256 = async (text) => base64(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text))));

export class Mac extends DurableObject {
  async fetch(request) {
    // What threw, in the answer: the relay keeps no logs of its own.
    try { return await this.open(request); } catch (error) { return new Response(`Zero's relay failed: ${error?.stack ?? error}`, { status: 500 }); }
  }

  async open(request) {
    const side = new URL(request.url).pathname.split("/")[1];
    const [client, server] = Object.values(new WebSocketPair());
    if (side === "mac") {
      const token = (request.headers.get("Authorization") ?? "").replace(/^Bearer /, "");
      if (token.length < 32) return new Response("A token, please", { status: 401 });
      const kept = await this.ctx.storage.get("token");
      const hash = await sha256(token);
      if (kept && kept !== hash) return new Response("Not this Mac's token", { status: 403 });
      if (!kept) await this.ctx.storage.put("token", hash);
      // One Mac at a time: a new connection (after a restart, a network change) takes over. A Mac that was killed
      // never closed its end, and its socket can linger in the list: each is stamped, and the newest open one is used.
      for (const old of this.ctx.getWebSockets("mac")) { try { old.close(1012, "Replaced"); } catch {} }
      this.ctx.acceptWebSocket(server, ["mac"]);
      server.serializeAttachment({ mac: Date.now() });
      // Phones connected meanwhile start again with it.
      for (const phone of this.ctx.getWebSockets("phone")) phone.close(1012, "Mac reconnected");
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

  phone(conn) { return this.ctx.getWebSockets(conn)[0]; }

  /** The Mac's newest open connection; one that can't say (closed, from before its stamp) is passed over. */
  mac() {
    let newest, at = -1;
    for (const ws of this.ctx.getWebSockets("mac")) {
      let stamp;
      try {
        if (ws.readyState !== 1) continue;
        stamp = ws.deserializeAttachment()?.mac ?? 0;
      } catch { continue; }
      if (stamp > at) { newest = ws; at = stamp; }
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
      mac.send(JSON.stringify({ conn: from.conn, data: base64(new Uint8Array(message)) }));
      return;
    }
    // The Mac's, for a phone.
    let frame;
    try { frame = JSON.parse(message); } catch { return; }
    const phone = frame.conn && this.phone(frame.conn);
    if (!phone) return;
    if (frame.close) return phone.close(1000, "Closed by the Mac");
    if (frame.data) phone.send(Uint8Array.from(atob(frame.data), (c) => c.charCodeAt(0)));
  }

  async webSocketClose(ws) {
    const from = ws.deserializeAttachment();
    if (from?.conn) {
      this.mac()?.send(JSON.stringify({ conn: from.conn, close: true }));
    } else if (!this.mac()) {
      // The Mac gone (not replaced by a newer connection): its phones with it.
      for (const phone of this.ctx.getWebSockets("phone")) phone.close(1001, "The Mac went away");
    }
  }

  async webSocketError(ws) { await this.webSocketClose(ws); }
}
