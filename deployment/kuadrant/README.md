# Models as a Service with Kuadrant

This repository demonstrates how to deploy a Models-as-a-Service platform using Kuadrant instead of 3scale for API management. Kuadrant provides cloud-native API gateway capabilities using Istio and the Gateway API.

## Architecture Overview

**Gateway:** Istio Gateway + Envoy with Kuadrant policies  
**Models:** KServe InferenceServices (Granite, Mistral, Nomic)  
**Authentication:** API Keys (simple) or Keycloak (Red Hat SSO)  
**Rate Limiting:** Kuadrant RateLimitPolicy with Redis backend  
**Observability:** Prometheus + Grafana with custom LLM metrics

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
6. Kubernetes Service exposes the pod
   ↓  
7. HTTPRoute connects gateway to the service
   ↓
8. Kuadrant policies protect the route
```

**Key Point**: Without applying InferenceService YAMLs, you get no model pods! The InferenceService is what triggers KServe to create the actual AI model containers.

## Prerequisites

- Kubernetes cluster (v1.25+) or minikube
- kubectl configured for your cluster
- Cluster admin permissions
- For minikube: `minikube start --memory=8192 --cpus=4`

## Quick Start (Manual Deployment)

Follow the manual deployment steps below for full understanding and control over your MaaS deployment.

## Manual Deployment Instructions

### 1. Install Istio and Gateway API

Install Istio and Gateway API CRDs using the provided script:

```bash
cd deployment/kuadrant
chmod +x istio-install.sh
./istio-install.sh apply
```

This script will:

- Install Gateway API CRDs
- Install Istio base components and Istiod
- Create the required namespaces (`llm` and `llm-observability`)

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


# Alt install:


# Install cert-manager
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.18.2/cert-manager.yaml
kubectl wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout=300s
kubectl wait --for=condition=Available deployment/cert-manager-cainjector -n cert-manager --timeout=300s
kubectl wait --for=condition=Available deployment/cert-manager-webhook -n cert-manager --timeout=300s

# Install KServe (server-side apply avoids the 256 KiB annotation limit on CRDs)
kubectl apply --server-side --force-conflicts \
  -f https://github.com/kserve/kserve/releases/download/v0.15.2/kserve.yaml \
  --field-manager="kserve-install"

# Wait for cert-manager to mint the webhook TLS secret
kubectl get secret kserve-webhook-server-cert -n kserve --watch

# Wait for KServe controller to be ready
kubectl rollout status deployment/kserve-controller-manager -n kserve --timeout=300s

# Configure KServe
kubectl apply -f 01-kserve-config.yaml

# Restart KServe controller to pick up new configuration
kubectl rollout restart deployment/kserve-controller-manager -n kserve
kubectl wait --for=condition=Available deployment/kserve-controller-manager -n kserve --timeout=120s

# View configmap
kubectl get configmap inferenceservice-config -n kserve -o yaml

$ kubectl get configmap inferenceservice-config -n kserve \
  -o jsonpath='{.data.deploy}{"\n"}{.data.ingress}{"\n"}'

# Output
# {"defaultDeploymentMode": "RawDeployment"}
# {"enableGatewayApi": true, "kserveIngressGateway": "kuadrant-gateway.llm"}

```

### 3. Install Kuadrant Operator

```bash
# Option 1: Using Helm (recommended)
helm repo add kuadrant https://kuadrant.io/helm-charts
helm repo update
helm install kuadrant-operator kuadrant/kuadrant-operator \
  --create-namespace \
  --namespace kuadrant-system

# Option 2: Using manifests
kubectl apply -f 02-kuadrant-operator.yaml

# Wait for the operator to be ready
kubectl wait --for=condition=Available deployment/kuadrant-operator-controller-manager -n kuadrant-system --timeout=300s

# If the status does not become ready try kicking the operator:
kubectl rollout restart deployment kuadrant-operator-controller-manager -n kuadrant-system

# Deploy Kuadrant instance
kubectl apply -f 03-kuadrant-instance.yaml

# Wait for Kuadrant components to be ready
kubectl wait --for=condition=Available deployment/limitador -n kuadrant-system --timeout=300s
kubectl wait --for=condition=Available deployment/authorino -n kuadrant-system --timeout=300s
```

### 4. Deploy Local Storage (for minikube/local development)

```bash
# Deploy MinIO for S3-compatible local storage
kubectl apply -f minio-local-storage.yaml

# Wait for MinIO to be ready
kubectl wait --for=condition=Available deployment/minio -n minio-system --timeout=300s
```

