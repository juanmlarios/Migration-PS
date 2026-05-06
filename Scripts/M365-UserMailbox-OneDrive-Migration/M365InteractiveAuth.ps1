function Assert-PowerShellSeven {
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "These scripts require PowerShell 7 or later. Current version: $($PSVersionTable.PSVersion)"
    }
}

function Import-SharePointOnlineModule {
    $loadedModule = Get-Module -Name Microsoft.Online.SharePoint.PowerShell | Select-Object -First 1
    if ($loadedModule) {
        return $loadedModule
    }

    if ($PSVersionTable.PSVersion.Major -ge 7 -and $IsWindows) {
        try {
            return Import-Module Microsoft.Online.SharePoint.PowerShell -UseWindowsPowerShell -PassThru -ErrorAction Stop
        }
        catch {
            throw @(
                "Required module 'Microsoft.Online.SharePoint.PowerShell' could not be imported through Windows PowerShell compatibility.",
                "PowerShell 7 requires: Import-Module Microsoft.Online.SharePoint.PowerShell -UseWindowsPowerShell",
                "Install or update it from Windows PowerShell 5.1, then restart PowerShell 7:",
                "  powershell.exe -NoProfile -Command ""Install-Module Microsoft.Online.SharePoint.PowerShell -Scope CurrentUser -Force -AllowClobber""",
                "Original error: $($_.Exception.Message)"
            ) -join [Environment]::NewLine
        }
    }

    $availableModule = Get-Module -ListAvailable -Name Microsoft.Online.SharePoint.PowerShell |
    Sort-Object Version -Descending |
    Select-Object -First 1

    if (-not $availableModule) {
        throw "Required module 'Microsoft.Online.SharePoint.PowerShell' is not installed."
    }

    return Import-Module Microsoft.Online.SharePoint.PowerShell -PassThru -ErrorAction Stop
}

function Assert-ModuleMinimumVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$MinimumVersion
    )

    $module = Get-Module -ListAvailable -Name $Name |
    Sort-Object Version -Descending |
    Select-Object -First 1

    if (-not $module) {
        throw "Required module '$Name' is not installed."
    }

    if ($module.Version -lt [version]$MinimumVersion) {
        throw "Module '$Name' version $($module.Version) is too old. Minimum required version is $MinimumVersion."
    }
}

function Assert-MigrationModuleSet {
    Assert-PowerShellSeven
    Assert-ModuleMinimumVersion -Name ExchangeOnlineManagement -MinimumVersion "3.7.2"
    Assert-ModuleMinimumVersion -Name Microsoft.Graph.Authentication -MinimumVersion "2.0.0"
    Assert-ModuleMinimumVersion -Name Microsoft.Graph.Users -MinimumVersion "2.0.0"
    Assert-ModuleMinimumVersion -Name Microsoft.Graph.Identity.DirectoryManagement -MinimumVersion "2.0.0"
    Assert-ModuleMinimumVersion -Name Microsoft.Graph.Groups -MinimumVersion "2.0.0"
    Assert-ModuleMinimumVersion -Name Microsoft.Graph.Identity.SignIns -MinimumVersion "2.0.0"
    $spoModule = Import-SharePointOnlineModule
    if ($spoModule.Version -lt [version]"16.0.0") {
        throw "Module 'Microsoft.Online.SharePoint.PowerShell' version $($spoModule.Version) is too old. Minimum required version is 16.0.0."
    }
}

function Write-ConnectionBanner {
    param(
        [Parameter(Mandatory = $true)][string]$Workload,
        [Parameter(Mandatory = $true)][string]$TenantLabel,
        [Parameter(Mandatory = $false)][string]$ExpectedTenantId,
        [Parameter(Mandatory = $false)][string]$AdminUrl,
        [Parameter(Mandatory = $false)][string]$AdminUpn,
        [Parameter(Mandatory = $false)][switch]$UseDeviceCode
    )

    $details = [System.Collections.Generic.List[string]]::new()
    $details.Add("workload=$Workload")
    $details.Add("tenant=$TenantLabel")

    if ($ExpectedTenantId) {
        $details.Add("tenantId=$ExpectedTenantId")
    }
    if ($AdminUrl) {
        $details.Add("adminUrl=$AdminUrl")
    }
    if ($AdminUpn) {
        $details.Add("accountHint=$AdminUpn")
    }
    if ($UseDeviceCode.IsPresent) {
        $details.Add("auth=device-code-when-supported")
    } else {
        $details.Add("auth=interactive-browser")
    }

    Write-Host ("[Auth] Connect {0}" -f ($details -join " | "))
}

