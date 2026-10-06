
bootstrap.ps1
Copied
<#
    bootstrap.ps1
    One-time, manual bootstrap of the Terraform remote state backend.

    Run by a human with Owner on the subscription. Terraform can't create its own
    state storage, because it needs that storage to exist before it can run.
    Replace <subscription-id> with your own before running.
#>


Update-Module Az.*

Connect-AzAccount -SubscriptionId "<subscription-id>"

# --- Resource group for bootstrap resources only ---------------------------
New-AzResourceGroup -Name "rg-bootstrap" -Location "westus2"

# --- Storage account for Terraform state ----------------------------------
# Names must be globally unique, 3-24 characters, lowercase letters and numbers only. This one is mine and you will need your own.
Get-AzStorageAccountNameAvailability -Name "stlabbootstraptfstate"

# Cheapest viable SKU (Standard_LRS, Hot tier), hardened:
#   -AllowSharedKeyAccess $false          account keys disabled; Entra ID auth only
#   -AllowBlobPublicAccess $false         no container can ever be anonymously readable
#   -MinimumTlsVersion TLS1_2             modern encryption only
#   -EnableHttpsTrafficOnly $true         no unencrypted connections
#   -AllowCrossTenantReplication $false   data can't be replicated to another tenant
New-AzStorageAccount -Name "stlabbootstraptfstate" -ResourceGroupName "rg-bootstrap" -Location "westus2" `
    -SkuName Standard_LRS -Kind StorageV2 -AccessTier Hot -MinimumTlsVersion TLS1_2 `
    -EnableHttpsTrafficOnly $true -AllowBlobPublicAccess $false -AllowSharedKeyAccess $false `
    -AllowCrossTenantReplication $false

# --- Recovery features ----------------------------------------------------
# Versioning keeps prior copies of the state file, so a corrupted state can be rolled back.
Update-AzStorageBlobServiceProperty -ResourceGroupName "rg-bootstrap" -StorageAccountName "stlabbootstraptfstate" -IsVersioningEnabled $true

# Soft delete: a deleted state file or container can be recovered for 30 days.
Enable-AzStorageBlobDeleteRetentionPolicy -ResourceGroupName "rg-bootstrap" -StorageAccountName "stlabbootstraptfstate" -RetentionDays 30
Enable-AzStorageContainerDeleteRetentionPolicy -ResourceGroupName "rg-bootstrap" -StorageAccountName "stlabbootstraptfstate" -RetentionDays 30

# --- Container for the state file -----------------------------------------
# With account keys disabled, this context authenticates with your Entra ID sign-in.
$StorageAccount = Get-AzStorageAccount -ResourceGroupName "rg-bootstrap" -StorageAccountName "stlabbootstraptfstate"
$Context = $StorageAccount.Context
New-AzStorageContainer -Name "tfstate" -Context $Context

# ---  Verify ---------------------------------------------------------------
# Account keys are disabled. Expected: False
(Get-AzStorageAccount -ResourceGroupName "rg-bootstrap" -StorageAccountName "stlabbootstraptfstate").AllowSharedKeyAccess

# Container exists and is private. Expected: tfstate, PublicAccess Off
Get-AzStorageContainer -Context $Context

# Recovery features are on. Expected (relevant lines):
#   DeleteRetentionPolicy.Enabled           : True
#   DeleteRetentionPolicy.Days              : 30
#   ContainerDeleteRetentionPolicy.Enabled  : True
#   ContainerDeleteRetentionPolicy.Days     : 30
#   IsVersioningEnabled                     : True
#   StaticWebsite.Enabled                   : False
Get-AzStorageBlobServiceProperty -ResourceGroupName "rg-bootstrap" -AccountName "stlabbootstraptfstate"

# --- Shared values for the identity steps ---------------------------------
# Confirm you're signed in to the right subscription before creating identities.
Get-AzContext

$rg         = "rg-bootstrap"
$loc        = "westus2"
$subId      = (Get-AzContext).Subscription.Id
$repo       = "cooke-labs/azure-detection-engineering-lab"
$sa         = Get-AzStorageAccount -ResourceGroupName $rg -Name "stlabbootstraptfstate"
# The state container's full Azure ID, used later to scope storage roles to just this container.
$stateScope = "$($sa.Id)/blobServices/default/containers/tfstate"

# --- Workload resource group -----------------------------------------------
# Terraform's apply identity is scoped to this group only, so it can never touch
# rg-bootstrap (the state backend and the pipeline identities themselves).
$workloadRg = New-AzResourceGroup -Name "rg-lab-core" -Location $loc

# --- Register the Managed Identity resource provider ------------------------
# A subscription must "turn on" each Azure service before resources of that type
# can be created. Fresh subscriptions haven't registered Microsoft.ManagedIdentity yet.
Register-AzResourceProvider -ProviderNamespace "Microsoft.ManagedIdentity"

# Registration takes a minute or two. Wait until it reports "Registered" before continuing.
while ((Get-AzResourceProvider -ProviderNamespace "Microsoft.ManagedIdentity" |
        Select-Object -ExpandProperty RegistrationState -Unique) -ne "Registered") {
    Write-Host "Waiting for Microsoft.ManagedIdentity to register..."
    Start-Sleep -Seconds 15
}

# --- Pipeline identities ------------------------------------------------------
# Two user-assigned managed identities: plan (read-only) and apply (write, behind
# an approval gate). Managed identities can't hold secrets, so there's nothing to leak.
$plan  = New-AzUserAssignedIdentity -ResourceGroupName $rg -Name "mi-tf-plan"  -Location $loc
$apply = New-AzUserAssignedIdentity -ResourceGroupName $rg -Name "mi-tf-apply" -Location $loc

# --- Federate the identities to GitHub Actions (OIDC) -------------------------
# Each federated credential trusts GitHub's login tokens only for this repo in one
# specific situation (the "subject"). The braces in ${repo} stop PowerShell from
# reading "$repo:pull_request" as a single variable name.

# Plan: trusted for pull request runs.
New-AzFederatedIdentityCredential -ResourceGroupName $rg -IdentityName "mi-tf-plan" `
    -Name "gh-pull-request" `
    -Issuer "https://token.actions.githubusercontent.com" `
    -Audience "api://AzureADTokenExchange" `
    -Subject "repo:${repo}:pull_request"

# Apply: trusted only for jobs in the protected "lab" GitHub environment,
# which requires manual approval before it runs.
New-AzFederatedIdentityCredential -ResourceGroupName $rg -IdentityName "mi-tf-apply" `
    -Name "gh-env-lab" `
    -Issuer "https://token.actions.githubusercontent.com" `
    -Audience "api://AzureADTokenExchange" `
    -Subject "repo:${repo}:environment:lab"

# Assign appropriately scoped roles to each new identity.
New-AzRoleAssignment -ObjectId $plan.PrincipalId  -RoleDefinitionName "Reader" -Scope "/subscriptions/$subId"
New-AzRoleAssignment -ObjectId $plan.PrincipalId  -RoleDefinitionName "Storage Blob Data Reader" -Scope $stateScope
New-AzRoleAssignment -ObjectId $apply.PrincipalId -RoleDefinitionName "Contributor" -Scope $workloadRg.ResourceId
New-AzRoleAssignment -ObjectId $apply.PrincipalId -RoleDefinitionName "Storage Blob Data Contributor" -Scope $stateScope

# Verify role assignment
# Each subject should match the ADR exactly
Get-AzFederatedIdentityCredential -ResourceGroupName $rg -IdentityName "mi-tf-plan"  | Select-Object Name, Subject
Get-AzFederatedIdentityCredential -ResourceGroupName $rg -IdentityName "mi-tf-apply" | Select-Object Name, Subject

# Each identity should have exactly two roles at the expected scopes
Get-AzRoleAssignment -ObjectId $plan.PrincipalId  | Select-Object RoleDefinitionName, Scope
Get-AzRoleAssignment -ObjectId $apply.PrincipalId | Select-Object RoleDefinitionName, Scope

# --- Values for GitHub Actions secrets ----------------------------------------
# These are identifiers, not credentials, but they identify your environment.
# Store them as GitHub secrets (masked in public logs). Don't commit this output.
[pscustomobject]@{
    AZURE_TENANT_ID       = (Get-AzContext).Tenant.Id
    AZURE_SUBSCRIPTION_ID = $subId
    AZURE_CLIENT_ID_PLAN  = $plan.ClientId
    AZURE_CLIENT_ID_APPLY = $apply.ClientId
} | Format-List
 
