#requires -Version 7.4

[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Programs\ColdShelf'),
    [string]$UserEnvironmentSubKey = 'Environment',
    [switch]$NoBroadcast
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NormalizedPath {
    param([Parameter(Mandatory)][string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if (-not [string]::Equals($full, $root, [StringComparison]::OrdinalIgnoreCase)) {
        $full = $full.TrimEnd([char[]]@('\', '/'))
    }
    return $full
}

function Test-EquivalentPathEntry {
    param(
        [Parameter(Mandatory)][string]$Entry,
        [Parameter(Mandatory)][string]$ExpectedPath
    )

    $candidate = $Entry.Trim().Trim('"')
    if ([string]::IsNullOrWhiteSpace($candidate)) { return $false }
    try {
        $expanded = [Environment]::ExpandEnvironmentVariables($candidate)
        return [string]::Equals((Get-NormalizedPath $expanded), (Get-NormalizedPath $ExpectedPath), [StringComparison]::OrdinalIgnoreCase)
    }
    catch { return $false }
}

function Test-PathContainsEntry {
    param(
        [AllowNull()][string]$PathValue,
        [Parameter(Mandatory)][string]$ExpectedPath
    )

    foreach ($entry in @(([string]$PathValue).Split(';'))) {
        if (Test-EquivalentPathEntry -Entry $entry -ExpectedPath $ExpectedPath) { return $true }
    }
    return $false
}

function Get-StringHash {
    param([AllowNull()][string]$Value)

    $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Value)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-RequiredStateProperty {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Name
    )

    if ($State.PSObject.Properties.Name -notcontains $Name) {
        throw "Existing installation state is missing required property: $Name"
    }
    return $State.$Name
}

function Assert-StateStringHash {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$ValueProperty,
        [Parameter(Mandatory)][string]$HashProperty
    )

    $value = [string](Get-RequiredStateProperty -State $State -Name $ValueProperty)
    $expected = [string](Get-RequiredStateProperty -State $State -Name $HashProperty)
    if ($expected -notmatch '^[0-9a-fA-F]{64}$' -or
        -not [string]::Equals((Get-StringHash $value), $expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Existing installation state failed its $ValueProperty integrity check."
    }
}

function Assert-ExistingInstallationState {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$InstallPath,
        [Parameter(Mandatory)][string]$RegistrySubKey,
        [Parameter(Mandatory)][string[]]$ManagedFiles
    )

    $version = [int](Get-RequiredStateProperty -State $State -Name 'version')
    if ($version -notin @(1, 2)) { throw 'Existing installation state has an unsupported version.' }
    $stateRoot = Get-NormalizedPath ([string](Get-RequiredStateProperty -State $State -Name 'installRoot'))
    if (-not [string]::Equals($stateRoot, $InstallPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Existing installation state does not own this InstallRoot.'
    }
    if (-not [string]::Equals([string](Get-RequiredStateProperty -State $State -Name 'registrySubKey'), $RegistrySubKey, [StringComparison]::Ordinal)) {
        throw 'Existing installation state belongs to a different registry location.'
    }
    foreach ($booleanProperty in @('pathOwned', 'pathBeforeExisted')) {
        if ((Get-RequiredStateProperty -State $State -Name $booleanProperty) -isnot [bool]) {
            throw "Existing installation state property must be Boolean: $booleanProperty"
        }
    }
    foreach ($property in @('pathBefore', 'pathBeforeKind', 'pathAfter', 'installedAt')) {
        [void](Get-RequiredStateProperty -State $State -Name $property)
    }
    $pathKind = [Microsoft.Win32.RegistryValueKind]::Unknown
    if (-not [Enum]::TryParse([Microsoft.Win32.RegistryValueKind], [string]$State.pathBeforeKind, $true, [ref]$pathKind) -or
        -not [Enum]::IsDefined([Microsoft.Win32.RegistryValueKind], $pathKind)) {
        throw 'Existing installation state has an invalid pathBeforeKind.'
    }
    $installedAt = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$State.installedAt, [ref]$installedAt)) {
        throw 'Existing installation state has an invalid installedAt timestamp.'
    }
    Assert-StateStringHash -State $State -ValueProperty 'pathBefore' -HashProperty 'pathBeforeSha256'
    Assert-StateStringHash -State $State -ValueProperty 'pathAfter' -HashProperty 'pathAfterSha256'

    if ($version -eq 2) {
        if (-not [string]::Equals([string](Get-RequiredStateProperty -State $State -Name 'product'), 'ColdShelf', [StringComparison]::Ordinal) -or
            -not [string]::Equals([string](Get-RequiredStateProperty -State $State -Name 'fileOwnership'), 'managed-files-v1', [StringComparison]::Ordinal)) {
            throw 'Existing installation state has an invalid ownership contract.'
        }
        $stateManagedFiles = @((Get-RequiredStateProperty -State $State -Name 'managedFiles') | ForEach-Object { [string]$_ })
        if ($stateManagedFiles.Count -ne $ManagedFiles.Count -or
            (@($stateManagedFiles | Sort-Object) -join '|') -cne (@($ManagedFiles | Sort-Object) -join '|')) {
            throw 'Existing installation state contains an invalid managed file set.'
        }
    }
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value
    )

    $parent = Split-Path -Path $Path -Parent
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $temp = Join-Path $parent ".$([IO.Path]::GetFileName($Path)).$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temp, (($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temp, $Path, $true)
    }
    finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
}

