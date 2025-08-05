#!/bin/bash

# Script to get JWT tokens from Keycloak for testing
# Usage: ./get-token.sh <username> [password]

set -euo pipefail

USERNAME="${1:-}"
PASSWORD="${2:-password123}"
KEYCLOAK_HOST="${KEYCLOAK_HOST:-localhost:8080}"
REALM="maas"
CLIENT_ID="maas-client"
CLIENT_SECRET="maas-client-secret"

if [[ -z "$USERNAME" ]]; then
    echo "Usage: $0 <username> [password]"
    echo ""
    echo "Available users:"
    echo "  freeuser1, freeuser2 (Free tier - 5 req/2min)"
    echo "  premiumuser1, premiumuser2 (Premium tier - 20 req/2min)"
    echo "  enterpriseuser1 (Enterprise tier - 100 req/2min)"
    echo ""
    echo "Default password: password123"
    echo ""
    echo "Examples:"
    echo "  $0 freeuser1"
    echo "  $0 premiumuser1 password123"
    exit 1
fi

echo "🔑 Getting JWT token for user: $USERNAME"

# Get token from Keycloak
response=$(curl -s -X POST \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "username=$USERNAME" \
  -d "password=$PASSWORD" \
  -d "grant_type=password" \
  -d "client_id=$CLIENT_ID" \
  -d "client_secret=$CLIENT_SECRET" \
  "http://$KEYCLOAK_HOST/realms/$REALM/protocol/openid-connect/token" || {
    echo "❌ Failed to connect to Keycloak at $KEYCLOAK_HOST"
    echo "💡 Make sure to port-forward Keycloak:"
    echo "   kubectl port-forward -n keycloak-system svc/keycloak 8080:8080"
    exit 1
})

# Extract access token
access_token=$(echo "$response" | grep -o '"access_token":"[^"]*' | grep -o '[^"]*$' || {
    echo "❌ Failed to get access token"
    echo "Response: $response"
    exit 1
})

if [[ -z "$access_token" ]]; then
    echo "❌ No access token in response"
    echo "Response: $response"
    exit 1
fi

echo "✅ Token retrieved successfully!"
echo ""
echo "🔗 Access Token:"
echo "$access_token"
echo ""
echo "📋 Test API call:"
echo "curl -H 'Authorization: Bearer $access_token' \\"
echo "     -H 'Content-Type: application/json' \\"
echo "     -d '{\"model\":\"simulator-model\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello from $USERNAME!\"}]}' \\"
echo "     http://simulator.maas.local:8000/v1/chat/completions"
echo ""

# Decode and show token claims
if command -v jq >/dev/null 2>&1; then
    echo "📋 Token Claims:"
    echo "$access_token" | cut -d. -f2 | base64 -d 2>/dev/null | jq . || echo "Failed to decode token"
fi