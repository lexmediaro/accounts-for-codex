# Stands in for the Codex CLI in the tests: records the CODEX_HOME it was started with and the arguments it got.
# "--exit N" as the last two arguments makes it exit with code N.
$record = [ordered]@{
    home = $env:CODEX_HOME
    args = @($args | ForEach-Object { [string]$_ })
}
($record | ConvertTo-Json -Compress) | Add-Content -LiteralPath $env:STUB_CODEX_LOG -Encoding UTF8
$code = 0
if ($args.Count -ge 2 -and $args[$args.Count - 2] -eq '--exit') { $code = [int]$args[$args.Count - 1] }
exit $code
