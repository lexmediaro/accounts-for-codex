# Tests for AccountsForCodex. No test framework needed:
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\Test-AccountsForCodex.ps1    (Windows PowerShell 5.1)
#   pwsh -NoProfile -File tests/Test-AccountsForCodex.ps1                                  (PowerShell 7)
#
# Everything happens in a temporary folder with a space in its name. Your real ~/.codex and your Windows Terminal
# settings are never touched, and the Codex CLI is replaced by tests/stub-codex.ps1.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$sandbox = Join-Path ([IO.Path]::GetTempPath()) ('accounts for codex ' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $sandbox | Out-Null

$saved = @{}
foreach ($name in 'CODEX_HOME', 'CODEX_ACCOUNTS_HOME', 'CODEX_ACCOUNTS_DEFAULT', 'CODEX_ACCOUNTS_CODEX', 'CODEX_ACCOUNTS_WT_FRAGMENTS', 'STUB_CODEX_LOG') {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name)
}
$env:CODEX_ACCOUNTS_HOME = Join-Path $sandbox 'accounts'
$env:CODEX_ACCOUNTS_DEFAULT = Join-Path $sandbox 'default home'
$env:CODEX_ACCOUNTS_CODEX = Join-Path $here 'stub-codex.ps1'
$env:CODEX_ACCOUNTS_WT_FRAGMENTS = Join-Path $sandbox 'fragments'
$env:STUB_CODEX_LOG = Join-Path $sandbox 'stub.log'
Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $env:CODEX_ACCOUNTS_DEFAULT | Out-Null

Import-Module (Join-Path (Join-Path (Split-Path -Parent $here) 'AccountsForCodex') 'AccountsForCodex.psd1') -Force

