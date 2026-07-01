# D365FO Integration Patterns — Azure API Management

A hands-on companion to the LinkedIn article
*"D365FO Integration Architecture — a real-world approach (REST & APIM)"* — **Part 2**.

This repository contains a **Git-based Azure API Management (APIM) template** that
demonstrates three concrete D365 Finance & Operations integration patterns through
a single APIM gateway, covering **security (OAuth2), routing, transformation,
logging and payload persistence**.

> All environment-specific data (hostnames, tenant, client id, secrets) is kept
> **out of source control** and externalized into APIM *named values*. The policy
> files are portable across environments as-is.

---

## 🧩 The three patterns

| # | API | Pattern | Endpoint (gateway) | Backend |
|---|-----|---------|--------------------|---------|
| 1 | **WHS Release to Warehouse** | REST → D365FO **custom service** + request transformation (OAuth2) | `POST /d365/whs/autoReleaseTransferOrders` | `.../api/services/WHSServices/WHSReleaseToWarehouseService/autoReleaseTransferOrders` |
| 2 | **Fake REST service** | Plain **pass-through** REST (no auth) | `GET /fake/posts/{id}`, `GET /fake/users` | `https://jsonplaceholder.typicode.com` |
| 3 | **Customers (REST → OData)** | **Transformation**: POST → OData GET + response reshape | `POST /d365/customers/search` | `.../data/CustomersV3` |

### Why these three?
- **API 1** shows the *process integration* case: a real-time call into a D365FO
  X++ custom service, with the gateway handling Microsoft Entra ID authentication.
- **API 2** is a dependency-free reference you can call immediately to validate the
  gateway, logging and subscription-key flow — no D365 environment required.
- **API 3** shows the *transformation* case: hide OData syntax from consumers.
  The caller posts a simple `{ "customerAccount": "DE-001" }`; APIM flips it into a
  D365FO OData query and returns a **compact, curated JSON** with only the main fields.

---

## 🏗️ Architecture

```
                         ┌──────────────────────────────────────────────┐
   Consumer  ──REST──►   │        Azure API Management (Consumption)      │
   (subscription key)    │                                               │
                         │  API1  /d365/whs   ──┐                         │
                         │  API2  /fake        ─┼─► policies:             │
                         │  API3  /d365/customers│   • OAuth2 token (M.EntraID)
                         │                       │   • routing / rewrite   │
                         │                       │   • REST↔OData transform │
                         │                       │   • App Insights logging │
                         └───────────┬───────────┴───────────┬────────────┘
                                     │                        │
                       ┌─────────────▼───────────┐   ┌────────▼─────────┐
                       │  D365FO (OData + custom  │   │ jsonplaceholder  │
                       │  services, OAuth2)       │   │ (public fake)    │
                       └──────────────────────────┘   └──────────────────┘
                                     │
                          ┌──────────▼───────────┐
                          │  Application Insights │  ← full request/response
                          │  + Log Analytics      │    payload logging
                          └───────────────────────┘
```

### Authentication (OAuth2 client-credentials)
APIs 1 and 3 acquire a token from Microsoft Entra ID **inside the policy** using the
client-credentials flow, then attach it as a `Bearer` token before routing to D365FO:

```
POST https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token
grant_type=client_credentials
client_id={{d365-client-id}}
client_secret={{d365-client-secret}}
scope={{d365-resource}}/.default
```

The app registration must be mapped to a service account in D365FO under
*System administration → Setup → Microsoft Entra ID applications*.

---

## 📁 Repository layout

```
apim/
  named-values.md                        # required named values (placeholders, no secrets)
  apis/
    01-whs-release/
      api.policy.xml                     # API-level: OAuth2 token (shared by all operations)
      operations/
        autoReleaseTransferOrders.policy.xml   # operation-level: route to custom service
    02-fake-echo/
      api.policy.xml                     # API-level: pass-through backend
    03-customers-odata/
      api.policy.xml                     # API-level: OAuth2 token
      operations/
        search.policy.xml                # operation-level: REST→OData + response reshape
infra/
  deploy-infra.ps1                       # create RG, Log Analytics, App Insights, APIM, logger
apim/
  deploy-apim.ps1                        # create named values, APIs, operations, apply policies
tests/
  requests.http                          # ready-to-run sample calls
```

### Policy scope: hybrid (API-level + operation-level)
Cross-cutting concerns (OAuth2 token acquisition) live at the **API scope** so they
are written once and apply to every operation. Operation-specific logic (backend
routing, the REST→OData transformation and response reshaping) lives at the
**operation scope** and inherits the API scope via `<base />`.

