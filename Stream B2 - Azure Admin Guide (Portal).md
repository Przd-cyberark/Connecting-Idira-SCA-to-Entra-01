# Stream B2: Azure Admin Guide — Azure Portal
## Connecting ACME's Azure Entra Tenant to CyberArk Identity Security Platform

**Audience:** ACME Azure administrator  
**Before you start:** You must receive the following from the CyberArk admin before beginning:

- The **platform name** (either `Idira` or `CyberArk`) — used in app display names throughout
- **SCA identity parameters** from the CyberArk CCE API:
  - SCA Identity Issuer (Entra)
  - SCA Identity User (Entra)
  - SCA Identity Issuer (Resources)
  - SCA Identity User (Resources)
- **CCE identity parameters:**
  - CCE Identity Issuer
  - CCE Identity User ID
  - CCE Identity Audience
- ACME's **Entra Tenant ID** (the GUID of the Azure AD directory)

All portal steps below are performed at: **https://portal.azure.com**

---

## Overview

You will create app registrations, custom roles, federated credentials, role assignments, and grant admin consent — all through the Azure portal UI.

**Order of operations is mandatory:**
1. Create the two SCA service apps first (Entra app and Resources app)
2. Create the CCE app last
3. Hand the app IDs back to the CyberArk admin

---

## Part 1: SCA (Security Cloud Access)

SCA requires two app registrations: one for Entra (directory-level) access and one for Azure Resources access.

---

### Step 1.1 — Create the SCA Entra App Registration

1. In the portal search bar, type **Microsoft Entra ID** and open it.
2. In the left menu, click **App registrations**.
3. Click **+ New registration**.
4. Fill in the form:
   - **Name:** `<Platform>-SCA-app-entra`  
     *(e.g. `Idira-SCA-app-entra` or `CyberArk-SCA-app-entra`)*
   - **Supported account types:** select **Accounts in this organizational directory only**
   - **Redirect URI:** leave blank
5. Click **Register**.
6. You are now on the app's overview page. **Copy and save the Application (client) ID** — you will need it later.

---

### Step 1.2 — Add API Permissions to the SCA Entra App

1. In the left menu of the SCA Entra app, click **API permissions**.
2. Click **+ Add a permission**.
3. Select **Microsoft Graph**.
4. Select **Application permissions**.
5. In the search box, search for and check each of the following permissions:
   - `RoleManagement.Read.Directory`
   - `Group.ReadWrite.All`
   - `User.ReadBasic.All`
6. Click **Add permissions**.

> **Note:** Do not grant admin consent yet — that is done in Step 1.11.

---

### Step 1.3 — Create Federated Credential on the SCA Entra App

1. In the left menu, click **Certificates & secrets**.
2. Click the **Federated credentials** tab.
3. Click **+ Add credential**.
4. For **Federated credential scenario**, select **Other issuer**.
5. Fill in the form:
   - **Issuer:** paste the **SCA Identity Issuer (Entra)** value from the CyberArk admin
   - **Subject identifier:** paste the **SCA Identity User (Entra)** value from the CyberArk admin
   - **Audience:** `api://AzureADTokenExchange`
   - **Name:** `sca-entra-federated-credential`
6. Click **Add**.

---

### Step 1.4 — Create the SCA Resources App Registration

1. Navigate back to **Microsoft Entra ID** > **App registrations**.
2. Click **+ New registration**.
3. Fill in the form:
   - **Name:** `<Platform>-SCA-app-resource`  
     *(e.g. `Idira-SCA-app-resource`)*
   - **Supported account types:** select **Accounts in this organizational directory only**
   - **Redirect URI:** leave blank
4. Click **Register**.
5. **Copy and save the Application (client) ID** — you will need it later.

---

### Step 1.5 — Add API Permissions to the SCA Resources App

1. In the left menu, click **API permissions**.
2. Click **+ Add a permission**.
3. Select **Microsoft Graph**.
4. Select **Application permissions**.
5. Search for and check each of the following permissions:
   - `Group.ReadWrite.All`
   - `User.ReadBasic.All`
   - `GroupMember.ReadWrite.All`
   - `Group.Create`
6. Click **Add permissions**.

> **Note:** Do not grant admin consent yet — that is done in Step 1.12.

