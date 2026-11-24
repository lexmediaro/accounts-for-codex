# AccountsForCodex: one Codex CLI login per account, side by side.
#
# Each account gets its own CODEX_HOME folder under ~/.codex-accounts/<name>. Codex keeps its login, settings and
# history in CODEX_HOME, so two windows with different folders are two accounts signed in at the same time.
# The module only sets that one environment variable. It never copies, moves or prints a login, and it never
# changes your normal ~/.codex folder.
#
# Works in Windows PowerShell 5.1 and PowerShell 7 (Windows, macOS, Linux).

Set-StrictMode -Version 2.0

$script:OnWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
$script:NamePattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$'
$script:DefaultName = 'default'
$script:Entered = $null                       # what Enter-CodexAccount changed, so Exit-CodexAccount can undo it
$script:TabColors = @('#2F6FEB', '#E8590C', '#8250DF', '#1A7F37', '#CF222E', '#0A7EA4')

function Get-AccountsRoot {
    if ($env:CODEX_ACCOUNTS_HOME) { return $env:CODEX_ACCOUNTS_HOME }
    Join-Path $HOME '.codex-accounts'
}

function Get-DefaultCodexHome {
    # Your normal Codex folder. CODEX_ACCOUNTS_DEFAULT exists for the tests; leave it unset.
    if ($env:CODEX_ACCOUNTS_DEFAULT) { return $env:CODEX_ACCOUNTS_DEFAULT }
    Join-Path $HOME '.codex'
}

function Test-AccountName([string]$Name) {
    if ($Name -notmatch $script:NamePattern) {
        throw "'$Name' is not a usable account name. Use letters, digits, dot, dash or underscore, starting with a letter or digit, up to 32 characters."
    }
    if ($Name -eq $script:DefaultName) {
        throw "'$($script:DefaultName)' is the name of your normal Codex folder. Pick another name."
    }
}

function ConvertFrom-JwtPayload([string]$Jwt) {
    $parts = $Jwt.Split('.')
    if ($parts.Count -lt 2) { return $null }
    $b64 = $parts[1].Replace('-', '+').Replace('_', '/')
    switch ($b64.Length % 4) {
        2 { $b64 += '==' }
        3 { $b64 += '=' }
        1 { return $null }
    }
    try { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) | ConvertFrom-Json }
    catch { $null }
}

function Read-CodexLogin([string]$Path) {
    # Who is signed in to this folder, read from auth.json. Returns the e-mail and plan, never a token.
    $login = @{ SignedIn = $false; Email = $null; Plan = $null; Kind = $null }
    $file = Join-Path $Path 'auth.json'
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $login }
    try { $auth = Get-Content -LiteralPath $file -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop }
    catch { $login.Kind = 'unreadable'; return $login }
    if ($null -eq $auth) { $login.Kind = 'unreadable'; return $login }

    $idToken = $null
    $tokens = $auth.PSObject.Properties['tokens']
    if ($tokens -and $tokens.Value) {
        $id = $tokens.Value.PSObject.Properties['id_token']
        if ($id) { $idToken = $id.Value }
    }
    $apiKey = $auth.PSObject.Properties['OPENAI_API_KEY']
    if ($idToken) {
        $login.SignedIn = $true
        $login.Kind = 'ChatGPT'
        $claims = if ($idToken -is [string]) { ConvertFrom-JwtPayload $idToken } else { $idToken }
        if ($claims) {
            $email = $claims.PSObject.Properties['email']
            if ($email) { $login.Email = [string]$email.Value }
            $openai = $claims.PSObject.Properties['https://api.openai.com/auth']
            if ($openai -and $openai.Value) {
                $plan = $openai.Value.PSObject.Properties['chatgpt_plan_type']
                if ($plan) { $login.Plan = [string]$plan.Value }
            }
        }
    }
    elseif ($apiKey -and $apiKey.Value) {
        $login.SignedIn = $true
        $login.Kind = 'API key'
    }
    $login
}

function Get-CurrentAccountPath {
    if ($env:CODEX_HOME) { return $env:CODEX_HOME }
    Get-DefaultCodexHome
}

