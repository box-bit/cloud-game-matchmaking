# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AWS serverless multiplayer matchmaking engine using SAM (Serverless Application Model). Currently implements Phases 1-2 of a 5-phase roadmap: identity, player data, API Gateway, and Lambda. Phase 3 (FlexMatch integration) is next.

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
sam logs -n StartMatchmaking --tail      # Stream CloudWatch logs for debugging
```

### Verify DynamoDB
```bash
aws dynamodb scan --table-name PlayerProfiles
```

## Architecture

**Request Flow:**
Client → Cognito (JWT) → API Gateway (`POST /match`) → Cognito Authorizer → Lambda → DynamoDB → Response

**AWS Resources (defined in template.yaml):**
- **Cognito UserPool**: `MatchmakingUserPool` - handles player authentication
- **API Gateway**: REST API with Cognito authorizer, stage: `dev`
- **Lambda**: `StartMatchmaking` (Python 3.12) - reads player profile, returns mock ticket
- **DynamoDB Tables**:
  - `PlayerProfiles`: UserId (PK), ELO, Wins, Losses
  - `MatchmakingTickets`: TicketId (PK) - for Phase 3+

**Lambda Handler** (`src/startMatchmaking/index.py`):
1. Extracts `sub` (user ID) from Cognito claims in `event["requestContext"]["authorizer"]["claims"]`
2. Queries PlayerProfiles table
3. Returns 404 if no profile, 200 with ELO and mock ticketId if found

## Session Files

The `.session/` directory (gitignored) stores runtime artifacts:
- `api_url.txt` - API Gateway endpoint
- `id_token.txt` - JWT token for authenticated requests
- `sub.txt` - Cognito user subject ID

Scripts depend on these files. Re-run `get-token.sh` if tokens expire.

## Development Status

- **Phase 1-2**: Complete (identity, API, Lambda, DynamoDB)
- **Phase 3**: TODO - FlexMatch integration (see `index.py:36` comment)
- **Phase 4**: TODO - GameLift fleet for game server hosting
- **Phase 5**: TODO - SNS notifications for match status

## Budget Notes

Project has a $50 budget. GameLift fleets (Phase 4) incur hourly charges - always delete fleets when not testing. Use Spot instances (70% cheaper).
