# Models as a Service (MaaS) - Step by Step Guide

This guide walks you through deploying a complete MaaS platform using KServe + Kuadrant from scratch.

## Current Infrastructure Status

Based on your `kubectl get pods --all-namespaces`, you already have:

✅ **Cert-Manager**: TLS certificate management  
✅ **Istio**: Service mesh and ingress gateway  
✅ **KServe**: Model serving controllers  
✅ **Kuadrant**: API gateway policies (Authorino, Limitador)  
✅ **MinIO**: S3-compatible storage  
✅ **Gateway Pod**: `kuadrant-gateway-istio` running  

❌ **Missing**: Actual AI model pods (this is what we'll deploy)

## How KServe Model Serving Works

Understanding the KServe flow is crucial:

```
1. InferenceService (YAML) 
   ↓
2. KServe Controller creates Deployment
   ↓  
3. Deployment creates Pod(s) with model
   ↓
4. Service exposes the Pod
   ↓
5. HTTPRoute routes traffic to Service
   ↓
6. Gateway + Kuadrant policies control access
```

**Key Point**: An `InferenceService` is a KServe custom resource that automatically creates:
- `Deployment` → Manages model pod lifecycle
- `Pod` → Runs the actual model server (vLLM, TEI, etc.)  
- `Service` → Exposes the pod internally
- Optionally: `HPA` for auto-scaling

## Step 1: Verify Infrastructure is Ready

```bash
# Check KServe is running
kubectl get pods -n kserve
# Should see: kserve-controller-manager

# Check Kuadrant components  
kubectl get pods -n kuadrant-system
# Should see: authorino, limitador, kuadrant-operator

# Check Istio gateway
kubectl get pods -n llm | grep gateway
# Should see: kuadrant-gateway-istio pod

# Check gateway configuration
kubectl get gateway -n llm
# Should see: kuadrant-gateway
```

## Step 2: Deploy Your First Model (Qwen3-0.6B)

Let's start with the smallest, fastest model:

```bash
# IMPORTANT: Deploy the latest vLLM runtime first (supports Qwen3)
kubectl apply -f ../model_serving/vllm-latest-runtime.yaml

# Deploy the Qwen model InferenceService
kubectl apply -f ../model_serving/qwen3-0.6b-vllm-raw.yaml

# Watch it get created (this triggers the KServe workflow)
kubectl get inferenceservice -n llm
kubectl describe inferenceservice qwen3-0-6b-instruct -n llm

# Watch for the actual pod to be created (may take 2-5 minutes)
kubectl get pods -n llm -l serving.kserve.io/inferenceservice
```

**What happens internally:**
1. KServe controller sees the InferenceService
2. Creates a Deployment with your model specification  
3. Kubernetes schedules a pod with GPU resources
4. Storage-initializer downloads Qwen3-0.6B model from HuggingFace (1-2 minutes)
5. Latest vLLM image loads the model with Qwen3 support (2-3 minutes)
6. vLLM starts serving the model on port 8080
7. KServe creates a Service to expose the pod

## Step 3: Verify Model Pod is Running

```bash
# Check if pod is created and downloading model
kubectl get pods -n llm -o wide

# Expected output should show something like:
# qwen3-0-6b-instruct-predictor-xxxxx   0/1   Init:0/1   0   5m   <none>   minikube

# Watch the download progress (model downloads from HuggingFace)
kubectl logs -n llm -l serving.kserve.io/inferenceservice=qwen3-0-6b-instruct -f

# Wait for READY status (5-15 minutes for download + startup)
kubectl wait --for=condition=Ready inferenceservice qwen3-0-6b-instruct -n llm --timeout=900s

# Final verification - pod should be Running
kubectl get pods -n llm -l serving.kserve.io/inferenceservice
```

## Step 4: Deploy Gateway Routing

Now create the HTTPRoute to connect your model to the gateway:

```bash
# Deploy the HTTPRoute for Qwen model
kubectl apply -f 05-model-routing.yaml

# Check the route was created
kubectl get httproute -n llm
kubectl describe httproute qwen-route -n llm

# Verify the backend service exists
kubectl get service -n llm | grep qwen
```

## Step 5: Deploy API Policies

```bash
# Deploy API key secrets
kubectl apply -f 07-api-key-secrets.yaml

# Deploy authentication policies
kubectl apply -f 08-auth-policies-apikey.yaml

# Deploy rate limiting
kubectl apply -f 06-rate-limit-policies.yaml

# Verify policies are applied
kubectl get authpolicy,ratelimitpolicy -n llm
```

## Step 6: Test Your Model with Authentication

**IMPORTANT**: For authentication to work, you MUST port-forward to the Kuadrant gateway service in the `llm` namespace:

```bash
# Port-forward to Kuadrant gateway (REQUIRED for authentication)
kubectl port-forward -n llm svc/kuadrant-gateway-istio 8000:80 &

# Wait for connection to establish
sleep 2

# Test the PROTECTED model endpoint (authentication required)
curl -H 'Authorization: APIKEY admin-key-12345' \
     -H 'Content-Type: application/json' \
     -d '{"model":"qwen3-0-6b-instruct","messages":[{"role":"user","content":"Hello! Write a Python function."}]}' \
     http://localhost:8000/qwen3/v1/chat/completions

# Expected: JSON response with AI-generated text
```

**Verify Authentication is Working:**
```bash
# Test WITHOUT API key (should be blocked)
curl -H 'Content-Type: application/json' \
     -d '{"model":"qwen3-0-6b-instruct","messages":[{"role":"user","content":"Hello"}]}' \
     http://localhost:8000/qwen3/v1/chat/completions

# Expected: Request hangs/times out (blocked by Kuadrant AuthPolicy)
```

## Troubleshooting Common Issues

### No Model Pods Appearing

```bash
# Check if InferenceService was created
kubectl get inferenceservice -n llm

# Check KServe controller logs
kubectl logs -n kserve deployment/kserve-controller-manager

# Check events in llm namespace
kubectl get events -n llm --sort-by=.metadata.creationTimestamp
```

### Pod Stuck in Pending/Init

```bash
# Check resource availability
kubectl describe pod -n llm -l serving.kserve.io/inferenceservice

# Common issues:
# - No GPU nodes available
# - Insufficient memory/CPU
# - Image pull failures
# - Storage issues
```

### Model Download Failures

```bash
# Check pod logs for download progress
kubectl logs -n llm -l serving.kserve.io/inferenceservice=qwen3-0-6b-instruct

# Common issues:
# - HuggingFace token required for private models
# - Network connectivity issues
# - Disk space insufficient
```

### 502 Bad Gateway Errors

```bash
# Check if model pod is actually ready
kubectl get pods -n llm -l serving.kserve.io/inferenceservice

# Check service endpoints
kubectl get endpoints -n llm

# Check HTTPRoute configuration  
kubectl describe httproute qwen-route -n llm

# Check if model is serving on correct port
kubectl port-forward -n llm pod/<qwen-pod-name> 8080:8080
curl http://localhost:8080/health
```

## Complete Architecture Flow

Once everything is working, here's the complete request flow:

```
User Request
    ↓
curl with APIKEY header
    ↓
Istio Gateway (port 8000)
    ↓
Kuadrant AuthPolicy (validates API key)
    ↓  
Kuadrant RateLimitPolicy (checks limits)
    ↓
HTTPRoute (/qwen → qwen3-0-6b-instruct-predictor service)
    ↓
Kubernetes Service (load balances to pod)
    ↓
Model Pod (vLLM serving Qwen3-0.6B)
    ↓
AI Response back through same path
```

## Adding More Models

Once Qwen is working, deploy additional models:

```bash
# Deploy all models at once
kubectl apply -f ../model_serving/ -n llm

# Or deploy individually  
kubectl apply -f ../model_serving/granite-code-vllm-raw.yaml
kubectl apply -f ../model_serving/mistral-vllm-raw.yaml
kubectl apply -f ../model_serving/nomic-embed-raw.yaml

# Monitor all deployments
kubectl get inferenceservice -n llm
kubectl get pods -n llm -l serving.kserve.io/inferenceservice
```

## Key Files Explained

- **`../model_serving/vllm-latest-runtime.yaml`**: Latest vLLM ServingRuntime with Qwen3 support
- **`../model_serving/qwen3-0.6b-vllm-raw.yaml`**: Defines the Qwen3-0.6B InferenceService
- **`05-model-routing.yaml`**: HTTPRoute connecting `/qwen3` to the model service  
- **`08-auth-policies-apikey.yaml`**: API key authentication for the route
- **`06-rate-limit-policies.yaml`**: Rate limiting policies per model
- **`07-api-key-secrets.yaml`**: API key secrets for user access

**New vLLM Runtime Features:**
- Uses `vllm/vllm-openai:latest` image for latest model support
- Includes `--trust-remote-code` for Qwen3 compatibility
- Serves on port 8080 with full OpenAI API compatibility

The beauty of this architecture is that each model gets its own InferenceService, Pod, Service, HTTPRoute, and policies - providing complete isolation and independent scaling.