function Test-SamePath([string]$A, [string]$B) {
    $trim = [char[]]@('\', '/')
    $a1 = $A.TrimEnd($trim)
    $b1 = $B.TrimEnd($trim)
    if ($script:OnWindows) { return [string]::Equals($a1, $b1, [StringComparison]::OrdinalIgnoreCase) }
    [string]::Equals($a1, $b1, [StringComparison]::Ordinal)
}

function New-AccountObject([string]$Name, [string]$Path) {
    $login = Read-CodexLogin $Path
    $account = [pscustomobject]@{
        Name     = $Name
        SignedIn = $login.SignedIn
        Email    = $login.Email
        Plan     = $login.Plan
        Login    = $login.Kind
        Current  = (Test-SamePath $Path (Get-CurrentAccountPath))
        Path     = $Path
    }
    $account.PSObject.TypeNames.Insert(0, 'AccountsForCodex.Account')
    $account
}

function Resolve-CodexAccount([string]$Name) {
    if (-not $Name) { throw 'Which account? Get-CodexAccount lists them.' }
    if ($Name -eq $script:DefaultName) { return New-AccountObject $script:DefaultName (Get-DefaultCodexHome) }
    Test-AccountName $Name
    $path = Join-Path (Get-AccountsRoot) $Name
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        throw "There is no Codex account named '$Name'. Create it with: New-CodexAccount $Name"
    }
    New-AccountObject $Name $path
}

function Get-CodexCommand {
    if ($env:CODEX_ACCOUNTS_CODEX) { return $env:CODEX_ACCOUNTS_CODEX }
    $found = Get-Command codex -CommandType Application, ExternalScript -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $found) { throw 'The Codex CLI was not found on your PATH. Install it first (for example: npm install -g @openai/codex).' }
    $found.Source
}

function Restore-DoubleDash([object[]]$Arguments, $Invocation) {
    # PowerShell removes the first bare "--" when it calls a function, but Codex needs it
    # ("codex mcp add docs -- npx ..."). Look at how the command was typed and put it back in the same place.
    # When that can't be worked out (the command spans lines, or an argument is spliced in with @), nothing is
    # changed; quoting it as '--' always gets it through.
    try {
        $line = $Invocation.Line
        if (-not $line -or $line.IndexOf('--') -lt 0) { return $Arguments }
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($line, [ref]$tokens, [ref]$errors)
        $column = $Invocation.OffsetInLine
        $command = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.CommandAst] -and
                $node.Extent.StartLineNumber -eq 1 -and $node.Extent.StartColumnNumber -eq $column }, $true)
        if (-not $command) { return $Arguments }
        $elements = @($command.CommandElements)
        for ($i = 2; $i -lt $elements.Count; $i++) {              # 0 is codex-as itself, 1 is the account
            $element = $elements[$i]
            if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                if ($element.Extent.Text -eq '--') {
                    $index = $i - 2
                    if ($index -gt $Arguments.Count) { return $Arguments }
                    $restored = New-Object System.Collections.Generic.List[object]
                    for ($k = 0; $k -lt $Arguments.Count; $k++) {
                        if ($k -eq $index) { $restored.Add('--') }
                        $restored.Add($Arguments[$k])
                    }
                    if ($index -eq $Arguments.Count) { $restored.Add('--') }
                    return $restored.ToArray()
                }
                if ($element.Argument) { return $Arguments }      # -name:value may arrive as two arguments
            }
            elseif ($element -is [System.Management.Automation.Language.VariableExpressionAst]) {
                if ($element.Splatted) { return $Arguments }      # @list can be any number of arguments
            }
            elseif ($element -isnot [System.Management.Automation.Language.StringConstantExpressionAst] -and
                $element -isnot [System.Management.Automation.Language.ExpandableStringExpressionAst] -and
                $element -isnot [System.Management.Automation.Language.ConstantExpressionAst]) { return $Arguments }
        }
    }
    catch { }
    $Arguments
}

