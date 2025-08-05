#!/bin/bash

# Test script for OIDC authentication and rate limiting with Keycloak
# This script tests all user tiers and their rate limits

set -euo pipefail

KEYCLOAK_HOST="${KEYCLOAK_HOST:-localhost:8080}"
API_HOST="${API_HOST:-simulator.maas.local:8000}"
REALM="maas"
CLIENT_ID="maas-client"
CLIENT_SECRET="maas-client-secret"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🧪 Testing OIDC Authentication and Rate Limiting${NC}"
echo -e "${BLUE}📡 API Host: $API_HOST${NC}"
echo -e "${BLUE}🔑 Keycloak: $KEYCLOAK_HOST${NC}"
echo ""

get_token() {
    local username=$1
    local password=${2:-password123}
    
    local response=$(curl -s -X POST \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "username=$username" \
      -d "password=$password" \
      -d "grant_type=password" \
      -d "client_id=$CLIENT_ID" \
      -d "client_secret=$CLIENT_SECRET" \
      "http://$KEYCLOAK_HOST/realms/$REALM/protocol/openid-connect/token")
    
    echo "$response" | grep -o '"access_token":"[^"]*' | grep -o '[^"]*$'
}

test_api_with_token() {
    local token=$1
    local username=$2
    local request_num=$3
    
    local response=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "http://$API_HOST/v1/chat/completions" \
        -H "Authorization: Bearer $token" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"simulator-model\",\"messages\":[{\"role\":\"user\",\"content\":\"Test request #$request_num from $username\"}],\"max_tokens\":10}")
    
    echo "$response"
}

test_user_tier() {
    local username=$1
    local tier=$2
    local limit=$3
    local test_count=$((limit + 2))
    
    echo -e "${YELLOW}=== Testing $tier User: $username (${limit} requests per 2min) ===${NC}"
    
    local token=$(get_token "$username")
    if [[ -z "$token" ]]; then
        echo -e "${RED}❌ Failed to get token for $username${NC}"
        return 1
    fi
    
    echo -e "${GREEN}✅ Token acquired for $username${NC}"
    
    # Test requests up to limit + 2
    for i in $(seq 1 $test_count); do
        local status=$(test_api_with_token "$token" "$username" "$i")
        if [[ $i -le $limit ]]; then
            if [[ "$status" == "200" ]]; then
                echo -e "${GREEN}$username req #$i -> $status ✅${NC}"
            else
                echo -e "${RED}$username req #$i -> $status ❌ (expected 200)${NC}"
            fi
        else
            if [[ "$status" == "429" ]]; then
                echo -e "${YELLOW}$username req #$i -> $status ⚠️ (rate limited)${NC}"
            else
                echo -e "${RED}$username req #$i -> $status ❌ (expected 429)${NC}"
            fi
        fi
        sleep 0.5
    done
    echo ""
}

# Check if Keycloak is accessible
if ! curl -s "http://$KEYCLOAK_HOST/realms/$REALM" > /dev/null; then
    echo -e "${RED}❌ Cannot connect to Keycloak at $KEYCLOAK_HOST${NC}"
    echo -e "${YELLOW}💡 Make sure to port-forward Keycloak:${NC}"
    echo -e "   kubectl port-forward -n keycloak-system svc/keycloak 8080:8080"
    exit 1
fi

echo -e "${GREEN}✅ Keycloak is accessible${NC}"
echo ""

# Test each user tier
test_user_tier "freeuser1" "Free" 5
test_user_tier "premiumuser1" "Premium" 20
test_user_tier "enterpriseuser1" "Enterprise" 100

echo -e "${BLUE}🏁 OIDC Authentication and Rate Limiting Test Complete!${NC}"
echo ""
echo -e "${YELLOW}📊 Summary:${NC}"
echo -e "• Free users: 5 requests per 2 minutes"
echo -e "• Premium users: 20 requests per 2 minutes" 
echo -e "• Enterprise users: 100 requests per 2 minutes"
echo -e "• All limits enforced per user ID from JWT token"