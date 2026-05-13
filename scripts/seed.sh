#!/bin/bash
aws dynamodb batch-write-item --request-items file://data/seed-player.json
echo "Test players seeded."
