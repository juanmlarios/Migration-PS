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

    $availableModule = Get-Module -ListAvailable -Name Microsoft.Online.SharePoint.PowerShell |
    Sort-Object Version -Descending |
    Select-Object -First 1

    if (-not $availableModule) {
        throw "Required module 'Microsoft.Online.SharePoint.PowerShell' is not installed."
    }

    if ($PSVersionTable.PSVersion.Major -ge 7 -and $IsWindows) {
        return Import-Module Microsoft.Online.SharePoint.PowerShell -UseWindowsPowerShell -PassThru -ErrorAction Stop
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
    Assert-ModuleMinimumVersion -Name ExchangeOnlineManagement -MinimumVersion "3.0.0"
    Assert-ModuleMinimumVersion -Name Microsoft.Graph.Authentication -MinimumVersion "2.0.0"
    Assert-ModuleMinimumVersion -Name Microsoft.Graph.Users -MinimumVersion "2.0.0"
    Assert-ModuleMinimumVersion -Name Microsoft.Graph.Identity.DirectoryManagement -MinimumVersion "2.0.0"
    Assert-ModuleMinimumVersion -Name Microsoft.Graph.Groups -MinimumVersion "2.0.0"
    Assert-ModuleMinimumVersion -Name Microsoft.Graph.Identity.SignIns -MinimumVersion "2.0.0"
    Assert-ModuleMinimumVersion -Name Microsoft.Online.SharePoint.PowerShell -MinimumVersion "16.0.0"
    Import-SharePointOnlineModule | Out-Null
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

    $connectParams = @{
        ShowBanner = $false
    }

    if ($AdminUpn) {
        $connectParams["UserPrincipalName"] = $AdminUpn
    }

    if ($UseDeviceCode.IsPresent) {
        $deviceParam = (Get-Command Connect-ExchangeOnline).Parameters.ContainsKey("Device")
        if (-not $deviceParam) {
            throw "The installed ExchangeOnlineManagement module does not support -Device. Update the module and retry."
        }
        Connect-ExchangeOnline @connectParams -Device
    } else {
        if ($DisableWAM.IsPresent) {
            if (-not $disableWamSupported) {
                throw "The installed ExchangeOnlineManagement module does not support -DisableWAM. Update the module and retry."
            }

            Write-Host "[Auth] Exchange Online will start with WAM disabled for this session."
            Connect-ExchangeOnline @connectParams -DisableWAM
        } else {
            try {
                Connect-ExchangeOnline @connectParams
            } catch {
                if (-not $disableWamSupported -or -not (Test-ExchangeWamBrokerFailure -ErrorRecord $_)) {
                    throw
                }

                Write-Warning "Exchange Online interactive sign-in failed in the WAM broker path. Retrying with -DisableWAM."
                Connect-ExchangeOnline @connectParams -DisableWAM
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

    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null

    if ($UseDeviceCode.IsPresent) {
        $deviceParam = (Get-Command Connect-MgGraph).Parameters.ContainsKey("UseDeviceCode")
        if (-not $deviceParam) {
            throw "The installed Microsoft.Graph.Authentication module does not support -UseDeviceCode. Update the module and retry."
        }
        Connect-MgGraph -Scopes $Scopes -UseDeviceCode | Out-Null
    } else {
        Connect-MgGraph -Scopes $Scopes | Out-Null
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