function Copy-FileAtomic {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    $parent = Split-Path -Path $Destination -Parent
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $temp = Join-Path $parent ".$([IO.Path]::GetFileName($Destination)).$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::Copy($Source, $temp, $true)
        [IO.File]::Move($temp, $Destination, $true)
    }
    finally {
        if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
    }
}

function Send-EnvironmentChanged {
    if ($NoBroadcast -or -not [string]::Equals($UserEnvironmentSubKey, 'Environment', [StringComparison]::OrdinalIgnoreCase)) { return }

    if (-not ('ColdShelf.NativeMethods' -as [type])) {
        Add-Type @'
using System;
using System.Runtime.InteropServices;
namespace ColdShelf {
    public static class NativeMethods {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        public static extern IntPtr SendMessageTimeout(
            IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
            uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
    }
}
'@
    }

    [UIntPtr]$result = [UIntPtr]::Zero
    [void][ColdShelf.NativeMethods]::SendMessageTimeout(
        [IntPtr]0xffff,
        0x001A,
        [UIntPtr]::Zero,
        'Environment',
        0x0002,
        5000,
        [ref]$result
    )
}

if ($PSVersionTable.PSVersion -lt [version]'7.4') {
    throw 'ColdShelf installation requires PowerShell 7.4 or newer.'
}
if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA) -and -not $PSBoundParameters.ContainsKey('InstallRoot')) {
    throw 'LOCALAPPDATA is unavailable. Pass -InstallRoot explicitly.'
}