function Get-CodexAccount {
    <#
    .SYNOPSIS
    Lists your Codex accounts and who is signed in to each.
    .DESCRIPTION
    Shows your normal Codex folder as "default" and every account under ~/.codex-accounts. The e-mail and plan come
    from each folder's own auth.json and are only shown on your screen. With credentials kept in the operating
    system's credential store instead of auth.json, SignedIn shows False even when you are signed in; run
    "codex-as <name> login status" to ask Codex itself.
    .EXAMPLE
    Get-CodexAccount
    .EXAMPLE
    Get-CodexAccount -Current
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$Name,
        [switch]$Current
    )
    if ($Name) { return Resolve-CodexAccount $Name }
    $all = @(New-AccountObject $script:DefaultName (Get-DefaultCodexHome))
    $root = Get-AccountsRoot
    if (Test-Path -LiteralPath $root -PathType Container) {
        foreach ($dir in Get-ChildItem -LiteralPath $root -Directory | Sort-Object Name) {
            if ($dir.Name -match $script:NamePattern -and $dir.Name -ne $script:DefaultName) {
                $all += New-AccountObject $dir.Name $dir.FullName
            }
        }
    }
    if ($Current) { return $all | Where-Object { $_.Current } }
    $all
}

function New-CodexAccount {
    <#
    .SYNOPSIS
    Creates an empty Codex account folder. Sign in to it the first time you use it.
    .DESCRIPTION
    Creates ~/.codex-accounts/<name>. Nothing is signed in yet: run "codex-as <name>" and Codex asks you to sign in,
    once. -CopyConfigFrom copies config.toml (your settings and MCP servers) from another account. The login
    (auth.json) is never copied, because that would put the same account in both folders.
    .EXAMPLE
    New-CodexAccount work
    .EXAMPLE
    New-CodexAccount client -CopyConfigFrom default
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Name,
        [string]$CopyConfigFrom
    )
    Test-AccountName $Name
    $path = Join-Path (Get-AccountsRoot) $Name
    if (Test-Path -LiteralPath $path) { throw "A Codex account named '$Name' already exists at $path" }
    $source = $null
    if ($CopyConfigFrom) {
        $source = Join-Path (Resolve-CodexAccount $CopyConfigFrom).Path 'config.toml'
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "The account '$CopyConfigFrom' has no config.toml to copy." }
    }
    if (-not $PSCmdlet.ShouldProcess($path, 'Create Codex account folder')) { return }
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    if ($source) { Copy-Item -LiteralPath $source -Destination (Join-Path $path 'config.toml') }
    New-AccountObject $Name $path
}

function Remove-CodexAccount {
    <#
    .SYNOPSIS
    Deletes an account folder: its login, settings and Codex history. Asks first.
    .DESCRIPTION
    Removes ~/.codex-accounts/<name> and that account's Windows Terminal profile, if it has one. Your normal Codex
    folder ("default") can't be removed with this command.
    .EXAMPLE
    Remove-CodexAccount client
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param([Parameter(Mandatory = $true, Position = 0)][string]$Name)
    if ($Name -eq $script:DefaultName) { throw "'default' is your normal Codex folder. This command doesn't remove it." }
    $account = Resolve-CodexAccount $Name
    if ($script:Entered -and $script:Entered.Name -eq $account.Name) { throw "This window is using '$Name'. Run Exit-CodexAccount first." }
    if (-not $PSCmdlet.ShouldProcess($account.Path, 'Delete this Codex account folder, with its login, settings and history')) { return }
    Remove-Item -LiteralPath $account.Path -Recurse -Force
    $fragment = Get-TerminalFragmentPath $Name
    if ($fragment -and (Test-Path -LiteralPath $fragment)) { Remove-Item -LiteralPath $fragment -Force }
}

