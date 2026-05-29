# Cloud Game Matchmaking

AWS serverless multiplayer matchmaking engine for the Red Eclipse FPS. Players
authenticate with Cognito, submit matchmaking tickets through API Gateway, and
get paired by ELO via a scheduled Lambda. Matched groups are dropped onto a
Red Eclipse Docker container running on ECS, and the server's public
`IP:port` is written back into the ticket so the client can connect over UDP.

The whole stack is defined in `template.yaml` and deployed with one
`sam deploy`. GameLift / FlexMatch is **not** used — AWS Academy LabRole does
not have the necessary permissions, so the matchmaker is custom.

---

## Repository Layout

```
cloud-game-matchmaking/
├── template.yaml          SAM/CloudFormation — every AWS resource
├── samconfig.toml         sam deploy defaults (stack name, region, …)
├── src/                   Lambda function source (Python 3.12)
│   ├── startMatchmaking/      POST /match
│   ├── getMatchStatus/        GET  /match/{ticketId}
│   ├── cancelMatch/           DELETE /match/{ticketId}
│   ├── getProfile/            GET  /profile
│   ├── registerUser/          POST /register
│   └── matchStatusPoller/     EventBridge-scheduled matchmaker
├── game-server/           Red Eclipse Docker image (Dockerfile + entrypoint)
├── frontend/              Static HTML/JS lobby (deployed to S3)
├── scripts/               Setup / deploy / test utilities (see below)
│   ├── tests/                 Phase + group-matchmaking E2E tests
│   └── loadtest/              Python latency load-test (S1)
├── data/                  Seed JSON for PlayerProfiles
├── docs/                  Architecture deep-dive
└── .session/              Runtime artifacts: tokens, API URL, sub (gitignored)
```

---

## Required Tools

| Tool       | Purpose                                  |
|------------|------------------------------------------|
| AWS CLI    | Interact with AWS with CLI               |
| AWS SAM CLI| Build / deploy `template.yaml`            |
| Docker     | Build the Red Eclipse game-server image  |
| Python 3   | Run the load-test and inline JSON parsers|
| `jq` (optional) | Easier output inspection              |

---

# Launching the Project

The whole platform comes up in three layers:

1. **Infrastructure** — `sam deploy` (everything in `template.yaml`).
2. **Game server image** — build, push to ECR, then run the ECS warm pool.
3. **Frontend** — deploy the static lobby to S3.

Then optionally seed test users, get a token, and run any of the E2E tests.

> All scripts read CloudFormation outputs of the stack (`matchmaking-engine`)
> via `aws cloudformation describe-stacks`, so once the stack is deployed,
> nothing else needs to be hard-coded. The `AWS_REGION` defaults to whatever
> `aws configure get region` returns (or `us-east-1`).

## Step 0 — Configure AWS credentials

```bash
aws configure                       # or paste fresh creds into ~/.aws/credentials
aws sts get-caller-identity         # check for the credentials
```

## Step 1 — Deploy the AWS stack

First-time deploy creates `samconfig.toml`:

```bash
sam deploy --guided
#   Stack name:               matchmaking-engine
#   Region:                   us-east-1
#   Confirm changes:          Y
#   Allow SAM to create roles: Y
#   Save config:              Y
```

Re-deploys after that are just:

```bash
sam deploy
```

This creates: 
- Cognito user pool + client
- API Gateway with Cognito authorizer
- five Lambdas
- two DynamoDB tables
- the ECS cluster + Auto Scaling Group + capacity provider
- the ECR repository 
- the task definition
- the warm-pool ECS service
- EventBridge schedule
- CloudWatch log groups.

## Step 2 — Build and push the game-server image

The ECR repository (`redeclipse-server`) is created by the stack but starts
empty. ECS tasks will fail to start until an image is pushed.

```bash
./scripts/push-game-server.sh
```