$sourceRoot = Get-NormalizedPath $PSScriptRoot
$installPath = Get-NormalizedPath $InstallRoot
if ([string]::Equals($sourceRoot, $installPath, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'InstallRoot must differ from the source repository.'
}

$sources = [ordered]@{
    'coldshelf.ps1' = Join-Path $sourceRoot 'coldshelf.ps1'
    'coldshelf.cmd' = Join-Path $sourceRoot 'coldshelf.cmd'
    'uninstall.ps1' = Join-Path $sourceRoot 'uninstall.ps1'
}
foreach ($source in $sources.Values) {
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Required installation source is missing: $source" }
}
if ($null -eq (Get-Command pwsh.exe -ErrorAction SilentlyContinue)) {
    throw 'pwsh.exe is not available on PATH.'
}

$managedFiles = @('coldshelf.ps1', 'coldshelf.cmd', 'uninstall.ps1', 'install-state.json')
$statePath = Join-Path $installPath 'install-state.json'
$existingState = $null
if (Test-Path -LiteralPath $installPath) {
    if (-not (Test-Path -LiteralPath $installPath -PathType Container)) {
        throw "InstallRoot exists but is not a directory: $installPath"
    }
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        try { $existingState = Get-Content -LiteralPath $statePath -Raw -Encoding utf8 | ConvertFrom-Json }
        catch { throw "Existing installation state is unreadable: $statePath" }
        Assert-ExistingInstallationState -State $existingState -InstallPath $installPath -RegistrySubKey $UserEnvironmentSubKey -ManagedFiles $managedFiles
        $unexpected = @(Get-ChildItem -LiteralPath $installPath -Force | Where-Object { $_.Name -notin $managedFiles })
        if ($unexpected.Count -gt 0) {
            throw "InstallRoot contains files not owned by ColdShelf: $($unexpected[0].FullName)"
        }
        $invalidManagedEntry = @(Get-ChildItem -LiteralPath $installPath -Force | Where-Object {
            $_.Name -in $managedFiles -and ($_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
        } | Select-Object -First 1)
        if ($invalidManagedEntry.Count -gt 0) {
            throw "InstallRoot contains an invalid managed file entry: $($invalidManagedEntry[0].FullName)"
        }
    }
    else {
        $existingItems = @(Get-ChildItem -LiteralPath $installPath -Force)
        if ($existingItems.Count -gt 0) {
            throw 'InstallRoot is non-empty and has no valid ColdShelf ownership state.'
        }
    }
}

[IO.Directory]::CreateDirectory($installPath) | Out-Null
foreach ($name in $sources.Keys) {
    Copy-FileAtomic -Source $sources[$name] -Destination (Join-Path $installPath $name)
}

$key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($UserEnvironmentSubKey, $true)
if ($null -eq $key) { throw "Could not open HKCU\$UserEnvironmentSubKey for writing." }
try {
    $valueNames = @($key.GetValueNames())
    $pathExisted = $valueNames -contains 'Path'
    $rawPath = if ($pathExisted) { [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } else { '' }
    $pathKind = if ($pathExisted) { $key.GetValueKind('Path') } else { [Microsoft.Win32.RegistryValueKind]::ExpandString }

    $ownedFromPreviousInstall = $false
    $beforePath = $rawPath
    $beforePathExisted = $pathExisted
    $beforePathKind = $pathKind.ToString()
    if ($null -ne $existingState -and [bool]$existingState.pathOwned -and [string]::Equals([string]$existingState.installRoot, $installPath, [StringComparison]::OrdinalIgnoreCase)) {
        $ownedFromPreviousInstall = Test-PathContainsEntry -PathValue $rawPath -ExpectedPath $installPath
        if ($ownedFromPreviousInstall) {
            $beforePath = [string]$existingState.pathBefore
            $beforePathExisted = [bool]$existingState.pathBeforeExisted
            $beforePathKind = [string]$existingState.pathBeforeKind
        }
    }

    $alreadyPresent = Test-PathContainsEntry -PathValue $rawPath -ExpectedPath $installPath
    $pathOwned = $ownedFromPreviousInstall
    $newPath = $rawPath
    if (-not $alreadyPresent) {
        if ([string]::IsNullOrEmpty($rawPath)) {
            $newPath = $installPath
        }
        elseif ($rawPath.EndsWith(';', [StringComparison]::Ordinal)) {
            $newPath = $rawPath + $installPath
        }
        else {
            $newPath = $rawPath + ';' + $installPath
        }
        $pathOwned = $true
    }

    $state = [ordered]@{
        version = 2
        product = 'ColdShelf'
        fileOwnership = 'managed-files-v1'
        installRoot = $installPath
        managedFiles = $managedFiles
        registrySubKey = $UserEnvironmentSubKey
        pathOwned = $pathOwned
        pathBefore = $beforePath
        pathBeforeExisted = $beforePathExisted
        pathBeforeKind = $beforePathKind
        pathAfter = $newPath
        pathBeforeSha256 = Get-StringHash $beforePath
        pathAfterSha256 = Get-StringHash $newPath
        installedAt = [DateTimeOffset]::Now.ToString('o')
    }
    Write-JsonAtomic -Path $statePath -Value $state

    if (-not [string]::Equals($newPath, $rawPath, [StringComparison]::Ordinal)) {
        $key.SetValue('Path', $newPath, $pathKind)
    }
}
finally {
    $key.Dispose()
}

Send-EnvironmentChanged
Write-Host "ColdShelf installed to: $installPath"
if ($alreadyPresent) {
    Write-Host 'The installation directory was already present in the user PATH.'
}
else {
    Write-Host 'The installation directory was added to the user PATH.'
}
Write-Host 'Open a new terminal, then run: coldshelf --help'
Write-Host "Uninstall with: pwsh -NoProfile -File `"$(Join-Path $installPath 'uninstall.ps1')`""
