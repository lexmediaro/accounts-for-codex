@{
    RootModule           = 'AccountsForCodex.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = '6c1f0d2e-3b7a-4e55-9a41-5d0b8c2f7e19'
    Author               = 'LEX GLOBAL IT S.R.L.'
    CompanyName          = 'LEX GLOBAL IT S.R.L.'
    Copyright            = '(c) 2026 LEX GLOBAL IT S.R.L. MIT License.'
    Description          = 'One Codex CLI login per account, side by side: each account gets its own CODEX_HOME folder and, on Windows, its own Windows Terminal profile. Logins are never copied or moved.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @(
        'Get-CodexAccount', 'New-CodexAccount', 'Remove-CodexAccount', 'Invoke-CodexAs',
        'Enter-CodexAccount', 'Exit-CodexAccount', 'Add-CodexTerminalProfile', 'Remove-CodexTerminalProfile'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @('codex-as')
    PrivateData          = @{
        PSData = @{
            Tags         = @('codex', 'cli', 'accounts', 'CODEX_HOME', 'windows-terminal', 'Windows', 'MacOS', 'Linux')
            LicenseUri   = 'https://github.com/lexmediaro/accounts-for-codex/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/lexmediaro/accounts-for-codex'
            ReleaseNotes = 'First release.'
        }
    }
}
