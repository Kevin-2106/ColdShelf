#requires -Version 7.4

[CmdletBinding()]
param(
    [string]$RepositoryRoot = (Split-Path -Parent $PSScriptRoot)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Passed = 0
$script:Failed = 0
$script:Failures = [Collections.Generic.List[string]]::new()
$repo = [IO.Path]::GetFullPath($RepositoryRoot)
$installScript = Join-Path $repo 'install.ps1'
$uninstallScript = Join-Path $repo 'uninstall.ps1'
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
$cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char[]]@('\', '/'))
$testRoot = Join-Path $tempBase ('ColdShelf-install-tests-' + [guid]::NewGuid().ToString('N'))
$registryParent = 'Software\ColdShelf\Tests\' + [guid]::NewGuid().ToString('N')
$registrySubKey = $registryParent + '\Environment'
$installRoot = Join-Path $testRoot 'Programs with spaces\ColdShelf 中文'
$stateRoot = Join-Path $testRoot 'state data preserved'
$archiveRoot = Join-Path $testRoot 'archive data preserved'

function Invoke-TestCase {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Body)
    try {
        & $Body
        $script:Passed++
        Write-Host "[PASS] $Name"
    }
    catch {
        $script:Failed++
        $script:Failures.Add("${Name}: $($_.Exception.Message)")
        Write-Host "[FAIL] $Name"
        Write-Host $_.Exception.Message
    }
}

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Actual, $Expected, [Parameter(Mandatory)][string]$Message)
    if ($Actual -ne $Expected) { throw "$Message (expected: $Expected; actual: $Actual)" }
}

function Assert-Matches {
    param([AllowEmptyString()][string]$Actual, [Parameter(Mandatory)][string]$Pattern, [Parameter(Mandatory)][string]$Message)
    if ($Actual -notmatch $Pattern) { throw "$Message (pattern: $Pattern; actual: $Actual)" }
}

function Invoke-Process {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [hashtable]$Environment = @{},
        [string]$WorkingDirectory = $testRoot,
        [int]$TimeoutSeconds = 60
    )

    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = $WorkingDirectory
    foreach ($argument in $Arguments) { [void]$psi.ArgumentList.Add($argument) }
    foreach ($key in $Environment.Keys) { $psi.Environment[[string]$key] = [string]$Environment[$key] }

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    if (-not $process.Start()) { throw "Could not start: $FilePath" }
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $finished = $process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $finished) {
        try { $process.Kill($true) } catch { }
        $process.WaitForExit()
    }
    $result = [pscustomobject]@{
        ExitCode = if ($finished) { $process.ExitCode } else { -1 }
        TimedOut = -not $finished
        StdOut = $stdout.GetAwaiter().GetResult()
        StdErr = $stderr.GetAwaiter().GetResult()
    }
    $process.Dispose()
    return $result
}

function Assert-Succeeded {
    param([Parameter(Mandatory)]$Result, [Parameter(Mandatory)][string]$Message)
    if ($Result.TimedOut -or $Result.ExitCode -ne 0) {
        throw "$Message`nexit=$($Result.ExitCode)`nstdout:`n$($Result.StdOut)`nstderr:`n$($Result.StdErr)"
    }
}

function Invoke-Installer {
    param([string]$Root = $script:installRoot)
    Invoke-Process -FilePath $pwsh -Arguments @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $installScript,
        '-InstallRoot', $Root,
        '-UserEnvironmentSubKey', $registrySubKey,
        '-NoBroadcast'
    )
}

function Invoke-Uninstaller {
    param(
        [string]$ScriptPath = (Join-Path $script:installRoot 'uninstall.ps1'),
        [string]$Root = $script:installRoot
    )
    Invoke-Process -FilePath $pwsh -Arguments @(
        '-NoLogo', '-NoProfile', '-NonInteractive', '-File', $ScriptPath,
        '-InstallRoot', $Root,
        '-NoBroadcast'
    )
}

