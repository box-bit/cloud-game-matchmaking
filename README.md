# Required tools
1. AWS CLI
2. AWS SAM CLI


# Steps to follow for setup
1. aws configure 
    - or you can copy-paste into $HOME/.aws/credentials the new credentials that aws gives you everytime you start a new session
2.  run `aws sts get-caller-identity`
    - to check that configure worked
4. sam deploy
    - if it is the first time deploying and samconfig.toml file doesn't exists
    - sam deploy --guided
```
# Stack name: matchmaking-engine
# Region: us-east-1
# Confirm changes: Y
# Allow SAM to create roles: Y
# Save config: Y  ← creates samconfig.toml, commit this file
```

5. run `./scripts/create-cognito-test-users.sh`
    - this will create an user in the cognito aws service
6. run `./scripts/get-token.sh`
    - this will retrieve the token related to the user created in cognito, everything will be found in the .session folder
7. run `./scripts/seed-test-players.sh`
    - run `aws dynamodb scan --table-name PlayerProfiles`
    - Check that table is now populated

8. `./scripts/tests/phase-3-tests.sh`
    - For a real match to complete you need two authenticated players submitting tickets
    - monitor with `sam logs -n MatchStatusPoller --tail`

9. Build and push the game server Docker image (requires the stack to be deployed first):
```bash
./scripts/push-game-server.sh
```

10. Run ./scripts/deploy-ui.sh to deploy minimalistic frontend
```bash
./scripts/deploye-ui.sh
```

12. Scale up the warm pool so 2 game server containers are always ready:
```bash
aws ecs update-service \
  --cluster matchmaking-engine-game-servers \
  --service game-server-warm-pool \
  --desired-count 2
```

---

# Architecture

## Overview

The system is serverless and event-driven. Players authenticate via Cognito, submit matchmaking tickets through API Gateway, and get paired by a scheduled Lambda that runs every minute. Once a match is found, a Red Eclipse game server container is allocated from the ECS cluster and its IP + port are written back to the ticket.

```
Client → Cognito (JWT) → API Gateway → Lambda → DynamoDB
                                                     ↓
                                       EventBridge (every 1 min)
                                                     ↓
                                       MatchStatusPoller Lambda
                                                     ↓
                                       ECS game server container
                                       (IP + port → ticket → client)
```

## API Endpoints

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| POST | `/register` | None | Create account |
| POST | `/match` | JWT | Start matchmaking |
| GET | `/match/{ticketId}` | JWT | Poll match status |
| DELETE | `/match/{ticketId}` | JWT | Cancel matchmaking |
| GET | `/profile` | JWT | Get player ELO and stats |

## Matchmaking Logic

The `MatchStatusPoller` Lambda runs every minute and scans all `SEARCHING` tickets. It pairs players by ELO using a tolerance that widens over time so players aren't stuck waiting forever:

| Wait time | ELO tolerance |
|-----------|--------------|
| 0–60s | ±200 |
| 60–120s | ±400 |
| 120s+ | ±800 |
| 300s+ | `TIMED_OUT` |

**Ticket statuses:** `SEARCHING` → `SUCCEEDED` \| `TIMED_OUT` \| `CANCELLED`

## Game Server Infrastructure (Phase 4)

Game servers run as Docker containers on EC2 instances managed by ECS. Multiple containers can fit on a single t3.micro (~5–6 per instance at 128 MB each).

```
ECS Cluster
└── Auto Scaling Group (1–2 × t3.micro)
    └── EC2 instance
        ├── Red Eclipse container  (host port: 32800/udp)
        ├── Red Eclipse container  (host port: 41200/udp)
        └── Red Eclipse container  (host port: 55000/udp)
```

**How port assignment works:** Each container uses `HostPort: 0` in the ECS task definition, so Docker assigns a random host UDP port from the range 32768–65535. After starting a container, the matchmaker calls `DescribeTasks` to read the assigned port and `DescribeInstances` to get the EC2 public IP.

**ECS resources:**

