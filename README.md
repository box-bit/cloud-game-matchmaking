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

# Budget Notes

Budget: **$50**. The main cost while the stack is deployed is the EC2 instance(s) in the ECS cluster (~$0.01/hr per t3.micro). Lambda, API Gateway, and DynamoDB are negligible or free tier.

Run `sam delete` when not testing to stop all charges.

