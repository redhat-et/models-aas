# API Key Authentication Guide

This guide explains how to use API key authentication instead of Keycloak for your Kuadrant deployment.

## Overview

API key authentication provides a simpler alternative to Keycloak for protecting your APIs. It's ideal for:
- Development and testing environments
- Internal services that don't need complex user management
- Scenarios where you want to avoid external dependencies

## API Key Structure

The system includes 4 predefined API keys with different access levels:

| API Key | Username | Role | Access Level |
|---------|----------|------|--------------|
| `admin-key-12345` | admin | admin | Full access to all models and operations |
| `dev-key-67890` | developer | developer | Standard development access |
| `user-key-abcdef` | user | user | Standard user access |
| `readonly-key-999` | readonly | readonly | Read-only access for monitoring |

## Usage

### Making API Calls

Use the `Authorization: Bearer` header with your API key:

```bash
curl -X POST http://localhost:8000/granite/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer admin-key-12345" \
  -d '{
    "model": "granite",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 50
  }'
```

### Testing Different Access Levels

```bash
# Admin access (full permissions)
curl -H "Authorization: Bearer admin-key-12345" http://localhost:8000/granite/...

# Developer access  
curl -H "Authorization: Bearer dev-key-67890" http://localhost:8000/mistral/...

# User access
curl -H "Authorization: Bearer user-key-abcdef" http://localhost:8000/nomic/...

# Read-only access (may be restricted on POST operations)
curl -H "Authorization: Bearer readonly-key-999" http://localhost:8000/granite/...
```

## Creating Custom API Keys

To create additional API keys:

1. Create a new secret:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: api-key-custom
  namespace: llm
  labels:
    authorino.kuadrant.io/managed-by: authorino
    app: models-api
  annotations:
    username: custom-user
    role: custom-role
    description: "Custom API key for specific use case"
stringData:
  api_key: "custom-key-xyz789"
type: Opaque
```

2. Apply the secret:

```bash
kubectl apply -f custom-api-key.yaml
```

3. The key is automatically picked up by the authentication system.

## Key Management

### Viewing Existing Keys

```bash
# List all API key secrets
kubectl get secrets -n llm -l app=models-api

# View details of a specific key
kubectl get secret api-key-admin -n llm -o yaml
```

### Rotating Keys

To rotate an API key:

1. Update the secret with a new key:

```bash
kubectl patch secret api-key-admin -n llm \
  --type='merge' \
  -p='{"stringData":{"api_key":"new-admin-key-54321"}}'
```

2. Update your applications to use the new key.

### Revoking Keys

To revoke an API key:

```bash
# Delete the secret
kubectl delete secret api-key-user -n llm

# Or remove the required labels to disable it
kubectl label secret api-key-user -n llm app-
```

## Authorization Rules

The current setup includes role-based authorization:

- **Admin role**: Full access to all operations
- **Developer role**: Standard development access  
- **User role**: Standard user access
- **Readonly role**: Limited to read operations

Authorization rules are defined in `08-auth-policies-apikey.yaml` and can be customized.

## Security Considerations

1. **Key Storage**: Store API keys securely and avoid committing them to version control.

2. **Key Rotation**: Regularly rotate API keys, especially in production.

3. **Least Privilege**: Use the appropriate role for each key - don't use admin keys for standard operations.

4. **Monitoring**: Monitor API key usage and watch for unusual patterns.

5. **HTTPS**: Always use HTTPS in production to protect keys in transit.

## Switching Back to Keycloak

If you need to switch back to Keycloak authentication:

1. Deploy Keycloak:
```bash
kubectl apply -f deployment/rh-sso/
```

2. Apply Keycloak auth policies:
```bash
kubectl apply -f 07-auth-policies.yaml
```

3. Remove API key policies:
```bash
kubectl delete -f 08-auth-policies-apikey.yaml
kubectl delete -f 07-api-key-secrets.yaml
```

## Troubleshooting

### 401 Unauthorized Errors

- Verify the API key exists: `kubectl get secret api-key-xxx -n llm`
- Check the authorization header format: `Authorization: Bearer your-key`
- Ensure the secret has the correct labels

### 403 Forbidden Errors

- Check the user's role in the secret annotations
- Verify the authorization policies allow the role
- Review the `AuthPolicy` configuration

### Key Not Working After Creation

- Verify labels match the selector in `AuthPolicy`
- Check that Authorino has picked up the new secret
- Allow a few seconds for configuration to propagate