---

### Step 1.6 — Create Federated Credential on the SCA Resources App

1. In the left menu, click **Certificates & secrets**.
2. Click the **Federated credentials** tab.
3. Click **+ Add credential**.
4. For **Federated credential scenario**, select **Other issuer**.
5. Fill in the form:
   - **Issuer:** paste the **SCA Identity Issuer (Resources)** value from the CyberArk admin
   - **Subject identifier:** paste the **SCA Identity User (Resources)** value from the CyberArk admin
   - **Audience:** `api://AzureADTokenExchange`
   - **Name:** `sca-resources-federated-credential`
6. Click **Add**.

---

### Step 1.7 — Create the SCA Entra Custom Role

This role has no Actions (it grants no resource permissions) and is used by the Entra app for identity-level access only.

1. In the portal search bar, type **Management Groups** and open it.
2. Click on the management group whose **ID matches the Entra Tenant ID** (this is the tenant root group).
3. In the left menu, click **Access control (IAM)**.
4. Click **+ Add** > **Add custom role**.
5. On the **Basics** tab:
   - **Custom role name:** `<Platform>-SCA-entra-role`
   - **Description:** leave blank or add a note
   - **Baseline permissions:** select **Start from scratch**
6. Click **Next** to go to the **Permissions** tab.
7. Do **not** add any permissions — leave the Actions list empty.
8. Click **Next** to go to the **Assignable scopes** tab.
9. Confirm the scope shown is the current management group. If not, click **+ Add assignable scopes** and select the tenant root management group.
10. Click **Next**, review, then click **Create**.

---

### Step 1.8 — Create the SCA Resources Custom Role

1. Still in **Management Groups** > [tenant root] > **Access control (IAM)**.
2. Click **+ Add** > **Add custom role**.
3. On the **Basics** tab:
   - **Custom role name:** `<Platform>-SCA-resources-role`
   - **Baseline permissions:** select **Start from scratch**
4. Click **Next** to go to the **Permissions** tab.
5. Click **+ Add permissions**.
6. In the search box, search for and add each of the following Actions one by one:
   - `Microsoft.Authorization/roleAssignments/read`
   - `Microsoft.Authorization/roleAssignments/write`
   - `Microsoft.Authorization/roleAssignments/delete`
   - `Microsoft.Authorization/roleDefinitions/read`
   - `Microsoft.ResourceGraph/resources/read`
   - `Microsoft.Management/managementGroups/read`

   For each: search the permission in the search box, check its checkbox, then click **Add**.
7. Click **Next** to go to the **Assignable scopes** tab.
8. Confirm the scope is the tenant root management group.
9. Click **Next**, review, then click **Create**.

---

### Step 1.9 — Assign the SCA Entra Role to the SCA Entra App

1. Still in **Management Groups** > [tenant root] > **Access control (IAM)**.
2. Click **+ Add** > **Add role assignment**.
3. On the **Role** tab:
   - Click the **Privileged administrator roles** tab or search in the search box for `<Platform>-SCA-entra-role`.
   - Select it and click **Next**.
4. On the **Members** tab:
   - **Assign access to:** select **User, group, or service principal**
   - Click **+ Select members**
   - Search for `<Platform>-SCA-app-entra` and select it
   - Click **Select**
5. Click **Next**, review, then click **Review + assign**.

---

### Step 1.10 — Assign the SCA Resources Role to the SCA Resources App

1. Still in **Management Groups** > [tenant root] > **Access control (IAM)**.
2. Click **+ Add** > **Add role assignment**.
3. On the **Role** tab:
   - Search for `<Platform>-SCA-resources-role` and select it.
   - Click **Next**.
4. On the **Members** tab:
   - **Assign access to:** select **User, group, or service principal**
   - Click **+ Select members**
   - Search for `<Platform>-SCA-app-resource` and select it
   - Click **Select**
5. Click **Next**, review, then click **Review + assign**.

---

### Step 1.11 — Grant Admin Consent for the SCA Entra App

1. Navigate to **Microsoft Entra ID** > **App registrations**.
2. Open `<Platform>-SCA-app-entra`.
3. In the left menu, click **API permissions**.
4. Click **Grant admin consent for [your tenant name]**.
5. Click **Yes** to confirm.
6. Verify that all three permissions now show a green checkmark with status **Granted for [tenant]**.

