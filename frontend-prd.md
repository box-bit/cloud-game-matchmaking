# Product Requirements Document — Matchmaking Web UI

**Project:** Cloud Game Matchmaking — Web Frontend
**Author:** Hogigo
**Status:** Draft
**Last updated:** 2026-05-23

---

## 1. Overview

Add a browser-based user interface on top of the existing AWS matchmaking backend. Today, the system only exposes REST/CLI access — players must run shell scripts to authenticate, request a match, and poll for results. This project delivers a public, browser-accessible UI that lets a player log in, see their profile, request a match, and receive the game server connection details, all without touching the command line.

The UI is the missing front-end layer for the matchmaking engine described in `CLAUDE.md`. It does **not** replace the backend; it consumes the existing Cognito + API Gateway + Lambda + DynamoDB stack.

---

## 2. Background

The current system (Phases 1–3 complete) provides:

- Cognito-based authentication (JWT tokens)
- REST API: `POST /match`, `GET /match/{ticketId}`, `DELETE /match/{ticketId}`
- ELO-based matchmaker that pairs players every 60 seconds
- A single EC2 Red Eclipse game server players connect to once matched

Players today must use `scripts/get-token.sh` and `curl` to interact with the system. This is not viable for any non-technical user and makes demonstrating the system difficult.

---

## 3. Goals

**In scope:**

- Browser-accessible login flow (via Cognito Hosted UI)
- View own player profile (ELO, wins, losses)
- Click a button to start matchmaking
- See real-time-ish status while searching (polling is acceptable)
- Cancel an in-progress search
- See game server IP/port when matched, with instructions for connecting via Red Eclipse
- Can connect to the game, that will be represented by a dummy page with button leave game
- Logout
- Hosted on AWS, **publicly reachable from any browser on the internet** via either a CloudFront HTTPS URL (preferred) or, as a fallback, a public S3 website endpoint / public IP — no VPN, IP allow-list, or AWS console login required to access it

**Out of scope (deferred):**

- Chess game UI or any in-browser gameplay (covered in `CHESS_DESIGN.md`)
- Player registration flow (test users are created via CLI script for now)
- Profile editing
- Friend lists, lobbies, chat
- Match history / game logs
- Mobile-optimized UI (desktop-only is acceptable for v1)
- Custom domain (the CloudFront default domain is fine)

---

## 4. Target Users

| Persona | Description | Primary need |
|---|---|---|
| **Developer / demo viewer** | Reviewing the project as a portfolio piece or class submission | Click around end-to-end without reading shell scripts |
| **Game player** | Wants to find an opponent and join a Red Eclipse server | Log in → click "Find Match" → get server IP |

---

## 5. User Stories

1. As a player, I can **log in** with my Cognito credentials from a web browser, so I don't need any CLI tools.
2. As a player, I can **see my ELO, wins, and losses** when I log in, so I understand my matchmaking context.
3. As a player, I can **click a "Find Match" button** to start searching for an opponent.
4. As a player, I can **see that the system is searching** (loading state) and approximately how long I've been waiting.
5. As a player, I can **cancel my search** if I no longer want to wait.
6. As a player, I am **notified when a match is found** and shown the game server IP and port to connect to.
7. As a player I can **leave the game** I connected to.
7. As a player, I can **log out** to clear my session.

---

## 6. Functional Requirements

### 6.1 Authentication

- The UI MUST redirect unauthenticated users to the Cognito Hosted UI for login
- After successful login, Cognito MUST redirect back to the UI with a JWT in the URL fragment
- The UI MUST parse and persist the JWT in `sessionStorage` for the duration of the browser session
- All API calls MUST include the JWT as `Authorization: Bearer <token>`
- Expired tokens MUST trigger a re-login flow
- A "Logout" action MUST clear the local session and redirect to Cognito's logout endpoint

### 6.2 Lobby Screen

- MUST display the player's `ELO`, `Wins`, and `Losses` values fetched from `GET /profile`
- MUST display a primary "Find Match" button
- MUST display a "Logout" link
- SHOULD display the player's username/email for confirmation of identity

