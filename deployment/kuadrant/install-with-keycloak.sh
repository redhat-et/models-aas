#!/usr/bin/env bash
set -euo pipefail

################################################################################
# Models-as-a-Service (MaaS) + Kuadrant + Keycloak OIDC one-shot installer
#
# This installer deploys the complete MaaS platform with Keycloak OIDC 
# authentication instead of static API keys.
#
# Flags
#   --simulator           Deploy only the vLLM simulator (CPU/KIND clusters)
#   --qwen3               Deploy only the Qwen3-0.6 B model (GPU cluster)
#   --install-all-models  Deploy both simulator and Qwen3
#   --deploy-kind          Spin up a kind cluster named llm-maas and deploy the
#                         simulator model into it
#   --skip-metrics        Skip Prometheus observability deployment
#
# The script must be run from  deployment/kuadrant  (it relies on relative paths)
################################################################################

NAMESPACE="llm"
MODEL_TYPE=""
DEPLOY_KIND=false
SKIP_METRICS=false

usage() {
  cat <<EOF
Usage: $0 [--simulator|--qwen3|--install-all-models|--deploy-kind] [--skip-metrics]

🔑 This installer deploys MaaS with Keycloak OIDC authentication instead of API keys

Options
  --simulator            Deploy vLLM simulator (no GPU required)
  --qwen3                Deploy Qwen3-0.6B model (GPU required)
  --install-all-models   Deploy both simulator and Qwen3
  --deploy-kind           Create a kind cluster named llm-maas and deploy the simulator model
  --skip-metrics         Skip Prometheus observability deployment

Examples
  $0 --simulator
  $0 --qwen3 --skip-metrics
  $0 --install-all-models
  $0 --deploy-kind

User Accounts (all password: password123):
  Free Tier (5 req/2min):       freeuser1, freeuser2
  Premium Tier (20 req/2min):   premiumuser1, premiumuser2
  Enterprise Tier (100 req/2min): enterpriseuser1
EOF
  exit 1
}

# ────────────────────────────── flag parsing ──────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --simulator)           MODEL_TYPE="simulator" ; shift ;;
    --qwen3)               MODEL_TYPE="qwen3"     ; shift ;;
    --install-all-models)  MODEL_TYPE="all"       ; shift ;;
    --deploy-kind)         DEPLOY_KIND=true; MODEL_TYPE="simulator" ; shift ;;
    --skip-metrics)        SKIP_METRICS=true ; shift ;;
    -h|--help)             usage ;;
    *) echo "❌ Unknown option: $1"; usage ;;
  esac
done

[[ -z "$MODEL_TYPE" ]] && { echo "❌ Must specify a model flag"; usage; }

# ────────────────────────────── sanity checks ─────────────────────────────────
if [[ ! -f "02-gateway-configuration.yaml" ]]; then
  echo "❌ Run this script from deployment/kuadrant"
  exit 1
fi

if [[ ! -d "keycloak" ]]; then
  echo "❌ Keycloak directory not found. Make sure keycloak/ directory exists."
  exit 1
fi

# ────────────────────────────── optional kind cluster ─────────────────────────
if [[ "$DEPLOY_KIND" == true ]]; then
  echo "🔧 Creating kind cluster 'llm-maas' (if absent)"
  if ! kind get clusters | grep -q '^llm-maas$'; then
    kind create cluster --name llm-maas
  else
    echo "ℹ️  kind cluster 'llm-maas' already exists; reusing"
  fi
fi

echo
echo "🚀 MaaS + Keycloak OIDC installation started"
echo "📦  Model selection: $MODEL_TYPE"
echo "🔑  Authentication: Keycloak OIDC JWT tokens"
echo

# ────────────────────────────── 1. Istio / Gateway API ────────────────────────
echo "🔧 1. Installing Istio & Gateway API"
chmod +x istio-install.sh
./istio-install.sh apply

# ────────────────────────────── 2. Namespaces ────────────────────────────────
echo "🔧 2. Creating namespaces"
kubectl apply -f 00-namespaces.yaml

# ────────────────────────────── 3. cert-manager & KServe ─────────────────────
echo "🔧 3. Installing cert-manager"
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.18.2/cert-manager.yaml