---

### Step 1.12 — Grant Admin Consent for the SCA Resources App

1. Navigate to **Microsoft Entra ID** > **App registrations**.
2. Open `<Platform>-SCA-app-resource`.
3. In the left menu, click **API permissions**.
4. Click **Grant admin consent for [your tenant name]**.
5. Click **Yes** to confirm.
6. Verify that all four permissions now show a green checkmark with status **Granted for [tenant]**.

---

## Part 2: CCE App (Always Required)

This must be created **after** the SCA apps above are complete.

---

### Step 2.1 — Create the CCE App Registration

1. Navigate to **Microsoft Entra ID** > **App registrations**.
2. Click **+ New registration**.
3. Fill in the form:
   - **Name:** `<Platform>-CCE-app`  
     *(e.g. `Idira-CCE-app`)*
   - **Supported account types:** select **Accounts in this organizational directory only**
   - **Redirect URI:** leave blank
4. Click **Register**.
5. **Copy and save the Application (client) ID** — you will need it later.

---

### Step 2.2 — Add API Permission to the CCE App

1. In the left menu, click **API permissions**.
2. Click **+ Add a permission**.
3. Select **Microsoft Graph**.
4. Select **Application permissions**.
5. Search for `CrossTenantInformation` and check:
   - `CrossTenantInformation.ReadBasic.All`
6. Click **Add permissions**.

---

### Step 2.3 — Create Federated Credential on the CCE App

1. In the left menu, click **Certificates & secrets**.
2. Click the **Federated credentials** tab.
3. Click **+ Add credential**.
4. For **Federated credential scenario**, select **Other issuer**.
5. Fill in the form:
   - **Issuer:** paste the **CCE Identity Issuer** value from the CyberArk admin
   - **Subject identifier:** paste the **CCE Identity User ID** value from the CyberArk admin
   - **Audience:** paste the **CCE Identity Audience** value from the CyberArk admin
   - **Name:** `cce-federated-credential`
6. Click **Add**.

---

### Step 2.4 — Assign the Management Group Reader Role to the CCE App

1. Navigate to **Management Groups** > [tenant root group] > **Access control (IAM)**.
2. Click **+ Add** > **Add role assignment**.
3. On the **Role** tab:
   - Search for `Management Group Reader` and select it.
   - Click **Next**.
4. On the **Members** tab:
   - **Assign access to:** select **User, group, or service principal**
   - Click **+ Select members**
   - Search for `<Platform>-CCE-app` and select it
   - Click **Select**
5. Click **Next**, review, then click **Review + assign**.

---

### Step 2.5 — Grant Admin Consent for the CCE App

1. Navigate to **Microsoft Entra ID** > **App registrations**.
2. Open `<Platform>-CCE-app`.
3. In the left menu, click **API permissions**.
4. Click **Grant admin consent for [your tenant name]**.
5. Click **Yes** to confirm.
6. Verify that `CrossTenantInformation.ReadBasic.All` shows a green checkmark with status **Granted for [tenant]**.

---

## Part 3: Hand Off to CyberArk Admin

Collect the Application (client) IDs you saved during registration and send them to the CyberArk admin:

| App | Where to find the ID |
|---|---|
| CCE app | Entra ID > App registrations > `<Platform>-CCE-app` > Overview |
| SCA Entra app | Entra ID > App registrations > `<Platform>-SCA-app-entra` > Overview |
| SCA Resources app | Entra ID > App registrations > `<Platform>-SCA-app-resource` > Overview |

The **Application (client) ID** is displayed prominently on each app's Overview page.

---

## Summary of Azure Admin Responsibilities

| Part | What you create | Where in portal |
|---|---|---|
| Part 1 (SCA) | 2 app registrations, 2 custom roles, 2 federated credentials, 2 role assignments, 2 admin consent grants | Entra ID + Management Groups |
| Part 2 (CCE) | 1 app registration, 1 federated credential, 1 role assignment, 1 admin consent grant | Entra ID + Management Groups |
| Part 3 | Hand off 3 app IDs to CyberArk admin | — |