function Get-ErrorRecordText {
    param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $segments = [System.Collections.Generic.List[string]]::new()

    if ($ErrorRecord.Exception) {
        $segments.Add($ErrorRecord.Exception.ToString())
    }

    $segments.Add(($ErrorRecord | Out-String))
    return ($segments -join [Environment]::NewLine)
}

function Test-ExchangeWamBrokerFailure {
    param([Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord)

    $errorText = Get-ErrorRecordText -ErrorRecord $ErrorRecord
    $wamFailurePatterns = @(
        "RuntimeBroker",
        "BrokerExtension",
        "FetchTokensFromBrokerAsync",
        "Object reference not set to an instance of an object",
        "A specified logon session does not exist",
        "0xffffffff80070520"
    )

    foreach ($pattern in $wamFailurePatterns) {
        if ($errorText -match [regex]::Escape($pattern)) {
            return $true
        }
    }

    return $false
}

function Get-ExchangeOnlineModuleDetail {
    $loadedModule = Get-Module -Name ExchangeOnlineManagement | Sort-Object Version -Descending | Select-Object -First 1
    if ($loadedModule) {
        return $loadedModule
    }

    return Get-Module -ListAvailable -Name ExchangeOnlineManagement |
    Sort-Object Version -Descending |
    Select-Object -First 1
}

function New-ExchangeWamFailureMessage {
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [Parameter(Mandatory = $true)][string]$AttemptedAuthMode
    )

    $module = Get-ExchangeOnlineModuleDetail
    $moduleVersion = if ($module) { $module.Version } else { "unknown" }
    $modulePath = if ($module) { $module.ModuleBase } else { "unknown" }
    $originalMessage = if ($ErrorRecord.Exception) { $ErrorRecord.Exception.Message } else { "unknown" }

    return @(
        "Exchange Online sign-in failed in the Microsoft WAM/MSAL broker path.",
        "Attempted auth mode: $AttemptedAuthMode",
        "ExchangeOnlineManagement version: $moduleVersion",
        "ExchangeOnlineManagement path: $modulePath",
        "Original error: $originalMessage",
        "",
        "Recommended retry: start a new PowerShell 7 session and run the script with -UseDeviceCode.",
        "Some ExchangeOnlineManagement builds can still enter the WAM broker even when -DisableWAM is supplied."
    ) -join [Environment]::NewLine
}

function Invoke-ExchangeOnlineConnect {
    param(
        [Parameter(Mandatory = $true)][hashtable]$ConnectParams,
        [Parameter(Mandatory = $true)][string]$AuthMode,
        [Parameter(Mandatory = $false)][switch]$Device,
        [Parameter(Mandatory = $false)][switch]$DisableWAM
    )

    try {
        if ($Device.IsPresent) {
            Connect-ExchangeOnline @ConnectParams -Device
            return
        }

        if ($DisableWAM.IsPresent) {
            Connect-ExchangeOnline @ConnectParams -DisableWAM
            return
        }

        Connect-ExchangeOnline @ConnectParams
    }
    catch {
        if (Test-ExchangeWamBrokerFailure -ErrorRecord $_) {
            throw (New-ExchangeWamFailureMessage -ErrorRecord $_ -AttemptedAuthMode $AuthMode)
        }

        throw
    }
}