### 6.3 Search Screen

- Triggered when the player clicks "Find Match"
- MUST call `POST /match` and store the returned `ticketId`
- MUST poll `GET /match/{ticketId}` every 3–5 seconds
- MUST display a loading indicator and elapsed-time counter
- MUST display a "Cancel" button that calls `DELETE /match/{ticketId}`
- On `SUCCEEDED` status, MUST transition to the Match Found screen
- On `TIMED_OUT` or `CANCELLED` status, MUST return to the Lobby with a clear message

### 6.4 Match Found Screen

- MUST display the `ServerIp` and `ServerPort` from the ticket
- MUST display the list of matched players
- MUST display instructions for connecting via Red Eclipse (server address, port, link to download client)
- MUST provide a "Connect to Game" button that transitions to the Game Session screen
- MUST provide a "Return to Lobby" button

### 6.5 Game Session Screen (dummy)

- Represents the player being "in the game" — a placeholder until real gameplay is integrated
- MUST display the matched server address and opponent(s)
- MUST provide a "Leave Game" button that returns the player to the Lobby
- Out of scope: actual gameplay rendering, score tracking, ELO updates

### 6.6 Error Handling

- Network errors MUST show a user-friendly message with a "Retry" option
- 401 responses MUST trigger a re-login flow
- 4xx/5xx responses from the API MUST show the error message (when safe) and offer to return to the lobby

---

## 7. Non-Functional Requirements

| Category | Requirement |
|---|---|
| **Availability** | Best-effort, no SLA |
| **Public reachability** | The UI URL (CloudFront domain, public IP, or custom domain) MUST be reachable from any internet-connected browser without authentication on the AWS console, VPN, or IP allow-list |
| **Performance** | UI MUST load in under 3 seconds on a typical broadband connection |
| **Security** | All traffic over HTTPS; JWT stored in `sessionStorage` (not `localStorage`) |
| **Browser support** | Latest Chrome, Firefox, Safari, Edge. No IE support |
| **Cost** | MUST stay within AWS Free Tier at testing scale; total monthly cost < $5 |
| **Accessibility** | Basic keyboard navigation works; semantic HTML; not WCAG-certified |

---

## 8. Technical Design

### 8.1 Architecture

```
┌──────────────────────┐
│   User's Browser     │  ← UI runs HERE, not on AWS
└──────────┬───────────┘
           │ HTTPS
           ▼
┌──────────────────────┐
│   CloudFront (CDN)   │
└──────────┬───────────┘
           ▼
┌──────────────────────┐
│    S3 Bucket         │  ← static HTML/CSS/JS
└──────────────────────┘

Browser also calls directly:
┌──────────────┐   ┌──────────────┐
│   Cognito    │   │ API Gateway  │
│  Hosted UI   │   │  REST API    │
└──────────────┘   └──────────────┘
```

The UI executes in the user's browser. AWS resources only **store and serve** the static files and back-end APIs — there is no UI process running on EC2 or in Lambda.

### 8.2 Hosting

- **S3 bucket** in `us-east-1` for static files (`index.html`, compiled JS modules, CSS)
- **CloudFront distribution** in front of the bucket for HTTPS + CDN
- Origin Access Control (OAC) restricts direct S3 access; only CloudFront can read
- The CloudFront-issued domain (e.g. `https://d1234abcd.cloudfront.net`) MUST be the **public entry point** — accessible from any browser on the open internet without further authentication on AWS
- If CloudFront cannot be created in the target AWS account (e.g. AWS Academy LabRole), the fallback is the **S3 public website endpoint** (`http://<bucket>.s3-website-us-east-1.amazonaws.com`) — still publicly reachable, but HTTP-only
- A custom domain via Route 53 is OPTIONAL and out of scope for v1

### 8.3 Tech Stack