### 5. Deploy AI Models with KServe

Deploy actual AI models using KServe InferenceServices with GPU acceleration:

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

**Available Models:**
- **Qwen3-0.6B**: Fast, efficient chat model (hf://Qwen/Qwen3-0.6B) ✅ **WORKING**
- **Granite-8B**: IBM's code-focused chat model  
- **Mistral-7B**: General purpose chat model
- **Nomic-Embed**: Text embeddings model

**Note**: Qwen3-0.6B requires the new `vllm-latest` ServingRuntime for compatibility.

**GPU Requirements:**
- Each model requires 1 GPU
- Qwen3-0.6B: ~2GB VRAM (minimal requirements)
- Granite-8B: ~16GB VRAM  
- Mistral-7B: ~14GB VRAM
- Nomic-Embed: ~4GB VRAM

**Model Download Process:**
KServe automatically downloads models from HuggingFace on first deployment. This can take 5-15 minutes depending on model size and network speed.

### 6. Start Port Forwarding for Local Access

Since you're running on minikube, you need port forwarding to access the models:

```bash
# Option 1: Use the automated script
./localhost-setup.sh start

# Option 2: Manual port forwarding
kubectl port-forward -n istio-system svc/istio-ingressgateway 8000:80 &

# Wait a moment for port-forward to establish
sleep 5

# Test connectivity
curl -H 'Host: localhost' http://localhost:8000/health
```

**Port Forwarding Endpoints:**
```bash
# Model endpoints (with API key) - Chat Completions
# Qwen3-0.6B Model (WORKING)
curl -H 'Authorization: APIKEY admin-key-12345' \
     -H 'Content-Type: application/json' \
     -d '{"model":"qwen3-0-6b-instruct","messages":[{"role":"user","content":"Hello! Write a Python function."}]}' \
     http://localhost:8000/qwen3/v1/chat/completions

# Other models (require setup)
curl -H 'Authorization: APIKEY admin-key-12345' \
     -H 'Content-Type: application/json' \
     -d '{"model":"granite","messages":[{"role":"user","content":"Hello"}]}' \
     http://localhost:8000/granite/v1/chat/completions

curl -H 'Authorization: APIKEY admin-key-12345' \
     -H 'Content-Type: application/json' \
     -d '{"model":"mistral","messages":[{"role":"user","content":"Hello"}]}' \
     http://localhost:8000/mistral/v1/chat/completions

# Embeddings endpoint
curl -H 'Authorization: APIKEY admin-key-12345' \
     -H 'Content-Type: application/json' \
     -d '{"input":"Hello world","model":"nomic-embed"}' \
     http://localhost:8000/nomic/embeddings

# Monitoring endpoints
kubectl port-forward -n istio-system svc/prometheus 9090 &
kubectl port-forward -n istio-system svc/grafana 3000 &
```

**Available API Keys:**
- **Admin**: `admin-key-12345` (full access)
- **Developer**: `dev-key-67890` (standard access)  
- **User**: `user-key-abcdef` (limited access)
- **Readonly**: `readonly-key-999` (monitoring access)

### 7. Configure Gateway and Routing

The configuration is pre-configured for localhost. Deploy the Gateway and routing configuration:

```bash
kubectl apply -f 04-gateway-configuration.yaml
kubectl apply -f 05-model-routing.yaml
```

**Note:** If you want to use a different domain, update the hostnames in the files before applying.

### 8. Configure Authentication

**Option A: Simple API Key Authentication (Recommended)**

Deploy API key secrets and auth policies:

```bash
# Create API key secrets
kubectl apply -f 07-api-key-secrets.yaml

# Apply API key-based auth policies
kubectl apply -f 08-auth-policies-apikey.yaml
```

This creates API keys for different user roles:
- `admin-key-12345` - Administrator access
- `dev-key-67890` - Developer access  
- `user-key-abcdef` - Standard user access
- `readonly-key-999` - Read-only access

**Option B: Keycloak Authentication (Legacy)**

For Keycloak-based authentication (requires Keycloak server):

```bash
kubectl apply -f 07-auth-policies.yaml
```

**Note:** If you have Keycloak running elsewhere, update the `issuerUrl` in the file before applying.

### 9. Apply Rate Limiting Policies

```bash
kubectl apply -f 06-rate-limit-policies.yaml
```

### 10. Deploy Observability

```bash
kubectl apply -f 08-observability.yaml
kubectl apply -f 09-monitoring-dashboard.yaml
```

### 11. Set Up Localhost Access

Use the localhost setup script to start port-forwarding:

```bash
chmod +x localhost-setup.sh
./localhost-setup.sh start
```

This will set up port-forwards for:
- API Gateway: http://localhost:8000
- Prometheus: http://localhost:9090 (if available)
- Grafana: http://localhost:3000 (if available)
- Keycloak: http://localhost:8080 (if available)

## API Usage

### Endpoints

With Kuadrant via localhost port-forwarding, your models are accessible at:

- **Granite Code Model**: `http://localhost:8000/granite/`
- **Mistral Model**: `http://localhost:8000/mistral/`
- **Nomic Embeddings**: `http://localhost:8000/nomic/`

### Authentication

All requests require a valid JWT token from Keycloak:

```bash
# Get token from Keycloak (if authentication is enabled)
TOKEN=$(curl -X POST \
  http://localhost:8080/auth/realms/maas/protocol/openid-connect/token \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d 'client_id=your-client-id' \
  -d 'client_secret=your-client-secret' \
  -d 'grant_type=client_credentials' | jq -r '.access_token')

# Make API request
curl -X POST \
  http://localhost:8000/granite/chat/completions \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "granite-8b-code-instruct-128k",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

### Rate Limits

Default rate limits per user:
- **Granite**: 100 requests/minute, 1000 requests/hour
- **Mistral**: 50 requests/minute, 500 requests/hour  
- **Nomic**: 200 requests/minute, 2000 requests/hour

Rate limits are enforced per authenticated user (JWT subject).

## Monitoring and Observability

### Prometheus Metrics

Kuadrant automatically exposes metrics for:
- Request rate by model
- Token usage (prompt, completion, total)
- Response times
- Error rates
- Rate limit hits

### Grafana Dashboard

A pre-configured Grafana dashboard is available at `09-monitoring-dashboard.yaml`. Import this into your Grafana instance to visualize:

- Model usage patterns
- Token consumption
- Performance metrics
- Rate limiting effectiveness

### Accessing Metrics

Use the localhost setup script to manage port-forwards:

```bash
# Start all port-forwards (including monitoring)
./localhost-setup.sh start

# Check status
./localhost-setup.sh status

# Stop all port-forwards
./localhost-setup.sh stop
```

Or manually:

```bash
# Forward Prometheus port
kubectl port-forward -n istio-system svc/prometheus 9090

# Forward Grafana port (if deployed)
kubectl port-forward -n istio-system svc/grafana 3000
```

## Migration from 3scale

### Key Differences

| Feature | 3scale | Kuadrant |
|---------|--------|----------|
| Gateway | APIcast | Istio + Envoy |
| API Definition | OpenAPI in 3scale | HTTPRoute resources |
| Rate Limiting | 3scale policies | RateLimitPolicy CRDs |
| Authentication | 3scale auth | AuthPolicy CRDs |
| Metrics | Custom LLM policy | Istio telemetry + custom metrics |
| Portal | 3scale Developer Portal | External portal (can integrate via API) |

### Migration Benefits

- **Cloud-Native**: Built on Kubernetes and Istio
- **GitOps-Friendly**: All configuration in YAML
- **Vendor-Neutral**: Uses open standards (Gateway API)
- **Scalable**: Leverages Istio's performance and reliability
- **Observable**: Rich metrics and tracing out of the box

## Troubleshooting

### Check Component Status

```bash
# Verify all components are running
kubectl get pods -n kuadrant-system
kubectl get pods -n istio-system
kubectl get pods -n llm

# Check Gateway status
kubectl get gateway -n llm
kubectl get httproute -n llm

# Verify policies are applied
kubectl get ratelimitpolicy -n llm
kubectl get authpolicy -n llm
```

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

1. **502 Bad Gateway**: Check if model services are running and healthy
2. **Rate Limit Errors**: Verify Redis is accessible and RateLimitPolicy is applied
3. **Auth Failures**: Confirm Keycloak URL and realm configuration
4. **No Metrics**: Ensure ServiceMonitor is created and Prometheus is scraping

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

### Adding New Models

1. Deploy new KServe InferenceService
2. Create HTTPRoute for the new model
3. Apply RateLimitPolicy and AuthPolicy
4. Update monitoring configuration

### Custom Authentication

Modify AuthPolicy resources to integrate with different identity providers:

```yaml
authentication:
  "custom-auth":
    apiKey:
      selector:
        matchLabels:
          app: my-app
    credentials:
      authorizationHeader:
        prefix: "ApiKey "
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

### Redis Optimization

For high-traffic deployments, consider:
- Redis clustering
- Persistent storage
- Memory optimization
- Connection pooling

## Security Considerations

- Use proper TLS certificates (not self-signed)
- Configure network policies
- Enable mutual TLS in Istio
- Regular security updates
- Monitor for suspicious activity

## 🚀 Quick Start 

**If you have infrastructure but no model pods running** (like the current state), follow the detailed guide:

**👉 [Complete Step-by-Step Guide](STEP-BY-STEP.md)**

### TL;DR - Get Your First Model Running

```bash
cd deployment/kuadrant

# 1. Deploy your first model (Qwen3-0.6B - smallest and fastest)
kubectl apply -f ../model_serving/qwen3-0.6b-vllm-raw.yaml

# 2. Wait for model to download and start (5-15 minutes)
kubectl wait --for=condition=Ready inferenceservice qwen3-0-6b-instruct -n llm --timeout=900s

# 3. Deploy routing and policies
kubectl apply -f 05-model-routing.yaml
kubectl apply -f 07-api-key-secrets.yaml
kubectl apply -f 08-auth-policies-apikey.yaml
kubectl apply -f 06-rate-limit-policies.yaml

# 4. Test your model
kubectl port-forward -n istio-system svc/istio-ingressgateway 8000:80 &
curl -H 'Authorization: APIKEY admin-key-12345' \
     -H 'Content-Type: application/json' \
     -d '{"messages":[{"role":"user","content":"Write a Python function!"}]}' \
     http://localhost:8000/qwen/v1/chat/completions
```

## Localhost Development Workflow

### Starting Everything

```bash
cd deployment/kuadrant

# Follow the step-by-step guide for initial setup
# See: STEP-BY-STEP.md

# For daily development:
./localhost-setup.sh start     # Start port-forwards
./test-api.sh                  # Test the APIs
```

### Daily Development

```bash
./localhost-setup.sh status    # Check what's running
./localhost-setup.sh restart   # Restart port-forwards if needed
./localhost-setup.sh stop      # Stop when done
```

### Troubleshooting Localhost Setup

```bash
# Check if components are running
kubectl get pods -n kuadrant-system
kubectl get pods -n istio-system  
kubectl get pods -n kserve
kubectl get pods -n cert-manager
kubectl get pods -n minio-system
kubectl get pods -n llm

# Check port-forward status
./localhost-setup.sh status

# Restart everything
./localhost-setup.sh restart
```

### Common Issues and Solutions

1. **KServe CRDs not found**: 
   ```bash
   # Install cert-manager first
   kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.17.0/cert-manager.yaml
   kubectl wait --for=condition=Available deployment/cert-manager -n cert-manager --timeout=300s
   
   # Then install KServe
   kubectl apply --server-side -f https://github.com/kserve/kserve/releases/download/v0.15.0/kserve.yaml
   kubectl wait --for=condition=Available deployment/kserve-controller-manager -n kserve --timeout=300s
   ```

2. **ObjectBucketClaim errors (original model_serving files)**:
   ```bash
   # Fix model serving for MinIO
   ./fix-model-serving.sh
   ```

3. **KServe webhook certificate errors**:
   ```bash
   # Check cert-manager is running
   kubectl get pods -n cert-manager
   
   # Check certificates are issued
   kubectl get certificates -n kserve
   
   # If issues persist, restart KServe controller
   kubectl rollout restart deployment/kserve-controller-manager -n kserve
   ```

4. **Model servers not starting**:
   ```bash
   kubectl logs -n llm deployment/granite-model-server
   kubectl get events -n llm
   ```

5. **MinIO not accessible**:
   ```bash
   kubectl port-forward -n minio-system svc/minio 9001:9001
   # Access MinIO console at http://localhost:9001 (admin/admin)
   ```

4. **Authentication not working**: 
   - The mock setup works without authentication by default
   - To enable auth, deploy Keycloak and configure the auth policies

## Support

- [Kuadrant Documentation](https://docs.kuadrant.io/)
- [Istio Documentation](https://istio.io/docs/)
- [Gateway API Documentation](https://gateway-api.sigs.k8s.io/)
- [KServe Documentation](https://kserve.github.io/website/)