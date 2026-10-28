# MusicSynq

An iOS app that syncs Apple Music between you and your friends, wherever in the world they are.

1. You and your friend both open MusicSynq. You're friends in the app.
2. The host taps **Start a party** and gets a 6-character code.
3. The friend sees the party under **Friends' parties**, taps it, and either:
   - types the code the host gave them, or
   - taps **Ask to let me in**, and the host gets a notification with **Let them in / Decline** buttons.
4. The host plays music in the normal **Apple Music** app. Guests hear the same song at the same moment, through their own Apple Music account.
5. Pause, play, scrubbing or skipping through a song (±15s or anywhere on the bar) and changing tracks are all synced. The host can also let guests control playback.
6. When a guest leaves, their music stops. When the host ends the party (or the host's app is gone for 2 minutes), everyone's music stops.

## How it works

```
 Host's iPhone                         MusicSynq server                  Guest's iPhone
┌────────────────────┐                ┌──────────────────┐             ┌────────────────────┐
│ Apple Music app    │                │ accounts         │             │ MusicSynq plays    │
│   ▲ watched by     │  "Song X, 42.5s│ friends          │  forwards   │ Song X through the │
│ MusicSynq          │──playing at T"─▶ parties + codes  │────────────▶│ guest's own Apple  │
│ (HostPlayer)       │   (WebSocket)  │ join requests    │             │ Music, seeked to   │
│                    │◀── guest ──────│ push (APNs)      │◀── pause ───│ where the host is  │
└────────────────────┘    controls    └──────────────────┘             └────────────────────┘
```

- **The host's app** watches the system Music player (`MPMusicPlayerController.systemMusicPlayer`) twice a second. It sends the song (catalog ID, ISRC, title, artist), whether it's playing, and the position, whenever something changes plus a heartbeat every 5 seconds.
- **Clocks:** both phones ping the server, NTP-style, so each one knows the server's clock to within a few milliseconds. The host stamps each report with server time, so a guest can work out exactly where the host's song is *now*, whatever the network delay.
- **The guest's app** finds the same song in *their* country's catalog (by catalog ID, then ISRC, then title/artist search), plays it with MusicKit's `ApplicationMusicPlayer`, and checks the drift every second. Over 0.6s off, it seeks back into line. It also learns how long its seeks take and aims slightly ahead to make up for it.
- **Guests use the app's own player**, not the Music app, so leaving the party (or closing MusicSynq) stops their music and their own Music queue is untouched.

## Repository layout

| Path | What |
| --- | --- |
| `server/` | Node.js backend (plain JavaScript, Fastify, SQLite, WebSockets, APNs) |
| `ios/MusicSynq/` | The SwiftUI iOS app |
| `ios/MusicSynqKit/` | Swift package shared by the app: API models, REST + WebSocket clients, clock sync, and the sync logic. Builds and tests on any platform |
| `ios/project.yml` | Xcode project definition (generated with XcodeGen) |

## What you need

- **An Apple Developer Program membership ($99/year).** MusicKit and push notifications don't work with a free account.
- A Mac with **Xcode 15 or newer**, and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).
- **Real iPhones on iOS 17+.** Apple Music playback doesn't work in the Simulator.
- **An Apple Music subscription for every guest**, because guests play songs from their own account. The host only has to be able to play the music they're sharing.
- **Node.js 20.12+** for the server, and somewhere to host it with HTTPS (both friends' phones must reach it).

## Setup

### 1. Run the server

```bash
cd server
npm install
npm start            # http://localhost:8080
npm test             # 22 tests: accounts, friends, parties, sync messages, push signing
```

For friends on different networks, deploy it somewhere public with HTTPS and a persistent disk for the SQLite database. There's a `Dockerfile`; on [Fly.io](https://fly.io), for example:

```bash
cd server
fly launch --no-deploy          # accept the Dockerfile
fly volumes create data --size 1
# in fly.toml add:  [mounts] source = "data"  destination = "/data"
fly deploy
```

Render, Railway and a small VPS work too. Just mount a volume at `/data`.

### 2. Apple Developer portal

At [developer.apple.com](https://developer.apple.com/account) → Certificates, Identifiers & Profiles:

1. **Identifiers → +** → App ID, e.g. `com.yourname.musicsynq`. Under **Capabilities**, tick **Push Notifications**. Under **App Services**, tick **MusicKit**.
2. **Keys → +** → tick **Apple Push Notifications service (APNs)**. Download the `.p8` file and note the Key ID. Your Team ID is in the top right of the portal.
3. Give the server those details (see `server/.env.example`):

   ```bash
   APNS_KEY_ID=ABC123DEFG
   APNS_TEAM_ID=TEAM123456
   APNS_BUNDLE_ID=com.yourname.musicsynq
   APNS_PRIVATE_KEY_PATH=/path/to/AuthKey_ABC123DEFG.p8   # or APNS_PRIVATE_KEY="-----BEGIN PRIVATE KEY-----\n…"
   ```

   Without these the app still works. Join requests then only show up while the host has the app open.

### 3. Build the app

```bash
cd ios
# edit project.yml: PRODUCT_BUNDLE_IDENTIFIER → your App ID,
#                   MUSICSYNQ_SERVER_URL      → your server, e.g. https://musicsynq.fly.dev
xcodegen
open MusicSynq.xcodeproj
```

In Xcode, select the **MusicSynq** target → **Signing & Capabilities** → pick your team. Then run it on your iPhone. To get it onto a friend's phone, use **TestFlight** (Product → Archive → Distribute). You can also change the server address in the app, on the sign-in screen.

> Testing at home with the server on your Mac: use your Mac's local IP, e.g. `http://192.168.1.20:8080`, and keep both phones on the same Wi-Fi.

## Using it

- **Friends tab:** search for a username, add them, and accept their request. Your own username is at the top, ready to share.
- **Listen tab:** **Start a party**, then play anything in Apple Music. The **Pick songs in Apple Music** button jumps there. Your code is at the top; share it, or approve people as they ask.
- **Guests:** tap a friend's party → enter the code, or ask to join. A status pill shows *In sync* (with the current offset), *Loading*, or why a song can't play (e.g. not available in your country).
- **Settings → Keep syncing in the background** (on by default) keeps the party running while your phone is locked or you're in the Music app.

## Things to know

- **I couldn't compile the iOS app.** It was written without access to a Mac or Xcode. The shared `MusicSynqKit` package *was* built and tested (on Linux, Swift 6.1). That includes the models, the API client against the real server, and all the sync logic. The SwiftUI/MusicKit layer in `ios/MusicSynq` has been reviewed carefully but never compiled. Expect a few small fixes on the first build.
- **Background syncing plays silence.** iOS suspends apps a few seconds after you leave them. During a party, MusicSynq keeps itself alive by playing silent audio mixed with your music. That's fine for personal use and TestFlight, but App Store review may reject it. You can turn it off in Settings, and then keep MusicSynq open during a party.
- **What syncs:** the current song, play/pause, position (seeks, ±15s, scrubbing), and track changes. Guests don't copy the host's queue; each new song loads when the host starts it, so expect a second or so of gap between songs.
- **Accuracy:** usually within half a second, depending on network jitter. That's close enough to talk about the song on a call, not sample-accurate.
- **Songs a guest can't play:** a song missing from the guest's country's catalog, or a song the host uploaded to their own library, may not be found. The guest sees why and waits for the next song. Radio stations and music videos aren't supported.
- **Hosts must use the Apple Music app** on the same iPhone. Music playing on another device (Mac, HomePod, CarPlay source) isn't visible to MusicSynq.

## Server API (for reference)

REST endpoints take and return JSON. Errors look like `{ "error": { "code", "message" } }`. Send the session token as `Authorization: Bearer <token>`.

| | |
| --- | --- |
| `POST /auth/register`, `POST /auth/login`, `POST /auth/logout` | Accounts (`{ username, displayName, password }` → `{ token, user }`) |
| `GET/PATCH/DELETE /me` | Your profile; `DELETE` needs `{ password }` |
| `GET /users/search?q=` | Find people by username prefix |
| `GET /friends` | `{ friends, incoming, outgoing }` |
| `POST /friends/requests`, `POST /friends/requests/:id/accept`, `DELETE /friends/requests/:id`, `DELETE /friends/:userId` | Friend requests and unfriending |
| `POST /parties` | Start hosting (returns your code) |
| `GET /parties/current`, `GET /parties/friends` | Your party; friends' live parties |
| `POST /parties/join` `{ code }`, `POST /parties/:id/join` `{ code }` | Join with a code |
| `POST /parties/:id/requests`, `…/requests/:rid/approve`, `…/decline`, `DELETE …/requests/:rid` | Ask to join, and answer |
| `POST /parties/:id/leave`, `DELETE /parties/:id`, `PATCH /parties/:id`, `DELETE /parties/:id/members/:userId` | Leave, end, settings, remove a guest |
| `PUT /devices`, `DELETE /devices/:token` | Register for push |
| `GET /ws` | WebSocket; see `server/src/realtime/hub.js` and `ios/MusicSynqKit/Sources/MusicSynqKit/Messages.swift` |

## Development

```bash
cd server && npm test                       # server tests
cd ios/MusicSynqKit && swift test           # sync logic + protocol tests

# Run the Swift client against a live server too:
(cd server && npm start) &
cd ios/MusicSynqKit && MUSICSYNQ_SERVER_URL=http://127.0.0.1:8080 swift test
```

## License

GPL-3.0. See [LICENSE](LICENSE).