This logs in to ECR, runs `docker build` against `game-server/`, tags the
image as `:latest`, and pushes it. Re-run this whenever you change
`game-server/Dockerfile` or `entrypoint.sh`.

## Step 3 — Scale the warm pool up

The ECS service `game-server-warm-pool` ships with desired-count = 0 so
nothing runs by accident. Bring it to 2 so two containers are always
idling and ready to host a match instantly:

```bash
aws ecs update-service \
  --cluster matchmaking-engine-game-servers \
  --service game-server-warm-pool \
  --desired-count 2
```

When you're done testing, set `--desired-count 0` (or `sam delete`) to stop
EC2 charges.

## Step 4 — Deploy the web frontend (optional but recommended)

```bash
./scripts/deploy-ui.sh
```

This creates a public-read S3 bucket
(`matchmaking-ui-<account-id>-<region>`), turns on static website hosting,
generates `frontend/config.js` from the stack outputs (so the SPA knows the
API URL and Cognito client ID), and uploads the contents of `frontend/`.

The script prints the public website URL when it finishes.

## Step 5 — Create a test user and grab a JWT

For ad-hoc curl / script use:

```bash
./scripts/create-cognito-test-users.sh      # one test user (testplayer@example.com)
./scripts/get-token.sh                      # writes .session/{id_token,sub,api_url}.txt
./scripts/seed-test-players.sh              # seeds PlayerProfiles for that user
```

Verify with:

```bash
aws dynamodb scan --table-name PlayerProfiles
aws dynamodb scan --table-name MatchmakingTickets
```

`./scripts/get-token.sh` re-runs in ~2s and is the fix for any
`401 Unauthorized` from API Gateway — Cognito ID tokens expire after 1 hour.

---

# Running the Tests

All test scripts live under `scripts/tests/` and assume the stack is
deployed. They write per-test artifacts under `.session/`.

| Script                                 | What it exercises                                                |
|----------------------------------------|------------------------------------------------------------------|
| `phase-1-tests.sh`                     | Auth + bare API (`/profile`, ticket CRUD)                        |
| `phase-3-tests.sh`                     | Custom ELO matchmaker, ticket lifecycle                          |
| `test-full-match.sh`                   | End-to-end happy path through `SUCCEEDED`                        |
| `setup-8player-test.sh`                | One-time: create 8 Cognito users (ELO 1200–1270) + seed profiles |
| `test-8player-matchmaking.sh`          | All 8 players queue in parallel → expect one shared server       |
| `test-ec2-gameserver-metrics.sh`       | Smoke-test the game server container and ECS port mapping        |

Typical run for the group-matchmaking story:

```bash
./scripts/tests/setup-8player-test.sh        # ~10s, idempotent
./scripts/tests/test-8player-matchmaking.sh  # ~1–2 min
```

Streaming Lambda logs while a test runs:

```bash
sam logs -n StartMatchmaking --tail
sam logs -n MatchStatusPoller --tail
```

> **Note:** `scripts/tests/DO_NOT_USE/` contains older 40-player setup +
> matchmaking scripts kept for reference. They are not maintained — prefer
> the 8-player path above.

## Load test (Scenario 1 — API latency floor)

A pure-stdlib Python script that creates N Cognito users, logs them all in,
then hammers `GET /profile` at several concurrency levels and writes a CSV
of per-request latencies.

```bash
cd scripts/loadtest
./s1_latency.py create     # idempotent — create the test users once
./s1_latency.py run        # log them in, run the latency sweep, write CSVs
./s1_latency.py all        # create then run
```

Configuration (number of users, concurrency levels, duration) lives in
`scripts/loadtest/config.json`. Output goes to `scripts/loadtest/runs/`. See
`scripts/loadtest/README.md` for the full breakdown.

## Tearing it all down

```bash
aws ecs update-service \
  --cluster matchmaking-engine-game-servers \
  --service game-server-warm-pool \
  --desired-count 0       # stop EC2 charges immediately

sam delete                # remove the whole stack when fully done
```

---



