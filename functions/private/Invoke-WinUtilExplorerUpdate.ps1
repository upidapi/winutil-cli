function Invoke-WinUtilExplorerUpdate {
    <#
    .SYNOPSIS
        Refreshes the Windows Explorer
    #>

    param (
        [string]$action = "refresh"
    )

    if ($action -eq "refresh") {
        Invoke-WPFRunspace -DebugPreference $DebugPreference -ScriptBlock {
            # Send the WM_SETTINGCHANGE message to all windows
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = false)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd,
        uint Msg,
        IntPtr wParam,
        string lParam,
        uint fuFlags,
        uint uTimeout,
        out IntPtr lpdwResult);
}
"@

            $HWND_BROADCAST = [IntPtr]0xffff
            $WM_SETTINGCHANGE = 0x1A
            $SMTO_ABORTIFHUNG = 0x2
            $timeout = 100

            # Send the broadcast message to all windows
            [Win32]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE, [IntPtr]::Zero, "ImmersiveColorSet", $SMTO_ABORTIFHUNG, $timeout, [ref]([IntPtr]::Zero))
        } | Out-null
    } elseif ($action -eq "restart") {
        # Restart the Windows Explorer
        taskkill.exe /F /IM "explorer.exe"
        Start-Process "explorer.exe"
    }
}