| Resource | Purpose |
|----------|---------|
| ECR `redeclipse-server` | Stores the Docker image |
| ECS Cluster | Schedules containers across EC2 instances |
| Auto Scaling Group | Adds/removes t3.micro instances as needed |
| Capacity Provider | Connects the ASG to ECS — ECS triggers scale-out when instances are full |
| Task Definition | Container blueprint: 128 MB RAM, UDP 26000, bridge network |
| ECS Service (warm pool) | Keeps N containers always running so allocation is instant |
| CloudWatch Log Group `/ecs/redeclipse-server` | Container stdout logs, 7-day retention |

**Game server container** (`game-server/`): Red Eclipse dedicated server in Docker (Ubuntu 22.04). Configured via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `MAX_PLAYERS` | 8 | Players per server |
| `TIME_LIMIT` | 600 | Match duration (seconds) |
| `FRAG_LIMIT` | 30 | Kills to end match |
| `SERVER_DESC` | stack name | Name shown in server browser |
| `SERVER_PUBLIC` | 0 | 0 = private, 1 = register with master server |

Mode is locked to `0` (deathmatch / free-for-all).

## DynamoDB Tables

**`PlayerProfiles`** — `UserId` (PK), `ELO`, `Wins`, `Losses`

**`MatchmakingTickets`** — `TicketId` (PK), `UserId`, `Status`, `ELO`, `CreatedAt`, `MatchedPlayers`, `ServerIp`, `ServerPort`, `TTL` (1 hour)

---

# Implementation Status

| Phase | Description | Status |
|-------|-------------|--------|
| 1 | Identity (Cognito), Player data (DynamoDB) | ✅ Complete |
| 2 | API Gateway + Lambda | ✅ Complete |
| 3 | Custom ELO matchmaker, ticket CRUD | ✅ Complete |
| 4 | ECS containerised game servers, dynamic session allocation | 🔧 In progress |
| 5 | Push notifications to players on match completion | ⬜ TODO |

---

# Group Matchmaking Tests

This section documents the multi-player matchmaking tests built during development. It explains every step that happens, every AWS component involved, and how they all interact — starting from creating test players all the way to receiving a game server address.

## Goal

Verify that when a group of players with similar skill levels all start matchmaking at the same time, they are correctly grouped together into **one shared game session** on a single server, rather than being scattered across multiple separate games.

Two test scenarios were built:
- **8-player test** — one group of 8 → one server
- **40-player test** — five groups of 8 → five servers

---

## AWS Components Used in These Tests

Before diving into steps, here is a plain-language description of every AWS service that participates.