| Layer | Choice | Rationale |
|---|---|---|
| Markup | Plain HTML5 | No build step |
| Styles | Pico.css (CDN) | Minimal, semantic, zero config |
| Logic | Vanilla TypeScript | No npm, no webpack, easy to read |
| Auth | Cognito Hosted UI (OAuth implicit flow) | Zero auth code; AWS hosts the login page |
| API client | `fetch()` | Built into the browser |

A framework (React, Vue) is explicitly avoided for v1 to keep the build/deploy story simple. If the project later grows (chess UI, etc.), a framework migration is acceptable.

### 8.4 Backend Additions Required

| Change | Why |
|---|---|
| Add `GET /profile` endpoint + `GetProfile` Lambda | UI needs to display ELO/wins/losses |
| Add CORS configuration to API Gateway | Browser blocks cross-origin calls without it |
| Configure Cognito User Pool Client for Hosted UI | Enable browser-based OAuth flow |
| Add S3 bucket and CloudFront distribution to `template.yaml` | Host the UI |

### 8.5 Frontend File Layout

The frontend is organized by **single responsibility** — one file per concern. TypeScript modules are compiled to ES modules and loaded with `<script type="module">`; a minimal `tsc` step is the only build tooling.

```
frontend/
├── index.html              # Entry point — DOM skeleton + view containers
├── styles.css              # All styles
└── src/
    ├── main.ts             # Bootstraps the app + view router
    ├── config.ts           # API base URL, Cognito IDs, polling interval
    ├── auth.ts             # JWT storage + Cognito Hosted-UI login/logout
    ├── api.ts              # All API calls (profile, match)
    ├── state.ts            # State machine + subscribers
    ├── utils.ts            # DOM + formatting helpers
    └── views/
        ├── login.ts        # Login screen
        ├── lobby.ts        # Profile + "Find Match"
        ├── search.ts       # Polling + "Cancel"
        ├── matchFound.ts   # Server IP/port + "Connect to Game"
        └── gameSession.ts  # Dummy in-game page + "Leave Game"
```

#### Responsibility Map

| File | Owns |
|---|---|
| `config.ts` | Endpoint URLs and constants |
| `auth.ts` | JWT session + Cognito URLs |
| `api.ts` | All HTTP calls to the backend |
| `state.ts` | App state + transitions (LOGGED_OUT → LOBBY → SEARCHING → FOUND → IN_GAME) |
| `main.ts` | Wiring + showing the right view for the current state |
| `views/*.ts` | One screen each — rendering and event handlers |
| `utils.ts` | Pure helpers (DOM shortcuts, time formatting) |

#### Navigation Rules

- **Views never call `fetch()` directly** — they go through `api.ts`.
- **Views never mutate state directly** — they call `state.ts` and subscribe to changes.
- **No view imports another view** — navigation flows through `state.ts` → `main.ts`.
- **Dependency direction:** `views → state → api → utils`. No cycles.

Adding a new screen later (e.g. chess) is a single new file in `views/` plus any new endpoint added to `api.ts`.

### 8.6 State Machine (Frontend)

```
LOGGED_OUT ──[login]──▶ LOBBY
LOBBY ──[find match]──▶ SEARCHING
SEARCHING ──[succeeded]──▶ FOUND
SEARCHING ──[cancel]──▶ LOBBY
SEARCHING ──[timeout]──▶ LOBBY
FOUND ──[connect]──▶ IN_GAME
FOUND ──[return]──▶ LOBBY
IN_GAME ──[leave]──▶ LOBBY
LOBBY ──[logout]──▶ LOGGED_OUT
```

---

## 9. Components

### 9.1 New AWS Resources

| Resource | Purpose | Cost estimate |
|---|---|---|
| S3 bucket (`matchmaking-ui`) | Static hosting | < $0.01/mo |
| CloudFront distribution | HTTPS + CDN | Free tier covers it |
| Cognito User Pool Client (update) | Enable Hosted UI | $0 |
| Cognito Domain | Hosted UI URL | $0 |

### 9.2 New Backend Code

