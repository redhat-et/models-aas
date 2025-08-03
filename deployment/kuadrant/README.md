# Models as a Service with Kuadrant

This repository demonstrates how to deploy a Models-as-a-Service platform using Kuadrant instead of 3scale for API management. Kuadrant provides cloud-native API gateway capabilities using Istio and the Gateway API.

## Architecture Overview

**Gateway:** Istio + Envoy with Kuadrant policies
**Models:** KServe InferenceServices (Granite, Mistral, Nomic, Qwen, Simulator)
**Authentication:** API Keys (simple) or Keycloak (Red Hat SSO)  (TODO: not implemented, static keys currently)
**Rate Limiting:** Kuadrant RateLimitPolicy with Redis backend (Limitador redis yaml included but not tested and probably not working)
**Observability:** Prometheus + Grafana with custom LLM metrics (TODO: setup chargeback prom)

### Key Components

- **Istio Service Mesh**: Provides the data plane for traffic management
- **Kuadrant Operator**: Manages API policies and traffic control
- **Limitador**: Rate limiting service with Redis backend
- **Authorino**: Authentication and authorization service
- **Gateway API**: Standard Kubernetes API for ingress traffic
- **KServe**: Model serving platform that creates model pods

## How Model Pods Get Created

**The flow that creates actual running model pods:**

```
1. You apply an InferenceService YAML
   ↓
2. KServe Controller sees the InferenceService
   ↓
3. KServe creates a Deployment for your model
   ↓
4. Deployment creates Pod(s) with:
   - GPU allocation
   - Model download from HuggingFace
   - vLLM or other serving runtime
   ↓
5. Pod starts serving model on port 8080
   ↓
6. Kube Service exposes the pod
   ↓
7. HTTPRoute connects gateway to the service
   ↓
8. Kuadrant policies protect the route
```

**Key Point**: Without applying InferenceService YAMLs, you get no model pods. The InferenceService is what triggers KServe to create the actual AI model containers.

## Prerequisites

- Kubernetes cluster with admin access
- kubectl configured
- For KIND clusters: `kind create cluster --name llm-maas`
- For minikube with GPU: `minikube start --driver docker --container-runtime docker --gpus all --memory no-limit --cpus no-limit`

## 🚀 Quick Start (Automated Installer)

**For KIND clusters (no GPU):**
```bash
cd ~/rhmaas/models-aas/deployment/kuadrant
./install.sh --simulator
```

**For GPU clusters:**
```bash
cd ~/rhmaas/models-aas/deployment/kuadrant  
./install.sh --qwen3
```

The installer will:
- ✅ Deploy Istio + Gateway API + KServe + Kuadrant
- ✅ Configure gateway-level authentication and rate limiting
- ✅ Deploy your chosen model (simulator or Qwen3-0.6B)
- ✅ Set up tiered API keys (Free/Premium/Enterprise)
- ✅ Show you the port-forward and test commands

**After installation, run the port-forward command shown to access your API!**

---

## Manual Deployment (Advanced)

Follow the manual deployment steps below for full understanding and control over your MaaS deployment.

## Manual Deployment Instructions

```shell
git clone xxx
cd deployment/kuadrant
```

### 1. Install Istio and Gateway API

Install Istio and Gateway API CRDs using the provided script:

- Install Gateway API CRDs
- Install Istio base components and Istiod

```bash
chmod +x istio-install.sh
./istio-install.sh apply
```

This manifest will create the required namespaces (`llm` and `llm-observability`)

Create additional namespaces:

```bash
kubectl apply -f 00-namespaces.yaml
```

### 2. Install KServe (for Model Serving)

**Note:** KServe requires cert-manager for webhook certificates.

```bash
# Install cert-manager first
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.18.2/cert-manager.yaml

# Wait for cert-manager to be ready
kubectl wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout=300s
kubectl wait --for=condition=Available deployment/cert-manager-cainjector -n cert-manager --timeout=300s
kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=300s

# Install KServe CRDs and controller
kubectl apply --server-side -f https://github.com/kserve/kserve/releases/download/v0.15.2/kserve.yaml

# Wait for KServe controller to be ready
kubectl wait --for=condition=Available deployment/kserve-controller-manager -n kserve --timeout=300s

# Configure KServe for Gateway API integration
kubectl apply -f 01-kserve-config.yaml

# Restart KServe controller to pick up new configuration
kubectl rollout restart deployment/kserve-controller-manager -n kserve
kubectl wait --for=condition=Available deployment/kserve-controller-manager -n kserve --timeout=120s

# View inferenceervice configmap
kubectl get configmap inferenceservice-config -n kserve -o yaml

kubectl get configmap inferenceservice-config -n kserve \
  -o jsonpath='{.data.deploy}{"\n"}{.data.ingress}{"\n"}'

# Output
# {"defaultDeploymentMode": "RawDeployment"}
# {"enableGatewayApi": true, "kserveIngressGateway": "kuadrant-gateway.llm"}

```

