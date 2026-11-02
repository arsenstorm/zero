# Zero's relay

Passes frames between Zero on a Mac and Zero on a phone. It can't read them: the two speak Noise end to end
(`apps/macos/Sources/ZeroCore/Noise.swift`). It keeps the hash of each Mac's token, nothing else.

Deploy it to your own Cloudflare account (Workers with Durable Objects, on the free plan):

    cd apps/relay
    npx wrangler deploy

Then put its address (`wss://zero-relay.<your account>.workers.dev`) in Zero's Settings › Devices.