function Invoke-CodexAs {
    <#
    .SYNOPSIS
    Runs Codex once as the given account. Everything after the name goes to Codex unchanged.
    .DESCRIPTION
    Sets CODEX_HOME for this one run and puts it back afterwards, so the rest of the window is unaffected.
    The alias is codex-as. "default" runs your normal Codex folder. A "--" separator reaches Codex too
    (PowerShell would normally swallow it); if one ever goes missing, quote it: '--'.
    .EXAMPLE
    codex-as work
    .EXAMPLE
    codex-as personal exec "summarize this repo" -m gpt-5
    .EXAMPLE
    codex-as work login status
    .EXAMPLE
    codex-as work mcp add docs -- npx -y some-mcp-server
    #>
    # A plain function on purpose: with no [CmdletBinding()], Codex's own options (-m, -c, --model ...) are passed
    # through untouched. The parameter starts with an underscore so that no Codex option can be mistaken for it.
    param([string]$_Account)
    if (-not $_Account) { throw 'Usage: codex-as <account> [codex arguments]. Get-CodexAccount lists your accounts.' }
    $account = Resolve-CodexAccount $_Account
    $codex = Get-CodexCommand
    $rest = @(Restore-DoubleDash $args $MyInvocation)
    $previous = $env:CODEX_HOME
    try {
        if ($account.Name -eq $script:DefaultName -and -not $env:CODEX_ACCOUNTS_DEFAULT) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue }
        else { $env:CODEX_HOME = $account.Path }
        & $codex @rest
    }
    finally {
        if ($null -eq $previous) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue }
        else { $env:CODEX_HOME = $previous }
    }
}

function Enter-CodexAccount {
    <#
    .SYNOPSIS
    Makes this window use one account until you close it or run Exit-CodexAccount.
    .DESCRIPTION
    Sets CODEX_HOME for this PowerShell window only, so plain "codex" and anything else you start from it use that
    account. Other windows are not affected, and nothing is saved for later sessions.
    .EXAMPLE
    Enter-CodexAccount work
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true, Position = 0)][string]$Name)
    $account = Resolve-CodexAccount $Name
    if (-not $script:Entered) {
        $title = $null
        try { $title = $Host.UI.RawUI.WindowTitle } catch { $title = $null }
        $script:Entered = @{ Name = $account.Name; PreviousHome = $env:CODEX_HOME; PreviousTitle = $title }
    }
    else { $script:Entered.Name = $account.Name }
    if ($account.Name -eq $script:DefaultName -and -not $env:CODEX_ACCOUNTS_DEFAULT) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue }
    else { $env:CODEX_HOME = $account.Path }
    try { $Host.UI.RawUI.WindowTitle = "Codex: $($account.Name)" } catch { }
    $who = if ($account.Email) { " ($($account.Email))" } elseif (-not $account.SignedIn) { ' (not signed in yet: run codex and sign in once)' } else { '' }
    Write-Host "This window now uses the Codex account '$($account.Name)'$who. Exit-CodexAccount puts it back."
}

function Exit-CodexAccount {
    <#
    .SYNOPSIS
    Puts this window back to the account it used before Enter-CodexAccount.
    #>
    [CmdletBinding()]
    param()
    if (-not $script:Entered) { return }
    if ($null -eq $script:Entered.PreviousHome) { Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue }
    else { $env:CODEX_HOME = $script:Entered.PreviousHome }
    if ($script:Entered.PreviousTitle) { try { $Host.UI.RawUI.WindowTitle = $script:Entered.PreviousTitle } catch { } }
    $script:Entered = $null
}

function Get-TerminalFragmentFolder {
    # Windows Terminal reads extra profiles from "fragment" files in this folder.
    if ($env:CODEX_ACCOUNTS_WT_FRAGMENTS) { return $env:CODEX_ACCOUNTS_WT_FRAGMENTS }   # for the tests
    if (-not $script:OnWindows -or -not $env:LOCALAPPDATA) { return $null }
    Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\AccountsForCodex'
}

function Get-TerminalFragmentPath([string]$Name) {
    $folder = Get-TerminalFragmentFolder
    if (-not $folder) { return $null }
    Join-Path $folder "$Name.json"
}

