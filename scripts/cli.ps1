# Create enums
Add-Type @"
public enum PackageManagers
{
    Winget,
    Choco
}
"@

# SPDX-License-Identifier: MIT
# Set the maximum number of threads for the RunspacePool to the number of threads on the machine
$maxthreads = [int]$env:NUMBER_OF_PROCESSORS

# Create a new session state for parsing variables into our runspace
$hashVars = New-object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'sync',$sync,$Null
$InitialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()

# Add the variable to the session state
$InitialSessionState.Variables.Add($hashVars)

# Get every private function and add them to the session state
$functions = Get-ChildItem function:\ | Where-Object { $_.Name -imatch 'winutil|Microwin|WPF' }
foreach ($function in $functions) {
    $functionDefinition = Get-Content function:\$($function.name)
    $functionEntry = New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $($function.name), $functionDefinition

    $initialSessionState.Commands.Add($functionEntry)
}

# Create the runspace pool
$sync.runspace = [runspacefactory]::CreateRunspacePool(
    1,                      # Minimum thread count
    $maxthreads,            # Maximum thread count
    $InitialSessionState,   # Initial session state
    $Host                   # Machine to create runspaces on
)

# Open the RunspacePool instance
$sync.runspace.Open()

# Create classes for different exceptions

# defined in main.ps1
# class WingetFailedInstall : Exception {
#     [string]$additionalData
#     WingetFailedInstall($Message) : base($Message) {}
# }
#
# class ChocoFailedInstall : Exception {
#     [string]$additionalData
#     ChocoFailedInstall($Message) : base($Message) {}
# }
#
# class GenericException : Exception {
#     [string]$additionalData
#     GenericException($Message) : base($Message) {}
# }

$inputXML = $inputXML -replace 'mc:Ignorable="d"', '' -replace "x:N", 'N' -replace '^<Win.*', '<Window'

[void][System.Reflection.Assembly]::LoadWithPartialName('presentationframework')
[xml]$XAML = $inputXML

# Read the XAML file
$readerOperationSuccessful = $false # There's more cases of failure then success.
$reader = (New-Object System.Xml.XmlNodeReader $xaml)
try {
    $sync["Form"] = [Windows.Markup.XamlReader]::Load( $reader )
    $readerOperationSuccessful = $true
} catch [System.Management.Automation.MethodInvocationException] {
    Write-Host "We ran into a problem with the XAML code.  Check the syntax for this control..." -ForegroundColor Red
    Write-Host $error[0].Exception.Message -ForegroundColor Red

    If ($error[0].Exception.Message -like "*button*") {
        write-Host "Ensure your &lt;button in the `$inputXML does NOT have a Click=ButtonClick property.  PS can't handle this`n`n`n`n" -ForegroundColor Red
    }
} catch {
    Write-Host "Unable to load Windows.Markup.XamlReader. Double-check syntax and ensure .net is installed." -ForegroundColor Red
}

if (-NOT ($readerOperationSuccessful)) {
    Write-Host "Failed to parse xaml content using Windows.Markup.XamlReader's Load Method." -ForegroundColor Red
    Write-Host "Quitting winutil..." -ForegroundColor Red
    $sync.runspace.Dispose()
    $sync.runspace.Close()
    [System.GC]::Collect()
    exit 1
}

$sync.configs.applicationsHashtable = @{}
$sync.configs.applications.PSObject.Properties | ForEach-Object {
    $sync.configs.applicationsHashtable[$_.Name] = $_.Value
}

#===========================================================================
# Store Form Objects In PowerShell
#===========================================================================

$xaml.SelectNodes("//*[@Name]") | ForEach-Object {
    $sync["$("$($psitem.Name)")"] = $sync["Form"].FindName($psitem.Name)
}

# Load computer information in the background
Invoke-WPFRunspace -ScriptBlock {
    try {
        $ProgressPreference = "SilentlyContinue"
        $sync.ConfigLoaded = $False
        $sync.ComputerInfo = Get-ComputerInfo
        $sync.ConfigLoaded = $True
    }
    finally{
        $ProgressPreference = $oldProgressPreference
    }

} | Out-Null


function updateProgrss {
    param(
        $activity,
        $totalItems,
        $currentItem,
        $status
    )

    $percentComplete = ($currentItem / $totalItems) * 100
    $barWidth = 20  # Width of the progress bar in characters

    $filled = [int]($percentComplete / (100 / $barWidth))
    $progressBar = "[" + ("=" * $Filled) + (" " * ($barWidth - $filled)) + "]"

    # Make sure the current item always has same width
    $itemWidth = [string]$totalItems
    $itemWidth = $itemWidth.Length
    $paddedCurrentItem = $currentItem.ToString().PadLeft($itemWidth)

    Write-Host "`r" -NoNewline
    Write-Host -NoNewline `
        "$($activity)$($ProgressBar) $($paddedCurrentItem)\$($totalItems) $($status)`r"
}


function printProgrss {
    param(
        $activity,
        $totalItems,
        $currentItem,
        $status
    )

    $itemWidth = [string]$totalItems
    $itemWidth = $itemWidth.Length
    $paddedCurrentItem = $currentItem.ToString().PadLeft($itemWidth)

    Write-Host "`r" -NoNewline
    Write-Host -NoNewline `
        "$($activity)$($paddedCurrentItem)\$($totalItems) $($status)`r"
}

