param (
    [string]$autoLoginUsername,
    [string]$autoLoginPasswordSecretKey,
    [string]$azurePortalUsernameSecretKey,
    [string]$azurePortalPasswordSecretKey,
    [string]$azurePortalMFASecretKey,
    [string]$keyvaultName,
    [string]$managedIdentityClientId,
    [string]$setupPath,
    [string]$storageAccountName,
    [string]$containerName,
    [int32]$tunnelPortNumber = 5000
)

Write-Output "Store KV info to be used by other scripts."
[System.Environment]::SetEnvironmentVariable("autoLoginUsername", $autoLoginUsername, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable("autoLoginPasswordSecretKey", $autoLoginPasswordSecretKey, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable("azurePortalUsernameSecretKey", $azurePortalUsernameSecretKey, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable("azurePortalPasswordSecretKey", $azurePortalPasswordSecretKey, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable("azurePortalMFASecretKey", $azurePortalMFASecretKey, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable("keyvaultName", $keyvaultName, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable("managedIdentityClientId", $managedIdentityClientId, [System.EnvironmentVariableTarget]::Machine)

Write-Output "Creating setup path if it doesn't exist"
if (-Not (Test-Path -Path $setupPath)) {
    New-Item -ItemType Directory -Path $setupPath
}

Set-Location -Path "C:\"
Write-Output "Installing Azure CLI.."
$ProgressPreference = 'SilentlyContinue';
Invoke-WebRequest -Uri https://aka.ms/installazurecliwindows -OutFile .\AzureCLI.msi;
Start-Process msiexec.exe -Wait -ArgumentList '/I AzureCLI.msi /quiet';
Remove-Item .\AzureCLI.msi
$env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

# First, download the config file to determine which directory to use
az login --identity --client-id $managedIdentityClientId
Write-Host "Downloading configuration file..."
$configFileName = "config.json"
$configFilePath = Join-Path -Path $setupPath -ChildPath $configFileName

# Get a SAS token for the config file
$endTime = (Get-Date).AddHours(1).ToString("yyyy-MM-ddTHH:mm:ssZ")
$configSasToken = az storage blob generate-sas `
    --account-name $storageAccountName `
    --container-name $containerName `
    --name $configFileName `
    --permissions r `
    --expiry $endTime `
    --auth-mode login `
    --as-user `
    --output tsv

if ($LASTEXITCODE -ne 0) {
    throw "Failed to generate SAS token for config file. Make sure the config file exists in the root of the container."
}

# Get config file URL and download it
$configUrl = "https://$storageAccountName.blob.core.windows.net/$containerName/$configFileName"
$configUrlWithSas = "${configUrl}?${configSasToken}"

Invoke-WebRequest -Uri $configUrlWithSas -OutFile $configFilePath

# Read the config file to get the directory and filename information
$config = Get-Content -Path $configFilePath -Raw | ConvertFrom-Json
$blobDirectory = $config.version
$blobFileName = $config.fileName

Write-Host "Retrieved configuration. Directory: $blobDirectory, File: $blobFileName"

# Construct the full blob path
$fullBlobPath = "$blobDirectory/$blobFileName"
$zipFilePath = Join-Path -Path $setupPath -ChildPath $blobFileName

# Get a SAS token for the actual blob file
$blobSasToken = az storage blob generate-sas `
    --account-name $storageAccountName `
    --container-name $containerName `
    --name $fullBlobPath `
    --permissions r `
    --expiry $endTime `
    --auth-mode login `
    --as-user `
    --output tsv

if ($LASTEXITCODE -ne 0) {
    throw "Failed to generate SAS token for the ZIP file at path: $fullBlobPath"
}

# Get blob URL and download it
$blobUrl = "https://$storageAccountName.blob.core.windows.net/$containerName/$fullBlobPath"
$blobUrlWithSas = "${blobUrl}?${blobSasToken}"

Write-Host "Downloading blob from $fullBlobPath to $zipFilePath..."
Invoke-WebRequest -Uri $blobUrlWithSas -OutFile $zipFilePath

# Extract the ZIP file
Write-Host "Extracting ZIP file to $setupPath..."
Expand-Archive -Path $zipFilePath -DestinationPath $setupPath -Force

Write-Host "Successfully downloaded and extracted the ZIP file"

Set-Location -Path $setupPath
Write-Output "Setting up Windows auto-logon..."
$scriptPath = ".\setup-autologon.ps1"
Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -autoLoginUsername `"$autoLoginUsername`" -autoLoginPasswordSecretKey `"$autoLoginPasswordSecretKey`" -keyvaultName `"$keyvaultName`" -managedIdentityClientId `"$managedIdentityClientId`"" -Wait

Write-Output "Installing dotnet 8..."
$dotnetInstallerUrl = "https://download.visualstudio.microsoft.com/download/pr/bd44cdb8-dcac-4f1f-8246-1ee392c68dac/ba818a6e513c305d4438c7da45c2b085/dotnet-sdk-8.0.406-win-x64.exe"
$installerPath = "$env:TEMP\dotnet-sdk-8.0.406-win-x64.exe"
Invoke-WebRequest -Uri $dotnetInstallerUrl -OutFile $installerPath
Start-Process -FilePath $installerPath -ArgumentList "/quiet" -NoNewWindow -Wait
Remove-Item -Path $installerPath -Force

Write-Output "Installing dev tunnel..."
Invoke-WebRequest -Uri https://aka.ms/TunnelsCliDownload/win-x64 -OutFile devtunnel.exe

Write-Output "Create a scheduled task to launch server setup tasks"
$serverSetup = "$setupPath\server-setup.ps1"
schtasks /create /tn "RunSetupScriptAtLogon" /tr "powershell.exe -File $serverSetup -setupPath $setupPath -tunnelPortNumber $tunnelPortNumber -autoLoginUsername $autoLoginUsername" /sc onlogon /rl highest /f /it /RU $autoLoginUsername