### 3. Configure Gateway and Routing

The configuration is pre-configured for domain-based routing. Deploy the Gateway and routing configuration:

```bash
kubectl apply -f 02-gateway-configuration.yaml
kubectl apply -f 03-model-routing-domains.yaml
```

**Note:** If you want to use a different domain, update the hostnames in the files before applying.

### 4. Install Kuadrant Operator

```bash
# Option 1: Using Helm (recommended)

helm repo add kuadrant https://kuadrant.io/helm-charts
helm repo update

helm install kuadrant-operator kuadrant/kuadrant-operator \
  --create-namespace \
  --namespace kuadrant-system

kubectl apply -f 04-kuadrant-operator.yaml

# Wait for the operator to be ready
kubectl wait --for=condition=Available deployment/kuadrant-operator-controller-manager -n kuadrant-system --timeout=300s

# If the status does not become ready try kicking the operator:
kubectl rollout restart deployment kuadrant-operator-controller-manager -n kuadrant-system

# Deploy Kuadrant instance HA Limitador (Not tested)
#kubectl apply -f 03-kuadrant-instance.yaml
#
## Wait for Kuadrant components to be ready
#kubectl wait --for=condition=Available deployment/limitador -n kuadrant-system --timeout=300s
#kubectl wait --for=condition=Available deployment/authorino -n kuadrant-system --timeout=300s
```

### 5. Deploy Local Storage (for minikube/local development)

```bash
# Deploy MinIO for S3-compatible local storage
kubectl apply -f minio-local-storage.yaml

# Wait for MinIO to be ready
kubectl wait --for=condition=Available deployment/minio -n minio-system --timeout=300s
```

### 7. Deploy AI Models with KServe

> Option 1 Deploy models using KServe InferenceServices on a GPU accelerator:
> There is an added example of how to set the runtime with kserve via `vllm-latest-runtime.yaml`

```bash
# Deploy the latest vLLM ServingRuntime with Qwen3 support
kubectl apply -f ../model_serving/vllm-latest-runtime.yaml

# Deploy the Qwen3-0.6B model (recommended for testing)
kubectl apply -f ../model_serving/qwen3-0.6b-vllm-raw.yaml

# Monitor InferenceService deployment status
kubectl get inferenceservice -n llm

# Watch model deployment (takes 5-10 minutes for model download)
kubectl describe inferenceservice qwen3-0-6b-instruct -n llm

# Check if pods are running (may take 5-15 minutes for model downloads)
kubectl get pods -n llm -l serving.kserve.io/inferenceservice

# Follow logs to see model loading progress
kubectl logs -n llm -l serving.kserve.io/inferenceservice -c kserve-container -f

# Wait for model to be ready
kubectl wait --for=condition=Ready inferenceservice qwen3-0-6b-instruct -n llm --timeout=900s
```

> Option 2 - If in a KIND environment or non-GPU use:

```shell
kubectl apply -f ../model_serving/vllm-simulator-kserve.yaml
```

### 6. Configure Authentication and Rate Limiting

Deploy API key secrets, auth policies, and rate limiting:

```bash
# Create API key secrets
kubectl apply -f 05-api-key-secrets.yaml

# Apply API key-based auth policies
kubectl apply -f 06-auth-policies-apikey.yaml

# Apply rate limiting policies
kubectl apply -f 07-rate-limit-policies.yaml

# Kick the kuadrant controller if you dont see a limitador-limitador deployment or no rate-limiting
kubectl rollout restart deployment kuadrant-operator-controller-manager -n kuadrant-system
```

### 7. Start Port Forwarding for Local Access

If running on kind/minikube, you need port forwarding to access the models:

```bash
# Port-forward to Kuadrant gateway (REQUIRED for authentication)
kubectl port-forward -n llm svc/kuadrant-gateway-istio 8000:80 &
```

### 8. Test the MaaS API

Test all user tiers and rate limits with the automated script:

```bash
# Test simulator model (default)
./scripts/test-request-limits.sh

# Test qwen3 model when ready
./scripts/test-request-limits.sh --host qwen3.maas.local --model qwen3-0-6b-instruct
```

Example output showing rate limiting in action:

