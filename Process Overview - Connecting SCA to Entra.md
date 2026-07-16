# Process Overview: Connecting SCA to Entra
## Sequence of Actions for All Participants

This document defines the exact order in which the two work streams must be executed.
It does not repeat step details — refer to the linked guides for full instructions.

| Guide | Audience | File |
|---|---|---|
| Stream A | CyberArk administrator | `Stream A - CyberArk Admin Guide.md` |
| Stream B | Azure administrator | `Stream B - Azure Admin Guide.md` |

---

## Who Does What and When

The two streams are **not parallel**. They are sequential with two hand-off points.

```
CyberArk Admin (Stream A)          Azure Admin (Stream B)
──────────────────────────         ──────────────────────
[1] Determine platform name
[2] Get identity parameters
        │
        │  ── HAND-OFF 1 ──────────────────────────>
        │  Platform name + 7 identity parameter values
        │                                            │
        │                                           [3] Create SCA Entra app
        │                                           [4] Create SCA Resources app
        │                                           [5] Create CCE app
        │                                            │
        │  <── HAND-OFF 2 ────────────────────────────
        │  3 app IDs (CCE, SCA Entra, SCA Resources)
        │
[6] Register tenant via API
[7] Save onboarding ID
```

---

## Detailed Sequence

### Stage 1 — CyberArk Admin prepares (before Azure work begins)

**Performed by:** CyberArk administrator  
**Reference:** Stream A, Steps 1–2

1. Determine whether the platform name is `Idira` or `CyberArk` based on tenant creation date and onboarding status (Stream A, Step 1).
2. Obtain a bearer token for the CyberArk Identity Security Platform (Stream A, Step 2.1).
3. Call `GET /api/azure/identity-params` to retrieve identity values (Stream A, Step 2.2).
4. Collect the 7 identity parameter values from the response (Stream A, Step 2.3).

---

### Hand-off 1 — CyberArk Admin → Azure Admin

The CyberArk admin sends the Azure admin:

- The **platform name** (`Idira` or `CyberArk`)
- **SCA Identity Issuer (Entra)**
- **SCA Identity User (Entra)**
- **SCA Identity Issuer (Resources)**
- **SCA Identity User (Resources)**
- **CCE Identity Issuer**
- **CCE Identity User ID**
- **CCE Identity Audience**
- Confirmation of the **Entra Tenant ID** (GUID)

The Azure admin must not begin until all of the above are received.

---

### Stage 2 — Azure Admin creates all Azure resources

**Performed by:** Azure administrator  
**Reference:** Stream B, Parts 1–2  
**Tool:** Azure Cloud Shell (Bash) or the PowerShell script `Stream B - Azure Admin - Connect-SCAtoEntra.ps1`

5. Set common variables (Stream B, Preparation).
6. Create SCA Entra custom role — no Actions (Stream B, Step 1.2–1.3).
7. Create SCA Resources custom role — Authorization + ResourceGraph + Management actions (Stream B, Step 1.2–1.3).
8. Create SCA Entra app registration with Graph permissions (Stream B, Step 1.4).
9. Create SCA Resources app registration with Graph permissions (Stream B, Step 1.4).
10. Create service principals for both SCA apps (Stream B, Step 1.5).
11. Create federated credential on SCA Entra app (Stream B, Step 1.6).
12. Create federated credential on SCA Resources app (Stream B, Step 1.6).
13. Assign SCA Entra role to SCA Entra app (Stream B, Step 1.7).
14. Assign SCA Resources role to SCA Resources app (Stream B, Step 1.7).
15. Grant admin consent for SCA Entra app — 3 permissions (Stream B, Step 1.8).
16. Grant admin consent for SCA Resources app — 4 permissions (Stream B, Step 1.8).
17. Create CCE app registration (Stream B, Step 2.1).
18. Create federated credential on CCE app (Stream B, Step 2.3).
19. Create CCE service principal (Stream B, Step 2.4).
20. Assign Management Group Reader role to CCE app (Stream B, Step 2.5).
21. Grant admin consent for CCE app — 1 permission (Stream B, Step 2.6).

> **Order within Stage 2 is mandatory:** SCA apps (steps 6–16) must be completed before the CCE app (steps 17–21).

---

### Hand-off 2 — Azure Admin → CyberArk Admin

The Azure admin sends the CyberArk admin the Application (client) IDs of the three apps created (Stream B, Part 3):

- **CCE App ID**
- **SCA Entra App ID**
- **SCA Resources App ID**

The CyberArk admin must not proceed to Stage 3 until all three IDs are received.

---

### Stage 3 — CyberArk Admin registers the tenant

**Performed by:** CyberArk administrator  
**Reference:** Stream A, Step 3  
**Tool:** PowerShell script `Stream A - CyberArk Admin - Connect-SCAtoEntra.ps1` (Phase 2)

22. Obtain a fresh bearer token if the previous one has expired (Stream A, Step 2.1).
23. Call `POST /api/azure/manual` with the three app IDs and SCA identity trusted usernames (Stream A, Step 3.2).
24. Save the **onboarding ID** returned in the response (Stream A, Step 3.3).

---

## Completion Criteria

The process is complete when:

- All Azure resources exist in the ACME tenant (verifiable in Azure Portal or via CLI)
- The `POST /api/azure/manual` call returned HTTP 200 with an onboarding ID
- The onboarding ID has been saved by the CyberArk admin

---

## Quick Reference: Scripts Available

| Stream | Script | When to use |
|---|---|---|
| Stream A | `Stream A - CyberArk Admin - Connect-SCAtoEntra.ps1 -Phase 1` | Stage 1 — retrieve identity parameters |
| Stream A | `Stream A - CyberArk Admin - Connect-SCAtoEntra.ps1 -Phase 2` | Stage 3 — register tenant in CCE |
| Stream B | `Stream B - Azure Admin - Connect-SCAtoEntra.ps1` | Stage 2 — create all Azure resources |

For portal-based execution of Stage 2 (no script), refer to `Stream B2 - Azure Admin Guide (Portal).md`.
