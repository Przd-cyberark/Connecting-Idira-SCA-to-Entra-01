# Stream B: Azure Admin Guide
## Connecting ACME's Azure Entra Tenant to CyberArk Identity Security Platform

**Audience:** ACME Azure administrator  
**Before you start:** You must receive the following from the CyberArk admin before beginning any steps:

- The **platform name** (either `Idira` or `CyberArk`) — used in app display names throughout
- All **SCA and CCE identity parameters** from the CyberArk CCE API (issuer URLs, user IDs, audience values)
- ACME's **Entra Tenant ID** (the GUID of the Azure AD directory)

---

## Overview

You will create Azure app registrations, custom role definitions, service principals, federated credentials, and role assignments — all within Azure Cloud Shell. No CyberArk platform access is required.

**Order of operations is mandatory:**
1. Create the SCA service apps first
2. Create the CCE app last
3. Hand the app IDs back to the CyberArk admin

Everything below uses **Azure Cloud Shell** (Bash). Open it at: `https://shell.azure.com`

---

## Preparation

At the top of your Cloud Shell session, set these common variables (you'll reference them throughout):

```bash
ENTRA_ID="<ACME-Entra-Tenant-ID>"           # The GUID of the Azure AD tenant
PLATFORM="<Platform>"                         # e.g. Idira or CyberArk (capitalize as given)
PLATFORM_LOWER="<platform>"                   # e.g. idira or cyberark (lowercase)
ROLE_SCOPE="/providers/Microsoft.Management/managementGroups/$ENTRA_ID"
MICROSOFT_GRAPH_ENDPOINT="https://graph.microsoft.com"
MICROSOFT_GRAPH_RESOURCE_ID=$(az ad sp list --filter "appId eq '00000003-0000-0000-c000-000000000000'" --query [].id --output tsv)
```

---

## Part 1: SCA (Security Cloud Access)

SCA requires **two** app registrations — Entra and resource — both with Graph permissions.

**Identity values needed from CyberArk admin:**
- `SCA_IDENTITY_ISSUER_ENTRA`
- `SCA_IDENTITY_USER_ENTRA`
- `SCA_IDENTITY_ISSUER_RESOURCES`
- `SCA_IDENTITY_USER_RESOURCES`
- `SCA_IDENTITY_AUDIENCE`

### Step 1.1 — Set SCA Parameters

```bash
SCA_ENTRA_APP_DISPLAY_NAME="${PLATFORM}-SCA-app-entra"
SCA_RESOURCES_APP_DISPLAY_NAME="${PLATFORM}-SCA-app-resource"
SCA_ENTRA_ROLE_DISPLAY_NAME="${PLATFORM}-SCA-entra-role"
SCA_RESOURCES_ROLE_DISPLAY_NAME="${PLATFORM}-SCA-resources-role"

SCA_IDENTITY_ISSUER_ENTRA="<SCA-Identity-Issuer-Entra-from-CyberArk-admin>"
SCA_IDENTITY_USER_ENTRA="<SCA-Identity-User-Entra-from-CyberArk-admin>"
SCA_IDENTITY_ISSUER_RESOURCES="<SCA-Identity-Issuer-Resources-from-CyberArk-admin>"
SCA_IDENTITY_USER_RESOURCES="<SCA-Identity-User-Resources-from-CyberArk-admin>"
SCA_IDENTITY_AUDIENCE="api://AzureADTokenExchange"
```

### Step 1.2 — Create Role Definition Files

**Entra role** (no Actions):

```bash
cat > sca_entra_role.json << EOF
{
    "Name": "$SCA_ENTRA_ROLE_DISPLAY_NAME",
    "IsCustom": true,
    "Actions": [],
    "AssignableScopes": ["$ROLE_SCOPE"]
}
EOF
```

**Resources role** (broad authorization + management):

```bash
cat > sca_resources_role.json << EOF
{
    "Name": "$SCA_RESOURCES_ROLE_DISPLAY_NAME",
    "IsCustom": true,
    "Actions": [
        "Microsoft.Authorization/roleAssignments/read",
        "Microsoft.Authorization/roleAssignments/write",
        "Microsoft.Authorization/roleAssignments/delete",
        "Microsoft.Authorization/roleDefinitions/read",
        "Microsoft.ResourceGraph/resources/read",
        "Microsoft.Management/managementGroups/read"
    ],
    "AssignableScopes": ["$ROLE_SCOPE"]
}
EOF
```

### Step 1.3 — Create Roles

```bash
RES_SCA_ENTRA=$(az role definition create --role-definition sca_entra_role.json)
SCA_ENTRA_ROLE_NAME=$(jq -r '.roleName' <<< $RES_SCA_ENTRA)

RES_SCA_RESOURCES=$(az role definition create --role-definition sca_resources_role.json)
SCA_RESOURCES_ROLE_NAME=$(jq -r '.roleName' <<< $RES_SCA_RESOURCES)

rm sca_entra_role.json sca_resources_role.json
```

### Step 1.4 — Create App Registrations

**Entra app** (Graph permissions: RoleManagement, Group, User):

```bash
cat > sca_entra_permissions.json << EOF
[
  {
    "resourceAppId": "00000003-0000-0000-c000-000000000000",
    "resourceAccess": [
      {"id": "9e3f62cf-723e-4eba-9247-35def7408f82", "type": "Role"},
      {"id": "62a82d76-70ea-4829-96f2-1b1e37f5aa90", "type": "Role"},
      {"id": "97235f07-e226-4f63-ace3-39588e11d3a1", "type": "Role"}
    ]
  }
]
EOF

SCA_ENTRA_APP_ID=$(az ad app create \
  --display-name "$SCA_ENTRA_APP_DISPLAY_NAME" \
  --required-resource-accesses @sca_entra_permissions.json \
  | jq -r '.appId')

echo "SCA Entra App ID: $SCA_ENTRA_APP_ID"
```

**Resources app** (additional Group permissions):

```bash
cat > sca_resources_permissions.json << EOF
[
  {
    "resourceAppId": "00000003-0000-0000-c000-000000000000",
    "resourceAccess": [
      {"id": "62a82d76-70ea-4829-96f2-1b1e37f5aa90", "type": "Role"},
      {"id": "97235f07-e226-4f63-ace3-39588e11d3a1", "type": "Role"},
      {"id": "dbaae8cf-10b5-4b86-a4a1-f871c94c6695", "type": "Role"},
      {"id": "bf7b1a76-6e77-406b-b258-bf5c7720e98f", "type": "Role"}
    ]
  }
]
EOF

SCA_RESOURCES_APP_ID=$(az ad app create \
  --display-name "$SCA_RESOURCES_APP_DISPLAY_NAME" \
  --required-resource-accesses @sca_resources_permissions.json \
  | jq -r '.appId')

echo "SCA Resources App ID: $SCA_RESOURCES_APP_ID"
rm sca_entra_permissions.json sca_resources_permissions.json
```

### Step 1.5 — Create Service Principals

```bash
SCA_ENTRA_PRINCIPAL_ID=$(az ad sp create --id "$SCA_ENTRA_APP_ID" --query id --output tsv)
SCA_RESOURCES_PRINCIPAL_ID=$(az ad sp create --id "$SCA_RESOURCES_APP_ID" --query id --output tsv)
```

### Step 1.6 — Create Federated Credentials

**Entra app:**

```bash
cat > sca_entra_cred.json << EOF
{
    "name": "sca-entra-federated-credential",
    "issuer": "$SCA_IDENTITY_ISSUER_ENTRA",
    "subject": "$SCA_IDENTITY_USER_ENTRA",
    "audiences": ["$SCA_IDENTITY_AUDIENCE"]
}
EOF

az ad app federated-credential create --id "$SCA_ENTRA_APP_ID" --parameters sca_entra_cred.json
rm sca_entra_cred.json
```

**Resources app:**

```bash
cat > sca_resources_cred.json << EOF
{
    "name": "sca-resources-federated-credential",
    "issuer": "$SCA_IDENTITY_ISSUER_RESOURCES",
    "subject": "$SCA_IDENTITY_USER_RESOURCES",
    "audiences": ["$SCA_IDENTITY_AUDIENCE"]
}
EOF

az ad app federated-credential create --id "$SCA_RESOURCES_APP_ID" --parameters sca_resources_cred.json
rm sca_resources_cred.json
```

### Step 1.7 — Assign Roles

```bash
az role assignment create \
  --assignee "$SCA_ENTRA_APP_ID" \
  --role "$SCA_ENTRA_ROLE_NAME" \
  --scope "$ROLE_SCOPE"

az role assignment create \
  --assignee "$SCA_RESOURCES_APP_ID" \
  --role "$SCA_RESOURCES_ROLE_NAME" \
  --scope "$ROLE_SCOPE"
```

### Step 1.8 — Grant Admin Consent

**Entra app** (3 permissions):

```bash
# RoleManagement.Read.Directory
az rest --method POST \
  --url "$MICROSOFT_GRAPH_ENDPOINT/v1.0/servicePrincipals/$SCA_ENTRA_PRINCIPAL_ID/appRoleAssignments" \
  --body "{\"principalId\": \"$SCA_ENTRA_PRINCIPAL_ID\", \"resourceId\": \"$MICROSOFT_GRAPH_RESOURCE_ID\", \"appRoleId\": \"9e3f62cf-723e-4eba-9247-35def7408f82\"}"

# Group.ReadWrite.All
az rest --method POST \
  --url "$MICROSOFT_GRAPH_ENDPOINT/v1.0/servicePrincipals/$SCA_ENTRA_PRINCIPAL_ID/appRoleAssignments" \
  --body "{\"principalId\": \"$SCA_ENTRA_PRINCIPAL_ID\", \"resourceId\": \"$MICROSOFT_GRAPH_RESOURCE_ID\", \"appRoleId\": \"62a82d76-70ea-4829-96f2-1b1e37f5aa90\"}"

# User.ReadBasic.All
az rest --method POST \
  --url "$MICROSOFT_GRAPH_ENDPOINT/v1.0/servicePrincipals/$SCA_ENTRA_PRINCIPAL_ID/appRoleAssignments" \
  --body "{\"principalId\": \"$SCA_ENTRA_PRINCIPAL_ID\", \"resourceId\": \"$MICROSOFT_GRAPH_RESOURCE_ID\", \"appRoleId\": \"97235f07-e226-4f63-ace3-39588e11d3a1\"}"
```

**Resources app** (4 permissions):

```bash
# Group.ReadWrite.All
az rest --method POST \
  --url "$MICROSOFT_GRAPH_ENDPOINT/v1.0/servicePrincipals/$SCA_RESOURCES_PRINCIPAL_ID/appRoleAssignments" \
  --body "{\"principalId\": \"$SCA_RESOURCES_PRINCIPAL_ID\", \"resourceId\": \"$MICROSOFT_GRAPH_RESOURCE_ID\", \"appRoleId\": \"62a82d76-70ea-4829-96f2-1b1e37f5aa90\"}"

# User.ReadBasic.All
az rest --method POST \
  --url "$MICROSOFT_GRAPH_ENDPOINT/v1.0/servicePrincipals/$SCA_RESOURCES_PRINCIPAL_ID/appRoleAssignments" \
  --body "{\"principalId\": \"$SCA_RESOURCES_PRINCIPAL_ID\", \"resourceId\": \"$MICROSOFT_GRAPH_RESOURCE_ID\", \"appRoleId\": \"97235f07-e226-4f63-ace3-39588e11d3a1\"}"

# GroupMember.ReadWrite.All
az rest --method POST \
  --url "$MICROSOFT_GRAPH_ENDPOINT/v1.0/servicePrincipals/$SCA_RESOURCES_PRINCIPAL_ID/appRoleAssignments" \
  --body "{\"principalId\": \"$SCA_RESOURCES_PRINCIPAL_ID\", \"resourceId\": \"$MICROSOFT_GRAPH_RESOURCE_ID\", \"appRoleId\": \"dbaae8cf-10b5-4b86-a4a1-f871c94c6695\"}"

# Group.Create
az rest --method POST \
  --url "$MICROSOFT_GRAPH_ENDPOINT/v1.0/servicePrincipals/$SCA_RESOURCES_PRINCIPAL_ID/appRoleAssignments" \
  --body "{\"principalId\": \"$SCA_RESOURCES_PRINCIPAL_ID\", \"resourceId\": \"$MICROSOFT_GRAPH_RESOURCE_ID\", \"appRoleId\": \"bf7b1a76-6e77-406b-b258-bf5c7720e98f\"}"
```

**Record these values — you will give them to the CyberArk admin:**
- SCA Entra App ID: `$SCA_ENTRA_APP_ID`
- SCA Resources App ID: `$SCA_RESOURCES_APP_ID`

---

## Part 2: CCE App (Always Required)

This must be created **after** all service apps above are complete.

**Identity values needed from CyberArk admin:**
- `CLOUD_ONBOARDING_IDENTITY_ISSUER`
- `CLOUD_ONBOARDING_IDENTITY_USER_ID`
- `CLOUD_ONBOARDING_IDENTITY_AUDIENCE`

### Step 2.1 — Create the CCE App Registration

```bash
CCE_APP_ID=$(az ad app create \
  --display-name "${PLATFORM}-CCE-app" \
  --required-resource-accesses '[{"resourceAppId":"00000003-0000-0000-c000-000000000000","resourceAccess":[{"id":"cac88765-0581-4025-9725-5ebc13f729ee","type":"Role"}]}]' \
  --query appId --output tsv)

echo "CCE App ID: $CCE_APP_ID"
```

### Step 2.2 — Set CCE Identity Parameters

```bash
CLOUD_ONBOARDING_IDENTITY_ISSUER="<CCE-Identity-Issuer-from-CyberArk-admin>"
CLOUD_ONBOARDING_IDENTITY_USER_ID="<CCE-Identity-User-ID-from-CyberArk-admin>"
CLOUD_ONBOARDING_IDENTITY_AUDIENCE="<CCE-Identity-Audience-from-CyberArk-admin>"
```

### Step 2.3 — Create Federated Credential

```bash
cat > cce_cred.json << EOF
{
    "name": "cce-federated-credential",
    "issuer": "$CLOUD_ONBOARDING_IDENTITY_ISSUER",
    "subject": "$CLOUD_ONBOARDING_IDENTITY_USER_ID",
    "audiences": ["$CLOUD_ONBOARDING_IDENTITY_AUDIENCE"]
}
EOF

az ad app federated-credential create --id "$CCE_APP_ID" --parameters cce_cred.json
rm cce_cred.json
```

### Step 2.4 — Create Service Principal

```bash
CCE_PRINCIPAL_ID=$(az ad sp create --id "$CCE_APP_ID" --query id --output tsv)
```

### Step 2.5 — Assign Management Group Reader Role

```bash
az role assignment create \
  --assignee "$CCE_APP_ID" \
  --role "Management Group Reader" \
  --scope "$ROLE_SCOPE"
```

### Step 2.6 — Grant Admin Consent

```bash
# CrossTenantInformation.ReadBasic.All
az rest --method POST \
  --url "$MICROSOFT_GRAPH_ENDPOINT/v1.0/servicePrincipals/$CCE_PRINCIPAL_ID/appRoleAssignments" \
  --body "{\"principalId\": \"$CCE_PRINCIPAL_ID\", \"resourceId\": \"$MICROSOFT_GRAPH_RESOURCE_ID\", \"appRoleId\": \"cac88765-0581-4025-9725-5ebc13f729ee\"}"
```

**Record this value — you will give it to the CyberArk admin:**
- CCE App ID: `$CCE_APP_ID`

---

## Part 3: Hand Off to CyberArk Admin

Send the following to the CyberArk admin:

| App | App ID |
|---|---|
| CCE app | (value of `$CCE_APP_ID`) |
| SCA Entra app | (value of `$SCA_ENTRA_APP_ID`) |
| SCA Resources app | (value of `$SCA_RESOURCES_APP_ID`) |

You can also retrieve them at any time with:

```bash
# CCE
az ad app list --filter "displayname eq '${PLATFORM}-CCE-app'" --query [].appId --output tsv

# SCA Entra
az ad app list --filter "displayname eq '${PLATFORM}-SCA-app-entra'" --query [].appId --output tsv

# SCA Resources
az ad app list --filter "displayname eq '${PLATFORM}-SCA-app-resource'" --query [].appId --output tsv
```

---

## Summary of Azure Admin Responsibilities

| Part | What you create | Services |
|---|---|---|
| Part 1 | 2 apps, 2 custom roles, 2 service principals, 2 federated credentials, 2 role assignments, 7 consent grants | SCA |
| Part 2 | 1 app, 1 service principal, 1 federated credential, 1 role assignment, 1 consent grant | CCE (always) |
| Part 3 | Hand off all app IDs to CyberArk admin | — |