function Add-CodexTerminalProfile {
    <#
    .SYNOPSIS
    Adds a Windows Terminal profile for an account, with its own tab title and color.
    .DESCRIPTION
    Writes one small file that Windows Terminal reads on its next start. The new profile, "Codex: <name>", opens
    PowerShell with CODEX_HOME already set, so every tab you open from it is that account. Your Terminal settings
    file is not edited. Remove-CodexTerminalProfile deletes the file again.
    .EXAMPLE
    Add-CodexTerminalProfile work
    .EXAMPLE
    Add-CodexTerminalProfile personal -TabColor '#1A7F37' -Shell pwsh
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Name,
        [ValidatePattern('^#[0-9A-Fa-f]{6}$')][string]$TabColor,
        [ValidateSet('powershell', 'pwsh')][string]$Shell = 'powershell'
    )
    $file = Get-TerminalFragmentPath $Name
    if (-not $file) { throw 'Windows Terminal profiles exist on Windows only.' }
    $account = Resolve-CodexAccount $Name
    if (-not $TabColor) {
        $names = @(Get-CodexAccount | ForEach-Object { $_.Name })
        $TabColor = $script:TabColors[[Math]::Max(0, [Array]::IndexOf($names, $account.Name)) % $script:TabColors.Count]
    }
    $title = "Codex: $($account.Name)"
    $setHome = if ($account.Name -eq $script:DefaultName) { 'Remove-Item Env:CODEX_HOME -ErrorAction SilentlyContinue' }
               else { "`$env:CODEX_HOME = '$($account.Path.Replace("'", "''"))'" }
    $fragment = [ordered]@{
        profiles = @(
            [ordered]@{
                name                     = $title
                commandline              = "$Shell.exe -NoExit -Command `"$setHome`""
                tabTitle                 = $title
                suppressApplicationTitle = $true
                tabColor                 = $TabColor
                startingDirectory        = '%USERPROFILE%'
            }
        )
    }
    if (-not $PSCmdlet.ShouldProcess($file, "Write the Windows Terminal profile '$title'")) { return }
    New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force | Out-Null
    # UTF-8 without a byte order mark: Windows Terminal can't read PowerShell's default UTF-16.
    [IO.File]::WriteAllText($file, ($fragment | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding $false))
    Write-Host "Added the Windows Terminal profile '$title'. Restart Windows Terminal to see it in the new-tab menu."
}

function Remove-CodexTerminalProfile {
    <#
    .SYNOPSIS
    Removes the Windows Terminal profile that Add-CodexTerminalProfile made for an account.
    .EXAMPLE
    Remove-CodexTerminalProfile work
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true, Position = 0)][string]$Name)
    $file = Get-TerminalFragmentPath $Name
    if (-not $file) { throw 'Windows Terminal profiles exist on Windows only.' }
    if ((Test-Path -LiteralPath $file) -and $PSCmdlet.ShouldProcess($file, 'Remove the Windows Terminal profile')) {
        Remove-Item -LiteralPath $file -Force
    }
}

# Tab completion of account names.
$completeAccount = {
    param($commandName, $parameterName, $wordToComplete)
    try {
        Get-CodexAccount | Where-Object { $_.Name -like "$wordToComplete*" } | ForEach-Object {
            $tip = if ($_.Email) { $_.Email } else { $_.Path }
            New-Object System.Management.Automation.CompletionResult $_.Name, $_.Name, 'ParameterValue', $tip
        }
    }
    catch { }
}
Register-ArgumentCompleter -CommandName Get-CodexAccount, Enter-CodexAccount, Remove-CodexAccount, Add-CodexTerminalProfile, Remove-CodexTerminalProfile -ParameterName Name -ScriptBlock $completeAccount
Register-ArgumentCompleter -CommandName New-CodexAccount -ParameterName CopyConfigFrom -ScriptBlock $completeAccount
Register-ArgumentCompleter -CommandName Invoke-CodexAs, codex-as -ParameterName _Account -ScriptBlock $completeAccount

Update-TypeData -TypeName 'AccountsForCodex.Account' -DefaultDisplayPropertySet Name, SignedIn, Email, Plan, Current -Force

Set-Alias -Name codex-as -Value Invoke-CodexAs
Export-ModuleMember -Function Get-CodexAccount, New-CodexAccount, Remove-CodexAccount, Invoke-CodexAs, Enter-CodexAccount, Exit-CodexAccount, Add-CodexTerminalProfile, Remove-CodexTerminalProfile -Alias codex-as