function Write-Banner {
    param (
        [string]$Text
    )

    $maxLength = 43
    $textLength = $Text.Length

    $paddingLength = $maxLength - $textLength - 4

    # Calculate left padding to center the text
    $leftPaddingLength = [int]($paddingLength / 2)
    $rightPaddingLength = $paddingLength - $leftPaddingLength

    # Create padding strings
    $leftPadding = " " * $leftPaddingLength
    $rightPadding = " " * $rightPaddingLength

    # Build the banner
    Write-Host
    Write-Host "==========================================="
    Write-Host "--$leftPadding$Text$rightPadding--"
    Write-Host "==========================================="
    Write-Host
}

function InstallTweaks {
    Param(
        $cfg
    )

    # take the list of tweaks from the json, and pass it one by one to this
    Write-Banner "Installing tweaks"
    $Tweaks = $cfg.WPFTweaks

    for ($i = 0; $i -lt $Tweaks.Count; $i++) {
        # updateProgrss "" $tweaks.Count $i "Applying $($tweaks[$i])"
        Write-Host
        Write-Host "Applying $($tweaks[$i])"

        Invoke-WinUtilTweaks $tweaks[$i]
    }

    Write-Banner "Installing toggles"
    $Toggles = $cfg.WPFToggle
    for ($i = 0; $i -lt $Toggles.Count; $i++) {
        $toggle = $Toggles[$i]
        $name = $toggle.Substring(0, $toggle.Length - 2)
        $state = $toggle.ToCharArray()[$toggle.Length - 1]

        Write-Host

        if ($state -eq "1") {
            Write-Host "Applying $($name)"
            Invoke-WinUtilTweaks $name
        } elseif ($state -eq "0") {
            Write-Host "Undoing $($name)"
            Invoke-WinUtilTweaks $name -undo $true
        } else {
            Write-Error "Invallid state, $($state) for $($toggle)"
        }

        # updateProgrss "" $Toggles.Count $i "Applying $($toggle)"
    }
}


function InstallFeatures {
    Param(
        $cfg
    )

    # Invoke-WinUtilFeatureInstall $Features
    Write-Banner "installing features"
    $Features = $cfg.WPFFeature

    $Features | ForEach-Object {
        if($sync.configs.feature.$psitem.feature) {
            Foreach( $feature in $sync.configs.feature.$psitem.feature ) {
                try {
                    Write-Host "Installing $feature"
                    Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart -LogLevel 2
                } catch {
                    if ($psitem.Exception.Message -like "*requires elevation*") {
                        Write-Warning "Unable to Install $feature due to permissions. Are you running as admin?"
                    } else {

                        Write-Warning "Unable to Install $feature due to unhandled exception"
                        Write-Warning $psitem.Exception.StackTrace
                    }
                }
            }
        }
        if($sync.configs.feature.$psitem.InvokeScript) {
            Foreach( $script in $sync.configs.feature.$psitem.InvokeScript ) {
                try {
                    $Scriptblock = [scriptblock]::Create($script)

                    Write-Host "Running Script for $psitem"
                    Invoke-Command $scriptblock -ErrorAction stop
                } catch {
                    if ($psitem.Exception.Message -like "*requires elevation*") {
                        Write-Warning "Unable to Install $feature due to permissions. Are you running as admin?"
                    } else {
                        Write-Warning "Unable to Install $feature due to unhandled exception"
                        Write-Warning $psitem.Exception.StackTrace
                    }
                }
            }
        }
    }
}

function InstallApps {
    Param(
        $cfg
    )

    # Invoke-WPFInstall
    Write-Banner "installing apps"

    $PackagesToInstall = $cfg.WPFInstall `
        | Foreach-Object { $sync.configs.applicationsHashtable.$_ }

    # always install these
    Install-WinUtilWinget
    Install-WinUtilChoco

    # Set-PackageManagerPreference
    $sync["ManagerPreference"] = [PackageManagers]::Choco
    $ManagerPreference = $sync["ManagerPreference"]

    if ($cfg.WPFInstall.Count -eq 0) {
        return
    }

    $packagesSorted = Get-WinUtilSelectedPackages `
        -PackageList $PackagesToInstall `
        -Preference $ManagerPreference

    $packagesWinget = $packagesSorted[[PackageManagers]::Winget]
    $packagesChoco = $packagesSorted[[PackageManagers]::Choco]

    try {
        $errorPackages = @()
        if($packagesWinget.Count -gt 0) {
            Install-WinUtilProgramWinget -Action Install -Programs $packagesWinget
        }
        if($packagesChoco.Count -gt 0) {
            Install-WinUtilProgramChoco -Action Install -Programs $packagesChoco
        }
    } catch {
        Write-Error $_
    }
}

function WingetSmt {
    Install-Module -Name Microsoft.WinGet.Client
    Import-Module -Name Microsoft.WinGet.Client

    # Install winget
    Repair-WinGetPackager 
    Assert-WinGetPackageManager -Latest

    $packageId = "Vencord.Vesktop"

    $packageData = Get-WingetPackage -Id $packageId -ErrorAction SilentlyContinue
    if (! $package) {
        Write-Host "Installing $packageId"

        $null = Install-WinGetPackage -Id $packageId
        # $errorCode = $installData.InstallerErrorCode
        # if ($errorCode -ne 0) {
        #     Write-Host "  failed with exit code: $($errorCode)"
        # } 
    } elseif ($packageData.IsUpdateAvailable) {
        Write-Host "Updating $packageId"

        $null = Update-WinGetPackage -Id $packageId
    }
}



Write-Host "Running config file tasks..."

if (!$PARAM_CONFIG) {
    Write-Error "Missing -Config"
}

$cfg = Get-Content $Config | ConvertFrom-Json

InstallTweaks $cfg

InstallFeatures $cfg

InstallApps $cfg

Write-Banner "Installs have finished"