function Open-TestRegistryKey {
    return [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($registrySubKey, $true)
}

function Get-TestPathState {
    $key = Open-TestRegistryKey
    try {
        $exists = @($key.GetValueNames()) -contains 'Path'
        return [pscustomobject]@{
            Exists = $exists
            Value = if ($exists) { [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } else { '' }
            Kind = if ($exists) { $key.GetValueKind('Path').ToString() } else { $null }
        }
    }
    finally { $key.Dispose() }
}

function Set-TestPath {
    param([Parameter(Mandatory)][string]$Value, [Microsoft.Win32.RegistryValueKind]$Kind = [Microsoft.Win32.RegistryValueKind]::ExpandString)
    $key = Open-TestRegistryKey
    try { $key.SetValue('Path', $Value, $Kind) }
    finally { $key.Dispose() }
}

function Wait-PathAbsent {
    param([Parameter(Mandatory)][string]$Path, [int]$Seconds = 15)
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ((Test-Path -LiteralPath $Path) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    return -not (Test-Path -LiteralPath $Path)
}

[IO.Directory]::CreateDirectory($testRoot) | Out-Null
[IO.Directory]::CreateDirectory($stateRoot) | Out-Null
[IO.Directory]::CreateDirectory($archiveRoot) | Out-Null
[IO.File]::WriteAllText((Join-Path $stateRoot 'keep.txt'), 'state must survive', [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $archiveRoot 'keep.txt'), 'archive must survive', [Text.UTF8Encoding]::new($false))

$segments = for ($index = 0; $index -lt 180; $index++) { "C:\Synthetic\Path-$index-$('x' * 12)" }
$originalPath = ($segments -join ';') + ';%USERPROFILE%\bin;C:\尾部路径'
Set-TestPath -Value $originalPath -Kind ([Microsoft.Win32.RegistryValueKind]::ExpandString)

try {
    Invoke-TestCase 'installer refuses a non-empty unowned directory before copying files' {
        $unsafeRoot = Join-Path $testRoot 'pre-existing user directory'
        [IO.Directory]::CreateDirectory($unsafeRoot) | Out-Null
        $sentinel = Join-Path $unsafeRoot 'user-data.txt'
        [IO.File]::WriteAllText($sentinel, 'must survive', [Text.UTF8Encoding]::new($false))
        $beforePath = Get-TestPathState
        $result = Invoke-Installer -Root $unsafeRoot
        Assert-True -Condition ($result.ExitCode -ne 0) -Message 'installer accepted a non-empty unowned directory'
        Assert-Equal -Actual (Get-Content -LiteralPath $sentinel -Raw) -Expected 'must survive' -Message 'installer changed pre-existing user data'
        Assert-True -Condition (-not (Test-Path -LiteralPath (Join-Path $unsafeRoot 'install-state.json'))) -Message 'installer wrote ownership state into an unowned directory'
        Assert-Equal -Actual (Get-TestPathState).Value -Expected $beforePath.Value -Message 'rejected install changed PATH'
    }

    Invoke-TestCase 'installer refuses forged legacy ownership state before copying files' {
        $unsafeRoot = Join-Path $testRoot 'forged legacy installation'
        [IO.Directory]::CreateDirectory($unsafeRoot) | Out-Null
        foreach ($name in @('coldshelf.ps1', 'coldshelf.cmd', 'uninstall.ps1')) {
            [IO.File]::WriteAllText((Join-Path $unsafeRoot $name), "sentinel-$name", [Text.UTF8Encoding]::new($false))
        }
        $forgedState = [ordered]@{
            version = 1
            installRoot = $unsafeRoot
            registrySubKey = $registrySubKey
            pathOwned = $true
            pathBefore = 'before'
            pathBeforeExisted = $true
            pathBeforeKind = 'String'
            pathAfter = 'after'
            pathBeforeSha256 = '0' * 64
            pathAfterSha256 = '0' * 64
            installedAt = [DateTimeOffset]::Now.ToString('o')
        }
        [IO.File]::WriteAllText((Join-Path $unsafeRoot 'install-state.json'), ($forgedState | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        $beforePath = Get-TestPathState
        $result = Invoke-Installer -Root $unsafeRoot
        Assert-True -Condition ($result.ExitCode -ne 0) -Message 'installer accepted forged legacy ownership state'
        Assert-Equal -Actual (Get-Content -LiteralPath (Join-Path $unsafeRoot 'coldshelf.ps1') -Raw) -Expected 'sentinel-coldshelf.ps1' -Message 'installer copied files before rejecting forged legacy state'
        Assert-Equal -Actual (Get-TestPathState).Value -Expected $beforePath.Value -Message 'forged legacy install changed PATH'
    }

    Invoke-TestCase 'installer preserves a long PATH and installs Unicode paths' {
        $result = Invoke-Installer
        Assert-Succeeded -Result $result -Message 'installer failed'
        foreach ($name in @('coldshelf.ps1', 'coldshelf.cmd', 'uninstall.ps1', 'install-state.json')) {
            Assert-True -Condition (Test-Path -LiteralPath (Join-Path $installRoot $name) -PathType Leaf) -Message "installed file is missing: $name"
        }
        $path = Get-TestPathState
        Assert-Equal -Actual $path.Kind -Expected 'ExpandString' -Message 'installer changed the registry value kind'
        Assert-True -Condition $path.Value.StartsWith($originalPath, [StringComparison]::Ordinal) -Message 'installer rewrote or truncated the original PATH prefix'
        Assert-Equal -Actual $path.Value -Expected ($originalPath + ';' + [IO.Path]::GetFullPath($installRoot).TrimEnd([char[]]@('\', '/'))) -Message 'installer did not append exactly one path entry'
    }

    Invoke-TestCase 'reinstall is idempotent' {
        $before = Get-TestPathState
        $result = Invoke-Installer
        Assert-Succeeded -Result $result -Message 'reinstall failed'
        $after = Get-TestPathState
        Assert-Equal -Actual $after.Value -Expected $before.Value -Message 'reinstall changed PATH or appended a duplicate'
    }

    Invoke-TestCase 'uninstaller refuses tampered state before changing PATH or files' {
        $statePath = Join-Path $installRoot 'install-state.json'
        $stateText = Get-Content -LiteralPath $statePath -Raw -Encoding utf8
        $state = $stateText | ConvertFrom-Json
        $state.pathAfterSha256 = '0' * 64
        [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
        $before = Get-TestPathState
        $result = Invoke-Uninstaller
        Assert-True -Condition ($result.ExitCode -ne 0) -Message 'uninstaller accepted tampered state'
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $installRoot 'coldshelf.ps1') -PathType Leaf) -Message 'uninstaller deleted files before rejecting tampered state'
        Assert-Equal -Actual (Get-TestPathState).Value -Expected $before.Value -Message 'tampered-state uninstall changed PATH'
        [IO.File]::WriteAllText($statePath, $stateText, [Text.UTF8Encoding]::new($false))
    }

    Invoke-TestCase 'uninstaller refuses unexpected files without changing PATH or data' {
        $unexpected = Join-Path $installRoot 'user-data.txt'
        [IO.File]::WriteAllText($unexpected, 'must survive', [Text.UTF8Encoding]::new($false))
        $before = Get-TestPathState
        $result = Invoke-Uninstaller
        Assert-True -Condition ($result.ExitCode -ne 0) -Message 'uninstaller accepted an installation root with unexpected files'
        Assert-Equal -Actual (Get-Content -LiteralPath $unexpected -Raw) -Expected 'must survive' -Message 'uninstaller changed unexpected user data'
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $installRoot 'coldshelf.ps1') -PathType Leaf) -Message 'uninstaller deleted managed files before rejecting unexpected content'
        Assert-Equal -Actual (Get-TestPathState).Value -Expected $before.Value -Message 'rejected uninstall changed PATH'
        [IO.File]::Delete($unexpected)
    }

    Invoke-TestCase 'PowerShell and cmd discover coldshelf from an unrelated directory' {
        $childPath = $installRoot + ';' + $env:PATH
        $environment = @{ PATH = $childPath; COLDSHELF_HOME = $stateRoot; NO_COLOR = '1' }
        $powerShell = Invoke-Process -FilePath $pwsh -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', 'Get-Command coldshelf -ErrorAction Stop | Out-Null; coldshelf --help') -Environment $environment
        Assert-Succeeded -Result $powerShell -Message 'PowerShell could not execute coldshelf directly'
        Assert-Matches -Actual ($powerShell.StdOut + $powerShell.StdErr) -Pattern '(?i)ColdShelf v1' -Message 'PowerShell help output is missing'

        $commandPrompt = Invoke-Process -FilePath $cmd -Arguments @('/d', '/c', 'coldshelf --help') -Environment $environment
        Assert-Succeeded -Result $commandPrompt -Message 'cmd could not execute coldshelf directly'
        Assert-Matches -Actual ($commandPrompt.StdOut + $commandPrompt.StdErr) -Pattern '(?i)ColdShelf v1' -Message 'cmd help output is missing'

        $unknown = Invoke-Process -FilePath $cmd -Arguments @('/d', '/c', 'coldshelf unknown-command') -Environment $environment
        Assert-Equal -Actual $unknown.ExitCode -Expected 2 -Message 'launcher did not preserve ColdShelf exit code'
    }

    Invoke-TestCase 'launcher forwards quoted special-character paths' {
        $childPath = $installRoot + ';' + $env:PATH
        $specialArchive = Join-Path $testRoot 'archive & data (中文)'
        $escapedArchive = $specialArchive.Replace("'", "''")
        $command = "coldshelf init '$escapedArchive'"
        $result = Invoke-Process -FilePath $pwsh -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-Command', $command) -Environment @{ PATH = $childPath; COLDSHELF_HOME = $stateRoot; NO_COLOR = '1' }
        Assert-Succeeded -Result $result -Message 'launcher did not forward a special-character archive path'
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $specialArchive 'archives') -PathType Container) -Message 'forwarded init path was not created correctly'
    }

    Invoke-TestCase 'uninstall preserves later PATH edits and user data' {
        $laterEntry = 'C:\Added\After\ColdShelf'
        $installedPath = Get-TestPathState
        Set-TestPath -Value ($installedPath.Value + ';' + $laterEntry) -Kind ([Microsoft.Win32.RegistryValueKind]::ExpandString)
        $result = Invoke-Uninstaller
        Assert-Succeeded -Result $result -Message 'uninstaller failed'
        Assert-True -Condition (Wait-PathAbsent -Path $installRoot) -Message 'installed directory was not removed after uninstall'
        $after = Get-TestPathState
        Assert-Equal -Actual $after.Value -Expected ($originalPath + ';' + $laterEntry) -Message 'uninstall lost later PATH edits or failed to remove owned entry'
        Assert-Equal -Actual $after.Kind -Expected 'ExpandString' -Message 'uninstall changed PATH value kind'
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $stateRoot 'keep.txt') -PathType Leaf) -Message 'uninstall removed ColdShelf state data'
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $archiveRoot 'keep.txt') -PathType Leaf) -Message 'uninstall removed archive data'
    }

    Invoke-TestCase 'uninstall is idempotent when install root is absent' {
        $result = Invoke-Uninstaller -ScriptPath $uninstallScript
        Assert-Succeeded -Result $result -Message 'second uninstall should succeed'
        Assert-Matches -Actual ($result.StdOut + $result.StdErr) -Pattern '(?i)already uninstalled' -Message 'second uninstall did not report idempotent state'
    }

    Invoke-TestCase 'pre-existing equivalent PATH entry is not owned or removed' {
        $equivalentRoot = Join-Path $testRoot 'Equivalent Install'
        $script:installRoot = $equivalentRoot
        Set-TestPath -Value ($originalPath + ';' + $equivalentRoot.ToUpperInvariant() + '\') -Kind ([Microsoft.Win32.RegistryValueKind]::String)
        $result = Invoke-Installer
        Assert-Succeeded -Result $result -Message 'installer failed with an equivalent pre-existing PATH entry'
        $installed = Get-TestPathState
        Assert-Equal -Actual $installed.Value -Expected ($originalPath + ';' + $equivalentRoot.ToUpperInvariant() + '\') -Message 'installer duplicated an equivalent PATH entry'
        $state = Get-Content -LiteralPath (Join-Path $equivalentRoot 'install-state.json') -Raw | ConvertFrom-Json
        Assert-True -Condition (-not [bool]$state.pathOwned) -Message 'installer claimed ownership of a pre-existing PATH entry'
        $remove = Invoke-Uninstaller
        Assert-Succeeded -Result $remove -Message 'uninstall failed for non-owned PATH entry'
        Assert-True -Condition (Wait-PathAbsent -Path $equivalentRoot) -Message 'non-owned installation directory was not removed'
        $after = Get-TestPathState
        Assert-Equal -Actual $after.Value -Expected ($originalPath + ';' + $equivalentRoot.ToUpperInvariant() + '\') -Message 'uninstall removed a pre-existing PATH entry'
    }
}
finally {
    try {
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($registryParent, $false)
    }
    catch { }
    if (Test-Path -LiteralPath $testRoot) {
        Get-ChildItem -LiteralPath $testRoot -Force -Recurse -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Attributes = [IO.FileAttributes]::Normal } catch { } }
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host ('Result: {0} passed, {1} failed.' -f $script:Passed, $script:Failed)
if ($script:Failures.Count -gt 0) {
    foreach ($failure in $script:Failures) { Write-Host $failure }
    exit 1
}
exit 0