function Connect-ExchangeInteractive {
    param(
        [Parameter(Mandatory = $true)][string]$TenantLabel,
        [Parameter(Mandatory = $false)][string]$ExpectedTenantId,
        [Parameter(Mandatory = $false)][string]$AdminUpn,
        [Parameter(Mandatory = $false)][switch]$UseDeviceCode,
        [Parameter(Mandatory = $false)][switch]$DisableWAM
    )

    Write-ConnectionBanner -Workload "Exchange Online" -TenantLabel $TenantLabel -ExpectedTenantId $ExpectedTenantId -AdminUpn $AdminUpn -UseDeviceCode:$UseDeviceCode

    $existingConnectionIds = @()
    if (Get-Command Get-ConnectionInformation -ErrorAction SilentlyContinue) {
        $existingConnectionIds = @(Get-ConnectionInformation -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ConnectionId)
    }

    $connectCommand = Get-Command Connect-ExchangeOnline
    $disableWamSupported = $connectCommand.Parameters.ContainsKey("DisableWAM")
    $deviceParamSupported = $connectCommand.Parameters.ContainsKey("Device")
    $exchangeModule = Get-ExchangeOnlineModuleDetail
    if ($exchangeModule) {
        Write-Host ("[Auth] ExchangeOnlineManagement module | version={0} | path={1}" -f $exchangeModule.Version, $exchangeModule.ModuleBase)
    }

    $connectParams = @{
        ShowBanner = $false
    }

    if ($AdminUpn) {
        $connectParams["UserPrincipalName"] = $AdminUpn
    }

    if ($UseDeviceCode.IsPresent) {
        if (-not $deviceParamSupported) {
            throw "The installed ExchangeOnlineManagement module does not support -Device. Update the module and retry."
        }
        Invoke-ExchangeOnlineConnect -ConnectParams $connectParams -AuthMode "device-code" -Device
    } else {
        if ($DisableWAM.IsPresent) {
            if (-not $disableWamSupported) {
                throw "The installed ExchangeOnlineManagement module does not support -DisableWAM. Update the module and retry."
            }

            Write-Host "[Auth] Exchange Online will start with WAM disabled for this session."
            try {
                Invoke-ExchangeOnlineConnect -ConnectParams $connectParams -AuthMode "interactive-browser-disable-wam" -DisableWAM
            } catch {
                if (-not $deviceParamSupported -or -not (Test-ExchangeWamBrokerFailure -ErrorRecord $_)) {
                    throw
                }

                Write-Warning "Exchange Online sign-in still failed in the WAM broker path with -DisableWAM. Retrying with device code auth."
                Invoke-ExchangeOnlineConnect -ConnectParams $connectParams -AuthMode "device-code-fallback" -Device
            }
        } else {
            try {
                Invoke-ExchangeOnlineConnect -ConnectParams $connectParams -AuthMode "interactive-browser"
            } catch {
                if (-not (Test-ExchangeWamBrokerFailure -ErrorRecord $_)) {
                    throw
                }

                if ($disableWamSupported) {
                    try {
                        Write-Warning "Exchange Online interactive sign-in failed in the WAM broker path. Retrying with -DisableWAM."
                        Invoke-ExchangeOnlineConnect -ConnectParams $connectParams -AuthMode "interactive-browser-disable-wam" -DisableWAM
                    } catch {
                        if (-not $deviceParamSupported -or -not (Test-ExchangeWamBrokerFailure -ErrorRecord $_)) {
                            throw
                        }

                        Write-Warning "Exchange Online sign-in still failed in the WAM broker path with -DisableWAM. Retrying with device code auth."
                        Invoke-ExchangeOnlineConnect -ConnectParams $connectParams -AuthMode "device-code-fallback" -Device
                    }
                }
                elseif ($deviceParamSupported) {
                    Write-Warning "Exchange Online interactive sign-in failed in the WAM broker path. Retrying with device code auth."
                    Invoke-ExchangeOnlineConnect -ConnectParams $connectParams -AuthMode "device-code-fallback" -Device
                }
                else {
                    throw "Exchange Online interactive sign-in failed in the WAM broker path, and this module does not support -DisableWAM or -Device."
                }
            }
        }
    }

    $connections = @(Get-ConnectionInformation)
    $connection = $connections |
    Where-Object { $_.ConnectionId -notin $existingConnectionIds } |
    Sort-Object Id -Descending |
    Select-Object -First 1

    if (-not $connection) {
        $connection = $connections | Sort-Object Id -Descending | Select-Object -First 1
    }

    if (-not $connection) {
        throw "Unable to determine the active Exchange Online connection."
    }

    if ($ExpectedTenantId -and $connection.TenantId -ne $ExpectedTenantId) {
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
        throw "Connected to unexpected Exchange tenant '$($connection.TenantId)'. Expected '$ExpectedTenantId'."
    }

    Write-Host ("[Auth] Verified Exchange Online | tenantId={0} | account={1}" -f $connection.TenantId, $connection.UserPrincipalName)
    return $connection
}