echo "⏳   Waiting for cert-manager to be ready"
kubectl wait --for=condition=Available deployment/cert-manager            -n cert-manager --timeout=300s
kubectl wait --for=condition=Available deployment/cert-manager-cainjector -n cert-manager --timeout=300s
kubectl wait --for=condition=Available deployment/cert-manager-webhook   -n cert-manager --timeout=300s

echo "🔧 Installing KServe"
kubectl apply --server-side -f https://github.com/kserve/kserve/releases/download/v0.15.2/kserve.yaml

echo "⏳   Waiting for KServe controller"
kubectl wait --for=condition=Available deployment/kserve-controller-manager -n kserve --timeout=300s

echo "🔧 Configuring KServe for Gateway API"
kubectl apply -f 01-kserve-config.yaml
kubectl rollout restart deployment/kserve-controller-manager -n kserve
kubectl wait --for=condition=Available deployment/kserve-controller-manager -n kserve --timeout=120s

echo "📄  Current inferenceservice-config ConfigMap:"
kubectl get configmap inferenceservice-config -n kserve -o yaml

# ────────────────────────────── 4. Gateway + Routes ──────────────────────────
echo "🔧 4. Setting up Gateway and domain-based routes"
kubectl apply -f 02-gateway-configuration.yaml
kubectl apply -f 03-model-routing-domains.yaml

if [[ -x ./setup-local-domains.sh ]]; then
  ./setup-local-domains.sh setup
fi

# ────────────────────────────── 5. Kuadrant Operator ─────────────────────────
echo "🔧 5. Installing Kuadrant operator"
helm repo add kuadrant https://kuadrant.io/helm-charts
helm repo update

helm install kuadrant-operator kuadrant/kuadrant-operator \
  --create-namespace \
  --namespace kuadrant-system

kubectl apply -f 04-kuadrant-operator.yaml

echo "⏳   Waiting for Kuadrant operator"
kubectl wait --for=condition=Available deployment/kuadrant-operator-controller-manager -n kuadrant-system --timeout=300s

# ────────────────────────────── 6. Keycloak & OIDC Setup ─────────────────────
echo "🔧 6. Deploying Keycloak and OIDC authentication"

# Deploy Keycloak
kubectl apply -k keycloak/

echo "⏳   Waiting for Keycloak to be ready"
kubectl wait --for=condition=Available deployment/keycloak -n keycloak-system --timeout=300s

echo "⏳   Waiting for realm import to complete"
kubectl wait --for=condition=Complete job/keycloak-realm-import -n keycloak-system --timeout=300s

# Remove the old API key auth if it exists and apply OIDC auth
kubectl delete -f 06-auth-policies-apikey.yaml 2>/dev/null || true
kubectl delete -f 07-rate-limit-policies.yaml 2>/dev/null || true

echo "🔧 Applying OIDC authentication and rate limiting policies"
kubectl apply -f keycloak/05-auth-policy-oidc.yaml
kubectl apply -f keycloak/06-rate-limit-policy-oidc.yaml

kubectl rollout restart deployment kuadrant-operator-controller-manager -n kuadrant-system
kubectl wait --for=condition=Available deployment/kuadrant-operator-controller-manager -n kuadrant-system --timeout=300s

# ────────────────────────────── 7. Model deployment ──────────────────────────
echo "🔧 7. Deploying model(s)"

case "$MODEL_TYPE" in
  simulator)
    kubectl apply -f ../model_serving/vllm-simulator-kserve.yaml
    kubectl wait --for=condition=Ready inferenceservice/vllm-simulator -n "$NAMESPACE" --timeout=120s
    ;;
  qwen3)
    kubectl apply -f ../model_serving/vllm-latest-runtime.yaml
    kubectl apply -f ../model_serving/qwen3-0.6b-vllm-raw.yaml
    # Uncomment the wait if you want the accelerator to finish loading before proceeding
    # kubectl wait --for=condition=Ready inferenceservice/qwen3-0-6b-instruct -n "$NAMESPACE" --timeout=900s
    ;;
  all)
    kubectl apply -f ../model_serving/vllm-latest-runtime.yaml
    kubectl apply -f ../model_serving/vllm-simulator-kserve.yaml
    kubectl apply -f ../model_serving/qwen3-0.6b-vllm-raw.yaml
    kubectl wait --for=condition=Ready inferenceservice/vllm-simulator       -n "$NAMESPACE" --timeout=120s
    kubectl wait --for=condition=Ready inferenceservice/qwen3-0-6b-instruct  -n "$NAMESPACE" --timeout=900s
    ;;