| Component | What it is | Role in these tests |
|-----------|-----------|---------------------|
| **Amazon Cognito** | An identity service. Manages user accounts and issues login tokens. | Stores the 8 or 40 test player accounts. Issues JWT tokens that prove who each player is. |
| **Amazon API Gateway** | The front door of the system. Receives HTTP requests from clients and routes them to the right Lambda function. | Validates each request's JWT token before passing it to a Lambda. |
| **AWS Lambda** | A serverless function. Code that runs on demand without a dedicated server. There are four Lambda functions in this system. | `StartMatchmaking` creates a ticket; `GetMatchStatus` returns its status; `MatchStatusPoller` pairs players; `CancelMatch` cancels a ticket. |
| **Amazon DynamoDB** | A NoSQL database. Stores data as items (like rows) in tables (like spreadsheets), with no fixed schema. | Two tables: `PlayerProfiles` (stores ELO ratings) and `MatchmakingTickets` (tracks every player's queue status). |
| **Amazon EventBridge** | A scheduler and event bus. Can trigger a Lambda on a fixed schedule, like a cron job. | Triggers the `MatchStatusPoller` Lambda every 60 seconds to check for eligible groups. |
| **Amazon ECS** (Elastic Container Service) | A container orchestration service. Runs Docker containers on EC2 machines and manages their lifecycle. | Runs the Red Eclipse game server containers. Allocates one container per matched group. |
| **Amazon ECR** (Elastic Container Registry) | A private Docker image registry hosted on AWS. | Stores the `redeclipse-server` Docker image that ECS pulls when starting a new game server. |
| **Amazon EC2** (Elastic Compute Cloud) | Virtual machines in the cloud. | The physical compute backing the ECS cluster. Each t3.micro instance can host multiple game server containers simultaneously. |
| **Auto Scaling Group (ASG)** | Automatically adjusts the number of EC2 instances based on demand. | Keeps at least 1 EC2 instance running and scales to 2 when load increases. |
| **AWS CloudFormation / SAM** | Infrastructure-as-code. Defines all the resources above in a YAML file (`template.yaml`). SAM (Serverless Application Model) is a layer on top that simplifies Lambda and API Gateway definitions. | `sam deploy` reads `template.yaml` and creates or updates all the AWS resources in one command. |

---

## Step-by-Step: What Happens During a Test

### Step 1 — Creating Test Players (`setup-Xplayer-test.sh`)

Before any test can run, each player needs two things: a **Cognito account** (so they can log in) and a **DynamoDB profile** (so the matchmaker knows their ELO rating).

The setup script loops through every player and does the following for each one that does not already exist.

#### 1a. Check if the player already exists

```
Script → Cognito: AdminGetUser("match-40-5@example.com")
Cognito → Script: sub = "a1b2c3d4-..."   (or UserNotFoundException)
```

`AdminGetUser` is a Cognito admin API that looks up an account by username without sending any emails. If a sub (a unique user ID that Cognito assigns internally) is returned, the user exists.

If the user exists, the script then checks DynamoDB:

```
Script → DynamoDB: GetItem(PlayerProfiles, UserId = "a1b2c3d4-...")
DynamoDB → Script: { ELO: 1200, ... }   (or empty)
```

If **both** exist → the player is fully set up → **skip**, print `already exists`.

This check is the key optimization: on a re-run, fully set-up players cost only two fast read calls (~0.4 s each) instead of going through the full creation flow (~2 s).

#### 1b. Create a new player (if missing)

The old approach used `sign-up`, which causes Cognito to send a verification email. AWS Academy Learner Labs have a hard limit of about 50 verification emails per day per user pool — easy to exceed when creating 40 players. The solution is to bypass email entirely using the admin API:

```
Script → Cognito: AdminCreateUser(
    username = "match-40-5@example.com",
    email_verified = true,
    message_action = SUPPRESS      ← no email is sent
)
Cognito → Script: { User: { Attributes: [{ Name: "sub", Value: "a1b2c3d4-..." }] } }
```

`SUPPRESS` tells Cognito to skip the welcome email entirely. `email_verified = true` marks the address as already verified so the account is usable immediately.

The sub (user ID) comes back in this response — no need for a second API call.

```
Script → Cognito: AdminSetUserPassword(
    username = "match-40-5@example.com",
    password = "MatchTest123",
    permanent = true               ← user can log in immediately, no forced reset
)
```

Without `permanent = true`, Cognito would place the account in `FORCE_CHANGE_PASSWORD` state and refuse logins until the password is changed.

#### 1c. Seed the DynamoDB profile

```
Script → DynamoDB: PutItem(PlayerProfiles, {
    UserId:   "a1b2c3d4-...",
    Username: "match-40-5",
    ELO:      1230,
    Wins:     5,
    Losses:   3
})
```

`PutItem` is an upsert — it creates the item if it does not exist, or replaces it if it does.

The sub (from Cognito) is used as the primary key in DynamoDB. This is how the two services stay linked: Cognito owns authentication, DynamoDB owns game data, and the sub is the bridge between them.

#### What gets saved locally

After each player is processed, one line is appended to `.session/Xplayer/players.tsv`:

```
5   match-40-5@example.com   MatchTest123   a1b2c3d4-...   1230
```

This file is the local reference that the test script reads later to know which credentials to use for each player.

---

### Step 2 — Authentication: Getting a Token (`test-Xplayer-matchmaking.sh`)

Each test run starts by authenticating all players to get fresh **JWT tokens**. Tokens expire, so this happens every time.

#### What a JWT token is

A JWT (JSON Web Token) is a string of text — a digitally signed proof of identity. Think of it like a concert wristband: the venue (Cognito) puts it on your wrist and anyone who sees it (API Gateway) can confirm it is genuine without calling back to Cognito for every single request. It encodes who you are (your `sub`), when it was issued, and when it expires.

```
Script → Cognito: InitiateAuth(
    flow = USER_PASSWORD_AUTH,
    username = "match-40-5@example.com",
    password = "MatchTest123"
)
Cognito → Script: { IdToken: "eyJhbGc...", AccessToken: "...", ExpiresIn: 3600 }
```

The `IdToken` is the JWT that gets sent with every API request. It is valid for 1 hour.

The test script stores all 40 tokens in memory and uses the right one for each player's requests in the next steps.

---

### Step 3 — Submitting Matchmaking Tickets (`POST /match`)

Each player sends a `POST /match` request to API Gateway. For the 40-player test all 40 requests are fired in parallel as background shell jobs so they all land in DynamoDB at approximately the same time.

Here is the full journey of one request:

#### 3a. API Gateway receives the request

```
Player's HTTP client → API Gateway (POST /match)
                            │
                            │  Authorization: Bearer eyJhbGc...
                            ▼
                     Cognito Authorizer
```

API Gateway does not immediately pass the request to Lambda. First it hands the `Authorization` header to the **Cognito Authorizer** — a built-in validation step that:
1. Decodes the JWT token
2. Verifies the digital signature (using Cognito's public key)
3. Checks that the token has not expired
4. If valid, extracts the claims (the data baked into the token, including `sub`)

If the token is invalid or expired, API Gateway returns `401 Unauthorized` and the Lambda never runs.

#### 3b. StartMatchmaking Lambda runs

If the token is valid, API Gateway calls the `StartMatchmaking` Lambda and passes the claims along with the request.

```python
user_id = claims["sub"]                     # who is this player?
player = PlayerProfiles.get_item(user_id)   # look up their ELO
ticket_id = uuid4()                         # generate a unique ticket ID
MatchmakingTickets.put_item({
    TicketId:  ticket_id,
    UserId:    user_id,
    Status:    "SEARCHING",
    ELO:       player["ELO"],
    CreatedAt: now,
    TTL:       now + 3600              # DynamoDB will auto-delete after 1 hour
})
return { ticketId: ticket_id, status: "SEARCHING", elo: 1230 }
```

`CreatedAt` is stored as a Unix timestamp (seconds since 1970). The matchmaker uses it later to calculate how long each player has been waiting, which determines the ELO tolerance.

`TTL` (Time To Live) is a DynamoDB feature: any item with a TTL timestamp in the past is automatically deleted by DynamoDB in the background. This keeps the tickets table clean without any manual cleanup code.

After all 40 `POST /match` calls complete, the `MatchmakingTickets` table contains 40 items all with `Status = SEARCHING`.

---

### Step 4 — The MatchStatusPoller: Finding a Match

This is the heart of the system. The `MatchStatusPoller` Lambda is the function that looks at all the waiting players and decides who plays together.

#### 4a. How it gets triggered

**Amazon EventBridge** runs the Lambda every 60 seconds automatically, like a recurring alarm clock. The schedule is defined in `template.yaml`:

```yaml
Events:
  MatchmakerSchedule:
    Type: Schedule
    Properties:
      Schedule: rate(1 minute)
```

In the tests, instead of waiting up to 60 seconds for the automatic trigger, the test script invokes the Lambda directly:

```
Script → Lambda: Invoke("MatchStatusPoller", payload={})
```

This is a synchronous call — the script waits for the Lambda to finish before continuing.

#### 4b. Scanning for waiting players

The Lambda starts by reading every ticket with `Status = SEARCHING` from DynamoDB:

```
Lambda → DynamoDB: Scan(MatchmakingTickets,
    FilterExpression = "Status = SEARCHING"
)
```

A `Scan` reads the entire table and filters results. With 40 tickets it reads all 40 in one pass.

#### 4c. Timing out stale tickets

For each ticket, the Lambda checks its age:

```
age = now - ticket.CreatedAt
if age > 300 seconds:
    update ticket Status → TIMED_OUT
```

Players waiting more than 5 minutes are marked `TIMED_OUT` and removed from the active pool. This prevents players from waiting forever.

#### 4d. The sliding-window ELO matching algorithm

This is the algorithm that was updated during this session. The original system paired players **2 at a time**. It was changed to group **8 players at a time** so that a full game server is always filled.

**What is ELO?** ELO is a number that represents a player's skill level. A higher ELO means a better player. When two players of equal ELO play, each has a 50% chance of winning. The matchmaker tries to pair players with similar ELOs to keep games balanced.

**The algorithm, step by step:**

1. Sort all waiting tickets by ELO in ascending order (lowest skill first).
2. Take the first 8 tickets as a "window".
3. Measure the ELO spread of the window: `highest ELO − lowest ELO`.
4. Check if that spread is within the current tolerance (which depends on how long the oldest player in the window has been waiting):

| Time waiting | Tolerance |
|---|---|
| 0–60 seconds | ±200 ELO |
| 60–120 seconds | ±400 ELO |
| 120+ seconds | ±800 ELO |

5. If the spread fits within tolerance → **this group is a match**. Allocate a server and mark all 8 tickets as `SUCCEEDED`. Advance to the next 8 tickets.
6. If the spread is too large → the player with the lowest ELO in the window is too far from the others. Slide the window forward by one and try again. That player stays `SEARCHING` and will be reconsidered on the next poller run.

**Visual example with 8 players (ELO 1200–1270):**

```
Sorted tickets:
 P1    P2    P3    P4    P5    P6    P7    P8
1200  1210  1220  1230  1240  1250  1260  1270

Window [P1–P8]:
  spread = 1270 − 1200 = 70
  tolerance = 200  (all tickets just created)
  70 ≤ 200 → ✅ GROUP FORMED
```

All 8 players match immediately in one poller run.

**Visual example with 40 players (ELO 1200–1590):**

```
Sorted tickets:
P1–P8:   1200–1270  spread = 70  ≤ 200  → Group 1 ✅  (advance window by 8)
P9–P16:  1280–1350  spread = 70  ≤ 200  → Group 2 ✅
P17–P24: 1360–1430  spread = 70  ≤ 200  → Group 3 ✅
P25–P32: 1440–1510  spread = 70  ≤ 200  → Group 4 ✅
P33–P40: 1520–1590  spread = 70  ≤ 200  → Group 5 ✅
```

All 5 groups form in a single Lambda invocation.

The tolerance uses the **most lenient value** in the window: if even one player in the group has been waiting long enough to earn ±400 tolerance, the whole group benefits. This prevents a single long-waiting player from blocking a group from forming.

---

### Step 5 — Allocating a Game Server

Once a group of 8 is found, the Lambda must assign them a game server. The server is a **Docker container** running the Red Eclipse dedicated game server.

#### 5a. Checking the warm pool

Starting a brand-new container takes 10–20 seconds. To avoid this delay, an **ECS Service** called `game-server-warm-pool` keeps 2 containers always running — idling, waiting to be assigned to a match.

The Lambda first checks if any of these idle containers are free:

```
Lambda → ECS: ListTasks(cluster, desiredStatus=RUNNING)
Lambda → DynamoDB: Scan(MatchmakingTickets,
    FilterExpression = "Status = SUCCEEDED AND TaskArn exists"
)
```

The second call gets the list of containers already assigned to active matches. Any running container **not** in that list is idle and available.

If an idle container exists → use it immediately (fast path, no startup wait).

#### 5b. Starting a new container (if no idle ones available)

If all warm containers are in use, the Lambda launches a new ECS task:

```
Lambda → ECS: RunTask(
    cluster = "matchmaking-engine-game-servers",
    taskDefinition = "redeclipse-server"
)
```

ECS picks up the task definition, finds an EC2 instance with enough free RAM (128 MB), pulls the `redeclipse-server` Docker image from ECR, and starts the container.

The Lambda then polls every 2 seconds for up to 20 seconds waiting for the container to reach `RUNNING` state:

```
Lambda → ECS: DescribeTasks(taskArn)
ECS → Lambda: { lastStatus: "PENDING" }   wait 2s...
Lambda → ECS: DescribeTasks(taskArn)
ECS → Lambda: { lastStatus: "RUNNING" }   ← ready
```

#### 5c. Discovering the server's IP address and port

The game server container listens on UDP port 26000 **inside the container**. On the EC2 host, Docker maps this to a random port in the range 32768–65535. This random assignment is how multiple containers can run on the same machine without port conflicts.

The Lambda reads the assigned port from the ECS task description:

```
Lambda → ECS: DescribeTasks(taskArn)
ECS → Lambda: {
    containers: [{
        networkBindings: [{
            containerPort: 26000,
            hostPort: 47832,      ← the random UDP port assigned by Docker
            protocol: "udp"
        }]
    }],
    containerInstanceArn: "arn:aws:ecs:..."
}
```

Then it resolves the EC2 public IP:

```
Lambda → ECS: DescribeContainerInstances(containerInstanceArn)
ECS → Lambda: { ec2InstanceId: "i-0a1b2c3d4e5f" }

Lambda → EC2: DescribeInstances(instanceId)
EC2 → Lambda: { PublicIpAddress: "54.123.45.67" }
```

Now the Lambda has both pieces needed to connect: `54.123.45.67:47832`.

#### 5d. Updating all 8 tickets

The Lambda writes the server address to all 8 tickets at once using a conditional update:

```
Lambda → DynamoDB: UpdateItem(MatchmakingTickets, ticketId, {
    Status:         "SUCCEEDED",
    ServerIp:       "54.123.45.67",
    ServerPort:     47832,
    MatchedPlayers: ["sub-of-p1", "sub-of-p2", ..., "sub-of-p8"],
    TaskArn:        "arn:aws:ecs:..."
})
```

The condition `Status = SEARCHING` prevents a race condition: if two Lambda invocations happen to run at the same time, only one will successfully update the ticket. The other will see a `ConditionalCheckFailedException` and skip it.

All 8 players' tickets now point to the same server.

---

### Step 6 — Polling for Results (`GET /match/{ticketId}`)

The test script polls each ticket in parallel until it reaches a terminal status (`SUCCEEDED`, `TIMED_OUT`, or `CANCELLED`).

```
Test script → API Gateway: GET /match/{ticketId}
                                │
                            JWT validation (Cognito Authorizer)
                                │
                            GetMatchStatus Lambda
                                │
                  DynamoDB: GetItem(MatchmakingTickets, ticketId)
                                │
                            ownership check: ticket.UserId == caller's sub?
                            if not → 403 Forbidden
                                │
                            return ticket data
```

Once status is `SUCCEEDED`, the response includes the server address and the list of all matched players:

```json
{
  "ticketId": "abc123",
  "status": "SUCCEEDED",
  "serverIp": "54.123.45.67",
  "serverPort": 47832,
  "matchedPlayers": ["sub-p1", "sub-p2", "sub-p3", "sub-p4",
                     "sub-p5", "sub-p6", "sub-p7", "sub-p8"],
  "players": [
    { "userId": "sub-p1", "username": "match-40-1" },
    ...
  ]
}
```

The player's game client uses `serverIp:serverPort` to connect to the Red Eclipse server over UDP.

---

### Step 7 — The Game Server Container

When the container starts, `entrypoint.sh` runs inside it. It generates the Red Eclipse server configuration file from environment variables (set in the ECS task definition) and then launches the game server process:

```bash
# entrypoint.sh generates /home/redeclipse/.redeclipse/servinit.cfg
serverpass "$SERVER_PASS"
adminpass  "$ADMIN_PASS"
servertype $SERVERTYPE      # 1=private, 3=public
serverport $SERVER_PORT     # 26000 (inside the container)

sv_serverclients $MAX_PLAYERS   # 8
sv_serverdesc    "$SERVER_DESC"
sv_timelimit     $((TIME_LIMIT / 60))   # converted from seconds to minutes
sv_pointlimit    $FRAG_LIMIT

exec /usr/games/redeclipse-server -ss3
```

The values come from the `Environment` block in the ECS task definition in `template.yaml`:

```yaml
Environment:
  - Name: MAX_PLAYERS
    Value: "8"
  - Name: SERVER_DESC
    Value: !Sub "${AWS::StackName} server"
```

---

## Full Request Flow Diagram

```
 SETUP (once)
 ─────────────────────────────────────────────────────────────────
 Setup script
   → Cognito  AdminCreateUser  (no email, get sub immediately)
   → Cognito  AdminSetUserPassword  (mark as confirmed)
   → DynamoDB PutItem PlayerProfiles  (store ELO)

 TEST RUN
 ─────────────────────────────────────────────────────────────────
 Test script  [×8 or ×40 players]
   → Cognito  InitiateAuth  →  JWT token

 Test script  [×8 or ×40, in parallel]
   → API Gateway  POST /match  Bearer <JWT>
       → Cognito Authorizer  validates JWT  →  sub
       → Lambda StartMatchmaking
           → DynamoDB GetItem  PlayerProfiles      (read ELO)
           → DynamoDB PutItem  MatchmakingTickets  (Status=SEARCHING)
       ← 200 { ticketId, status: "SEARCHING" }

 Test script
   → Lambda  MatchStatusPoller  (direct invoke, skip 60s wait)
       → DynamoDB Scan  MatchmakingTickets  (all SEARCHING)
       → sort by ELO
       → sliding window of 8:
           if ELO spread ≤ tolerance → GROUP FORMED
               → ECS  ListTasks           (find idle container)
               → ECS  DescribeTasks       (get host port)
               → EC2  DescribeInstances   (get public IP)
               → DynamoDB UpdateItem ×8  (Status=SUCCEEDED, ip, port)
       → repeat for next 8 tickets

 Test script  [×8 or ×40, in parallel, every 3s]
   → API Gateway  GET /match/{ticketId}  Bearer <JWT>
       → Cognito Authorizer  validates JWT
       → Lambda GetMatchStatus
           → DynamoDB GetItem  MatchmakingTickets
       ← 200 { status: "SUCCEEDED", serverIp, serverPort, matchedPlayers }

 All players connect to the same serverIp:serverPort over UDP
```

---

## Test Scripts Reference

### 8-Player Test

Creates **8 players** (ELO 1200–1270). One group of 8 forms on the first poller run.

```bash
# One-time setup: create Cognito users and seed DynamoDB profiles
./scripts/tests/setup-8player-test.sh

# Run the test (can be repeated)
./scripts/tests/test-8player-matchmaking.sh
```

**Expected output:**
- All 8 players reach `SUCCEEDED` in round 1 of polling
- All 8 tickets show the same `serverIp:serverPort`
- `Groups formed: 1`, `Servers used: 1`

### 40-Player Test

Creates **40 players** (ELO 1200–1590, step 10). Five groups of 8 form, each on a separate server.

```bash
./scripts/tests/setup-40player-test.sh    # ~1 minute (40 Cognito + DynamoDB calls)
./scripts/tests/test-40player-matchmaking.sh
```

**Expected output:**
- All 40 players reach `SUCCEEDED`
- 5 different `serverIp:serverPort` combinations
- `Groups formed: 5`, `Servers used: 5`

**Why multiple Lambda invocations:** The warm pool keeps 2 containers ready. The first Lambda run handles the first 2 groups instantly using those warm containers, then starts new containers for groups 3–5. Starting a container takes up to 20 seconds. If the Lambda's 55-second timeout is reached before all 5 groups are served, the remaining `SEARCHING` tickets are picked up by the next invocation. The test script handles this automatically, invoking the Lambda up to 4 times and polling between each attempt.

### Setup script optimization: skipping existing players

Both setup scripts check DynamoDB before doing any creation work. The decision tree per player:

```
AdminGetUser(email)
    │
    ├── UserNotFoundException
    │       → AdminCreateUser (no email) + AdminSetUserPassword
    │       → DynamoDB PutItem
    │
    └── sub found
            │
            ├── DynamoDB GetItem → item found
            │       → SKIP (print "already exists")
            │
            └── DynamoDB GetItem → not found
                    → DynamoDB PutItem only  (Cognito already exists)
```

On a re-run where all players exist: ~0.4 s per player (2 read calls) instead of ~2 s (4 read+write calls). For 40 players this means ~16 s vs ~80 s.

---

# Budget Notes

Budget: **$50**. The main cost while the stack is deployed is the EC2 instance(s) in the ECS cluster (~$0.01/hr per t3.micro). Lambda, API Gateway, and DynamoDB are negligible or free tier.

Run `sam delete` when not testing to stop all charges.

