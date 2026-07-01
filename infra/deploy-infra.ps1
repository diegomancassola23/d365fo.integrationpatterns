<#
    deploy-infra.ps1
    Provisions the base infrastructure for the D365FO Integration Patterns demo:
      - Resource Group
      - Log Analytics Workspace
      - Application Insights (workspace-based)
      - API Management (Consumption tier)
      - APIM logger + service diagnostic wired to Application Insights (payload logging)

    Requires: Azure CLI (az) logged in, PowerShell 7+.
    Idempotent: safe to re-run.
#>
param(
    [Parameter(Mandatory)] [string] $ResourceGroup,
    [Parameter(Mandatory)] [string] $ApimName,
    [string] $Location       = "westeurope",
    [string] $WorkspaceName  = "$ApimName-law",
    [string] $AppInsightsName = "$ApimName-appi",
    [Parameter(Mandatory)] [string] $PublisherName,
    [Parameter(Mandatory)] [string] $PublisherEmail
)

$ErrorActionPreference = "Stop"
$ApiV = "2022-08-01"

Write-Host "==> Resource group"
az group create --name $ResourceGroup --location $Location --output none

Write-Host "==> Providers"
az provider register --namespace Microsoft.ApiManagement    --output none
az provider register --namespace Microsoft.Insights         --output none
az provider register --namespace Microsoft.OperationalInsights --output none

Write-Host "==> Log Analytics workspace"
az monitor log-analytics workspace create -g $ResourceGroup -n $WorkspaceName -l $Location --output none
$wsId = az monitor log-analytics workspace show -g $ResourceGroup -n $WorkspaceName --query id -o tsv

Write-Host "==> Application Insights"
az monitor app-insights component create --app $AppInsightsName -g $ResourceGroup -l $Location `
    --application-type web --workspace $wsId --output none
$iKey = az monitor app-insights component show --app $AppInsightsName -g $ResourceGroup --query instrumentationKey -o tsv
$aiId = az monitor app-insights component show --app $AppInsightsName -g $ResourceGroup --query id -o tsv

Write-Host "==> API Management (Consumption) — this can take a few minutes"
az apim create --name $ApimName -g $ResourceGroup -l $Location --sku-name Consumption `
    --publisher-name $PublisherName --publisher-email $PublisherEmail --output none

# --- Wire Application Insights logger + diagnostic via ARM (Invoke-RestMethod avoids
#     the Windows console/BOM encoding issues seen with `az rest`). ---
$sub  = az account show --query id -o tsv
$base = "https://management.azure.com/subscriptions/$sub/resourceGroups/$ResourceGroup/providers/Microsoft.ApiManagement/service/$ApimName"
$tok  = az account get-access-token --resource https://management.azure.com --query accessToken -o tsv
$H    = @{ Authorization = "Bearer $tok" }

Write-Host "==> APIM logger -> Application Insights"
$logger = @{ properties = @{
    loggerType  = "applicationInsights"
    description = "Application Insights logger $AppInsightsName"
    credentials = @{ instrumentationKey = $iKey }
    resourceId  = $aiId
} } | ConvertTo-Json -Depth 10
Invoke-RestMethod -Method Put -Uri "$base/loggers/appinsights-logger?api-version=$ApiV" -Headers $H -ContentType "application/json" -Body $logger | Out-Null

Write-Host "==> APIM service diagnostic (full payload logging)"
$diag = @{ properties = @{
    loggerId              = "$($base.Replace('https://management.azure.com',''))/loggers/appinsights-logger"
    alwaysLog             = "allErrors"
    sampling              = @{ samplingType = "fixed"; percentage = 100 }
    verbosity             = "information"
    httpCorrelationProtocol = "W3C"
    logClientIp           = $true
    frontend = @{ request = @{ headers = @("content-type"); body = @{ bytes = 8192 } }; response = @{ headers = @("content-type"); body = @{ bytes = 8192 } } }
    backend  = @{ request = @{ headers = @("content-type"); body = @{ bytes = 8192 } }; response = @{ headers = @("content-type"); body = @{ bytes = 8192 } } }
} } | ConvertTo-Json -Depth 12
Invoke-RestMethod -Method Put -Uri "$base/diagnostics/applicationinsights?api-version=$ApiV" -Headers $H -ContentType "application/json" -Body $diag | Out-Null

Write-Host "`nDone. Gateway: https://$($ApimName.ToLower()).azure-api.net"