---

## 🔌 The APIs in detail

### API 1 — WHS Release to Warehouse (custom service + request transformation)
```http
POST /d365/whs/autoReleaseTransferOrders
Ocp-Apim-Subscription-Key: {key}
Content-Type: application/json

{
  "quantitySpecification": "All",          // All | ReservedPhysically | ReservedPhysicallyAndCrossDock
  "allowPartiallyReleased": false,
  "groupIntoMultipleReleases": false,
  "packedQuery": ""                        // optional packed query over InventTransferTable
}
```
The D365FO operation `autoReleaseTransferOrders` expects a single `_contract`
parameter (`WHSTransferAutoRTWContract`) whose members are typed X++ values — the
release-quantity is an **enum** (integer) and the two flags are **NoYes** (0/1).
Rather than leak that shape to consumers, the policy accepts the friendly JSON
above and **transforms** it into the contract D365FO wants:

```json
{
  "_contract": {
    "WHSReleaseQuantitySpecification": 0,
    "AllowPartiallyReleased": 0,
    "GroupIntoMultipleReleases": 0,
    "_packedQuery": ""
  }
}
```

> Demo note: the service ultimately needs a *packed query* over `InventTransferTable`
> to actually release orders. Without it, D365FO returns a validation error — which
> is expected here. The point of this API is to show the APIM request transformation
> and OAuth2 routing, not to run a real warehouse release.

### API 2 — Fake REST service (pass-through)
```http
GET /fake/posts/1
GET /fake/users
Ocp-Apim-Subscription-Key: {key}
```
No D365 dependency — ideal for smoke-testing the gateway and logging.

### API 3 — Customers, REST → OData transformation
```http
POST /d365/customers/search
Ocp-Apim-Subscription-Key: {key}
Content-Type: application/json

{ "customerAccount": "DE-001" }
```
APIM validates the input, translates it into
`GET /data/CustomersV3?$filter=CustomerAccount eq 'DE-001'&$top=1&cross-company=true`,
and reshapes the verbose OData record into:

```json
{
  "found": true,
  "customerAccount": "DE-001",
  "name": "Contoso Europe",
  "dataAreaId": "usmf",
  "currency": "EUR",
  "customerGroup": "90",
  "paymentTerms": "Net10",
  "email": "contoso.europe@example.com",
  "phone": "01234 56789",
  "address": {
    "street": "Bahnhofstrasse 5",
    "city": "Berlin",
    "zipCode": "10115",
    "state": "BE",
    "countryRegionId": "DEU",
    "countryISO": "DE"
  }
}
```
Missing `customerAccount` → `400`; no match → `{ "found": false }`.

---

## 🚀 Deploy

> Prerequisites: Azure CLI (`az`), PowerShell 7+, an Azure subscription, and a
> D365FO app registration (client id + secret) already mapped inside D365FO.

```powershell
# 1) Provision infrastructure (RG, Log Analytics, App Insights, APIM Consumption, logger)
./infra/deploy-infra.ps1 -ResourceGroup <rg> -ApimName <apim> -Location westeurope `
    -PublisherName "<org>" -PublisherEmail "<email>"

# 2) Create named values, import the 3 APIs and apply the policies
./apim/deploy-apim.ps1 -ResourceGroup <rg> -ApimName <apim> `
    -TenantId <entra-tenant> -ClientId <app-client-id> -ClientSecret <app-secret> `
    -D365Resource https://<your-d365fo-host>
```

Both scripts are idempotent (they use `PUT`/upsert semantics).

---

## 🔎 Observability

- An **Application Insights** logger is attached to APIM with a service-level
  diagnostic that logs **full request/response payloads** (up to 8 KB per section)
  for frontend and backend, plus client IP and W3C correlation.
- For payloads larger than the Application Insights limit, the article describes
  persisting the **full body to Azure Blob Storage** and logging only a reference —
  a natural next step on top of this template.

---

## ⚠️ Notes & limitations

- **APIM Consumption tier**: no built-in cache, so the OAuth token is acquired per
  request. On Basic/Standard/Premium, cache the token with
  `cache-store-value` / `cache-lookup-value` keyed on expiry to cut latency.
- **5-minute** maximum gateway request timeout (APIM constraint).
- For production, store the client secret in **Azure Key Vault** and reference it
  from the named value.

---

## 🔐 Security

No secrets are stored in this repository. Hostnames, tenant, client id and secret
are provided at deploy time and stored in APIM as named values (the secret with the
*secret* flag). See [`apim/named-values.md`](apim/named-values.md).
