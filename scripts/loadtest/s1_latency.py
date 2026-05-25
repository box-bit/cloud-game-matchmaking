#!/usr/bin/env python3
"""S1 — API latency floor.

Straightforward, dependency-free load test:

  1. create  — create N Cognito users (per config.json), idempotently
  2. run     — log them all in (in parallel), then hammer GET /profile from
               `concurrency_levels` parallel virtual users and record latencies

Uses only the Python standard library plus the `aws` CLI (already configured by
the other scripts in this repo). No venv, no pip installs.

    ./s1_latency.py create          # make the users once
    ./s1_latency.py run             # run the latency sweep
    ./s1_latency.py all             # create then run

Output: runs/s1-<N>/requests.csv (one row per request) + a printed percentile
summary per concurrency level.
"""
from __future__ import annotations

import argparse
import csv
import http.client
import json
import shutil
import statistics
import subprocess
import sys
import time
import urllib.parse
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
CONFIG_PATH = HERE / "config.json"
RUNS_DIR = HERE / "runs"


# ── helpers ──────────────────────────────────────────────────────────────────

def load_config() -> dict:
    cfg = json.loads(CONFIG_PATH.read_text())
    cfg.setdefault("num_users", 100)
    if cfg["num_users"] < max(cfg["concurrency_levels"]):
        sys.exit(
            f"config error: num_users ({cfg['num_users']}) must be >= the largest "
            f"concurrency level ({max(cfg['concurrency_levels'])})"
        )
    return cfg


def check_prerequisites() -> None:
    """Fail early and clearly if the environment can't run the test."""
    if shutil.which("aws") is None:
        sys.exit(
            "error: the 'aws' CLI is not on PATH.\n"
            "This script drives Cognito/CloudFormation through the same aws CLI the\n"
            "repo's other scripts use. Install it and configure credentials\n"
            "(your AWS Academy lab credentials), then re-run."
        )


def aws(*args: str) -> dict:
    """Run an `aws` CLI command with --output json and return the parsed result.
    Raises with stderr on failure."""
    proc = subprocess.run(
        ["aws", *args, "--output", "json"],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"aws {' '.join(args)} failed:\n{proc.stderr.strip()}")
    return json.loads(proc.stdout) if proc.stdout.strip() else {}


def stack_outputs(stack_name: str) -> dict[str, str]:
    data = aws("cloudformation", "describe-stacks", "--stack-name", stack_name)
    outs = data["Stacks"][0].get("Outputs", [])
    return {o["OutputKey"]: o["OutputValue"] for o in outs}


def email_for(cfg: dict, i: int) -> str:
    return cfg["email_pattern"].format(i=i)


def extract_sub(attributes: list[dict]) -> str:
    """Pull the Cognito 'sub' (the PlayerProfiles partition key) out of a list
    of {Name, Value} attribute dicts."""
    for a in attributes:
        if a["Name"] == "sub":
            return a["Value"]
    raise RuntimeError("no 'sub' attribute on Cognito user")


# ── create users ─────────────────────────────────────────────────────────────

