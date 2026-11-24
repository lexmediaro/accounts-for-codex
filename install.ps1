<#
Installs AccountsForCodex for the current user. No administrator rights, nothing system-wide.
Run it from the repository folder:

    .\install.ps1               install or update
    .\install.ps1 -Uninstall    remove the module (your accounts in ~/.codex-accounts stay)

On Windows the module is copied to both Windows PowerShell's and PowerShell 7's user module folders, so
"powershell" and "pwsh" both find it. On macOS and Linux it goes to ~/.local/share/powershell/Modules.
#>
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows

if ($onWindows) {
    $documents = [Environment]::GetFolderPath('MyDocuments')
    $moduleFolders = @(
        (Join-Path (Join-Path $documents 'WindowsPowerShell') 'Modules'),
        (Join-Path (Join-Path $documents 'PowerShell') 'Modules')
    )
}
else {
    $moduleFolders = @(Join-Path $HOME '.local/share/powershell/Modules')
}

$source = Join-Path $PSScriptRoot 'AccountsForCodex'
foreach ($folder in $moduleFolders) {
    $target = Join-Path $folder 'AccountsForCodex'
    if ($Uninstall) {
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force
            Write-Output "Removed $target"
        }
        continue
    }
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    Copy-Item -Path (Join-Path $source '*') -Destination $target -Recurse -Force
    Write-Output "Installed to $target"
}

if ($Uninstall) { Write-Output 'Your accounts in ~/.codex-accounts were not touched.' }
else { Write-Output 'Open a new PowerShell window, then try: New-CodexAccount work' }
