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

#
# function Invoke-MicrowinGetIso2 {
#     <#
#     .DESCRIPTION
#     Function to get the path to Iso file for MicroWin, unpack that isom=, read basic information and populate the UI Options
#     #>
#
#     Write-Host "Invoking WPFGetIso"
#
#     # if($sync.ProcessRunning) {
#     #     $msg = "GetIso process is currently running."
#     #     [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
#     #     return
#     # }
#
#     $sync.BusyMessage.Visibility="Visible"
#     $sync.BusyText.Text="N Busy"
#
#     Write-Host "         _                     __    __  _         "
#     Write-Host "  /\/\  (_)  ___  _ __   ___  / / /\ \ \(_) _ __   "
#     Write-Host " /    \ | | / __|| '__| / _ \ \ \/  \/ /| || '_ \  "
#     Write-Host "/ /\/\ \| || (__ | |   | (_) | \  /\  / | || | | | "
#     Write-Host "\/    \/|_| \___||_|    \___/   \/  \/  |_||_| |_| "
#
#     $oscdimgPath = Join-Path $env:TEMP 'oscdimg.exe'
#     $oscdImgFound = [bool] (Get-Command -ErrorAction Ignore -Type Application oscdimg.exe) -or (Test-Path $oscdimgPath -PathType Leaf)
#     Write-Host "oscdimg.exe on system: $oscdImgFound"
#
#     if (!$oscdImgFound) {
#         # $downloadFromGitHub = $sync.WPFMicrowinDownloadFromGitHub.IsChecked
#         # $sync.BusyMessage.Visibility="Hidden"
#         #
#         # if (!$downloadFromGitHub) {
#         #     # only show the message to people who did check the box to download from github, if you check the box
#         #     # you consent to downloading it, no need to show extra dialogs
#         #     [System.Windows.MessageBox]::Show("oscdimge.exe is not found on the system, winutil will now attempt do download and install it using choco. This might take a long time.")
#         #     # the step below needs choco to download oscdimg
#         #     # Install Choco if not already present
#         #     Install-WinUtilChoco
#         #     $chocoFound = [bool] (Get-Command -ErrorAction Ignore -Type Application choco)
#         #     Write-Host "choco on system: $chocoFound"
#         #     if (!$chocoFound) {
#         #         [System.Windows.MessageBox]::Show("choco.exe is not found on the system, you need choco to download oscdimg.exe")
#         #         return
#         #     }
#         #
#         #     Start-Process -Verb runas -FilePath powershell.exe -ArgumentList "choco install windows-adk-oscdimg"
#         #     [System.Windows.MessageBox]::Show("oscdimg is installed, now close, reopen PowerShell terminal and re-launch winutil.ps1")
#         #     return
#         # } else {
#         #     [System.Windows.MessageBox]::Show("oscdimge.exe is not found on the system, winutil will now attempt do download and install it from github. This might take a long time.")
#         #     Microwin-GetOscdimg -oscdimgPath $oscdimgPath
#         #     $oscdImgFound = Test-Path $oscdimgPath -PathType Leaf
#         #     if (!$oscdImgFound) {
#         #         $msg = "oscdimg was not downloaded can not proceed"
#         #         [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
#         #         return
#         #     } else {
#         #         Write-Host "oscdimg.exe was successfully downloaded from github"
#         #     }
#         # }
#
#         Write-Host "oscdimge.exe is not found on the system, winutil will now attempt do download and install it from github. This might take a long time."
#
#         Microwin-GetOscdimg -oscdimgPath $oscdimgPath
#         $oscdImgFound = Test-Path $oscdimgPath -PathType Leaf
#         if (!$oscdImgFound) {
#             Write-Error "oscdimg was not downloaded can not proceed"
#             return
#         } else {
#             Write-Host "oscdimg.exe was successfully downloaded from github"
#         }
#     }
#
#     $FILE_PATH = "" # TODO: provid by args
#
#     if (!$FILE_PATH) {
#
#     }
#
#     if ($sync["ISOmanual"].IsChecked) {
#         # Open file dialog to let user choose the ISO file
#         [System.Reflection.Assembly]::LoadWithPartialName("System.windows.forms") | Out-Null
#         $openFileDialog = New-Object System.Windows.Forms.OpenFileDialog
#         $openFileDialog.initialDirectory = $initialDirectory
#         $openFileDialog.filter = "ISO files (*.iso)| *.iso"
#         $openFileDialog.ShowDialog() | Out-Null
#         $filePath = $openFileDialog.FileName
#
#         if ([string]::IsNullOrEmpty($filePath)) {
#             Write-Host "No ISO is chosen"
#             $sync.BusyMessage.Visibility="Hidden"
#             return
#         }
#     } elseif ($sync["ISOdownloader"].IsChecked) {
#         # Create folder browsers for user-specified locations
#         # [System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms") | Out-Null
#         # $isoDownloaderFBD = New-Object System.Windows.Forms.FolderBrowserDialog
#         # $isoDownloaderFBD.Description = "Please specify the path to download the ISO file to:"
#         # $isoDownloaderFBD.ShowNewFolderButton = $true
#         # if ($isoDownloaderFBD.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK)
#         # {
#         #     return
#         # }
#
#         # Grab the location of the selected path
#         $targetFolder = "." # $isoDownloaderFBD.SelectedPath
#
#         # Auto download newest ISO
#         # Credit: https://github.com/pbatard/Fido
#         $fidopath = "$env:temp\Fido.ps1"
#         $originalLocation = $PSScriptRoot
#
#         Invoke-WebRequest "https://github.com/pbatard/Fido/raw/master/Fido.ps1" -OutFile $fidopath
#
#         Set-Location -Path $env:temp
#         # Detect if the first option ("System language") has been selected and get a Fido-approved language from the current culture
#         $lang = if ($sync["ISOLanguage"].SelectedIndex -eq 0) {
#             Microwin-GetLangFromCulture -langName (Get-Culture).Name
#         } else {
#             $sync["ISOLanguage"].SelectedItem
#         }
#
#         & $fidopath -Win 'Windows 11' -Rel $sync["ISORelease"].SelectedItem -Arch "x64" -Lang $lang -Ed "Windows 11 Home/Pro/Edu"
#         if (-not $?)
#         {
#             Write-Host "Could not download the ISO file. Look at the output of the console for more information."
#             $msg = "The ISO file could not be downloaded"
#             [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
#             return
#         }
#         Set-Location $originalLocation
#         # Use the FullName property to only grab the file names. Using this property is necessary as, without it, you're passing the usual output of Get-ChildItem
#         # to the variable, and let's be honest, that does NOT exist in the file system
#         $filePath = (Get-ChildItem -Path "$env:temp" -Filter "Win11*.iso").FullName | Sort-Object LastWriteTime -Descending | Select-Object -First 1
#         $fileName = [IO.Path]::GetFileName("$filePath")
#
#         if (($targetFolder -ne "") -and (Test-Path "$targetFolder"))
#         {
#             try
#             {
#                 # "Let it download to $env:TEMP and then we **move** it to the file path." - CodingWonders
#                 $destinationFilePath = "$targetFolder\$fileName"
#                 Write-Host "Moving ISO file. Please wait..."
#                 Move-Item -Path "$filePath" -Destination "$destinationFilePath" -Force
#                 $filePath = $destinationFilePath
#             }
#             catch
#             {
#                 Write-Host "Unable to move the ISO file to the location you specified. The downloaded ISO is in the `"$env:TEMP`" folder"
#                 Write-Host "Error information: $($_.Exception.Message)" -ForegroundColor Yellow
#             }
#         }
#     }
#
#     Write-Host "File path $($filePath)"
#     if (-not (Test-Path -Path "$filePath" -PathType Leaf)) {
#         $msg = "File you've chosen doesn't exist"
#         [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
#         return
#     }
#
#     Set-WinUtilTaskbaritem -state "Indeterminate" -overlay "logo"
#
#     # Detect the file size of the ISO and compare it with the free space of the system drive
#     $isoSize = (Get-Item -Path "$filePath").Length
#     Write-Debug "Size of ISO file: $($isoSize) bytes"
#     # Use this procedure to get the free space of the drive depending on where the user profile folder is stored.
#     # This is done to guarantee a dynamic solution, as the installation drive may be mounted to a letter different than C
#     $driveSpace = (Get-Volume -DriveLetter ([IO.Path]::GetPathRoot([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)).Replace(":\", "").Trim())).SizeRemaining
#     Write-Debug "Free space on installation drive: $($driveSpace) bytes"
#     if ($driveSpace -lt ($isoSize * 2)) {
#         # It's not critical and we _may_ continue. Output a warning
#         Write-Warning "You may not have enough space for this operation. Proceed at your own risk."
#     }
#     elseif ($driveSpace -lt $isoSize) {
#         # It's critical and we can't continue. Output an error
#         Write-Host "You don't have enough space for this operation. You need at least $([Math]::Round(($isoSize / ([Math]::Pow(1024, 2))) * 2, 2)) MB of free space to copy the ISO files to a temp directory and to be able to perform additional operations."
#         Set-WinUtilTaskbaritem -state "Error" -value 1 -overlay "warning"
#         return
#     } else {
#         Write-Host "You have enough space for this operation."
#     }
#
#     try {
#         Write-Host "Mounting Iso. Please wait."
#         $mountedISO = Mount-DiskImage -PassThru "$filePath"
#         Write-Host "Done mounting Iso `"$($mountedISO.ImagePath)`""
#         $driveLetter = (Get-Volume -DiskImage $mountedISO).DriveLetter
#         Write-Host "Iso mounted to '$driveLetter'"
#     } catch {
#         # @ChrisTitusTech  please copy this wiki and change the link below to your copy of the wiki
#         Write-Error "Failed to mount the image. Error: $($_.Exception.Message)"
#         Write-Error "This is NOT winutil's problem, your ISO might be corrupt, or there is a problem on the system"
#         Write-Host "Please refer to this wiki for more details: https://christitustech.github.io/winutil/KnownIssues/#troubleshoot-errors-during-microwin-usage" -ForegroundColor Red
#         Set-WinUtilTaskbaritem -state "Error" -value 1 -overlay "warning"
#         return
#     }
#     # storing off values in hidden fields for further steps
#     # there is probably a better way of doing this, I don't have time to figure this out
#     $sync.MicrowinIsoDrive.Text = $driveLetter
#
#     $mountedISOPath = (Split-Path -Path "$filePath")
#      if ($sync.MicrowinScratchDirBox.Text.Trim() -eq "Scratch") {
#         $sync.MicrowinScratchDirBox.Text =""
#     }
#
#     $UseISOScratchDir = $sync.WPFMicrowinISOScratchDir.IsChecked
#
#     if ($UseISOScratchDir) {
#         $sync.MicrowinScratchDirBox.Text=$mountedISOPath
#     }
#
#     if( -Not $sync.MicrowinScratchDirBox.Text.EndsWith('\') -And  $sync.MicrowinScratchDirBox.Text.Length -gt 1) {
#
#          $sync.MicrowinScratchDirBox.Text = Join-Path   $sync.MicrowinScratchDirBox.Text.Trim() '\'
#
#     }
#
#     # Detect if the folders already exist and remove them
#     if (($sync.MicrowinMountDir.Text -ne "") -and (Test-Path -Path $sync.MicrowinMountDir.Text)) {
#         try {
#             Write-Host "Deleting temporary files from previous run. Please wait..."
#             Remove-Item -Path $sync.MicrowinMountDir.Text -Recurse -Force
#             Remove-Item -Path $sync.MicrowinScratchDir.Text -Recurse -Force
#         } catch {
#             Write-Host "Could not delete temporary files. You need to delete those manually."
#         }
#     }
#
#     Write-Host "Setting up mount dir and scratch dirs"
#     $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
#     $randomNumber = Get-Random -Minimum 1 -Maximum 9999
#     $randomMicrowin = "Microwin_${timestamp}_${randomNumber}"
#     $randomMicrowinScratch = "MicrowinScratch_${timestamp}_${randomNumber}"
#     $sync.BusyText.Text=" - Mounting"
#     Write-Host "Mounting Iso. Please wait."
#     if ($sync.MicrowinScratchDirBox.Text -eq "") {
#         $mountDir = Join-Path $env:TEMP $randomMicrowin
#         $scratchDir = Join-Path $env:TEMP $randomMicrowinScratch
#     } else {
#         $scratchDir = $sync.MicrowinScratchDirBox.Text+"Scratch"
#         $mountDir = $sync.MicrowinScratchDirBox.Text+"micro"
#     }
#
#     $sync.MicrowinMountDir.Text = $mountDir
#     $sync.MicrowinScratchDir.Text = $scratchDir
#     Write-Host "Done setting up mount dir and scratch dirs"
#     Write-Host "Scratch dir is $scratchDir"
#     Write-Host "Image dir is $mountDir"
#
#     try {
#
#         #$data = @($driveLetter, $filePath)
#         New-Item -ItemType Directory -Force -Path "$($mountDir)" | Out-Null
#         New-Item -ItemType Directory -Force -Path "$($scratchDir)" | Out-Null
#         Write-Host "Copying Windows image. This will take awhile, please don't use UI or cancel this step!"
#
#         # xcopy we can verify files and also not copy files that already exist, but hard to measure
#         # xcopy.exe /E /I /H /R /Y /J $DriveLetter":" $mountDir >$null
#         $totalTime = Measure-Command { Copy-Files "$($driveLetter):" "$mountDir" -Recurse -Force }
#         Write-Host "Copy complete! Total Time: $($totalTime.Minutes) minutes, $($totalTime.Seconds) seconds"
#
#         $wimFile = "$mountDir\sources\install.wim"
#         Write-Host "Getting image information $wimFile"
#
#         if ((-not (Test-Path -Path "$wimFile" -PathType Leaf)) -and (-not (Test-Path -Path "$($wimFile.Replace(".wim", ".esd").Trim())" -PathType Leaf))) {
#             $msg = "Neither install.wim nor install.esd exist in the image, this could happen if you use unofficial Windows images. Please don't use shady images from the internet, use only official images. Here are instructions how to download ISO images if the Microsoft website is not showing the link to download and ISO. https://www.techrepublic.com/article/how-to-download-a-windows-10-iso-file-without-using-the-media-creation-tool/"
#             Write-Host $msg
#             [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
#             Set-WinUtilTaskbaritem -state "Error" -value 1 -overlay "warning"
#             throw
#         }
#         elseif ((-not (Test-Path -Path $wimFile -PathType Leaf)) -and (Test-Path -Path $wimFile.Replace(".wim", ".esd").Trim() -PathType Leaf)) {
#             Write-Host "Install.esd found on the image. It needs to be converted to a WIM file in order to begin processing"
#             $wimFile = $wimFile.Replace(".wim", ".esd").Trim()
#         }
#         $sync.MicrowinWindowsFlavors.Items.Clear()
#         Get-WindowsImage -ImagePath $wimFile | ForEach-Object {
#             $imageIdx = $_.ImageIndex
#             $imageName = $_.ImageName
#             $sync.MicrowinWindowsFlavors.Items.Add("$imageIdx : $imageName")
#         }
#         $sync.MicrowinWindowsFlavors.SelectedIndex = 0
#         Write-Host "Finding suitable Pro edition. This can take some time. Do note that this is an automatic process that might not select the edition you want."
#         Get-WindowsImage -ImagePath $wimFile | ForEach-Object {
#             if ((Get-WindowsImage -ImagePath $wimFile -Index $_.ImageIndex).EditionId -eq "Professional") {
#                 # We have found the Pro edition
#                 $sync.MicrowinWindowsFlavors.SelectedIndex = $_.ImageIndex - 1
#             }
#         }
#         Get-Volume $driveLetter | Get-DiskImage | Dismount-DiskImage
#         Write-Host "Selected value '$($sync.MicrowinWindowsFlavors.SelectedValue)'....."
#
#         $sync.MicrowinOptionsPanel.Visibility = 'Visible'
#     } catch {
#         Write-Host "Dismounting bad image..."
#         Get-Volume $driveLetter | Get-DiskImage | Dismount-DiskImage
#         Remove-Item -Recurse -Force "$($scratchDir)"
#         Remove-Item -Recurse -Force "$($mountDir)"
#     }
#
#     Write-Host "Done reading and unpacking ISO"
#     Write-Host ""
#     Write-Host "*********************************"
#     Write-Host "Check the UI for further steps!!!"
#
#     $sync.BusyMessage.Visibility="Hidden"
#     $sync.ProcessRunning = $false
#     Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"
# }
#
# Invoke-MicrowinGetIso2
# if ($MICROWIN) {
# }