def create_users(cfg: dict, outs: dict[str, str]) -> None:
    # Admin-create instead of self sign-up: no verification email is sent, so we
    # don't hit Cognito's default ~50 emails/day account limit when creating
    # hundreds of test users. SUPPRESS skips the invite mail, email_verified=true
    # + a permanent password make the account immediately usable for
    # USER_PASSWORD_AUTH.
    pool_id = outs["UserPoolId"]
    player_table = outs["PlayerTableName"]
    password = cfg["password"]
    created = skipped = 0

    print(f"\n[create] ensuring {cfg['num_users']} Cognito users + PlayerProfiles "
          f"exist (pattern '{cfg['email_pattern']}', no emails sent)…")
    for i in range(cfg["num_users"]):
        email = email_for(cfg, i)
        existed = False
        try:
            resp = aws("cognito-idp", "admin-create-user",
                       "--user-pool-id", pool_id,
                       "--username", email,
                       "--message-action", "SUPPRESS",
                       "--user-attributes",
                       f"Name=email,Value={email}", "Name=email_verified,Value=true")
            sub = extract_sub(resp["User"]["Attributes"])
        except RuntimeError as e:
            if "UsernameExistsException" not in str(e):
                raise
            existed = True
            info = aws("cognito-idp", "admin-get-user",
                       "--user-pool-id", pool_id, "--username", email)
            sub = extract_sub(info["UserAttributes"])
        # Always set a permanent password. For new users this makes the account
        # usable; for users that already exist (including any left UNCONFIRMED by
        # an earlier sign-up flow) a permanent password flips them to CONFIRMED —
        # so re-running `create` heals broken accounts instead of skipping them.
        aws("cognito-idp", "admin-set-user-password",
            "--user-pool-id", pool_id,
            "--username", email,
            "--password", password,
            "--permanent")
        # Seed the PlayerProfiles row keyed by the Cognito sub, otherwise
        # GET /profile returns 404 ("Player profile not found"). Idempotent.
        item = {
            "UserId": {"S": sub},
            "Username": {"S": email},
            "ELO": {"N": "1000"},
            "Wins": {"N": "0"},
            "Losses": {"N": "0"},
        }
        aws("dynamodb", "put-item",
            "--table-name", player_table,
            "--item", json.dumps(item))
        skipped += existed
        created += not existed
        if (i + 1) % 25 == 0:
            print(f"  …{i + 1}/{cfg['num_users']}")

    print(f"users ready: {created} created, {skipped} already existed (all CONFIRMED)")


# ── login ────────────────────────────────────────────────────────────────────

def login(cfg: dict, client_id: str, i: int) -> str:
    """InitiateAuth for one user, return its IdToken."""
    res = aws("cognito-idp", "initiate-auth",
              "--client-id", client_id,
              "--auth-flow", "USER_PASSWORD_AUTH",
              "--auth-parameters",
              f"USERNAME={email_for(cfg, i)},PASSWORD={cfg['password']}")
    return res["AuthenticationResult"]["IdToken"]


def login_all(cfg: dict, client_id: str, count: int) -> list[str]:
    """Log in `count` users in parallel; return their tokens (index-aligned)."""
    print(f"\n[login] authenticating {count} users in parallel "
          f"(one InitiateAuth each, JWT reused for the run)…")
    t0 = time.perf_counter()
    tokens: list[str | None] = [None] * count
    done = 0
    with ThreadPoolExecutor(max_workers=min(count, 50)) as pool:
        futures = {pool.submit(login, cfg, client_id, i): i for i in range(count)}
        for fut in as_completed(futures):
            tokens[futures[fut]] = fut.result()
            done += 1
            if done % 25 == 0 or done == count:
                print(f"  …{done}/{count} logged in")
    got = [t for t in tokens if t]
    print(f"[login] got {len(got)} tokens in {time.perf_counter() - t0:.1f}s")
    return got


# ── load generation ──────────────────────────────────────────────────────────

def virtual_user(url: str, token: str, deadline: float, interval: float) -> list[tuple]:
    """One VU: GET /profile every `interval` seconds until `deadline`.
    Returns rows of (iso_ts, latency_ms, status_code).

    Uses ONE keep-alive connection for the whole run instead of a fresh TLS
    handshake per request — otherwise, at high VU counts, the client's own
    connection churn dominates the latency and we'd be measuring the laptop,
    not the API. A real client reuses its connection too, so this is also more
    representative of the floor we're after.
    """
    parsed = urllib.parse.urlparse(url)
    path = parsed.path or "/"
    headers = {"Authorization": f"Bearer {token}", "Connection": "keep-alive"}
    conn_cls = (http.client.HTTPSConnection if parsed.scheme == "https"
                else http.client.HTTPConnection)
    conn = conn_cls(parsed.netloc, timeout=30)

    rows = []
    while time.time() < deadline:
        t0 = time.perf_counter()
        try:
            conn.request("GET", path, headers=headers)
            resp = conn.getresponse()
            resp.read()                      # must drain so the conn is reusable
            status = resp.status
        except Exception:
            status = 0
            conn.close()                     # connection is suspect; rebuild it
            conn = conn_cls(parsed.netloc, timeout=30)
        latency_ms = (time.perf_counter() - t0) * 1000
        rows.append((datetime.now(timezone.utc).isoformat(), round(latency_ms, 2), status))
        # constant pacing: aim for one request per `interval`, regardless of latency
        time.sleep(max(0.0, interval - (time.perf_counter() - t0)))
    conn.close()
    return rows


