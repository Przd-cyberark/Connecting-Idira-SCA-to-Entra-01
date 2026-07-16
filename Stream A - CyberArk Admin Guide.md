# Stream A: CyberArk Admin Guide
## Connecting ACME's Azure Entra Tenant to CyberArk Identity Security Platform

**Audience:** ACME CyberArk administrator  
**Prerequisite:** Stream B (Azure Admin tasks) must be fully completed before Step 3.

---

## Overview

Your role has two parts:
1. **Before Azure work begins** — provide the Azure admin with identity parameters they need to configure Azure app registrations.
2. **After Azure work is done** — call the CCE onboarding API to register the Entra tenant in the CyberArk platform.

---

## Step 1: Determine the Platform Name

Before anything else, determine which platform name applies to your tenant. This affects the display names of all Azure resources the Azure team will create.

| Your tenant was created... | Use in resource names |
|---|---|
| On or after June 14, 2026 | **Idira** / **idira** / **IDIRA** |
| Before June 14, 2026, and no services have been onboarded yet | **Idira** / **idira** / **IDIRA** |
| Before June 14, 2026, and services are already onboarded | **CyberArk** / **cyberark** / **CYBERARK** |

Communicate this to the Azure admin before they start.

---

## Step 2: Obtain Identity Parameters

The Azure admin needs specific identity values to configure federated credentials on Azure app registrations. You retrieve these from the CCE API.

### 2.1 Get a Bearer Token

Log in to the CyberArk Identity Security Platform and obtain a bearer token for API authentication. The exact method depends on your tenant's configuration (OIDC, service account, or UI-based token copy).

### 2.2 Call the Identity Parameters API

```
GET https://<subdomain>.cloudonboarding.cyberark.cloud/api/azure/identity-params
Authorization: Bearer <your-token>
```

Replace `<subdomain>` with your CyberArk tenant subdomain.

### 2.3 Collect and Share the Values

From the response, note the following and pass them to the Azure admin:

| Parameter | Description | Needed for service |
|---|---|---|
| `SCA Identity Issuer (Entra)` | Issuer URL for SCA Entra app | SCA |
| `SCA Identity User (Entra)` | Subject for SCA Entra federated credential | SCA |
| `SCA Identity Issuer (Resources)` | Issuer URL for SCA resource app | SCA |
| `SCA Identity User (Resources)` | Subject for SCA resource federated credential | SCA |
| `CCE Identity Issuer` | Issuer URL for CCE app | CCE (always required) |
| `CCE Identity User ID` | Subject user ID for CCE federated credential | CCE (always required) |
| `CCE Identity Audience` | Audience value for CCE federated credential | CCE (always required) |

Also confirm with the Azure admin before they start:
- ACME's **Entra Tenant ID** (the GUID of the Azure AD directory)

---

## Step 3: Register the Entra Tenant via API

After the Azure admin confirms all app registrations are created, you call the CCE onboarding endpoint.

### 3.1 Collect App IDs from the Azure Admin

Ask the Azure admin to provide the App (client) IDs for each app they created:

| App | Display name created by Azure admin |
|---|---|
| CCE app | `<Platform>-CCE-app` |
| SCA Entra app | `<Platform>-SCA-app-entra` |
| SCA Resource app | `<Platform>-SCA-app-resource` |

### 3.2 Call the Onboarding API

```
POST https://<subdomain>.cloudonboarding.cyberark.cloud/api/azure/manual
Authorization: Bearer <your-token>
Content-Type: application/json
```

#### Request Body

```json
{
  "deploymentType": "organization",
  "entraId": "<ACME-Entra-Tenant-ID>",
  "services": [
    {
      "serviceName": "sca",
      "resources": {
        "applications": [
          {
            "application_id": "<SCA-ENTRA-APP-ID>",
            "identity_trusted_username": "<SCA-identity-trusted-user-entra>"
          },
          {
            "application_id": "<SCA-RESOURCE-APP-ID>",
            "identity_trusted_username": "<SCA-identity-trusted-user-resources>"
          }
        ]
      }
    }
  ],
  "cceResources": {
    "appId": "<CCE-APP-ID>"
  }
}
```

### 3.3 Save the Onboarding ID

The API response contains an **onboarding ID**. Save this value — it is required for any subsequent API calls related to this tenant (e.g., adding management groups, subscriptions, or additional services later).

---

## Summary of CyberArk Admin Responsibilities

| Phase | Your action |
|---|---|
| Before Azure work | Retrieve identity parameters from CCE API; share with Azure admin |
| Coordination | Confirm SCA is in scope; share platform name |
| After Azure work | Collect app IDs from Azure admin; call POST onboarding API |
| After onboarding | Save returned onboarding ID for future use |