esac

# ────────────────────────────── 8. Observability ─────────────────────────────
if [[ "$SKIP_METRICS" == false ]]; then
  echo "🔧 8. Installing Prometheus observability"
  
  # Install Prometheus Operator
  kubectl apply --server-side --field-manager=quickstart-installer -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/master/bundle.yaml
  
  # Wait for Prometheus Operator to be ready
  kubectl wait --for=condition=Available deployment/prometheus-operator -n default --timeout=300s
  
  # From models-aas/deployment/kuadrant Kuadrant prometheus observability
  kubectl apply -k kustomize/prometheus/
else
  echo "⏭️  8. Skipping Prometheus observability (--skip-metrics flag)"
fi

# ────────────────────────────── 9. Verification ──────────────────────────────
echo "🔧 9. Verifying objects"
kubectl get gateway,httproute,authpolicy,ratelimitpolicy -n "$NAMESPACE"
kubectl get inferenceservice,pods -n "$NAMESPACE"

echo
echo "✅ MaaS + Keycloak OIDC installation complete!"
echo
echo "🔌 Port-forward commands (run in separate terminals):"
echo "   # API Gateway"
echo "   kubectl port-forward -n $NAMESPACE svc/inference-gateway-istio 8000:80"
echo "   # Keycloak (for token management)"  
echo "   kubectl port-forward -n keycloak-system svc/keycloak 8080:8080"
echo

if [[ "$SKIP_METRICS" == false ]]; then
echo "📊 Access Prometheus metrics (in separate terminals):"
echo "   kubectl port-forward -n llm-observability svc/models-aas-observability 9090:9090"
echo "   kubectl port-forward -n kuadrant-system svc/limitador-limitador 8081:8080"
echo "   Then visit: http://localhost:9090 (Prometheus) and http://localhost:8081/metrics (Limitador)"
echo
fi

echo "🎯 Test OIDC authentication:"
echo

if [[ "$MODEL_TYPE" == "simulator" || "$MODEL_TYPE" == "all" ]]; then
cat <<'EOF'
# Get JWT token for free user
cd keycloak/
TOKEN=$(./get-token.sh freeuser1 | grep -A1 "Access Token:" | tail -1)

# Test API call with JWT token
curl -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"model":"simulator-model","messages":[{"role":"user","content":"Hello from Keycloak OIDC!"}]}' \
     http://simulator.maas.local:8000/v1/chat/completions

# Run comprehensive OIDC tests
./test-oidc-auth.sh
EOF
echo
fi

if [[ "$MODEL_TYPE" == "qwen3" || "$MODEL_TYPE" == "all" ]]; then
cat <<'EOF'
# Test Qwen3 with Premium user token
cd keycloak/
TOKEN=$(./get-token.sh premiumuser1 | grep -A1 "Access Token:" | tail -1)

curl -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"model":"qwen3-0-6b-instruct","messages":[{"role":"user","content":"OIDC test auth."}]}' \
     http://qwen3.maas.local:8000/v1/chat/completions
EOF
echo
fi

echo
echo "🔑 Keycloak User Accounts (password: password123):"
echo "    Free Tier (5 req/2min):       freeuser1, freeuser2"
echo "    Premium Tier (20 req/2min):   premiumuser1, premiumuser2" 
echo "    Enterprise Tier (100 req/2min): enterpriseuser1"
echo
echo "📋 Useful Commands:"
echo "    Get JWT tokens → cd keycloak/ && ./get-token.sh freeuser1"
echo "    Test OIDC auth → cd keycloak/ && ./test-oidc-auth.sh"
echo "    Keycloak admin → http://localhost:8080 (admin/admin123, realm: maas)"
echo
echo "🔥 Deploy complete with Keycloak OIDC authentication!"