def run_level(cfg: dict, url: str, tokens: list[str], n: int) -> None:
    run_dir = RUNS_DIR / f"s1-{n}"
    run_dir.mkdir(parents=True, exist_ok=True)
    duration = cfg["duration_seconds"]
    interval = cfg["request_interval_seconds"]

    expected = n * (duration // interval)
    print(f"\n=== {n} VUs for {duration}s (1 request / {interval}s each) ===")
    print(f"  GET {url}")
    print(f"  ~{expected} requests expected; finishes ~"
          f"{datetime.now(timezone.utc).strftime('%H:%M:%S')}+{duration}s UTC")
    deadline = time.time() + duration
    all_rows: list[tuple] = []
    with ThreadPoolExecutor(max_workers=n) as pool:
        futures = [
            pool.submit(virtual_user, url, tokens[i], deadline, interval)
            for i in range(n)
        ]
        for fut in as_completed(futures):
            all_rows.extend(fut.result())
    print(f"  done — collected {len(all_rows)} requests")

    csv_path = run_dir / "requests.csv"
    with csv_path.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["ts", "latency_ms", "status_code"])
        w.writerows(all_rows)

    summarise(all_rows, n, csv_path)


def summarise(rows: list[tuple], n: int, csv_path: Path) -> None:
    latencies = [r[1] for r in rows if r[2] == 200]
    errors = sum(1 for r in rows if r[2] != 200)
    if not latencies:
        print(f"  !! no successful requests ({errors} errors) — check auth/endpoint")
        return
    latencies.sort()

    def pct(p: float) -> float:
        return latencies[min(len(latencies) - 1, int(p / 100 * len(latencies)))]

    print(f"  requests={len(rows)} ok={len(latencies)} errors={errors}")
    print(f"  median={statistics.median(latencies):.1f}ms  "
          f"p95={pct(95):.1f}ms  p99={pct(99):.1f}ms  max={latencies[-1]:.1f}ms")
    print(f"  -> {csv_path.relative_to(HERE)}")


# ── entrypoint ───────────────────────────────────────────────────────────────

def main() -> None:
    ap = argparse.ArgumentParser(description="S1 API latency floor load test")
    ap.add_argument("command", choices=["create", "run", "all"],
                    help="create users / run sweep / both")
    args = ap.parse_args()

    check_prerequisites()
    cfg = load_config()
    print(f"[s1] command='{args.command}'  stack='{cfg['stack_name']}'")
    print(f"[s1] resolving stack outputs from CloudFormation…")
    outs = stack_outputs(cfg["stack_name"])
    print(f"[s1] API endpoint : {outs['ApiEndpoint']}")
    print(f"[s1] user pool    : {outs['UserPoolId']}")
    print(f"[s1] plan         : {cfg['num_users']} users, "
          f"levels {cfg['concurrency_levels']}, "
          f"{cfg['duration_seconds']}s each")

    if args.command in ("create", "all"):
        create_users(cfg, outs)

    if args.command in ("run", "all"):
        api_url = outs["ApiEndpoint"].rstrip("/")
        url = api_url + cfg["endpoint"]
        client_id = outs["UserPoolClientId"]
        # Log in enough users for the largest level once, then reuse per level.
        tokens = login_all(cfg, client_id, max(cfg["concurrency_levels"]))
        for n in cfg["concurrency_levels"]:
            run_level(cfg, url, tokens, n)
            time.sleep(5)  # brief cooldown between levels
        print("S1 sweep complete.")


if __name__ == "__main__":
    main()
