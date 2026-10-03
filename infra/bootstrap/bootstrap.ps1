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