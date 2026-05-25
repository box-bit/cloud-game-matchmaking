# Load Test — Scenario 1 (API latency floor)

Measures the latency floor of the JWT-protected read path (`GET /profile`) with
no matchmaking traffic — S1 from `load-test-prd.md`.

One Python file, standard library only, plus the `aws` CLI the other scripts in
this repo already use. **No venv, no pip installs.**

## Files

```
scripts/loadtest/
├── s1_latency.py     # create users, parallel login, hammer /profile, write CSV
├── config.json       # how many users, concurrency levels, duration, interval
└── runs/             # gitignored output
```

## Prerequisites

- A deployed stack and configured AWS credentials (the same setup the repo's
  other scripts assume — `aws` CLI on PATH).
- Python 3.

## Configure (`config.json`)

```json
{
  "stack_name": "matchmaking-engine",
  "num_users": 100,
  "password": "TestPass123",
  "email_pattern": "loadtest+{i}@example.com",
  "endpoint": "/profile",
  "concurrency_levels": [10, 50, 100],
  "duration_seconds": 300,
  "request_interval_seconds": 5
}
```

`num_users` must be ≥ the largest concurrency level (each virtual user gets its
own account so no two share a JWT).

## Run

```bash
cd scripts/loadtest

./s1_latency.py create     # create the Cognito users once (idempotent)
./s1_latency.py run        # log them in (parallel) + run the latency sweep
./s1_latency.py all        # create then run
```

The script resolves the API URL and Cognito client/pool ids from the
CloudFormation stack outputs (`ApiEndpoint`, `UserPoolClientId`, `UserPoolId`),
so there's nothing to paste in.

## Output

Per concurrency level it writes `runs/s1-<N>/requests.csv` (one row per request:
`ts, latency_ms, status_code`) and prints a summary:

```
=== 50 VUs for 300s (1 request / 5s each) ===
  logging in 100 users in parallel…
  requests=3000 ok=2998 errors=2
  median=42.1ms  p95=88.0ms  p99=131.4ms  max=540.2ms
  -> runs/s1-50/requests.csv
```

## How it works

1. **create** — signs up `num_users` Cognito accounts and admin-confirms them;
   accounts that already exist are skipped, so it's safe to re-run.
2. **run** — logs in the users in parallel (one `InitiateAuth` each), then for
   each concurrency level spins up that many threads, each issuing
   `GET /profile` every `request_interval_seconds` for `duration_seconds`, and
   records every request's latency.
