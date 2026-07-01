# APIM Named Values

All environment- and tenant-specific configuration is externalized into APIM
**named values**, so the policy files in this repository stay clean, portable
and free of secrets. Policies reference them with the `{{name}}` syntax.

| Name                 | Type    | Example / Placeholder                                  | Used by            | Description |
|----------------------|---------|--------------------------------------------------------|--------------------|-------------|
| `d365-tenant-id`     | plain   | `<your-entra-tenant-guid>`                             | API 1, API 3       | Microsoft Entra ID tenant used to issue the OAuth2 token. |
| `d365-client-id`     | plain   | `<your-app-registration-client-id>`                   | API 1, API 3       | App registration (client) used for the client-credentials flow. Must be registered in D365FO under *System administration → Setup → Microsoft Entra ID applications*. |
| `d365-client-secret` | secret  | `********`                                             | API 1, API 3       | Client secret for the app registration. **Stored as a secret named value — never committed to Git.** |
| `d365-resource`      | plain   | `https://<your-d365fo-host>`                          | API 1, API 3       | Base URL of the D365FO environment. Also the OAuth resource/scope (`{{d365-resource}}/.default`). |

## Notes

- **Secrets**: `d365-client-secret` is created with the *secret* flag so its
  value is masked in the portal and API responses. For production, back it with
  **Azure Key Vault** instead of an inline secret named value.
- **OAuth scope**: the client-credentials scope is built as
  `{{d365-resource}}/.default`, e.g. `https://<your-d365fo-host>/.default`.
- **Rotation**: rotating the app secret only requires updating the
  `d365-client-secret` named value — no policy change and no redeploy.