```bash
📡  Host    : simulator.maas.local
🤖  Model ID: simulator-model

=== Free User (5 requests per 2min) ===
Free req #1  -> 200
Free req #2  -> 200
Free req #3  -> 200
Free req #4  -> 200
Free req #5  -> 200
Free req #6  -> 429
Free req #7  -> 429

=== Premium User 1 (20 requests per 2min) ===
Premium1 req #1  -> 200
Premium1 req #2  -> 200
...
Premium1 req #20 -> 200
Premium1 req #21 -> 429
Premium1 req #22 -> 429

=== Premium User 2 (20 requests per 2min) ===
Premium2 req #1  -> 200
...
Premium2 req #20 -> 200
Premium2 req #21 -> 429
Premium2 req #22 -> 429

=== Second Free User (5 requests per 2min) ===
Free2 req #1  -> 200
...
Free2 req #5  -> 200
Free2 req #6  -> 429
Free2 req #7  -> 429
```

Test individual models with manual curl commands:

**Simulator Model:**

```bash
# Single request test
curl -s -H 'Authorization: APIKEY freeuser1_key' \
     -H 'Content-Type: application/json' \
     -d '{"model":"simulator-model","messages":[{"role":"user","content":"Hello!"}]}' \
     http://simulator.maas.local:8000/v1/chat/completions

# Test rate limiting (Free tier: 5 requests per 2min)
for i in {1..7}; do
  printf "Free tier request #%-2s -> " "$i"
  curl -s -o /dev/null -w "%{http_code}\n" \
       -X POST http://simulator.maas.local:8000/v1/chat/completions \
       -H 'Authorization: APIKEY freeuser1_key' \
       -H 'Content-Type: application/json' \
       -d '{"model":"simulator-model","messages":[{"role":"user","content":"Test request"}],"max_tokens":10}'
done
```

**Qwen3 Model:**

```bash
# Single request test
curl -s -H 'Authorization: APIKEY premiumuser1_key' \
     -H 'Content-Type: application/json' \
     -d '{"model":"qwen3-0-6b-instruct","messages":[{"role":"user","content":"Hello!"}]}' \
     http://qwen3.maas.local:8000/v1/chat/completions

# Test rate limiting (Premium tier: 20 requests per 2min)
for i in {1..22}; do
  printf "Premium tier request #%-2s -> " "$i"
  curl -s -o /dev/null -w "%{http_code}\n" \
       -X POST http://qwen3.maas.local:8000/v1/chat/completions \
       -H 'Authorization: APIKEY premiumuser1_key' \
       -H 'Content-Type: application/json' \
       -d '{"model":"qwen3-0-6b-instruct","messages":[{"role":"user","content":"Test request"}],"max_tokens":10}'
done
```

**Available API Keys and Rate Limits:**

| Tier | API Keys | Rate Limits (per 2min) |
|------|----------|------------------------|
| **Free** | `freeuser1_key`, `freeuser2_key` | 5 requests |
| **Premium** | `premiumuser1_key`, `premiumuser2_key` | 20 requests |

- Expected Responses

- ✅ **200**: Request successful
- ❌ **429**: Rate limit exceeded (too many requests)
- ❌ **401**: Invalid/missing API key

### 9. Deploy Observability

```bash
kubectl apply -f 08-observability.yaml
kubectl apply -f 09-monitoring-dashboard.yaml
```

## Troubleshooting

### View Logs

```bash
# Kuadrant operator logs
kubectl logs -n kuadrant-system deployment/kuadrant-operator-controller-manager

# Istio gateway logs
kubectl logs -n istio-system deployment/istio-ingressgateway

# Limitador logs
kubectl logs -n kuadrant-system deployment/limitador

# Authorino logs
kubectl logs -n kuadrant-system deployment/authorino
```

### Common Issues

- **502 Bad Gateway**: Check if model services are running and healthy
- **No Rate Limiting or Auth**: Kick the kuadrant-operator-controller-manager

## Customization

### Adjusting Rate Limits

Edit the RateLimitPolicy resources in `06-rate-limit-policies.yaml`:

```yaml
limits:
  "requests-per-minute":
    rates:
      - limit: 150  # Increase from 100
        duration: 1m
        unit: request
```

## Performance Tuning

### Gateway Scaling

```bash
# Scale Istio gateway
kubectl scale deployment/istio-ingressgateway -n istio-system --replicas=3

# Scale Kuadrant components
kubectl scale deployment/limitador -n kuadrant-system --replicas=3
kubectl scale deployment/authorino -n kuadrant-system --replicas=2
```