function Connect-GraphInteractive {
    param(
        [Parameter(Mandatory = $true)][string]$TenantLabel,
        [Parameter(Mandatory = $true)][string[]]$Scopes,
        [Parameter(Mandatory = $false)][string]$ExpectedTenantId,
        [Parameter(Mandatory = $false)][switch]$UseDeviceCode
    )

    Write-ConnectionBanner -Workload "Microsoft Graph" -TenantLabel $TenantLabel -ExpectedTenantId $ExpectedTenantId -UseDeviceCode:$UseDeviceCode

    $existingContext = Get-MgContext -ErrorAction SilentlyContinue
    if ($existingContext) {
        $tenantMatches = (-not $ExpectedTenantId) -or ($existingContext.TenantId -eq $ExpectedTenantId)
        $missingScopes = @($Scopes | Where-Object { $_ -notin @($existingContext.Scopes) })

        if ($tenantMatches -and $missingScopes.Count -eq 0) {
            Write-Host ("[Auth] Reusing Microsoft Graph context | tenantId={0} | account={1}" -f $existingContext.TenantId, $existingContext.Account)
            return $existingContext
        }

        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    }

    $connectCommand = Get-Command Connect-MgGraph
    $connectParams = @{
        Scopes = $Scopes
    }

    if ($ExpectedTenantId) {
        $connectParams["TenantId"] = $ExpectedTenantId
    }

    if ($connectCommand.Parameters.ContainsKey("NoWelcome")) {
        $connectParams["NoWelcome"] = $true
    }

    if ($UseDeviceCode.IsPresent) {
        $deviceParam = $connectCommand.Parameters.ContainsKey("UseDeviceCode")
        if (-not $deviceParam) {
            throw "The installed Microsoft.Graph.Authentication module does not support -UseDeviceCode. Update the module and retry."
        }

        Connect-MgGraph @connectParams -UseDeviceCode
    } else {
        Connect-MgGraph @connectParams
    }

    $context = Get-MgContext
    if (-not $context) {
        throw "Unable to determine the active Microsoft Graph context."
    }

    if ($ExpectedTenantId -and $context.TenantId -ne $ExpectedTenantId) {
        Disconnect-MgGraph | Out-Null
        throw "Connected to unexpected Graph tenant '$($context.TenantId)'. Expected '$ExpectedTenantId'."
    }

    Write-Host ("[Auth] Verified Microsoft Graph | tenantId={0} | account={1}" -f $context.TenantId, $context.Account)
    return $context
}

function Connect-SPOInteractive {
    param(
        [Parameter(Mandatory = $true)][string]$TenantLabel,
        [Parameter(Mandatory = $true)][string]$AdminUrl,
        [Parameter(Mandatory = $false)][switch]$UseDeviceCode
    )

    Write-ConnectionBanner -Workload "SharePoint Online" -TenantLabel $TenantLabel -AdminUrl $AdminUrl -UseDeviceCode:$UseDeviceCode

    if ($UseDeviceCode.IsPresent) {
        Write-Host "[Auth] Connect-SPOService does not support device code auth. Falling back to system browser."
    }

    Import-SharePointOnlineModule | Out-Null
    $spoCommand = Get-Command Connect-SPOService
    if (-not $spoCommand.Parameters.ContainsKey("UseSystemBrowser")) {
        throw "The installed Microsoft.Online.SharePoint.PowerShell module does not support -UseSystemBrowser. Update the module and retry."
    }

    Connect-SPOService -Url $AdminUrl -UseSystemBrowser $true
    $null = Get-SPOTenant

    Write-Host ("[Auth] Verified SharePoint Online admin access | adminUrl={0}" -f $AdminUrl)
    return $AdminUrl
}
