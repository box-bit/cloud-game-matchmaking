# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AWS serverless multiplayer matchmaking engine using SAM (Serverless Application Model). Implements Phases 1-3 of a 5-phase roadmap: identity, player data, API Gateway, Lambda, and custom ELO-based matchmaking. GameLift/FlexMatch is not used — AWS Academy LabRole lacks the required permissions.

## Commands

### Deploy
```bash
sam deploy                    # Deploy stack (uses samconfig.toml)
sam deploy --guided           # First-time deploy, creates samconfig.toml
```

### Setup (run in order after deploy)
```bash
./scripts/create-cognito-test-users.sh   # Create test user in Cognito
./scripts/get-token.sh                   # Get JWT token, saves to .session/
./scripts/seed-test-players.sh           # Populate DynamoDB with test players
```

### Test
```bash
./scripts/tests/phase-1-tests.sh         # E2E tests for authentication and API
./scripts/tests/phase-3-tests.sh         # E2E tests for matchmaking
sam logs -n StartMatchmaking --tail      # Stream CloudWatch logs for debugging
sam logs -n MatchStatusPoller --tail     # Stream matchmaker run logs
```

### Verify DynamoDB
```bash
aws dynamodb scan --table-name PlayerProfiles
aws dynamodb scan --table-name MatchmakingTickets
```

## Architecture

**Request Flow:**
Client → Cognito (JWT) → API Gateway (`POST /match`) → Cognito Authorizer → Lambda → DynamoDB → Response

**AWS Resources (defined in template.yaml):**
- **Cognito UserPool**: `MatchmakingUserPool` - handles player authentication
- **API Gateway**: REST API with Cognito authorizer, stage: `dev`
  - `POST /match` - start matchmaking
  - `GET /match/{ticketId}` - poll match status
  - `DELETE /match/{ticketId}` - cancel matchmaking
- **Lambda Functions** (Python 3.12):
  - `StartMatchmaking` - reads player ELO, writes SEARCHING ticket to DynamoDB
  - `MatchStatusPoller` - EventBridge-scheduled (every 1 min), matches players by ELO
  - `GetMatchStatus` - returns ticket status for the authenticated owner
  - `CancelMatch` - marks a SEARCHING ticket as CANCELLED
- **DynamoDB Tables**:
  - `PlayerProfiles`: UserId (PK), ELO, Wins, Losses
  - `MatchmakingTickets`: TicketId (PK), UserId, Status, ELO, CreatedAt, MatchedPlayers, ServerIp, ServerPort, TTL (1h)
- **EC2**:
  - `GameServerInstance` - t3.micro Ubuntu 22.04, runs Red Eclipse dedicated server on boot (UDP 26000)
  - `GameServerSecurityGroup` - opens UDP 26000-26001 and TCP 22

**Matchmaking flow:**
1. `StartMatchmaking` writes ticket (Status=SEARCHING, ELO, CreatedAt) to DynamoDB
2. `MatchStatusPoller` runs every minute, scans SEARCHING tickets, pairs players by ELO
3. ELO tolerance expands over time: ±200 (0–60s) → ±400 (60–120s) → ±800 (120s+)
4. Matched tickets are updated to SUCCEEDED with ServerIp, ServerPort, and MatchedPlayers
5. Tickets searching >300s are marked TIMED_OUT
6. Client polls `GET /match/{ticketId}` until status is terminal (SUCCEEDED / CANCELLED / TIMED_OUT)

**Ticket statuses:** `SEARCHING` → `SUCCEEDED` | `TIMED_OUT` | `CANCELLED`

## Session Files

The `.session/` directory (gitignored) stores runtime artifacts:
- `api_url.txt` - API Gateway endpoint
- `id_token.txt` - JWT token for authenticated requests
- `sub.txt` - Cognito user subject ID

Scripts depend on these files. Re-run `get-token.sh` if tokens expire.

## Development Status

- **Phase 1-2**: Complete (identity, API, Lambda, DynamoDB)
- **Phase 3**: Complete (custom ELO matchmaker, EventBridge scheduler, EC2 game server, ticket CRUD API)
- **Phase 4**: TODO - EC2 orchestration (dynamic session allocation via Lambda→EC2 API instead of static IP)
- **Phase 5**: TODO - push notifications to players on match completion

## Budget Notes

Project has a $50 budget. The EC2 t3.micro instance (~$0.01/hr) runs continuously while the stack is deployed. Stop or terminate it when not testing to save costs.