| Resource | Purpose |
|---|---|
| `src/getProfile/index.py` | Lambda returning the caller's ELO/wins/losses |
| `template.yaml` updates | New endpoint, CORS config, S3 + CloudFront, Cognito config |

### 9.3 New Frontend Code

See §8.5 for the full file layout. Top-level structure:

| Path | Purpose |
|---|---|
| `frontend/index.html` | Single HTML entry point with view containers |
| `frontend/styles.css` | All styles |
| `frontend/src/` | TypeScript modules — one file per concern, plus a `views/` folder for the five screens |

### 9.4 New Scripts

| Script | Purpose |
|---|---|
| `scripts/deploy-ui.sh` | `aws s3 sync frontend/ s3://<bucket>` + CloudFront invalidation |

---

## 10. Phased Plan

### Phase 1 — Backend Prep

- Add `GetProfile` Lambda and `GET /profile` endpoint
- Enable CORS on all REST endpoints in `template.yaml`
- Add Cognito Hosted UI configuration (domain, callback URLs, OAuth flows)
- Deploy with `sam deploy`

### Phase 2 — Frontend Development

- Create the `frontend/` directory following the layout in §8.5
- Implement state machine, router, five views, and the API/auth modules
- Test locally with `python3 -m http.server 8000` against the live API

### Phase 3 — Hosting Deployment

- Add S3 bucket + CloudFront distribution to `template.yaml`
- Add `scripts/deploy-ui.sh` for uploading files
- Update Cognito callback URL to include the CloudFront domain
- Re-deploy stack and upload UI
- Verify the CloudFront URL is reachable from a browser **outside the AWS console** (e.g. an incognito window or a different network)

### Phase 4 — End-to-End Testing

- Open the public URL in two browser windows (two test users)
- Both click "Find Match," wait for matchmaker, verify both see the same server IP
- Both click "Connect to Game" → land on the dummy in-game page → "Leave Game" returns to lobby
- (Optional) Download Red Eclipse and connect to verify the full loop

---

## 11. Success Metrics

- A new user can complete login → find match → receive server IP entirely in the browser, with zero CLI usage
- Two test players in two browser windows can be paired through the UI within 60 seconds
- The UI loads in under 3 seconds on a typical broadband connection
- No backend changes are required for chess (Phase 5 of `CHESS_DESIGN.md`) beyond what this PRD adds — the UI layer is reusable

---

## 12. Risks and Open Questions

| Risk / Question | Mitigation |
|---|---|
| **AWS Academy LabRole may not allow CloudFront creation** | Fallback: use S3 static website hosting only (HTTP). Test before committing to CloudFront. |
| **Cognito Hosted UI redirect URLs are case-sensitive and must match exactly** | Document the exact CloudFront URL in setup notes; configure both `https://` and `http://localhost:8000` during dev |
| **Polling `GET /match/{ticketId}` may be slow if the matchmaker hasn't run yet** | Set polling interval to 5s; accept up to a 60s wait by design (matchmaker runs every minute) |
| **CORS preflight failures are hard to debug** | Verify with `curl -X OPTIONS` after deploying CORS changes; include explicit `OPTIONS` test in `scripts/tests/` |
| **Should JWT be in `sessionStorage` or `localStorage`?** | `sessionStorage` for v1 — re-login per browser session is acceptable and reduces XSS risk |
| **Token expiry handling — silent refresh or force re-login?** | Force re-login for v1; refresh-token flow is a v2 enhancement |

---

## 13. Future Extensions

Once this PRD ships, the UI is the foundation for:

- **Chess matchmaking** (per `CHESS_DESIGN.md`) — adds in-browser gameplay
- **Match history page** — list past games, opponents, ELO changes
- **Live leaderboard** — top-ranked players
- **Multiple game types** — let the player choose between Red Eclipse and chess from the lobby
- **Push notifications via WebSocket** — replace polling

---

## 14. References

- `CLAUDE.md` — current backend architecture
- `CHESS_DESIGN.md` — future in-browser chess gameplay design
- `template.yaml` — existing SAM stack definition
