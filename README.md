# Required tools
1. AWS CLI
2. AWS SAM CLI


# Steps to follow for setup
1. aws configure 
2. aws sts get-caller-identity
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
5. run `scripts/seed.sh` 
    - populate dynamodb with some players
6. aws dynamodb scan --table-name PlayerProfiles
    - Check that table is now populated


# AWS Multiplayer Matchmaking Engine: Roadmap & Implementation

This roadmap is designed for a **$50 budget**, leveraging serverless components and AWS Free Tier where possible.

---

## 🏗️ Architectural Overview
The system follows a serverless event-driven pattern to minimize idle costs.



1.  **Identity:** Amazon Cognito handles player login.
2.  **Request Layer:** API Gateway + Lambda initiates matchmaking.
3.  **Engine:** GameLift FlexMatch groups players by ELO/Skill.
4.  **Hosting:** GameLift Fleet (Spot Instances) hosts the game session.
5.  **Notification:** SNS + Lambda updates the player's ticket with the server IP.

---

## 📅 Phase-by-Phase Roadmap

### Phase 1: Identity & Player Data (Cost: ~$0)
* **Amazon Cognito:** Create a User Pool. This provides the JWT tokens needed to authenticate API calls.
    * *Tip:* The first 50,000 monthly active users are free.
* **Amazon DynamoDB:** Create a table named `PlayerProfiles`.
    * **Partition Key:** `UserId` (String).
    * **Attributes:** `ELO` (Number), `Wins` (Number), `Losses` (Number).
    * *Tip:* Use "On-Demand" capacity mode to ensure you only pay for actual hits.

### Phase 2: The Matchmaking Request (Cost: ~$0.01/1k requests)
* **AWS Lambda (StartMatchmaking):** A function that:
    1.  Receives the `UserId` from the Cognito token.
    2.  Reads the player's `ELO` from the `PlayerProfiles` table.
    3.  Calls the `StartMatchmaking` API in GameLift FlexMatch.
* **Amazon API Gateway:** Create a simple REST endpoint (POST `/match`) to trigger the Lambda.

### Phase 3: FlexMatch Configuration (Engine Logic)
* **FlexMatch RuleSet:** Define a JSON rule that dictates how players are grouped.
    * Example: Find 2 players where `abs(player1.elo - player2.elo) <= 200`.
* **Matchmaking Configuration:** A GameLift resource that links your RuleSet to a specific GameLift Queue.

### Phase 4: Game Server Hosting (Cost: THE CRITICAL PART)
* **Game Server Executable:** Develop a "Headless" version of your game (Node.js, C#, or C++) that integrates the **GameLift Server SDK**.
* **GameLift Fleet:**
    * Upload your server build as a GameLift Script or Build.
    * **CRITICAL:** Create a **Spot Instance Fleet** (e.g., `c5.large`).
    * *Budget Alert:* Spot instances are ~70% cheaper than On-Demand. 125 hours are free for new accounts, but **always shut down the fleet when not testing.**

### Phase 5: Notification & Connection (Cost: ~$0)
* **Amazon SNS:** Configure FlexMatch to send status updates (Success/Failure) to an SNS Topic.
* **AWS Lambda (TicketProcessor):** Triggered by SNS. It parses the message and saves the Game Server's **IP Address** and **Port** into a `MatchmakingTickets` DynamoDB table.
* **Client Polling:** The game client polls a `/status` API until it sees the IP address, then connects to the server via UDP/TCP.

---

## 💰 Budget Management ($50 Limit)

1.  **The "Kill Switch":** Your EC2 instance and GameLift Fleets charge by the hour. When you finish your coding session, **delete the fleet** and **stop the EC2**. Do not just "leave them running."
2.  **CloudWatch Alarms:** Set a "Billing Alarm" in the AWS Billing Dashboard for **$10**. This ensures you are notified long before you hit your $50 limit.
3.  **Infrastructure as Code:** Consider using **AWS SAM** or **CDK**. This allows you to "deploy" your whole architecture for testing and "destroy" it completely in 2 minutes when done.

---

## 🛠️ Implementation Steps for You Right Now

1.  **Stop your EC2 instance** unless you are actively using it to compile your game server code.
2.  **Initialize Cognito:** Set up a user pool so you can simulate a "Logged In" player.
3.  **Write the FlexMatch RuleSet:** Start with a simple JSON that requires exactly 2 players to start a match.
4.  **Dummy Server:** Don't build the whole game yet. Build a tiny app that just connects to GameLift and says "I am ready."

---
*Reference: Based on the architecture described in "Real Life AWS Architecture Examples - Multiplayer Matchmaking Engine" by Be A Better Dev.*

