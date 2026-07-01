<#
    deploy-apim.ps1
    Creates the named values, imports the 3 demo APIs (with operations) and applies
    the hybrid (API-level + operation-level) policies from this repository.

    Requires: Azure CLI (az) logged in, PowerShell 7+, infra already provisioned
    (see ../infra/deploy-infra.ps1).
    Idempotent: safe to re-run.

    NOTE: policies reference only named values, so no secret/host is ever committed.
#>
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $ApimName,
    [Parameter(Mandatory)] [string] $TenantId,
    [Parameter(Mandatory)] [string] $ClientId,
    [Parameter(Mandatory)] [string] $ClientSecret,
    [Parameter(Mandatory)] [string] $D365Resource   # e.g. https://<your-d365fo-host>
)

$ErrorActionPreference = "Stop"
$ApiV     = "2022-08-01"
$RepoRoot = Split-Path $PSScriptRoot -Parent
$ApisDir  = Join-Path $PSScriptRoot "apis"
$bom      = [char]0xFEFF

$sub  = az account show --query id -o tsv
$base = "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName"
$tok  = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
$H    = @{ Authorization = "Bearer $tok" }

function Put-Arm($rel, $obj) {
    Invoke-RestMethod -Method Put -Uri "$base$rel`?api-version=$ApiV" -Headers $H `
        -ContentType "application/json" -Body ($obj | ConvertTo-Json -Depth 30) | Out-Null
}
function Put-Nv($id, $value, [switch]$Secret) {
    Put-Arm "/namedValues/$id" @{ properties = @{ displayName = $id; value = $value; secret = [bool]$Secret } }
}
function Put-Policy($rel, $xmlPath) {
    # Strip a possible UTF-8 BOM: APIM/az reject it inside the JSON string value.
    $xml  = (Get-Content $xmlPath -Raw).TrimStart($bom)
    $body = @{ properties = @{ value = $xml; format = "rawxml" } } | ConvertTo-Json -Depth 30
    Invoke-RestMethod -Method Put -Uri "$base$rel`?api-version=$ApiV" -Headers $H `
        -ContentType "application/json" -Body $body | Out-Null
}

Write-Host "==> Named values"
Put-Nv "d365-tenant-id"     $TenantId
Put-Nv "d365-client-id"     $ClientId
Put-Nv "d365-client-secret" $ClientSecret -Secret
Put-Nv "d365-resource"      $D365Resource

Write-Host "==> API 1: whs-release"
Put-Arm "/apis/whs-release" @{ properties = @{ displayName = "D365FO - WHS Release to Warehouse"; apiRevision = "1"; path = "d365/whs"; protocols = @("https"); subscriptionRequired = $true } }
Put-Arm "/apis/whs-release/operations/auto-release-transfer-orders" @{ properties = @{ displayName = "Auto release transfer orders"; method = "POST"; urlTemplate = "/autoReleaseTransferOrders" } }
Put-Policy "/apis/whs-release/policies/policy" "$ApisDir\01-whs-release\api.policy.xml"
Put-Policy "/apis/whs-release/operations/auto-release-transfer-orders/policies/policy" "$ApisDir\01-whs-release\operations\autoReleaseTransferOrders.policy.xml"

Write-Host "==> API 2: fake-echo"
Put-Arm "/apis/fake-echo" @{ properties = @{ displayName = "Fake REST service (JSONPlaceholder)"; apiRevision = "1"; path = "fake"; protocols = @("https"); subscriptionRequired = $true } }
Put-Arm "/apis/fake-echo/operations/get-post"  @{ properties = @{ displayName = "Get post by id"; method = "GET"; urlTemplate = "/posts/{id}"; templateParameters = @(@{ name = "id"; type = "string"; required = $true }) } }
Put-Arm "/apis/fake-echo/operations/get-users" @{ properties = @{ displayName = "List users"; method = "GET"; urlTemplate = "/users" } }
Put-Policy "/apis/fake-echo/policies/policy" "$ApisDir\02-fake-echo\api.policy.xml"

Write-Host "==> API 3: customers-odata"
Put-Arm "/apis/customers-odata" @{ properties = @{ displayName = "D365FO - Customers (REST to OData)"; apiRevision = "1"; path = "d365/customers"; protocols = @("https"); subscriptionRequired = $true } }
Put-Arm "/apis/customers-odata/operations/search" @{ properties = @{ displayName = "Search customer"; method = "POST"; urlTemplate = "/search" } }
Put-Policy "/apis/customers-odata/policies/policy" "$ApisDir\03-customers-odata\api.policy.xml"
Put-Policy "/apis/customers-odata/operations/search/policies/policy" "$ApisDir\03-customers-odata\operations\search.policy.xml"

Write-Host "`nDone. Gateway: https://$($ApimName.ToLower()).azure-api.net"
