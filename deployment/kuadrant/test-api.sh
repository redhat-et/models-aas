#!/bin/bash

# Test script for Kuadrant Models-as-a-Service API
# This script tests the deployed endpoints with authentication

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Configuration
DOMAIN=${DOMAIN:-"localhost:8000"}
KEYCLOAK_URL=${KEYCLOAK_URL:-"http://localhost:8080"}

# API Keys for testing (tiered rate limiting)
PREMIUM_API_KEY_1="premiumuser1_key"
PREMIUM_API_KEY_2="premiumuser2_key"
FREE_API_KEY_1="freeuser1_key"
FREE_API_KEY_2="freeuser2_key"

echo -e "${GREEN}Testing Kuadrant Models-as-a-Service API...${NC}"

# Function to test API key
test_api_key() {
    local key_name=$1
    local api_key=$2
    
    echo "Testing $key_name..."
    response=$(curl -s -w "%{http_code}" -H "Authorization: APIKEY $api_key" \
        "http://$DOMAIN/qwen/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d '{"model": "qwen", "messages": [{"role": "user", "content": "Hello"}], "max_tokens": 10}')
    
    http_code="${response: -3}"
    
    if [[ "$http_code" == "200" ]]; then
        echo -e "${GREEN}✅ $key_name authentication successful (HTTP $http_code)${NC}"
        return 0
    else
        echo -e "${RED}❌ $key_name authentication failed (HTTP $http_code)${NC}"
        return 1
    fi
}

# Function to setup authentication
setup_auth() {
    echo -e "${YELLOW}Setting up API Key authentication...${NC}"
    
    # Test different API keys
    test_api_key "Premium User 1" "$PREMIUM_API_KEY_1"
test_api_key "Premium User 2" "$PREMIUM_API_KEY_2"
test_api_key "Free User 1" "$FREE_API_KEY_1"
test_api_key "Free User 2" "$FREE_API_KEY_2"
    
    # Use premium key for tests
    TOKEN="$PREMIUM_API_KEY_1"
    echo -e "${GREEN}✓ Using Premium API Key for tests${NC}"
}

# Function to test endpoint
test_endpoint() {
    local model=$1
    local endpoint=$2
    local payload=$3
    
    echo -e "\n${YELLOW}Testing $model model...${NC}"
    
    response=$(curl -s -w "\n%{http_code}" -X POST \
        "http://$DOMAIN/$endpoint" \
        -H "Authorization: APIKEY $TOKEN" \
        -H "Content-Type: application/json" \
        -d "$payload")
    
    http_code=$(echo "$response" | tail -n1)
    body=$(echo "$response" | head -n -1)
    
    if [ "$http_code" -eq 200 ]; then
        echo -e "${GREEN}✓ $model API is working${NC}"
        echo -e "Response: $body" | head -c 200
        echo "..."
    elif [ "$http_code" -eq 429 ]; then
        echo -e "${YELLOW}⚠ Rate limit hit for $model${NC}"
    elif [ "$http_code" -eq 401 ]; then
        echo -e "${RED}✗ Authentication failed for $model${NC}"
    else
        echo -e "${RED}✗ $model API failed with HTTP $http_code${NC}"
        echo -e "Response: $body"
    fi
}

# Function to test rate limiting
test_rate_limiting() {
    local endpoint=$1
    local limit=$2
    
    echo -e "\n${YELLOW}Testing rate limiting for $endpoint (limit: $limit/min)...${NC}"
    
    for i in $(seq 1 $((limit + 5))); do
        response=$(curl -s -w "%{http_code}" -o /dev/null -X POST \
            "http://$DOMAIN/$endpoint" \
            -H "Authorization: APIKEY $TOKEN" \
            -H "Content-Type: application/json" \
            -d '{"model": "test", "messages": [{"role": "user", "content": "test"}]}')
        
        if [ "$response" -eq 429 ]; then
            echo -e "${GREEN}✓ Rate limiting working - hit limit at request $i${NC}"
            break
        elif [ $i -eq $((limit + 5)) ]; then
            echo -e "${YELLOW}⚠ Rate limiting not triggered within expected range${NC}"
        fi
        
        sleep 1
    done
}

# Function to check monitoring
check_monitoring() {
    echo -e "\n${YELLOW}Checking monitoring endpoints...${NC}"
    
    # Check if Prometheus is accessible
    if kubectl get svc prometheus -n istio-system &>/dev/null; then
        echo -e "${GREEN}✓ Prometheus service found${NC}"
        kubectl port-forward -n istio-system svc/prometheus 9090 &>/dev/null &
        PROM_PID=$!
        sleep 3
        
        if curl -s http://localhost:9090/api/v1/query?query=up | grep -q "success"; then
            echo -e "${GREEN}✓ Prometheus is accessible${NC}"
        else
            echo -e "${YELLOW}⚠ Prometheus not accessible${NC}"
        fi
        
        kill $PROM_PID 2>/dev/null || true
    else
        echo -e "${YELLOW}⚠ Prometheus service not found${NC}"
    fi
    
    # Check for Grafana dashboard
    if kubectl get configmap llm-metrics-dashboard -n kuadrant-models &>/dev/null; then
        echo -e "${GREEN}✓ Grafana dashboard ConfigMap found${NC}"
    else
        echo -e "${YELLOW}⚠ Grafana dashboard not found${NC}"
    fi
}

# Main test execution
main() {
    echo -e "${YELLOW}Configuration:${NC}"
    echo -e "• Domain: $DOMAIN"
    echo -e "• Keycloak: $KEYCLOAK_URL"
    echo -e "• Client ID: $CLIENT_ID"
    
    # Setup API key authentication
    setup_auth
    
    # Test Qwen model (fastest to start)
    qwen_payload='{"model": "qwen", "messages": [{"role": "user", "content": "Write a simple hello world function in Python"}], "max_tokens": 100}'
    test_endpoint "Qwen3-0.6B" "qwen/v1/chat/completions" "$qwen_payload"
    
    # Test Granite model
    granite_payload='{"model": "granite-8b-code-instruct-128k", "messages": [{"role": "user", "content": "Write a simple hello world function in Python"}], "max_tokens": 100}'
    test_endpoint "Granite" "granite/v1/chat/completions" "$granite_payload"
    
    # Test Mistral model
    mistral_payload='{"model": "mistral-7b-instruct", "messages": [{"role": "user", "content": "Explain what is artificial intelligence in one sentence"}], "max_tokens": 50}'
    test_endpoint "Mistral" "mistral/v1/chat/completions" "$mistral_payload"
    
    # Test Nomic embeddings
    nomic_payload='{"input": "This is a test sentence for embedding", "model": "nomic-embed-text-v1.5"}'
    test_endpoint "Nomic" "nomic/embeddings" "$nomic_payload"
    
    # Test rate limiting (be careful not to exhaust limits)
    echo -e "\n${YELLOW}Testing rate limiting (quick test)...${NC}"
    test_rate_limiting "qwen/v1/chat/completions" 5
    
    # Check monitoring
    check_monitoring
    
    echo -e "\n${GREEN}🎉 API testing completed!${NC}"
    
    echo -e "\n${YELLOW}Summary:${NC}"
    echo -e "• All endpoints should return 200 OK with valid authentication"
    echo -e "• Rate limiting should return 429 when limits are exceeded"
    echo -e "• Monitor metrics in Prometheus/Grafana dashboards"
    
    echo -e "\n${YELLOW}Troubleshooting:${NC}"
    echo -e "• 401 errors: Check Keycloak configuration and token"
    echo -e "• 502 errors: Verify model services are running"
    echo -e "• 404 errors: Check HTTPRoute configuration"
    echo -e "• No response: Verify DNS and LoadBalancer IP"
}

# Check prerequisites
if ! command -v curl &> /dev/null; then
    echo -e "${RED}curl is required but not installed${NC}"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo -e "${RED}jq is required but not installed${NC}"
    exit 1
fi

if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}kubectl is required but not installed${NC}"
    exit 1
fi

# Run main function
main "$@"