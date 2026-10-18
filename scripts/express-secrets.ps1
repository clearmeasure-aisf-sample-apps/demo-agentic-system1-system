#!/usr/bin/env pwsh
#Requires -Version 7.4

<#
.SYNOPSIS
    Library of the Octopus steps that change a container app in an Azure Container Apps express environment: copies
    the app's secrets from the environment's vault into manual secrets of the app (decision 0056).

.DESCRIPTION
    An express environment has no Key Vault secret references. So there the template names no secret
    (infra/modules/containerapps.bicep), and the step that changes the app copies each value, as the tier's deploy
    identity, from the vault into a manual secret of the app, and maps it to its environment variable:

        Sync-ExpressSecret -AppId <resource id> -Secrets <expressSecrets of the stack output> -RegistryServer <server>

    Each value is read and written in memory, through the REST APIs: never a file, a command-line argument, a
    template, a parameter or a log line. A log line names the secrets only. octopus/projects.tf joins this file before
    the step's own script (as it joins github-token.ps1), so the file has no param block.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

function Get-ExpressAccessToken {
    # A token of the signed-in identity for one resource, held in memory only.
    param([Parameter(Mandatory)] [string] $Resource)
    $token = [string] (az account get-access-token --resource $Resource --query accessToken --output tsv)
    if (-not $token) { throw "No access token for $Resource" }
    return $token.Trim()
}

function Sync-ExpressSecret {
    # Copies the vault values of $Secrets ([{ name, secretUri, env }]) into manual secrets of the express app $AppId,
    # maps each to its environment variable on the app's first container, and keeps the app's other secrets. The
    # environment's shared identity id-<slug>-<env>-app pulls the image again with the same request (express keeps no
    # registry setting, update-deployable.ps1).
    param(
        [Parameter(Mandatory)] [string] $AppId,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Secrets,
        [Parameter(Mandatory)] [string] $RegistryServer
    )
    if ($Secrets.Count -eq 0) { return }
    $api = 'api-version=2026-07-01'
    $appUri = "https://management.azure.com${AppId}?$api"
    $arm = @{ Authorization = "Bearer $(Get-ExpressAccessToken -Resource 'https://management.azure.com/')" }
    $vault = @{ Authorization = "Bearer $(Get-ExpressAccessToken -Resource 'https://vault.azure.net')" }
    $app = (Invoke-WebRequest -Method Get -Uri $appUri -Headers $arm).Content | ConvertFrom-Json -AsHashtable
    $name = [string] $app.name

    # The app's present values, so a secret this sync does not own survives the change.
    $values = [ordered] @{}
    if (@($app.properties.configuration['secrets'] | Where-Object { $_ }).Count -gt 0) {
        $listed = (Invoke-WebRequest -Method Post -Uri "https://management.azure.com${AppId}/listSecrets?$api" -Headers $arm -ContentType 'application/json' -Body '{}').Content | ConvertFrom-Json -AsHashtable
        foreach ($s in @($listed.value)) { $values[[string] $s.name] = [string] $s.value }
    }
    foreach ($s in $Secrets) {
        $read = $null
        foreach ($attempt in 1..6) {
            try { $read = Invoke-RestMethod -Method Get -Uri "$($s.secretUri)?api-version=7.4" -Headers $vault; break }
            catch {
                if ($attempt -eq 6) { throw "Reading the vault secret of $($s.name) for $name failed: $($_.Exception.Message)" }
                Write-Host "Waiting for read access to the vault secret of $($s.name) (attempt $attempt of 6)"
                Start-Sleep -Seconds 20
            }
        }
        $values[[string] $s.name] = [string] $read.value
    }

    $containers = @($app.properties.template.containers)
    $mapped = @($Secrets | ForEach-Object { [string] $_.env })
    $envVars = @(@($containers[0]['env']) | Where-Object { $_ -and $mapped -notcontains [string] $_.name -and [string] $_.name -ne 'SECRETS_VERSION' })
    foreach ($s in $Secrets) { $envVars += @{ name = [string] $s.env; secretRef = [string] $s.name } }
    # A changed secret alone starts no new container, and an express app's revision cannot be restarted (the API
    # answers 500): the running container would keep the old value. A short digest of the values the app is given
    # changes with them, so a new value starts the app again, and an unchanged one changes nothing.
    $digest = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes((@($Secrets | ForEach-Object { "$($_.name)=$($values[[string] $_.name])" }) -join "`n")))
    $envVars += @{ name = 'SECRETS_VERSION'; value = [Convert]::ToHexString($digest).Substring(0, 12).ToLowerInvariant() }
    $digest = $null
    $containers[0].env = $envVars

    $pullIdentity = [string] (@($app.identity.userAssignedIdentities.Keys | Where-Object { $_ -match '/id-[^/]+-app$' }) | Select-Object -First 1)
    $configuration = @{ secrets = @($values.GetEnumerator() | ForEach-Object { @{ name = $_.Key; value = $_.Value } }) }
    if ($pullIdentity) { $configuration.registries = @(@{ server = $RegistryServer; identity = $pullIdentity }) }
    $body = @{ properties = @{ configuration = $configuration; template = @{ containers = $containers } } } | ConvertTo-Json -Depth 20 -Compress
    Invoke-RestMethod -Method Patch -Uri $appUri -Headers $arm -Body $body -ContentType 'application/json' | Out-Null
    $body = $null
    $values = $null

    foreach ($attempt in 1..60) {
        $state = [string] ((Invoke-WebRequest -Method Get -Uri $appUri -Headers $arm).Content | ConvertFrom-Json -AsHashtable).properties.provisioningState
        if ($state -eq 'Succeeded') { break }
        if ($state -eq 'Failed') { throw "$name failed to take its secrets: provisioning state Failed" }
        Start-Sleep -Seconds 5
    }
    Write-Host "Synced $($Secrets.Count) secret(s) from the vault into $name (express): $(@($Secrets | ForEach-Object { $_.name }) -join ', ')"
}
