# Note that the install field doesn't do anything

Set-ExecutionPolicy Unrestricted -Force
Start-Service VirtioFsSvc

cd C:\\Users\Default
rm .\winutil\ -r -fo
cp Z:\winutil-v3 .\winutil -r 
cd .\winutil\

Write-Host "Converting file encodings"

$files = Get-ChildItem -Path . -Recurse -File `
    | Where-Object { 
        $_.Extension -in @(".ps1", ".txt", ".xml", ".config", ".csv", ".json") 
    }

# Iterate through each file.
foreach ($file in $files) {
  try {
    # Read the content of the file.
    $content = Get-Content -Path $file.FullName

    # Write the content back to the file, using the specified encoding.
    $content | Out-File -FilePath $file.FullName -Encoding Unicode

    Write-Host "$($file.FullName)"
  }
  catch {
    Write-Host "Error converting encoding for: $($file.FullName)"
    Write-Host "Error Message: $($_.Exception.Message)"
  }
}

Write-Host "Encoding conversion process completed."

.\Compile.ps1
.\winutil.ps1 -Config "config.json" -Run
