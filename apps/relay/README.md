# Zero's relay

Passes frames between Zero on a Mac and Zero on a phone. It can't read them: the two speak Noise end to end
(`apps/macos/Sources/ZeroCore/Noise.swift`). It also sends the Mac's notifications to its phones through Apple's push
service (below).

What it keeps, per Mac: the hash of its token; its phones' push tokens (up to 10, as the Mac registers them) and
whether each is a development build's (Apple's sandbox) or not; and how many pushes it sent this minute and today.
Nothing else.

Deploy it to your own Cloudflare account (Workers with Durable Objects, on the free plan):

    cd apps/relay
    npx wrangler deploy

Then put its address (`wss://zero-relay.<your account>.workers.dev`) in Zero's Settings › Phone. Without one, Zero
uses the hosted relay at `wss://relay.withzero.dev`.

## Closing a relay

Set the `CLOSED` variable to a message for its users (`npx wrangler secret put CLOSED`), for example where to run their
own. `/status` then answers `{"open": false, "message": …}`, every connection is refused with 410 and the same JSON,
and Zero shows the message in Settings › Phone and stops connecting. Remove the variable to open it again.

## Notifications

The Mac posts each notification to `POST /push/<mac id>`, with its token, as `{token, payload, collapse, quiet}`. The
payload is sealed for the phone already (only its Notify extension can open it), so the relay signs a request to APNs
and passes it on unread. Development builds of the phone app have sandbox tokens: Apple answers BadDeviceToken to the
production address, and the relay tries the sandbox and remembers.

So it isn't anyone's free push service, it sends only:

- to the phones the Mac registered, over its own connection (`{"push": [tokens]}`, the whole list each time, up to 10);
- 30 a minute and 1000 a day per Mac (429 beyond that);
- payloads of 4 KB or less (413), APNs' own limit;
- while it's open (410 once closed, as everything else).

It needs an APNs key, from developer.apple.com › Certificates, Identifiers & Profiles › Keys: a key with Apple Push
Notification service on, downloaded once as a `.p8`. Add it and its details as secrets:

    base64 -i AuthKey_XXXXXXXXXX.p8 | npx wrangler secret put APNS_KEY   # the .p8, on one line
    npx wrangler secret put APNS_KEY_ID     # the key's ID, ten characters
    npx wrangler secret put APNS_TEAM_ID    # the team's ID, top right of the developer site
    npx wrangler secret put APNS_TOPIC      # the phone app's bundle ID

Without them, `/push` answers 501, and Zero sends from the Mac with its own key if it has one in the Keychain (service
`Zero tunnel`, accounts `apns.key`, `apns.keyid`, `apns.team`).

`node --test apps/relay/relay.test.js` checks all of this without Apple.