$script:passed = 0
$script:failed = 0
function Check([string]$What, [scriptblock]$Test) {
    try {
        if (& $Test) { $script:passed++; Write-Output "ok    $What" }
        else { $script:failed++; Write-Output "FAIL  $What" }
    }
    catch { $script:failed++; Write-Output "FAIL  $What  ->  $($_.Exception.Message)" }
}
function Throws([scriptblock]$Code, [string]$Like = '*') {
    try { & $Code | Out-Null; $false } catch { $_.Exception.Message -like $Like }
}
function Calls { if (Test-Path -LiteralPath $env:STUB_CODEX_LOG) { @(Get-Content -LiteralPath $env:STUB_CODEX_LOG).Count } else { 0 } }
function LastCall { Get-Content -LiteralPath $env:STUB_CODEX_LOG | Select-Object -Last 1 | ConvertFrom-Json }
function AccountPath([string]$Name) { Join-Path $env:CODEX_ACCOUNTS_HOME $Name }
function New-FakeJwt($Claims) {
    $part = { param($o) [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($o | ConvertTo-Json -Compress -Depth 5))).TrimEnd('=').Replace('+', '-').Replace('/', '_') }
    '{0}.{1}.not-a-real-signature' -f (& $part @{ alg = 'none' }), (& $part $Claims)
}
function Set-FakeLogin([string]$Folder, [string]$Email, [string]$Plan) {
    $auth = @{
        OPENAI_API_KEY = $null
        tokens         = @{
            id_token      = (New-FakeJwt @{ email = $Email; 'https://api.openai.com/auth' = @{ chatgpt_plan_type = $Plan } })
            access_token  = 'SECRET-ACCESS-TOKEN'
            refresh_token = 'SECRET-REFRESH-TOKEN'
            account_id    = 'acct_test'
        }
        last_refresh   = '2026-11-01T00:00:00Z'
    }
    [IO.File]::WriteAllText((Join-Path $Folder 'auth.json'), ($auth | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
}

try {
    # --- listing and creating
    Check 'at first only the normal Codex folder is listed, and it is the current one' {
        $all = @(Get-CodexAccount)
        $all.Count -eq 1 -and $all[0].Name -eq 'default' -and $all[0].Current -and -not $all[0].SignedIn
    }
    Check 'New-CodexAccount creates an empty folder and reports it as not signed in' {
        $a = New-CodexAccount work
        $a.Name -eq 'work' -and -not $a.SignedIn -and (Test-Path -LiteralPath (AccountPath 'work') -PathType Container) -and
            @(Get-ChildItem -LiteralPath (AccountPath 'work') -Force).Count -eq 0
    }
    Check 'names that would escape the folder, hold spaces or reuse "default" are refused' {
        (Throws { New-CodexAccount 'a b' } '*not a usable account name*') -and (Throws { New-CodexAccount '..\x' } '*not a usable*') -and
            (Throws { New-CodexAccount '../x' } '*not a usable*') -and (Throws { New-CodexAccount '-x' } '*not a usable*') -and
            (Throws { New-CodexAccount ('a' * 33) } '*not a usable*') -and (Throws { New-CodexAccount 'default' } '*normal Codex folder*')
    }
    Check 'creating the same account twice is an error' { Throws { New-CodexAccount work } '*already exists*' }
    Check '-WhatIf creates nothing' {
        New-CodexAccount ghost -WhatIf | Out-Null
        -not (Test-Path -LiteralPath (AccountPath 'ghost'))
    }

    # --- who is signed in
    Set-FakeLogin (AccountPath 'work') 'me@company.com' 'team'
    Check 'the e-mail and plan are read from the account''s own auth.json' {
        $a = Get-CodexAccount work
        $a.SignedIn -and $a.Email -eq 'me@company.com' -and $a.Plan -eq 'team' -and $a.Login -eq 'ChatGPT'
    }
    Check 'no token ever appears in what the module returns' {
        $text = (Get-CodexAccount | ConvertTo-Json -Depth 6) + (Get-CodexAccount | Format-List * | Out-String)
        $text -notmatch 'SECRET' -and $text -notmatch 'not-a-real-signature' -and $text -match 'me@company.com'
    }
    New-CodexAccount personal | Out-Null
    [IO.File]::WriteAllText((Join-Path (AccountPath 'personal') 'auth.json'), '{"OPENAI_API_KEY":"sk-test-not-real","tokens":null}', (New-Object Text.UTF8Encoding $false))
    Check 'an API key login counts as signed in, with no e-mail' {
        $a = Get-CodexAccount personal
        $a.SignedIn -and $a.Login -eq 'API key' -and -not $a.Email -and ((Get-CodexAccount personal | ConvertTo-Json) -notmatch 'sk-test')
    }
    New-CodexAccount broken | Out-Null
    [IO.File]::WriteAllText((Join-Path (AccountPath 'broken') 'auth.json'), '{ this is not json', (New-Object Text.UTF8Encoding $false))
    Check 'a damaged auth.json is reported, not fatal' {
        $a = Get-CodexAccount broken
        -not $a.SignedIn -and $a.Login -eq 'unreadable' -and @(Get-CodexAccount).Count -eq 4
    }

    # --- codex-as
    Check 'codex-as runs Codex with that account''s folder and passes every argument through unchanged' {
        codex-as work exec 'two words' -m gpt-5 -c 'model_reasoning_effort="high"' --full-auto -a never
        $call = LastCall
        $expected = @('exec', 'two words', '-m', 'gpt-5', '-c', 'model_reasoning_effort="high"', '--full-auto', '-a', 'never')
        $call.home -eq (AccountPath 'work') -and (($call.args -join '|') -eq ($expected -join '|'))
    }
    Check 'afterwards CODEX_HOME is unset again when it was unset before' { $null -eq $env:CODEX_HOME }
    Check 'afterwards CODEX_HOME is back to its earlier value when it had one' {
        $env:CODEX_HOME = 'some-earlier-value'
        try { codex-as personal login status; (LastCall).home -eq (AccountPath 'personal') -and $env:CODEX_HOME -eq 'some-earlier-value' }
        finally { Remove-Item Env:CODEX_HOME }
    }
    Check 'CODEX_HOME is put back even when Codex fails' {
        codex-as work --exit 3
        $LASTEXITCODE -eq 3 -and $null -eq $env:CODEX_HOME
    }
    Check '"default" runs the normal Codex folder' {
        codex-as default --version
        (LastCall).home -eq $env:CODEX_ACCOUNTS_DEFAULT
    }
    Check 'an unknown account is an error and Codex is not started' {
        $before = Calls
        (Throws { codex-as nobody exec hi } '*no Codex account named*New-CodexAccount nobody*') -and (Calls) -eq $before
    }
    Check 'codex-as with no account explains itself' { Throws { codex-as } '*Usage: codex-as*' }

    # --- Enter / Exit
    Check 'Enter-CodexAccount sets this window to the account, and it becomes the current one' {
        Enter-CodexAccount work 6>$null
        $env:CODEX_HOME -eq (AccountPath 'work') -and (Get-CodexAccount -Current).Name -eq 'work'
    }
    Check 'entering another account switches, and Exit-CodexAccount returns to how the window started' {
        Enter-CodexAccount personal 6>$null
        $switched = (Get-CodexAccount -Current).Name -eq 'personal'
        Exit-CodexAccount
        $switched -and $null -eq $env:CODEX_HOME -and (Get-CodexAccount -Current).Name -eq 'default'
    }
    Check 'Exit-CodexAccount with nothing entered does nothing' { Exit-CodexAccount; $null -eq $env:CODEX_HOME }

    # --- copying settings, never the login
    [IO.File]::WriteAllText((Join-Path (AccountPath 'work') 'config.toml'), "model = `"gpt-5`"`n", (New-Object Text.UTF8Encoding $false))
    Check '-CopyConfigFrom copies config.toml and never auth.json' {
        $a = New-CodexAccount client -CopyConfigFrom work
        (Test-Path -LiteralPath (Join-Path $a.Path 'config.toml')) -and -not (Test-Path -LiteralPath (Join-Path $a.Path 'auth.json')) -and -not $a.SignedIn -and
            @(Get-ChildItem -LiteralPath $a.Path -Force).Count -eq 1
    }
    Check '-CopyConfigFrom an account without settings is an error and creates nothing' {
        (Throws { New-CodexAccount other -CopyConfigFrom personal } '*no config.toml*') -and -not (Test-Path -LiteralPath (AccountPath 'other'))
    }

    # --- Windows Terminal profiles
    Check 'Add-CodexTerminalProfile writes one UTF-8 JSON file without a byte order mark' {
        Add-CodexTerminalProfile work 6>$null
        $file = Join-Path $env:CODEX_ACCOUNTS_WT_FRAGMENTS 'work.json'
        $bytes = [IO.File]::ReadAllBytes($file)
        $p = ([IO.File]::ReadAllText($file) | ConvertFrom-Json).profiles[0]
        $bytes[0] -eq 0x7B -and $p.name -eq 'Codex: work' -and $p.tabTitle -eq 'Codex: work' -and $p.suppressApplicationTitle -eq $true -and
            $p.tabColor -match '^#[0-9A-Fa-f]{6}$' -and $p.commandline -eq ('powershell.exe -NoExit -Command "$env:CODEX_HOME = ''{0}''"' -f (AccountPath 'work'))
    }
    Check 'the tab color and shell can be chosen' {
        Add-CodexTerminalProfile personal -TabColor '#1A7F37' -Shell pwsh 6>$null
        $p = ([IO.File]::ReadAllText((Join-Path $env:CODEX_ACCOUNTS_WT_FRAGMENTS 'personal.json')) | ConvertFrom-Json).profiles[0]
        $p.tabColor -eq '#1A7F37' -and $p.commandline.StartsWith('pwsh.exe -NoExit')
    }
    Check 'a bad color is refused' { Throws { Add-CodexTerminalProfile work -TabColor 'blue' } }
    Check 'Remove-CodexTerminalProfile deletes only that file' {
        Remove-CodexTerminalProfile personal
        -not (Test-Path -LiteralPath (Join-Path $env:CODEX_ACCOUNTS_WT_FRAGMENTS 'personal.json')) -and (Test-Path -LiteralPath (Join-Path $env:CODEX_ACCOUNTS_WT_FRAGMENTS 'work.json'))
    }

    # --- removing
    Check 'the normal Codex folder cannot be removed' { (Throws { Remove-CodexAccount default -Confirm:$false } '*normal Codex folder*') -and (Test-Path -LiteralPath $env:CODEX_ACCOUNTS_DEFAULT) }
    Check 'an account in use by this window cannot be removed' {
        Enter-CodexAccount client 6>$null
        try { (Throws { Remove-CodexAccount client -Confirm:$false } '*Exit-CodexAccount first*') -and (Test-Path -LiteralPath (AccountPath 'client')) }
        finally { Exit-CodexAccount }
    }
    Check 'Remove-CodexAccount -WhatIf removes nothing' {
        Remove-CodexAccount work -WhatIf
        Test-Path -LiteralPath (AccountPath 'work')
    }
    Check 'Remove-CodexAccount deletes the folder and its Terminal profile, and nothing else' {
        Remove-CodexAccount work -Confirm:$false
        -not (Test-Path -LiteralPath (AccountPath 'work')) -and -not (Test-Path -LiteralPath (Join-Path $env:CODEX_ACCOUNTS_WT_FRAGMENTS 'work.json')) -and
            (Test-Path -LiteralPath (AccountPath 'personal')) -and (Test-Path -LiteralPath $env:CODEX_ACCOUNTS_DEFAULT)
    }

    # --- tab completion
    Check 'account names complete with Tab' {
        $line = 'Enter-CodexAccount pe'
        $names = @([System.Management.Automation.CommandCompletion]::CompleteInput($line, $line.Length, $null).CompletionMatches | ForEach-Object { $_.CompletionText })
        $line2 = 'codex-as cl'
        $names2 = @([System.Management.Automation.CommandCompletion]::CompleteInput($line2, $line2.Length, $null).CompletionMatches | ForEach-Object { $_.CompletionText })
        ($names -contains 'personal') -and ($names2 -contains 'client')
    }

    # --- the manifest
    Check 'the manifest is valid and exports exactly the public commands' {
        $m = Test-ModuleManifest (Join-Path (Join-Path (Split-Path -Parent $here) 'AccountsForCodex') 'AccountsForCodex.psd1')
        $m.Version.ToString() -eq '1.0.0' -and @($m.ExportedFunctions.Keys).Count -eq 8 -and @($m.ExportedAliases.Keys) -contains 'codex-as'
    }
}
finally {
    Remove-Module AccountsForCodex -ErrorAction SilentlyContinue
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
Write-Output ("{0} passed, {1} failed (PowerShell {2})" -f $script:passed, $script:failed, $PSVersionTable.PSVersion)
exit $script:failed
