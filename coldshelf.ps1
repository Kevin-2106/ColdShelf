#requires -Version 7.4

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ExitCodes = @{
    Success   = 0
    General   = 1
    Usage     = 2
    NotFound  = 3
    Conflict  = 4
    Safety    = 5
    Tar       = 6
    Integrity = 7
    State     = 8
    Defender  = 9
    Degraded  = 10
}

function Stop-ColdShelf {
    param(
        [Parameter(Mandatory)] [int] $Code,
        [Parameter(Mandatory)] [string] $Message
    )

    $exception = [System.InvalidOperationException]::new($Message)
    $exception.Data['ColdShelfExitCode'] = $Code
    throw $exception
}

function Write-ColdShelfMessage {
    param([Parameter(Mandatory)] [string] $Message)
    Write-Host "[ColdShelf] $Message"
}

function Write-ColdShelfWarning {
    param([Parameter(Mandatory)] [string] $Message)
    Write-Warning "[ColdShelf] $Message"
}

function Get-ColdShelfHome {
    if (-not [string]::IsNullOrWhiteSpace($env:COLDSHELF_HOME)) {
        return [System.IO.Path]::GetFullPath($env:COLDSHELF_HOME)
    }

    if ([string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        Stop-ColdShelf -Code $script:ExitCodes.State -Message 'USERPROFILE is not available. Set COLDSHELF_HOME explicitly.'
    }

    return [System.IO.Path]::Combine($env:USERPROFILE, '.coldshelf')
}

function Get-ColdShelfPaths {
    $stateRoot = Get-ColdShelfHome
    return [pscustomobject]@{
        Home        = $stateRoot
        Config      = [System.IO.Path]::Combine($stateRoot, 'config.json')
        History         = [System.IO.Path]::Combine($stateRoot, 'history.json')
        DefenderSessions = [System.IO.Path]::Combine($stateRoot, 'defender-sessions')
        HistoryLock     = "Global\ColdShelf-History-$((Get-StableHash -Value $stateRoot).Substring(0, 16))"
    }
}

function Get-StableHash {
    param([Parameter(Mandatory)] [string] $Value)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $hash = [System.Security.Cryptography.SHA256]::HashData($bytes)
    return [System.Convert]::ToHexString($hash).ToLowerInvariant()
}

function Test-ObjectProperty {
    param(
        [AllowNull()] $Object,
        [Parameter(Mandatory)] [string] $Name
    )

    return $null -ne $Object -and $Object.PSObject.Properties.Name -contains $Name
}

function Get-ObjectPropertyValue {
    param(
        [AllowNull()] $Object,
        [Parameter(Mandatory)] [string] $Name,
        $Default = $null
    )

    if (Test-ObjectProperty -Object $Object -Name $Name) {
        return $Object.$Name
    }
    return $Default
}

function Get-NormalizedPath {
    param([Parameter(Mandatory)] [string] $Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        Stop-ColdShelf -Code $script:ExitCodes.Safety -Message 'A path cannot be empty.'
    }

    try {
        $providerPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
        $fullPath = [System.IO.Path]::GetFullPath($providerPath)
    }
    catch {
        Stop-ColdShelf -Code $script:ExitCodes.Safety -Message "Cannot resolve filesystem path '$Path': $($_.Exception.Message)"
    }

    $root = [System.IO.Path]::GetPathRoot($fullPath)
    if (-not [string]::Equals($fullPath, $root, [System.StringComparison]::OrdinalIgnoreCase)) {
        $fullPath = $fullPath.TrimEnd([char[]]@('\', '/'))
    }
    return $fullPath
}

function Test-PathEqual {
    param(
        [Parameter(Mandatory)] [string] $Left,
        [Parameter(Mandatory)] [string] $Right
    )

    return [string]::Equals(
        (Get-NormalizedPath -Path $Left),
        (Get-NormalizedPath -Path $Right),
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Test-PathWithin {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Parent,
        [switch] $AllowEqual
    )

    $normalizedPath = Get-NormalizedPath -Path $Path
    $normalizedParent = Get-NormalizedPath -Path $Parent

    if (Test-PathEqual -Left $normalizedPath -Right $normalizedParent) {
        return $AllowEqual.IsPresent
    }

    $prefix = $normalizedParent
    if (-not $prefix.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $prefix += [System.IO.Path]::DirectorySeparatorChar
    }

    return $normalizedPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-ColdShelfTestContext {
    param([int]$FailureCode = $script:ExitCodes.Safety)

    $testRootValue = [string]$env:COLDSHELF_TEST_ROOT
    $expectedToken = [string]$env:COLDSHELF_TEST_TOKEN
    if ([string]::IsNullOrWhiteSpace($testRootValue) -or [string]::IsNullOrWhiteSpace($expectedToken)) {
        Stop-ColdShelf -Code $FailureCode -Message 'Test-only behavior requires an authenticated temporary test workspace.'
    }

    $testRoot = Get-NormalizedPath -Path $testRootValue
    $tempRoot = Get-NormalizedPath -Path ([System.IO.Path]::GetTempPath())
    $stateRoot = Get-NormalizedPath -Path (Get-ColdShelfHome)
    $marker = Join-Path $testRoot '.coldshelf-test-owner'
    $actualToken = if (Test-Path -LiteralPath $marker -PathType Leaf) { Get-Content -LiteralPath $marker -Raw -Encoding utf8 } else { '' }
    if (-not (Test-PathWithin -Path $testRoot -Parent $tempRoot) -or
        -not (Split-Path -Path $testRoot -Leaf).StartsWith('ColdShelf-tests-', [System.StringComparison]::Ordinal) -or
        -not (Test-PathWithin -Path $stateRoot -Parent $testRoot) -or
        -not [string]::Equals($actualToken, $expectedToken, [System.StringComparison]::Ordinal)) {
        Stop-ColdShelf -Code $FailureCode -Message 'Test-only behavior is restricted to an authenticated temporary test workspace.'
    }
    if (-not (Test-Path -LiteralPath $testRoot -PathType Container) -or -not (Test-Path -LiteralPath $marker -PathType Leaf)) {
        Stop-ColdShelf -Code $FailureCode -Message 'Authenticated test workspace paths are missing.'
    }
    foreach ($itemPath in @($testRoot, $marker)) {
        $item = Get-Item -LiteralPath $itemPath -Force -ErrorAction Stop
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Stop-ColdShelf -Code $FailureCode -Message "Authenticated test workspace contains a reparse point: $itemPath"
        }
    }
    return $testRoot
}

function Resolve-ExistingDirectory {
    param([Parameter(Mandatory)] [string] $Path)

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
    catch {
        Stop-ColdShelf -Code $script:ExitCodes.NotFound -Message "Directory does not exist: $Path"
    }

    if (-not $item.PSIsContainer) {
        Stop-ColdShelf -Code $script:ExitCodes.Usage -Message "Path is not a directory: $Path"
    }

    return Get-NormalizedPath -Path $item.FullName
}

function Test-IsFileSystemRoot {
    param([Parameter(Mandatory)] [string] $Path)

    $normalized = Get-NormalizedPath -Path $Path
    $root = [System.IO.Path]::GetPathRoot($normalized)
    return [string]::Equals($normalized, $root, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoReparsePoints {
    param([Parameter(Mandatory)] [string] $Path)

    $rootItem = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Stop-ColdShelf -Code $script:ExitCodes.Safety -Message "Reparse points are not supported in v1: $($rootItem.FullName)"
    }

    foreach ($item in Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction Stop) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Stop-ColdShelf -Code $script:ExitCodes.Safety -Message "Reparse points are not supported in v1: $($item.FullName)"
        }
        if ($item.Name.Contains("`n") -or $item.Name.Contains("`r")) {
            Stop-ColdShelf -Code $script:ExitCodes.Safety -Message "File names containing newlines are not supported: $($item.FullName)"
        }
    }
}

function Assert-NoReparsePointAncestors {
    param([Parameter(Mandatory)] [string] $Path)

    $currentPath = Get-NormalizedPath -Path $Path
    if (-not (Test-Path -LiteralPath $currentPath)) {
        while (-not (Test-Path -LiteralPath $currentPath)) {
            $parentPath = Split-Path -Path $currentPath -Parent
            if ([string]::IsNullOrWhiteSpace($parentPath) -or [string]::Equals($parentPath, $currentPath, [System.StringComparison]::OrdinalIgnoreCase)) {
                Stop-ColdShelf -Code $script:ExitCodes.Safety -Message "Cannot find an existing ancestor for path: $Path"
            }
            $currentPath = $parentPath
        }
    }

    while ($true) {
        $item = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Stop-ColdShelf -Code $script:ExitCodes.Safety -Message "Path ancestor is a reparse point: $($item.FullName)"
        }
        $parentPath = Split-Path -Path $currentPath -Parent
        if ([string]::IsNullOrWhiteSpace($parentPath) -or [string]::Equals($parentPath, $currentPath, [System.StringComparison]::OrdinalIgnoreCase)) { break }
        $currentPath = $parentPath
    }
}

function Assert-SafeStateAndArchiveRoots {
    param(
        [Parameter(Mandatory)] [string] $StateRoot,
        [Parameter(Mandatory)] [string] $ArchiveRoot
    )

    $state = Get-NormalizedPath -Path $StateRoot
    $archive = Get-NormalizedPath -Path $ArchiveRoot
    if (Test-IsFileSystemRoot -Path $state) {
        Stop-ColdShelf -Code $script:ExitCodes.Safety -Message 'ColdShelf state must be below the filesystem root.'
    }
    if (Test-IsFileSystemRoot -Path $archive) {
        Stop-ColdShelf -Code $script:ExitCodes.Safety -Message 'archiveRoot must be below the filesystem root.'
    }

    foreach ($candidate in @($env:USERPROFILE, $env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $protected = Get-NormalizedPath -Path $candidate
        if (Test-PathEqual -Left $state -Right $protected) {
            Stop-ColdShelf -Code $script:ExitCodes.Safety -Message "ColdShelf state cannot be a protected root: $state"
        }
        if (Test-PathEqual -Left $archive -Right $protected) {
            Stop-ColdShelf -Code $script:ExitCodes.Safety -Message "archiveRoot cannot be a protected root: $archive"
        }
    }

    if ((Test-PathWithin -Path $archive -Parent $state -AllowEqual) -or (Test-PathWithin -Path $state -Parent $archive -AllowEqual)) {
        Stop-ColdShelf -Code $script:ExitCodes.Safety -Message 'archiveRoot and the ColdShelf state directory cannot contain each other.'
    }

    Assert-NoReparsePointAncestors -Path $state
    Assert-NoReparsePointAncestors -Path $archive
}

function Assert-SafeSourcePath {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $ArchiveRoot
    )

    $normalized = Get-NormalizedPath -Path $Path
    if (Test-IsFileSystemRoot -Path $normalized) {
        Stop-ColdShelf -Code $script:ExitCodes.Safety -Message "Refusing to use a filesystem root as a source: $normalized"
    }

    if (Test-PathWithin -Path $normalized -Parent $ArchiveRoot -AllowEqual) {
        Stop-ColdShelf -Code $script:ExitCodes.Safety -Message "Source path cannot be inside archiveRoot: $normalized"
    }
    if (Test-PathWithin -Path $ArchiveRoot -Parent $normalized -AllowEqual) {
        Stop-ColdShelf -Code $script:ExitCodes.Safety -Message "archiveRoot cannot be inside the source directory: $ArchiveRoot"
    }

    $stateRoot = Get-ColdShelfHome
    if ((Test-PathWithin -Path $normalized -Parent $stateRoot -AllowEqual) -or (Test-PathWithin -Path $stateRoot -Parent $normalized -AllowEqual)) {
        Stop-ColdShelf -Code $script:ExitCodes.Safety -Message 'Source path and the ColdShelf state directory cannot contain each other.'
    }

    $protected = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in @(
        $env:USERPROFILE,
        $env:SystemRoot,
        $env:ProgramFiles,
        ${env:ProgramFiles(x86)},
        $env:ProgramData,
        (Split-Path -Path $ArchiveRoot -Parent),
        $ArchiveRoot
    )) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $protected.Add((Get-NormalizedPath -Path $candidate))
        }
    }

    foreach ($candidate in $protected) {
        if (Test-PathEqual -Left $normalized -Right $candidate) {
            Stop-ColdShelf -Code $script:ExitCodes.Safety -Message "Refusing to operate on protected path: $normalized"
        }
    }

    Assert-NoReparsePointAncestors -Path $normalized
    Assert-NoReparsePoints -Path $normalized
}

function Assert-SafeRestoreTarget {
    param(
        [Parameter(Mandatory)] [string] $Target,
        [Parameter(Mandatory)] [string] $ExpectedName,
        [Parameter(Mandatory)] $Config
    )

    $normalized = Get-NormalizedPath -Path $Target
    if (Test-IsFileSystemRoot -Path $normalized) {
        Stop-ColdShelf -Code $script:ExitCodes.Safety -Message "Refusing to restore to a filesystem root: $normalized"
    }
    if (-not [string]::Equals((Split-Path -Path $normalized -Leaf), $ExpectedName, [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'Restore target leaf name does not match archive metadata name.'
    }
    if (Test-PathWithin -Path $normalized -Parent $Config.ArchiveRoot -AllowEqual) {
        Stop-ColdShelf -Code $script:ExitCodes.Safety -Message 'Restore target cannot be inside archiveRoot.'
    }
    $stateRoot = Get-ColdShelfHome
    if (Test-PathWithin -Path $normalized -Parent $stateRoot -AllowEqual) {
        Stop-ColdShelf -Code $script:ExitCodes.Safety -Message 'Restore target cannot be inside the ColdShelf state directory.'
    }

    foreach ($candidate in @($env:USERPROFILE, $env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-PathEqual -Left $normalized -Right $candidate)) {
            Stop-ColdShelf -Code $script:ExitCodes.Safety -Message "Refusing to restore to protected path: $normalized"
        }
    }

    $parent = Split-Path -Path $normalized -Parent
    if ([string]::IsNullOrWhiteSpace($parent)) {
        Stop-ColdShelf -Code $script:ExitCodes.Safety -Message "Invalid restore target: $normalized"
    }
    Assert-NoReparsePointAncestors -Path $parent
    return $normalized
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] $Value
    )

    $parent = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $tempName = ".$(Split-Path -Path $Path -Leaf).$([guid]::NewGuid().ToString('N')).tmp"
    $tempPath = Join-Path $parent $tempName
    $json = $Value | ConvertTo-Json -Depth 20
    $encoding = [System.Text.UTF8Encoding]::new($false)

    try {
        [System.IO.File]::WriteAllText($tempPath, $json + [Environment]::NewLine, $encoding)
        [System.IO.File]::Move($tempPath, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Read-JsonFile {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [int] $FailureCode = $script:ExitCodes.State
    )

    try {
        return Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Stop-ColdShelf -Code $FailureCode -Message "Cannot read JSON file '$Path': $($_.Exception.Message)"
    }
}

function Initialize-ColdShelf {
    param([Parameter(Mandatory)] [string] $ArchiveRoot)

    $paths = Get-ColdShelfPaths
    $root = Get-NormalizedPath -Path $ArchiveRoot
    Assert-SafeStateAndArchiveRoots -StateRoot $paths.Home -ArchiveRoot $root

    New-Item -ItemType Directory -Path $paths.Home -Force | Out-Null
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $archives = Join-Path $root 'archives'
    New-Item -ItemType Directory -Path $archives -Force | Out-Null
    Assert-NoReparsePointAncestors -Path $paths.Home
    Assert-NoReparsePointAncestors -Path $root
    Assert-NoReparsePointAncestors -Path $archives

    $config = [ordered]@{
        version     = 1
        archiveRoot = $root
    }
    Write-JsonAtomic -Path $paths.Config -Value $config
    $runtimeConfig = [pscustomobject]@{
        ArchiveRoot  = $root
        ArchivesRoot = $archives
        IndexPath    = Join-Path $root 'index.json'
    }
    Rebuild-ColdShelfIndex -Config $runtimeConfig | Out-Null

    Write-ColdShelfMessage "Initialized."
    Write-Host "Config:  $($paths.Config)"
    Write-Host "Archives: $root"
}

function Get-ColdShelfConfig {
    $paths = Get-ColdShelfPaths
    if (-not (Test-Path -LiteralPath $paths.Config -PathType Leaf)) {
        Stop-ColdShelf -Code $script:ExitCodes.State -Message "ColdShelf is not initialized. Run: coldshelf init `"E:\ColdShelf`""
    }

    $config = Read-JsonFile -Path $paths.Config
    if ([string]::IsNullOrWhiteSpace([string]$config.archiveRoot)) {
        Stop-ColdShelf -Code $script:ExitCodes.State -Message "Config is missing archiveRoot: $($paths.Config)"
    }

    $root = Get-NormalizedPath -Path ([string]$config.archiveRoot)
    Assert-SafeStateAndArchiveRoots -StateRoot $paths.Home -ArchiveRoot $root
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        Stop-ColdShelf -Code $script:ExitCodes.State -Message "archiveRoot does not exist: $root"
    }

    $archives = Join-Path $root 'archives'
    if (-not (Test-Path -LiteralPath $archives -PathType Container)) {
        Stop-ColdShelf -Code $script:ExitCodes.State -Message "archives directory does not exist: $archives"
    }
    Assert-NoReparsePointAncestors -Path $paths.Home
    Assert-NoReparsePointAncestors -Path $root
    Assert-NoReparsePointAncestors -Path $archives

    return [pscustomobject]@{
        Version      = [int](Get-ObjectPropertyValue -Object $config -Name 'version' -Default 1)
        ArchiveRoot  = $root
        ArchivesRoot = $archives
        IndexPath    = Join-Path $root 'index.json'
    }
}

function Get-ColdShelfTarPath {
    if (-not [string]::IsNullOrWhiteSpace($env:COLDSHELF_TAR_PATH)) {
        $testRoot = Assert-ColdShelfTestContext -FailureCode $script:ExitCodes.Tar
        $override = Get-NormalizedPath -Path $env:COLDSHELF_TAR_PATH
        if (-not (Test-PathWithin -Path $override -Parent $testRoot)) {
            Stop-ColdShelf -Code $script:ExitCodes.Tar -Message 'COLDSHELF_TAR_PATH must be inside the authenticated test workspace.'
        }
        if (-not (Test-Path -LiteralPath $override -PathType Leaf)) {
            Stop-ColdShelf -Code $script:ExitCodes.Tar -Message "Configured tar executable does not exist: $override"
        }
        if ([System.IO.Path]::GetExtension($override) -ne '.exe') {
            Stop-ColdShelf -Code $script:ExitCodes.Tar -Message 'COLDSHELF_TAR_PATH must point to an executable .exe file.'
        }
        $overrideItem = Get-Item -LiteralPath $override -Force -ErrorAction Stop
        if (($overrideItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Stop-ColdShelf -Code $script:ExitCodes.Tar -Message 'COLDSHELF_TAR_PATH cannot be a reparse point.'
        }
        return $override
    }

    $tarPath = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (-not (Test-Path -LiteralPath $tarPath -PathType Leaf)) {
        Stop-ColdShelf -Code $script:ExitCodes.Tar -Message "Windows tar.exe was not found: $tarPath"
    }
    return $tarPath
}

function Invoke-NativeProcess {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [string] $WorkingDirectory,
        [System.Text.Encoding] $StandardOutputEncoding,
        [int] $FailureCode = $script:ExitCodes.Tar
    )

    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $FilePath
    foreach ($argument in $Arguments) {
        $info.ArgumentList.Add($argument)
    }

    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $info.WorkingDirectory = $WorkingDirectory
    }
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    if ($null -ne $StandardOutputEncoding) {
        $info.StandardOutputEncoding = $StandardOutputEncoding
    }
    $info.CreateNoWindow = $true

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        if (-not $process.Start()) {
            Stop-ColdShelf -Code $FailureCode -Message "Could not start native process: $FilePath"
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut   = $stdoutTask.GetAwaiter().GetResult()
            StdErr   = $stderrTask.GetAwaiter().GetResult()
        }
    }
    catch {
        if ($_.Exception.Data.Contains('ColdShelfExitCode')) { throw }
        Stop-ColdShelf -Code $FailureCode -Message "Native process failed: $($_.Exception.Message)"
    }
    finally {
        $process.Dispose()
    }
}

function Get-DirectoryStats {
    param([Parameter(Mandatory)] [string] $Path)

    [long]$bytes = 0
    [long]$fileCount = 0
    [long]$directoryCount = 1

    try {
        foreach ($item in Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction Stop) {
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                Stop-ColdShelf -Code $script:ExitCodes.Safety -Message "Reparse points are not supported in v1: $($item.FullName)"
            }
            if ($item.Name.Contains("`n") -or $item.Name.Contains("`r")) {
                Stop-ColdShelf -Code $script:ExitCodes.Safety -Message "File names containing newlines are not supported: $($item.FullName)"
            }
            if ($item.PSIsContainer) {
                $directoryCount++
            }
            else {
                $fileCount++
                $bytes += [long]$item.Length
            }
        }
    }
    catch {
        if ($_.Exception.Data.Contains('ColdShelfExitCode')) { throw }
        Stop-ColdShelf -Code $script:ExitCodes.Safety -Message "Cannot enumerate source directory safely: $($_.Exception.Message)"
    }

    return [pscustomobject]@{
        Bytes          = $bytes
        FileCount      = $fileCount
        DirectoryCount = $directoryCount
    }
}

function Get-DirectoryManifest {
    param([Parameter(Mandatory)] [string] $Path)

    $root = Get-NormalizedPath -Path $Path
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($item in Get-ChildItem -LiteralPath $root -Force -Recurse -ErrorAction Stop | Sort-Object FullName) {
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Stop-ColdShelf -Code $script:ExitCodes.Safety -Message "Reparse points are not supported in v1: $($item.FullName)"
        }
        $relative = [System.IO.Path]::GetRelativePath($root, $item.FullName).Replace('\', '/')
        if ($item.PSIsContainer) {
            $entries.Add([pscustomobject][ordered]@{ path = $relative; type = 'directory'; length = 0; sha256 = $null })
        }
        else {
            $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
            $entries.Add([pscustomobject][ordered]@{ path = $relative; type = 'file'; length = [long]$item.Length; sha256 = $hash })
        }
    }
    return @($entries)
}

function Read-ManifestFile {
    param([Parameter(Mandatory)] [string] $Path)

    $document = Read-JsonFile -Path $Path -FailureCode $script:ExitCodes.Integrity
    if (-not (Test-ObjectProperty -Object $document -Name 'version') -or [int]$document.version -ne 1 -or -not (Test-ObjectProperty -Object $document -Name 'entries')) {
        Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message "Invalid manifest file: $Path"
    }
    return @($document.entries)
}

function Compare-ManifestEntries {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Expected,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Actual,
        [Parameter(Mandatory)] [string] $Context
    )

    $expectedJson = @($Expected | Sort-Object path, type | ForEach-Object {
        [ordered]@{ path = [string]$_.path; type = [string]$_.type; length = [long]$_.length; sha256 = [string](Get-ObjectPropertyValue -Object $_ -Name 'sha256' -Default '') }
    }) | ConvertTo-Json -Depth 5 -Compress
    $actualJson = @($Actual | Sort-Object path, type | ForEach-Object {
        [ordered]@{ path = [string]$_.path; type = [string]$_.type; length = [long]$_.length; sha256 = [string](Get-ObjectPropertyValue -Object $_ -Name 'sha256' -Default '') }
    }) | ConvertTo-Json -Depth 5 -Compress
    if (-not [string]::Equals($expectedJson, $actualJson, [System.StringComparison]::Ordinal)) {
        Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message "$Context content manifest does not match."
    }
}

function Get-TarContentManifest {
    param(
        [Parameter(Mandatory)] [string] $ArchivePath,
        [Parameter(Mandatory)] [string] $ExpectedRoot,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $NativeEntries
    )

    $stream = [System.IO.File]::Open($ArchivePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $reader = $null
    $entries = [System.Collections.Generic.List[object]]::new()
    $index = 0
    try {
        $reader = [System.Formats.Tar.TarReader]::new($stream, $false)
        while ($null -ne ($entry = $reader.GetNextEntry($false))) {
            if ($index -ge $NativeEntries.Count) {
                Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'Managed tar reader returned more entries than the native listing.'
            }

            $nativeName = [string]$NativeEntries[$index]
            $managedName = ([string]$entry.Name).Replace('\', '/')
            $namesAgree = [string]::Equals($managedName, $nativeName, [System.StringComparison]::Ordinal)
            if (-not $namesAgree) {
                $nativeBytes = [System.Text.Encoding]::UTF8.GetByteCount($nativeName)
                $managedBytes = [System.Text.Encoding]::UTF8.GetByteCount($managedName)
                $paxSuffix = $entry.Format -eq [System.Formats.Tar.TarEntryFormat]::Pax `
                    -and $nativeBytes -gt 100 `
                    -and $managedBytes -gt 0 `
                    -and $managedBytes -le 100 `
                    -and $nativeName.EndsWith($managedName, [System.StringComparison]::Ordinal)
                if ($paxSuffix -and $entry.PSObject.Properties.Name -contains 'ExtendedAttributes' -and $entry.ExtendedAttributes.ContainsKey('path')) {
                    $paxSuffix = [string]::Equals([string]$entry.ExtendedAttributes['path'], $nativeName, [System.StringComparison]::Ordinal)
                }
                if (-not $paxSuffix) {
                    Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message "Native and managed tar parsers disagree at entry $index."
                }
            }

            $nativeIsDirectory = $nativeName.EndsWith('/', [System.StringComparison]::Ordinal)
            $pathWithoutTrailingSlash = $nativeName.TrimEnd('/')
            $segments = @($pathWithoutTrailingSlash.Split('/', [System.StringSplitOptions]::None))
            if ($segments.Count -eq 0 -or -not [string]::Equals($segments[0], $ExpectedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'Tar content root does not match metadata.'
            }
            $isRoot = $segments.Count -eq 1
            $relative = ($segments | Select-Object -Skip 1) -join '/'

            switch ($entry.EntryType) {
                ([System.Formats.Tar.TarEntryType]::Directory) {
                    if (-not $nativeIsDirectory -or [long]$entry.Length -ne 0) {
                        Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message "Native and managed tar entry types disagree at entry $index."
                    }
                    if (-not $isRoot) {
                        $entries.Add([pscustomobject][ordered]@{ path = $relative; type = 'directory'; length = 0; sha256 = $null })
                    }
                }
                { $_ -in @([System.Formats.Tar.TarEntryType]::RegularFile, [System.Formats.Tar.TarEntryType]::V7RegularFile, [System.Formats.Tar.TarEntryType]::ContiguousFile) } {
                    if ($nativeIsDirectory -or $isRoot) {
                        Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message "Native and managed tar entry types disagree at entry $index."
                    }
                    if ([long]$entry.Length -gt 0 -and $null -eq $entry.DataStream) {
                        Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message "Tar file entry has no readable content stream: $nativeName"
                    }
                    $hash = if ($null -ne $entry.DataStream) { [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($entry.DataStream)).ToLowerInvariant() } else { [System.Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([byte[]]@())).ToLowerInvariant() }
                    $entries.Add([pscustomobject][ordered]@{ path = $relative; type = 'file'; length = [long]$entry.Length; sha256 = $hash })
                }
                default {
                    Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message "Unsupported tar entry type '$($entry.EntryType)' for '$nativeName'."
                }
            }
            $index++
        }
        if ($index -ne $NativeEntries.Count) {
            Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'Native tar listing and managed tar reader returned different entry counts.'
        }
    }
    catch {
        if ($_.Exception.Data.Contains('ColdShelfExitCode')) { throw }
        Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message "Cannot read tar content safely: $($_.Exception.Message)"
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        $stream.Dispose()
    }
    return @($entries)
}

function Format-ByteSize {
    param([Parameter(Mandatory)] [double] $Bytes)

    if ($Bytes -ge 1TB) { return ('{0:N1} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function Format-Speed {
    param([Parameter(Mandatory)] [double] $BytesPerSecond)
    return ('{0:N0} MB/s' -f ($BytesPerSecond / 1MB))
}

function Format-Duration {
    param([Parameter(Mandatory)] [double] $Seconds)

    $rounded = [Math]::Max(0, [Math]::Round($Seconds))
    $span = [TimeSpan]::FromSeconds($rounded)
    if ($span.TotalHours -ge 1) {
        return ('{0}h {1}m' -f [Math]::Floor($span.TotalHours), $span.Minutes)
    }
    if ($span.TotalMinutes -ge 1) {
        return ('{0}m {1}s' -f [Math]::Floor($span.TotalMinutes), $span.Seconds)
    }
    return ('{0}s' -f $span.Seconds)
}

function New-ColdShelfId {
    $random = [System.Security.Cryptography.RandomNumberGenerator]::GetBytes(3)
    $suffix = [System.Convert]::ToHexString($random).ToLowerInvariant()
    return "$(Get-Date -Format 'yyyyMMdd-HHmmss')-$suffix"
}

function Assert-ArchiveFreeSpace {
    param(
        [Parameter(Mandatory)] [string] $ArchiveRoot,
        [Parameter(Mandatory)] [long] $RequiredBytes
    )

    try {
        $root = [System.IO.Path]::GetPathRoot($ArchiveRoot)
        $drive = [System.IO.DriveInfo]::new($root)
        $margin = [Math]::Max(64MB, [long]($RequiredBytes * 0.05))
        if ($drive.AvailableFreeSpace -lt ($RequiredBytes + $margin)) {
            Stop-ColdShelf -Code $script:ExitCodes.State -Message "Not enough free space on $root. Required approximately $(Format-ByteSize ($RequiredBytes + $margin)); available $(Format-ByteSize $drive.AvailableFreeSpace)."
        }
    }
    catch {
        if ($_.Exception.Data.Contains('ColdShelfExitCode')) { throw }
        Write-ColdShelfWarning "Could not determine free space: $($_.Exception.Message)"
    }
}

function Get-ColdShelfArchives {
    param([Parameter(Mandatory)] $Config)

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($directory in Get-ChildItem -LiteralPath $Config.ArchivesRoot -Directory -Force -ErrorAction Stop) {
        if ($directory.Name.EndsWith('.tmp', [System.StringComparison]::OrdinalIgnoreCase) -or
            $directory.Name.StartsWith('.coldshelf-remove-archive-', [System.StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        $metaPath = Join-Path $directory.FullName 'meta.json'
        if (-not (Test-Path -LiteralPath $metaPath -PathType Leaf)) {
            continue
        }
        try {
            $meta = Get-Content -LiteralPath $metaPath -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace([string]$meta.id)) { continue }
            $results.Add([pscustomobject]@{
                Id               = [string]$meta.id
                Name             = [string]$meta.name
                SourcePath       = [string]$meta.sourcePath
                Status           = [string]$meta.status
                CreatedAt        = [string]$meta.createdAt
                OriginalSize     = [long]$meta.originalSize
                FileCount        = [long]$meta.fileCount
                DirectoryCount   = [long](Get-ObjectPropertyValue -Object $meta -Name 'directoryCount' -Default 0)
                ArchiveFile      = [string]$meta.archiveFile
                ArchiveDirectory = $directory.FullName
                MetaPath         = $metaPath
                Metadata         = $meta
            })
        }
        catch {
            Write-ColdShelfWarning "Ignoring invalid metadata: $metaPath"
        }
    }
    return @($results | Sort-Object CreatedAt, Id)
}

function Resolve-ColdShelfArchive {
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string] $Query
    )

    $archives = @(Get-ColdShelfArchives -Config $Config)
    $matches = @($archives | Where-Object { $_.Id -eq $Query })
    if ($matches.Count -eq 0) {
        $matches = @($archives | Where-Object { $_.Id.StartsWith($Query, [System.StringComparison]::OrdinalIgnoreCase) })
    }
    if ($matches.Count -eq 0) {
        $matches = @($archives | Where-Object { [string]::Equals($_.Name, $Query, [System.StringComparison]::OrdinalIgnoreCase) })
    }

    if ($matches.Count -eq 0) {
        Stop-ColdShelf -Code $script:ExitCodes.NotFound -Message "No archive matches '$Query'."
    }
    if ($matches.Count -gt 1) {
        Write-Host "Multiple archives match '$Query':"
        $matches | Select-Object Id, Name, Status, CreatedAt | Format-Table -AutoSize | Out-String | Write-Host
        Stop-ColdShelf -Code $script:ExitCodes.Conflict -Message 'Archive name or ID prefix is ambiguous. Use a longer ID.'
    }
    return $matches[0]
}

function Read-TarBlock {
    param(
        [Parameter(Mandatory)] [System.IO.Stream] $Stream,
        [Parameter(Mandatory)] [byte[]] $Buffer
    )

    $offset = 0
    while ($offset -lt $Buffer.Length) {
        $read = $Stream.Read($Buffer, $offset, $Buffer.Length - $offset)
        if ($read -eq 0) { break }
        $offset += $read
    }
    return $offset
}

function Test-ZeroTarBlock {
    param([Parameter(Mandatory)] [byte[]] $Block)

    foreach ($value in $Block) {
        if ($value -ne 0) { return $false }
    }
    return $true
}

function Get-TarTextField {
    param(
        [Parameter(Mandatory)] [byte[]] $Block,
        [Parameter(Mandatory)] [int] $Offset,
        [Parameter(Mandatory)] [int] $Length,
        [Parameter(Mandatory)] [string] $FieldName
    )

    $end = $Offset + $Length
    $contentEnd = $end
    for ($index = $Offset; $index -lt $end; $index++) {
        if ($Block[$index] -eq 0) {
            $contentEnd = $index
            for ($padding = $index; $padding -lt $end; $padding++) {
                if ($Block[$padding] -ne 0) {
                    Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message "Tar $FieldName field contains data after a NUL terminator."
                }
            }
            break
        }
    }
    if ($contentEnd -eq $Offset) { return '' }

    try {
        return [System.Text.UTF8Encoding]::new($false, $true).GetString($Block, $Offset, $contentEnd - $Offset)
    }
    catch {
        Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message "Tar $FieldName field is not valid UTF-8."
    }
}

function Get-TarNumber {
    param(
        [Parameter(Mandatory)] [byte[]] $Block,
        [Parameter(Mandatory)] [int] $Offset,
        [Parameter(Mandatory)] [int] $Length,
        [Parameter(Mandatory)] [string] $FieldName
    )

    if (($Block[$Offset] -band 0x80) -ne 0) {
        if (($Block[$Offset] -band 0x40) -ne 0) {
            Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message "Tar $FieldName field contains a negative base-256 number."
        }
        [long]$value = $Block[$Offset] -band 0x3f
        for ($index = $Offset + 1; $index -lt ($Offset + $Length); $index++) {
            if ($value -gt ([long]::MaxValue - $Block[$index]) / 256) {
                Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message "Tar $FieldName field exceeds Int64."
            }
            $value = ($value * 256) + $Block[$index]
        }
        return $value
    }

    $text = [System.Text.Encoding]::ASCII.GetString($Block, $Offset, $Length).Trim([char]0, ' ')
    if ($text.Length -eq 0) { return [long]0 }
    if ($text -notmatch '^[0-7]+$') {
        Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message "Tar $FieldName field is not a valid octal number."
    }
    try {
        return [Convert]::ToInt64($text, 8)
    }
    catch {
        Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message "Tar $FieldName field exceeds Int64."
    }
}

function Assert-TarHeaderChecksum {
    param([Parameter(Mandatory)] [byte[]] $Block)

    $expected = Get-TarNumber -Block $Block -Offset 148 -Length 8 -FieldName 'checksum'
    [long]$unsigned = 0
    [long]$signed = 0
    for ($index = 0; $index -lt 512; $index++) {
        $value = if ($index -ge 148 -and $index -lt 156) { 32 } else { [int]$Block[$index] }
        $unsigned += $value
        $signed += if ($value -ge 128) { $value - 256 } else { $value }
    }
    if ($expected -ne $unsigned -and $expected -ne $signed) {
        Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'Tar header checksum is invalid.'
    }
}

function Read-PaxAttributes {
    param([Parameter(Mandatory)] [byte[]] $Data)

    $attributes = @{}
    $offset = 0
    $utf8 = [System.Text.UTF8Encoding]::new($false, $true)
    while ($offset -lt $Data.Length) {
        $space = [Array]::IndexOf($Data, [byte]32, $offset)
        if ($space -lt 0) {
            Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'PAX record is missing its length separator.'
        }
        $lengthText = [System.Text.Encoding]::ASCII.GetString($Data, $offset, $space - $offset)
        if ($lengthText -notmatch '^[1-9][0-9]*$') {
            Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'PAX record contains an invalid length.'
        }
        try { [int]$recordLength = $lengthText }
        catch { Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'PAX record length is too large.' }
        if ($recordLength -le ($space - $offset + 2) -or $recordLength -gt ($Data.Length - $offset) -or $Data[$offset + $recordLength - 1] -ne 10) {
            Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'PAX record length does not match its payload.'
        }

        $payloadOffset = $space + 1
        $payloadLength = ($offset + $recordLength - 1) - $payloadOffset
        try { $payload = $utf8.GetString($Data, $payloadOffset, $payloadLength) }
        catch { Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'PAX record is not valid UTF-8.' }
        $equals = $payload.IndexOf('=')
        if ($equals -le 0) {
            Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'PAX record is missing a key or value separator.'
        }
        $key = $payload.Substring(0, $equals)
        if ($attributes.ContainsKey($key)) {
            Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message "PAX record contains duplicate key '$key'."
        }
        $attributes[$key] = $payload.Substring($equals + 1)
        $offset += $recordLength
    }
    return $attributes
}

function Get-RawTarEntries {
    param([Parameter(Mandatory)] [string] $ArchivePath)

    $stream = [System.IO.File]::Open($ArchivePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $entries = [System.Collections.Generic.List[string]]::new()
    $pendingPax = $null
    $pendingLongName = $null
    try {
        while ($true) {
            $block = [byte[]]::new(512)
            $read = Read-TarBlock -Stream $stream -Buffer $block
            if ($read -eq 0) {
                Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'Tar archive is missing its end-of-archive blocks.'
            }
            if ($read -ne 512) {
                Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'Tar archive ends in a partial header block.'
            }
            if (Test-ZeroTarBlock -Block $block) {
                $second = [byte[]]::new(512)
                if ((Read-TarBlock -Stream $stream -Buffer $second) -ne 512 -or -not (Test-ZeroTarBlock -Block $second)) {
                    Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'Tar archive has an invalid end-of-archive marker.'
                }
                $trailing = [byte[]]::new(512)
                while (($trailingRead = Read-TarBlock -Stream $stream -Buffer $trailing) -gt 0) {
                    for ($index = 0; $index -lt $trailingRead; $index++) {
                        if ($trailing[$index] -ne 0) {
                            Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'Tar archive contains non-zero data after its end marker.'
                        }
                    }
                    [Array]::Clear($trailing)
                }
                if ($null -ne $pendingPax -or $null -ne $pendingLongName) {
                    Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'Tar archive ends with an unconsumed extension header.'
                }
                break
            }

            Assert-TarHeaderChecksum -Block $block
            $name = Get-TarTextField -Block $block -Offset 0 -Length 100 -FieldName 'name'
            $prefix = Get-TarTextField -Block $block -Offset 345 -Length 155 -FieldName 'prefix'
            $typeFlag = [char]$block[156]
            [long]$size = Get-TarNumber -Block $block -Offset 124 -Length 12 -FieldName 'size'
            if ($size -lt 0) {
                Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'Tar entry contains a negative size.'
            }
            $remainder = $size % 512
            if ($remainder -ne 0 -and $size -gt ([long]::MaxValue - (512 - $remainder))) {
                Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'Tar entry padded size exceeds Int64.'
            }
            [long]$paddedSize = if ($remainder -eq 0) { $size } else { $size + (512 - $remainder) }
            if ($paddedSize -lt $size -or $paddedSize -gt ($stream.Length - $stream.Position)) {
                Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'Tar entry data extends beyond the archive.'
            }

            if ($typeFlag -in @('x', 'g', 'L', 'K')) {
                if ($typeFlag -eq 'g') {
                    Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'Global PAX headers are not supported.'
                }
                if ($typeFlag -eq 'K') {
                    Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'GNU long-link headers are not supported.'
                }
                if ($size -gt 16MB) {
                    Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'Tar extension header exceeds the supported safety limit.'
                }
                $data = [byte[]]::new([int]$size)
                if ($size -gt 0 -and (Read-TarBlock -Stream $stream -Buffer $data) -ne $size) {
                    Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'Tar extension header data is truncated.'
                }
                $padding = $paddedSize - $size
                if ($padding -gt 0) { [void]$stream.Seek($padding, [System.IO.SeekOrigin]::Current) }

                if ($typeFlag -eq 'x') {
                    $pax = Read-PaxAttributes -Data $data
                    if ($pax.ContainsKey('linkpath')) {
                        Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message "PAX attribute 'linkpath' is not supported."
                    }
                    if ($null -ne $pendingPax) {
                        Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'Tar archive contains stacked PAX extension headers.'
                    }
                    $pendingPax = $pax
                }
                elseif ($typeFlag -eq 'L') {
                    if ($null -ne $pendingLongName) {
                        Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'Tar archive contains stacked GNU long-name headers.'
                    }
                    $longNameLength = $data.Length
                    while ($longNameLength -gt 0 -and ($data[$longNameLength - 1] -eq 0 -or $data[$longNameLength - 1] -eq 10)) { $longNameLength-- }
                    try { $pendingLongName = [System.Text.UTF8Encoding]::new($false, $true).GetString($data, 0, $longNameLength) }
                    catch { Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'GNU long-name header is not valid UTF-8.' }
                    if ([string]::IsNullOrEmpty($pendingLongName)) {
                        Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'GNU long-name header is empty.'
                    }
                }
                continue
            }

            $fullName = if ([string]::IsNullOrEmpty($prefix)) { $name } else { "$prefix/$name" }
            if ($null -ne $pendingLongName) { $fullName = $pendingLongName }
            if ($null -ne $pendingPax) {
                if ($pendingPax.ContainsKey('path')) { $fullName = [string]$pendingPax['path'] }
                if ($pendingPax.ContainsKey('size')) {
                    $paxSizeText = [string]$pendingPax['size']
                    if ($paxSizeText -notmatch '^(0|[1-9][0-9]*)$') {
                        Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message "PAX attribute 'size' is not a canonical non-negative decimal integer."
                    }
                    try { [long]$paxSize = $paxSizeText }
                    catch { Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message "PAX attribute 'size' exceeds Int64." }
                    if ($paxSize -ne $size) {
                        Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message "PAX attribute 'size' does not match the tar header size."
                    }
                }
            }
            if ([string]::IsNullOrEmpty($fullName)) {
                Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'Tar entry has an empty path.'
            }
            if ($typeFlag -eq '5' -and -not $fullName.EndsWith('/', [System.StringComparison]::Ordinal)) { $fullName += '/' }
            $entries.Add($fullName)

            if ($paddedSize -gt 0) { [void]$stream.Seek($paddedSize, [System.IO.SeekOrigin]::Current) }
            $pendingPax = $null
            $pendingLongName = $null
        }
    }
    catch {
        if ($_.Exception.Data.Contains('ColdShelfExitCode')) { throw }
        Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message "Cannot parse tar headers safely: $($_.Exception.Message)"
    }
    finally {
        $stream.Dispose()
    }
    return @($entries)
}

function Test-TarEntrySafety {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Entries,
        [Parameter(Mandatory)] [string] $ExpectedRoot
    )

    if ($Entries.Count -eq 0) {
        Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'Archive contains no entries.'
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedRoot) -or $ExpectedRoot.Contains("`r") -or $ExpectedRoot.Contains("`n") -or $ExpectedRoot.Contains([char]0)) {
        Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'Archive metadata contains an invalid top-level directory name.'
    }

    $normalizedEntries = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($rawEntry in $Entries) {
        if ($null -eq $rawEntry -or $rawEntry.Length -eq 0 -or $rawEntry.Contains("`r") -or $rawEntry.Contains("`n") -or $rawEntry.Contains([char]0)) {
            Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'Archive contains an empty or ambiguous path.'
        }
        $normalized = $rawEntry.Replace('\', '/')
        if ($normalized.StartsWith('/') -or $normalized.StartsWith('//') -or $normalized -match '^[A-Za-z]:') {
            Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message "Archive contains an absolute path: $rawEntry"
        }
        $directoryHint = $normalized.EndsWith('/', [System.StringComparison]::Ordinal)
        $pathWithoutTrailingSlash = $normalized.TrimEnd('/')
        if ($pathWithoutTrailingSlash.Length -eq 0) {
            Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message "Archive contains an empty path: $rawEntry"
        }
        $segments = @($pathWithoutTrailingSlash.Split('/', [System.StringSplitOptions]::None))
        if ($segments.Count -eq 0 -or $segments -contains '' -or $segments -contains '.' -or $segments -contains '..') {
            Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message "Archive contains an unsafe path: $rawEntry"
        }
        if (-not [string]::Equals($segments[0], $ExpectedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message "Archive top-level directory does not match metadata name '$ExpectedRoot'."
        }
        $canonical = if ($directoryHint) { "$pathWithoutTrailingSlash/" } else { $pathWithoutTrailingSlash }
        if (-not $seen.Add($canonical)) {
            Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message "Archive contains a duplicate path: $canonical"
        }
        $normalizedEntries.Add($canonical)
    }
    return @($normalizedEntries)
}

function Test-ColdShelfArchiveData {
    param(
        [Parameter(Mandatory)] $Metadata,
        [Parameter(Mandatory)] [string] $ArchiveDirectory,
        [switch] $Full,
        [switch] $Content
    )

    if ([int]$Metadata.version -ne 1) {
        Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message "Unsupported metadata version: $($Metadata.version)"
    }
    if ([string]::IsNullOrWhiteSpace([string]$Metadata.name) -or [string]::IsNullOrWhiteSpace([string]$Metadata.id)) {
        Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'Metadata is missing id or name.'
    }

    $archiveFile = Join-Path $ArchiveDirectory ([string]$Metadata.archiveFile)
    if (-not (Test-Path -LiteralPath $archiveFile -PathType Leaf)) {
        Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message "Archive file is missing: $archiveFile"
    }
    $archiveItem = Get-Item -LiteralPath $archiveFile -Force
    if ($archiveItem.Length -le 0) {
        Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message "Archive file is empty: $archiveFile"
    }

    $tar = Get-ColdShelfTarPath
    $listing = Invoke-NativeProcess `
        -FilePath $tar `
        -Arguments @('-tf', $archiveFile) `
        -FailureCode $script:ExitCodes.Integrity
    if ($listing.ExitCode -ne 0) {
        $detail = $listing.StdErr.Trim()
        Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message "tar listing failed (exit $($listing.ExitCode)): $detail"
    }
    $headerEntries = Get-RawTarEntries -ArchivePath $archiveFile
    $entries = @(Test-TarEntrySafety -Entries $headerEntries -ExpectedRoot ([string]$Metadata.name))

    $manifestPath = Join-Path $ArchiveDirectory ([string](Get-ObjectPropertyValue -Object $Metadata -Name 'manifestFile' -Default 'manifest.json'))
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message "Content manifest is missing: $manifestPath"
    }
    $expectedManifest = Read-ManifestFile -Path $manifestPath
    if ($Content -or $Full) {
        $tarManifest = Get-TarContentManifest -ArchivePath $archiveFile -ExpectedRoot ([string]$Metadata.name) -NativeEntries $entries
        Compare-ManifestEntries -Expected $expectedManifest -Actual $tarManifest -Context 'Archive'
    }

    $hash = $null
    if ($Full) {
        $expectedHash = [string](Get-ObjectPropertyValue -Object $Metadata -Name 'archiveSha256' -Default '')
        if ([string]::IsNullOrWhiteSpace($expectedHash)) {
            Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'Metadata does not contain an archive SHA-256 baseline.'
        }
        $hash = (Get-FileHash -LiteralPath $archiveFile -Algorithm SHA256).Hash.ToLowerInvariant()
        if (-not [string]::Equals($hash, $expectedHash, [System.StringComparison]::OrdinalIgnoreCase)) {
            Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'Archive SHA-256 does not match metadata.'
        }
    }

    return [pscustomobject]@{
        ArchivePath = $archiveFile
        ArchiveSize = [long]$archiveItem.Length
        EntryCount  = $entries.Count
        Sha256      = $hash
        ManifestPath = $manifestPath
        Manifest    = $expectedManifest
    }
}

function Test-ColdShelfArchive {
    param(
        [Parameter(Mandatory)] $Archive,
        [switch] $Full
    )

    $metadata = Read-JsonFile -Path $Archive.MetaPath -FailureCode $script:ExitCodes.Integrity
    if (-not [string]::Equals([string]$metadata.id, [string]$Archive.Id, [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'Archive directory and metadata ID do not match.'
    }
    return Test-ColdShelfArchiveData -Metadata $metadata -ArchiveDirectory $Archive.ArchiveDirectory -Full:$Full
}

function Rebuild-ColdShelfIndex {
    param([Parameter(Mandatory)] $Config)

    $archives = @(Get-ColdShelfArchives -Config $Config | ForEach-Object {
        [ordered]@{
            id           = $_.Id
            name         = $_.Name
            sourcePath   = $_.SourcePath
            status       = $_.Status
            createdAt    = $_.CreatedAt
            originalSize = $_.OriginalSize
            fileCount    = $_.FileCount
        }
    })

    $index = [ordered]@{
        version   = 1
        updatedAt = [DateTimeOffset]::Now.ToString('o')
        archives  = $archives
    }
    Write-JsonAtomic -Path $Config.IndexPath -Value $index
    return $index
}

function Try-RebuildIndex {
    param([Parameter(Mandatory)] $Config)
    try {
        Rebuild-ColdShelfIndex -Config $Config | Out-Null
        return $true
    }
    catch {
        Write-ColdShelfWarning "Could not rebuild index.json: $($_.Exception.Message)"
        return $false
    }
}

function New-EmptyHistory {
    return [pscustomobject]@{
        version    = 1
        updatedAt  = [DateTimeOffset]::Now.ToString('o')
        aggregates = [pscustomobject]@{
            cold = [pscustomobject]@{ samples = 0; totalBytes = 0; averageBytesPerSecond = 0.0; recentAverageBytesPerSecond = 0.0; emaBytesPerSecond = 0.0 }
            hot  = [pscustomobject]@{ samples = 0; totalBytes = 0; averageBytesPerSecond = 0.0; recentAverageBytesPerSecond = 0.0; emaBytesPerSecond = 0.0 }
        }
        records    = @()
    }
}

function Read-HistorySafe {
    $paths = Get-ColdShelfPaths
    if (-not (Test-Path -LiteralPath $paths.History -PathType Leaf)) {
        return New-EmptyHistory
    }
    try {
        $history = Get-Content -LiteralPath $paths.History -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $history.records -or $null -eq $history.aggregates) { throw 'Missing required history fields.' }
        return $history
    }
    catch {
        Write-ColdShelfWarning "History is unavailable; using default ETA: $($_.Exception.Message)"
        return New-EmptyHistory
    }
}

function Get-HistoryAggregate {
    param(
        [Parameter(Mandatory)] $History,
        [Parameter(Mandatory)] [ValidateSet('cold', 'hot')] [string] $Operation
    )

    if ($Operation -eq 'cold') { return $History.aggregates.cold }
    return $History.aggregates.hot
}

function Get-ThroughputEstimate {
    param([Parameter(Mandatory)] [ValidateSet('cold', 'hot')] [string] $Operation)

    $default = if ($Operation -eq 'cold') { 110MB } else { 130MB }
    try {
        $history = Read-HistorySafe
        $aggregate = Get-HistoryAggregate -History $history -Operation $Operation
        if ([int]$aggregate.samples -gt 0 -and [double]$aggregate.emaBytesPerSecond -gt 0) {
            return [pscustomobject]@{
                BytesPerSecond = [double]$aggregate.emaBytesPerSecond
                Samples        = [int]$aggregate.samples
                IsDefault      = $false
            }
        }
    }
    catch {
        Write-ColdShelfWarning "Could not calculate historical throughput: $($_.Exception.Message)"
    }

    return [pscustomobject]@{
        BytesPerSecond = [double]$default
        Samples        = 0
        IsDefault      = $true
    }
}

function Add-HistoryRecord {
    param(
        [Parameter(Mandatory)] [ValidateSet('cold', 'hot')] [string] $Operation,
        [Parameter(Mandatory)] [string] $ArchiveId,
        [Parameter(Mandatory)] [long] $Bytes,
        [Parameter(Mandatory)] [DateTimeOffset] $StartedAt,
        [Parameter(Mandatory)] [DateTimeOffset] $CompletedAt
    )

    $duration = ($CompletedAt - $StartedAt).TotalSeconds
    if ($duration -le 0 -or $Bytes -lt 0) { return $null }
    $speed = if ($Bytes -eq 0) { 0.0 } else { [double]$Bytes / $duration }
    $paths = Get-ColdShelfPaths
    $mutex = $null
    $acquired = $false

    try {
        $mutex = [System.Threading.Mutex]::new($false, $paths.HistoryLock)
        $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(10))
        if (-not $acquired) { throw 'Timed out waiting for the history lock.' }

        $history = $null
        if (Test-Path -LiteralPath $paths.History -PathType Leaf) {
            try {
                $history = Get-Content -LiteralPath $paths.History -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
                if ($null -eq $history.records -or $null -eq $history.aggregates) { throw 'Missing required fields.' }
            }
            catch {
                $corruptPath = Join-Path $paths.Home "history.corrupt-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$([guid]::NewGuid().ToString('N').Substring(0, 6)).json"
                Copy-Item -LiteralPath $paths.History -Destination $corruptPath -Force -ErrorAction SilentlyContinue
                $history = New-EmptyHistory
                Write-ColdShelfWarning "Damaged history was preserved as $corruptPath; starting a new history file."
            }
        }
        else {
            $history = New-EmptyHistory
        }

        $record = [pscustomobject]@{
            operation             = $Operation
            archiveId             = $ArchiveId
            bytes                 = $Bytes
            startedAt             = $StartedAt.ToString('o')
            completedAt           = $CompletedAt.ToString('o')
            durationSeconds       = [Math]::Round($duration, 3)
            averageBytesPerSecond = [Math]::Round($speed, 3)
        }
        $records = @($history.records) + @($record)
        $history.records = $records
        $history.updatedAt = [DateTimeOffset]::Now.ToString('o')

        $operationRecords = @($records | Where-Object { $_.operation -eq $Operation -and [double]$_.durationSeconds -gt 0 })
        $aggregate = Get-HistoryAggregate -History $history -Operation $Operation
        $oldEma = [double]$aggregate.emaBytesPerSecond
        $previousSamples = [Math]::Max(0, $operationRecords.Count - 1)
        $newEma = if ($previousSamples -gt 0) { ($oldEma * 0.7) + ($speed * 0.3) } else { $speed }
        $recent = @($operationRecords | Select-Object -Last 5)
        $aggregate.samples = $operationRecords.Count
        $aggregate.totalBytes = [long](($operationRecords | Measure-Object -Property bytes -Sum).Sum)
        $totalDuration = [double](($operationRecords | Measure-Object -Property durationSeconds -Sum).Sum)
        $recentBytes = [long](($recent | Measure-Object -Property bytes -Sum).Sum)
        $recentDuration = [double](($recent | Measure-Object -Property durationSeconds -Sum).Sum)
        $aggregate.averageBytesPerSecond = if ($totalDuration -gt 0) { [double]$aggregate.totalBytes / $totalDuration } else { 0.0 }
        $aggregate.recentAverageBytesPerSecond = if ($recentDuration -gt 0) { [double]$recentBytes / $recentDuration } else { 0.0 }
        $aggregate.emaBytesPerSecond = [double]$newEma

        Write-JsonAtomic -Path $paths.History -Value $history
        return [pscustomobject]@{ Record = $record; Aggregate = $aggregate }
    }
    catch {
        Write-ColdShelfWarning "Could not update throughput history: $($_.Exception.Message)"
        return $null
    }
    finally {
        if ($acquired -and $null -ne $mutex) { $mutex.ReleaseMutex() }
        if ($null -ne $mutex) { $mutex.Dispose() }
    }
}

function Show-OperationEstimate {
    param(
        [Parameter(Mandatory)] [ValidateSet('cold', 'hot')] [string] $Operation,
        [Parameter(Mandatory)] [long] $Bytes
    )

    $estimate = Get-ThroughputEstimate -Operation $Operation
    $seconds = if ($estimate.BytesPerSecond -gt 0) { [double]$Bytes / $estimate.BytesPerSecond } else { 0 }
    Write-Host "Estimated speed: $(Format-Speed $estimate.BytesPerSecond)"
    $label = if ($Operation -eq 'cold') { 'Estimated archive time' } else { 'Estimated time' }
    if ($estimate.IsDefault) {
        Write-Host "$label`: ~$(Format-Duration $seconds)"
        Write-Host 'Based on default throughput'
    }
    else {
        Write-Host "$label`: ~$(Format-Duration $seconds)"
        Write-Host "Based on historical $Operation EMA across $($estimate.Samples) samples"
    }
    if ($Operation -eq 'cold') {
        Write-Host 'Verification may require additional time.'
    }
    Write-Host
}

function Set-MetadataProperty {
    param(
        [Parameter(Mandatory)] $Metadata,
        [Parameter(Mandatory)] [string] $Name,
        $Value
    )

    if ($Metadata.PSObject.Properties.Name -contains $Name) {
        $Metadata.$Name = $Value
    }
    else {
        $Metadata | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Get-QuarantineOwnershipPath {
    param([Parameter(Mandatory)] [string] $QuarantinePath)

    return "$(Get-NormalizedPath -Path $QuarantinePath).coldshelf-owner"
}

function Open-QuarantineOwnership {
    param(
        [Parameter(Mandatory)] [string] $QuarantinePath,
        [Parameter(Mandatory)] [string] $Token
    )

    $ownershipPath = Get-QuarantineOwnershipPath -QuarantinePath $QuarantinePath
    $stream = $null
    try {
        try {
            $stream = [System.IO.FileStream]::new(
                $ownershipPath,
                [System.IO.FileMode]::CreateNew,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None,
                4096,
                [System.IO.FileOptions]::DeleteOnClose
            )
        }
        catch [System.IO.IOException] {
            Stop-ColdShelf -Code $script:ExitCodes.Conflict -Message "Quarantine ownership record already exists or could not be created exclusively: $ownershipPath"
        }

        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Token)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Position = 0
        return $stream
    }
    catch {
        if ($null -ne $stream) { $stream.Dispose() }
        throw
    }
}

function Assert-QuarantineOwnership {
    param(
        [Parameter(Mandatory)] [System.IO.FileStream] $OwnershipHandle,
        [Parameter(Mandatory)] [string] $Token
    )

    if ($OwnershipHandle.SafeFileHandle.IsClosed -or $OwnershipHandle.SafeFileHandle.IsInvalid) {
        Stop-ColdShelf -Code $script:ExitCodes.Safety -Message 'Quarantine ownership handle is not valid.'
    }
    $bytes = [byte[]]::new([int]$OwnershipHandle.Length)
    $OwnershipHandle.Position = 0
    $read = 0
    while ($read -lt $bytes.Length) {
        $count = $OwnershipHandle.Read($bytes, $read, $bytes.Length - $read)
        if ($count -le 0) { break }
        $read += $count
    }
    $OwnershipHandle.Position = 0
    $actual = [System.Text.Encoding]::UTF8.GetString($bytes, 0, $read)
    if (-not [string]::Equals($actual, $Token, [System.StringComparison]::Ordinal)) {
        Stop-ColdShelf -Code $script:ExitCodes.Safety -Message 'Quarantine ownership token does not match the held file object.'
    }
}

function Close-QuarantineOwnership {
    param(
        [Parameter(Mandatory)] [System.IO.FileStream] $OwnershipHandle,
        [Parameter(Mandatory)] [string] $Token
    )

    Assert-QuarantineOwnership -OwnershipHandle $OwnershipHandle -Token $Token
    $OwnershipHandle.Dispose()
}

function Move-SourceToDeletionQuarantine {
    param(
        [Parameter(Mandatory)] [string] $OriginalResolvedPath,
        [Parameter(Mandatory)] [object[]] $ExpectedManifest,
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string] $ArchiveId
    )

    if (-not (Test-Path -LiteralPath $OriginalResolvedPath -PathType Container)) {
        Stop-ColdShelf -Code $script:ExitCodes.Safety -Message "Source directory no longer exists: $OriginalResolvedPath"
    }
    $current = Resolve-ExistingDirectory -Path $OriginalResolvedPath
    if (-not (Test-PathEqual -Left $current -Right $OriginalResolvedPath)) {
        Stop-ColdShelf -Code $script:ExitCodes.Safety -Message 'Source path changed before deletion. Refusing to remove it.'
    }
    Assert-SafeSourcePath -Path $current -ArchiveRoot $Config.ArchiveRoot
    $parent = Split-Path -Path $current -Parent
    Assert-NoReparsePointAncestors -Path $parent
    $nonce = [guid]::NewGuid().ToString('N')
    $token = [guid]::NewGuid().ToString('N')
    $quarantine = Join-Path $parent ".coldshelf-delete-$ArchiveId-$nonce"
    if (Test-Path -LiteralPath $quarantine) {
        Stop-ColdShelf -Code $script:ExitCodes.Conflict -Message "Deletion quarantine already exists: $quarantine"
    }

    [System.IO.Directory]::Move($current, $quarantine)
    $ownershipHandle = $null
    try {
        $ownershipHandle = Open-QuarantineOwnership -QuarantinePath $quarantine -Token $token
        Assert-NoReparsePointAncestors -Path $quarantine
        Assert-NoReparsePoints -Path $quarantine
        $frozenManifest = Get-DirectoryManifest -Path $quarantine
        Compare-ManifestEntries -Expected $ExpectedManifest -Actual $frozenManifest -Context 'Frozen source before deletion'
        return [pscustomobject]@{ Path = $quarantine; Token = $token; OwnershipHandle = $ownershipHandle }
    }
    catch {
        if (-not (Test-Path -LiteralPath $current) -and (Test-Path -LiteralPath $quarantine -PathType Container)) {
            try { [System.IO.Directory]::Move($quarantine, $current) }
            catch { Write-ColdShelfWarning "Could not restore quarantined source to its original name: $quarantine" }
        }
        if ($null -ne $ownershipHandle) { $ownershipHandle.Dispose() }
        throw
    }
}

function Remove-ColdShelfQuarantineSafely {
    param(
        [Parameter(Mandatory)] [string] $QuarantinePath,
        [Parameter(Mandatory)] [string] $ExpectedParent,
        [Parameter(Mandatory)] [string] $ArchiveId,
        [Parameter(Mandatory)] [string] $OwnershipToken,
        [Parameter(Mandatory)] [System.IO.FileStream] $OwnershipHandle,
        [Parameter(Mandatory)] [object[]] $ExpectedManifest
    )

    $path = Get-NormalizedPath -Path $QuarantinePath
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        Assert-QuarantineOwnership -OwnershipHandle $OwnershipHandle -Token $OwnershipToken
        Stop-ColdShelf -Code $script:ExitCodes.Safety -Message "Source deletion quarantine disappeared before deletion: $path"
    }
    $expectedPath = Join-Path (Get-NormalizedPath -Path $ExpectedParent) (Split-Path -Path $QuarantinePath -Leaf)
    if (-not (Test-PathEqual -Left $path -Right $expectedPath) -or -not (Split-Path -Path $path -Leaf).StartsWith(".coldshelf-delete-$ArchiveId-", [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-ColdShelf -Code $script:ExitCodes.Safety -Message "Refusing to remove unrecognized deletion quarantine: $path"
    }
    Assert-QuarantineOwnership -OwnershipHandle $OwnershipHandle -Token $OwnershipToken
    Assert-NoReparsePointAncestors -Path $path
    Assert-NoReparsePoints -Path $path
    $finalManifest = Get-DirectoryManifest -Path $path
    Compare-ManifestEntries -Expected $ExpectedManifest -Actual $finalManifest -Context 'Source quarantine immediately before deletion'
    Assert-QuarantineOwnership -OwnershipHandle $OwnershipHandle -Token $OwnershipToken
    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
    Close-QuarantineOwnership -OwnershipHandle $OwnershipHandle -Token $OwnershipToken
}

function Remove-RestoreStagingSafely {
    param(
        [Parameter(Mandatory)] [string] $StagingPath,
        [Parameter(Mandatory)] [string] $ExpectedParent,
        [Parameter(Mandatory)] [string] $ArchiveId
    )

    if (-not (Test-Path -LiteralPath $StagingPath -PathType Container)) { return }
    $normalized = Get-NormalizedPath -Path $StagingPath
    $parent = Get-NormalizedPath -Path (Split-Path -Path $normalized -Parent)
    $expectedNamePrefix = ".coldshelf-restore-$ArchiveId-"
    if (-not (Test-PathEqual -Left $parent -Right $ExpectedParent) -or -not (Split-Path -Path $normalized -Leaf).StartsWith($expectedNamePrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-ColdShelf -Code $script:ExitCodes.Safety -Message "Refusing to remove unrecognized restore staging directory: $normalized"
    }
    Assert-NoReparsePointAncestors -Path $normalized
    $item = Get-Item -LiteralPath $normalized -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        Stop-ColdShelf -Code $script:ExitCodes.Safety -Message "Refusing to remove reparse-point staging directory: $normalized"
    }
    Remove-Item -LiteralPath $normalized -Recurse -Force -ErrorAction Stop
}

function Invoke-ColdOperation {
    param(
        [Parameter(Mandatory)] [string] $SourceArgument,
        [ValidateSet('prompt', 'remove', 'keep')] [string] $RemovalMode = 'prompt'
    )

    $config = Get-ColdShelfConfig
    $sourcePath = Resolve-ExistingDirectory -Path $SourceArgument
    Assert-SafeSourcePath -Path $sourcePath -ArchiveRoot $config.ArchiveRoot
    $name = Split-Path -Path $sourcePath -Leaf
    if ([string]::IsNullOrWhiteSpace($name)) {
        Stop-ColdShelf -Code $script:ExitCodes.Safety -Message 'Could not determine the source directory name.'
    }
    if ($name.Contains("`r") -or $name.Contains("`n") -or $name.Contains([char]0)) {
        Stop-ColdShelf -Code $script:ExitCodes.Safety -Message 'Source directory names containing newlines or NUL are not supported.'
    }
    $parent = Split-Path -Path $sourcePath -Parent
    $statsBefore = Get-DirectoryStats -Path $sourcePath
    Write-ColdShelfMessage 'Building content manifest...'
    $manifestBefore = Get-DirectoryManifest -Path $sourcePath
    Assert-ArchiveFreeSpace -ArchiveRoot $config.ArchiveRoot -RequiredBytes $statsBefore.Bytes

    $id = New-ColdShelfId
    while (Test-Path -LiteralPath (Join-Path $config.ArchivesRoot $id)) { $id = New-ColdShelfId }
    $tempDirectory = Join-Path $config.ArchivesRoot "$id.tmp"
    $finalDirectory = Join-Path $config.ArchivesRoot $id
    New-Item -ItemType Directory -Path $tempDirectory -ErrorAction Stop | Out-Null
    $archivePath = Join-Path $tempDirectory 'archive.tar'
    $metaPath = Join-Path $tempDirectory 'meta.json'
    $manifestPath = Join-Path $tempDirectory 'manifest.json'

    $metadata = [pscustomobject][ordered]@{
        version          = 1
        id               = $id
        name             = $name
        sourcePath       = $sourcePath
        archiveFile      = 'archive.tar'
        manifestFile     = 'manifest.json'
        createdAt        = [DateTimeOffset]::Now.ToString('o')
        originalSize     = [long]$statsBefore.Bytes
        fileCount        = [long]$statsBefore.FileCount
        directoryCount   = [long]$statsBefore.DirectoryCount
        archiveSize      = 0
        status                 = 'creating'
        sourceRemoved          = $false
        sourceRemovedAt        = $null
        sourceRemovalPending   = $false
        sourceQuarantine       = $null
        restoredAt             = $null
        archiveSha256          = $null
    }
    Write-JsonAtomic -Path $manifestPath -Value ([ordered]@{ version = 1; entries = $manifestBefore })
    Write-JsonAtomic -Path $metaPath -Value $metadata

    Write-ColdShelfMessage "Archiving $name"
    Write-Host
    Write-Host "Source:  $sourcePath"
    Write-Host "Size:    $(Format-ByteSize $statsBefore.Bytes) / $($statsBefore.FileCount) files"
    Write-Host "Archive: $finalDirectory"
    Write-Host
    Show-OperationEstimate -Operation cold -Bytes $statsBefore.Bytes
    Write-Host 'Archiving...'

    $tarStarted = [DateTimeOffset]::Now
    $sourceRemovalCommitted = $false
    try {
        $tar = Get-ColdShelfTarPath
        $result = Invoke-NativeProcess -FilePath $tar -Arguments @('-cf', $archivePath, '-C', $parent, '--', $name)
        $tarCompleted = [DateTimeOffset]::Now
        if ($result.ExitCode -ne 0) {
            $detail = $result.StdErr.Trim()
            Stop-ColdShelf -Code $script:ExitCodes.Tar -Message "tar failed (exit $($result.ExitCode)): $detail"
        }
        if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf) -or (Get-Item -LiteralPath $archivePath).Length -le 0) {
            Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'tar reported success but did not create a non-empty archive.'
        }

        Write-ColdShelfMessage 'Verifying archive...'
        $verification = Test-ColdShelfArchiveData -Metadata $metadata -ArchiveDirectory $tempDirectory -Content
        $manifestAfter = Get-DirectoryManifest -Path $sourcePath
        Compare-ManifestEntries -Expected $manifestBefore -Actual $manifestAfter -Context 'Source after archiving'
        $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()

        Set-MetadataProperty -Metadata $metadata -Name archiveSize -Value ([long]$verification.ArchiveSize)
        Set-MetadataProperty -Metadata $metadata -Name archiveSha256 -Value $archiveHash
        Set-MetadataProperty -Metadata $metadata -Name status -Value 'cold'
        Write-JsonAtomic -Path $metaPath -Value $metadata
        if (Test-Path -LiteralPath $finalDirectory) {
            Stop-ColdShelf -Code $script:ExitCodes.Conflict -Message "Archive destination already exists: $finalDirectory"
        }
        [System.IO.Directory]::Move($tempDirectory, $finalDirectory)

        $historyResult = Add-HistoryRecord -Operation cold -ArchiveId $id -Bytes $statsBefore.Bytes -StartedAt $tarStarted -CompletedAt $tarCompleted
        [void](Try-RebuildIndex -Config $config)

        $duration = ($tarCompleted - $tarStarted).TotalSeconds
        Write-ColdShelfMessage 'Archive completed.'
        Write-Host
        Write-Host "Size:          $(Format-ByteSize $statsBefore.Bytes)"
        Write-Host "Time:          $(Format-Duration $duration)"
        if ($duration -gt 0) { Write-Host "Average speed: $(Format-Speed ($statsBefore.Bytes / $duration))" }
        Write-Host
        Write-Host 'Archive verification successful.'
        if ($null -ne $historyResult) {
            Write-Host "Historical cold average: $(Format-Speed ([double]$historyResult.Aggregate.emaBytesPerSecond))"
        }
        Write-Host "Stored as: $id"

        $shouldRemove = $RemovalMode -eq 'remove'
        if ($RemovalMode -eq 'prompt') {
            if ([Console]::IsInputRedirected) {
                Write-ColdShelfMessage 'Input is redirected; keeping the original directory. Use --remove for verified automatic removal.'
            }
            else {
                $answer = Read-Host 'Remove original directory from SSD? [y/N]'
                $shouldRemove = $answer -match '^(?i:y|yes)$'
            }
        }

        if ($shouldRemove) {
            $quarantine = $null
            $archiveCommitLock = $null
            $manifestCommitLock = $null
            try {
                $finalArchivePath = Join-Path $finalDirectory 'archive.tar'
                $finalManifestPath = Join-Path $finalDirectory 'manifest.json'
                $archiveCommitLock = [System.IO.File]::Open($finalArchivePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
                $manifestCommitLock = [System.IO.File]::Open($finalManifestPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
                $commitVerification = Test-ColdShelfArchiveData -Metadata $metadata -ArchiveDirectory $finalDirectory -Full
                Compare-ManifestEntries -Expected $manifestBefore -Actual $commitVerification.Manifest -Context 'Published archive before source deletion'

                $quarantine = Move-SourceToDeletionQuarantine -OriginalResolvedPath $sourcePath -ExpectedManifest $manifestBefore -Config $config -ArchiveId $id
                Set-MetadataProperty -Metadata $metadata -Name sourceRemovalPending -Value $true
                Set-MetadataProperty -Metadata $metadata -Name sourceRemoved -Value $false
                Set-MetadataProperty -Metadata $metadata -Name sourceRemovedAt -Value $null
                Set-MetadataProperty -Metadata $metadata -Name sourceQuarantine -Value $quarantine.Path
                try {
                    Write-JsonAtomic -Path (Join-Path $finalDirectory 'meta.json') -Value $metadata
                    $sourceRemovalCommitted = $true
                }
                catch {
                    if (-not (Test-Path -LiteralPath $sourcePath) -and (Test-Path -LiteralPath $quarantine.Path -PathType Container)) {
                        [System.IO.Directory]::Move($quarantine.Path, $sourcePath)
                        Close-QuarantineOwnership -OwnershipHandle $quarantine.OwnershipHandle -Token $quarantine.Token
                    }
                    throw
                }
                Remove-ColdShelfQuarantineSafely -QuarantinePath $quarantine.Path -ExpectedParent (Split-Path -Path $sourcePath -Parent) -ArchiveId $id -OwnershipToken $quarantine.Token -OwnershipHandle $quarantine.OwnershipHandle -ExpectedManifest $manifestBefore
                Set-MetadataProperty -Metadata $metadata -Name sourceRemovalPending -Value $false
                Set-MetadataProperty -Metadata $metadata -Name sourceRemoved -Value $true
                Set-MetadataProperty -Metadata $metadata -Name sourceRemovedAt -Value ([DateTimeOffset]::Now.ToString('o'))
                Set-MetadataProperty -Metadata $metadata -Name sourceQuarantine -Value $null
                try { Write-JsonAtomic -Path (Join-Path $finalDirectory 'meta.json') -Value $metadata }
                catch { Write-ColdShelfWarning 'Source was removed, but final metadata update failed; metadata remains in sourceRemovalPending state.' }
                [void](Try-RebuildIndex -Config $config)
                Write-ColdShelfMessage 'Original directory removed after successful verification.'
            }
            catch {
                Write-ColdShelfWarning "Archive is safe, but the original directory could not be removed: $($_.Exception.Message)"
                Stop-ColdShelf -Code $script:ExitCodes.Safety -Message 'The archive was preserved. The original directory or its ColdShelf quarantine may still exist.'
            }
            finally {
                if ($null -ne $manifestCommitLock) { $manifestCommitLock.Dispose() }
                if ($null -ne $archiveCommitLock) { $archiveCommitLock.Dispose() }
            }
        }
        else {
            Write-ColdShelfMessage 'Original directory kept.'
        }
    }
    catch {
        if (Test-Path -LiteralPath $tempDirectory -PathType Container) {
            try {
                Set-MetadataProperty -Metadata $metadata -Name status -Value 'failed'
                Set-MetadataProperty -Metadata $metadata -Name failureMessage -Value $_.Exception.Message
                Write-JsonAtomic -Path $metaPath -Value $metadata
            }
            catch { }
        }
        if ($sourceRemovalCommitted) {
            Write-Host 'Original directory was committed for removal; check metadata.sourceQuarantine if cleanup was interrupted.'
        }
        else {
            Write-Host 'Original directory has NOT been removed.'
        }
        throw
    }
}

function Test-ExactPathInCollection {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [AllowNull()] $Collection
    )

    foreach ($candidate in @($Collection)) {
        if ([string]::IsNullOrWhiteSpace([string]$candidate)) { continue }
        try {
            if (Test-PathEqual -Left $Path -Right ([string]$candidate)) { return $true }
        }
        catch { continue }
    }
    return $false
}

function Invoke-DefenderSessionHelper {
    param(
        [Parameter(Mandatory)] [string] $SessionDirectory,
        [Parameter(Mandatory)] [string] $ExpectedRequestSha256
    )

    $sessionPath = Get-NormalizedPath -Path $SessionDirectory
    $expectedSessionsRoot = Get-NormalizedPath -Path (Get-ColdShelfPaths).DefenderSessions
    if (-not (Test-PathEqual -Left (Split-Path -Path $sessionPath -Parent) -Right $expectedSessionsRoot)) {
        Stop-ColdShelf -Code $script:ExitCodes.Defender -Message 'Defender helper session is not a direct child of the ColdShelf session root.'
    }
    foreach ($pathToCheck in @($expectedSessionsRoot, $sessionPath)) {
        $item = Get-Item -LiteralPath $pathToCheck -Force -ErrorAction Stop
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Stop-ColdShelf -Code $script:ExitCodes.Defender -Message "Defender helper path is a reparse point: $pathToCheck"
        }
    }
    $requestPath = Join-Path $sessionPath 'request.json'
    $readyPath = Join-Path $sessionPath 'ready.json'
    $resultPath = Join-Path $sessionPath 'result.json'
    $stopPath = Join-Path $sessionPath 'stop'
    $actualRequestHash = (Get-FileHash -LiteralPath $requestPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    if (-not [string]::Equals($actualRequestHash, $ExpectedRequestSha256, [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-ColdShelf -Code $script:ExitCodes.Defender -Message 'Defender helper request integrity check failed.'
    }
    $request = Read-JsonFile -Path $requestPath -FailureCode $script:ExitCodes.Defender
    $owned = [System.Collections.Generic.List[string]]::new()
    $preExisting = [System.Collections.Generic.List[string]]::new()
    $fakeMode = [string](Get-ObjectPropertyValue -Object $request -Name 'testMode' -Default '')
    if (-not [string]::IsNullOrWhiteSpace($fakeMode)) { [void](Assert-ColdShelfTestContext -FailureCode $script:ExitCodes.Defender) }
    $cleanupSucceeded = $true
    $cleanupError = $null

    try {
        if ($fakeMode -eq 'add-fail') { throw 'Injected Defender add failure.' }
        if ([string]::IsNullOrWhiteSpace($fakeMode)) {
            foreach ($command in @('Get-MpPreference', 'Add-MpPreference', 'Remove-MpPreference')) {
                if ($null -eq (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Microsoft Defender command is unavailable: $command" }
            }
            $existing = @((Get-MpPreference -ErrorAction Stop).ExclusionPath)
            foreach ($path in @($request.paths)) {
                $normalized = Get-NormalizedPath -Path ([string]$path)
                if (Test-ExactPathInCollection -Path $normalized -Collection $existing) {
                    $preExisting.Add($normalized)
                }
                else {
                    Add-MpPreference -ExclusionPath $normalized -ErrorAction Stop
                    $afterAdd = @((Get-MpPreference -ErrorAction Stop).ExclusionPath)
                    $exactMatches = @($afterAdd | Where-Object { try { Test-PathEqual -Left $normalized -Right ([string]$_) } catch { $false } })
                    if ($exactMatches.Count -eq 1) { $owned.Add($normalized) } else { $preExisting.Add($normalized) }
                }
            }
        }
        elseif ($fakeMode -eq 'pre-existing') {
            foreach ($path in @($request.paths)) { $preExisting.Add((Get-NormalizedPath -Path ([string]$path))) }
        }
        else {
            foreach ($path in @($request.paths)) { $owned.Add((Get-NormalizedPath -Path ([string]$path))) }
        }

        Write-JsonAtomic -Path $readyPath -Value ([ordered]@{ ready = $true; ownedPaths = @($owned); preExistingPaths = @($preExisting); createdAt = [DateTimeOffset]::Now.ToString('o') })
        while ($true) {
            if (Test-Path -LiteralPath $stopPath -PathType Leaf) { break }
            try {
                $process = Get-Process -Id ([int]$request.parentPid) -ErrorAction Stop
                $actualStart = $process.StartTime.ToUniversalTime().Ticks
                if ([long]$actualStart -ne [long]$request.parentStartTicks) { break }
            }
            catch { break }
            Start-Sleep -Milliseconds 250
        }
    }
    catch {
        Write-JsonAtomic -Path $readyPath -Value ([ordered]@{ ready = $false; error = $_.Exception.Message; ownedPaths = @($owned); preExistingPaths = @($preExisting) })
    }
    finally {
        try {
            if ($fakeMode -eq 'remove-fail') { throw 'Injected Defender remove failure.' }
            if ([string]::IsNullOrWhiteSpace($fakeMode)) {
                foreach ($path in @($owned)) { Remove-MpPreference -ExclusionPath $path -ErrorAction Stop }
            }
        }
        catch {
            $cleanupSucceeded = $false
            $cleanupError = $_.Exception.Message
        }
        Write-JsonAtomic -Path $resultPath -Value ([ordered]@{ cleanupSucceeded = $cleanupSucceeded; cleanupError = $cleanupError; ownedPaths = @($owned); preExistingPaths = @($preExisting); completedAt = [DateTimeOffset]::Now.ToString('o') })
    }
}

function Get-StandaloneDefenderHelperCommand {
    param(
        [Parameter(Mandatory)] [string] $SessionDirectory,
        [Parameter(Mandatory)] [string] $ExpectedRequestSha256
    )

    $sessionLiteral = $SessionDirectory.Replace("'", "''")
    $hashLiteral = $ExpectedRequestSha256.Replace("'", "''")
    return @"
`$ErrorActionPreference = 'Stop'
`$session = [IO.Path]::GetFullPath('$sessionLiteral')
`$requestPath = [IO.Path]::Combine(`$session, 'request.json')
foreach (`$pathToCheck in @([IO.Directory]::GetParent(`$session).FullName, `$session, `$requestPath)) {
    `$item = Get-Item -LiteralPath `$pathToCheck -Force -ErrorAction Stop
    if ((`$item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Defender helper path is a reparse point: `$pathToCheck" }
}
`$readyPath = [IO.Path]::Combine(`$session, 'ready.json')
`$resultPath = [IO.Path]::Combine(`$session, 'result.json')
`$stopPath = [IO.Path]::Combine(`$session, 'stop')
`$owned = [Collections.Generic.List[string]]::new()
`$preExisting = [Collections.Generic.List[string]]::new()
`$cleanupSucceeded = `$true
`$cleanupError = `$null
`$encoding = [Text.UTF8Encoding]::new(`$false)
function Write-State([string]`$Path, `$Value) {
    `$temp = [IO.Path]::Combine(`$session, '.' + [IO.Path]::GetFileName(`$Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText(`$temp, ((`$Value | ConvertTo-Json -Depth 10) + [Environment]::NewLine), `$encoding)
        [IO.File]::Move(`$temp, `$Path, `$true)
    } finally { if ([IO.File]::Exists(`$temp)) { [IO.File]::Delete(`$temp) } }
}
function Normalize([string]`$Path) {
    `$full = [IO.Path]::GetFullPath(`$Path)
    `$root = [IO.Path]::GetPathRoot(`$full)
    if (-not [string]::Equals(`$full, `$root, [StringComparison]::OrdinalIgnoreCase)) { `$full = `$full.TrimEnd([char[]]@('\','/')) }
    return `$full
}
try {
    `$actualHash = (Get-FileHash -LiteralPath `$requestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if (-not [string]::Equals(`$actualHash, '$hashLiteral', [StringComparison]::OrdinalIgnoreCase)) { throw 'Defender helper request integrity check failed.' }
    `$request = Get-Content -LiteralPath `$requestPath -Raw -Encoding utf8 | ConvertFrom-Json
    foreach (`$command in @('Get-MpPreference','Add-MpPreference','Remove-MpPreference')) { if (`$null -eq (Get-Command `$command -ErrorAction SilentlyContinue)) { throw "Microsoft Defender command is unavailable: `$command" } }
    `$existing = @((Get-MpPreference -ErrorAction Stop).ExclusionPath)
    foreach (`$rawPath in @(`$request.paths)) {
        `$path = Normalize ([string]`$rawPath)
        `$alreadyExists = `$false
        foreach (`$candidate in `$existing) {
            if ([string]::IsNullOrWhiteSpace([string]`$candidate)) { continue }
            try { if ([string]::Equals((Normalize ([string]`$candidate)), `$path, [StringComparison]::OrdinalIgnoreCase)) { `$alreadyExists = `$true; break } } catch { }
        }
        if (`$alreadyExists) { `$preExisting.Add(`$path) } else {
            Add-MpPreference -ExclusionPath `$path -ErrorAction Stop
            `$afterAdd = @((Get-MpPreference -ErrorAction Stop).ExclusionPath)
            `$matchCount = 0
            foreach (`$candidate in `$afterAdd) { try { if ([string]::Equals((Normalize ([string]`$candidate)), `$path, [StringComparison]::OrdinalIgnoreCase)) { `$matchCount++ } } catch { } }
            if (`$matchCount -eq 1) { `$owned.Add(`$path) } else { `$preExisting.Add(`$path) }
        }
    }
    Write-State `$readyPath ([ordered]@{ ready = `$true; ownedPaths = @(`$owned); preExistingPaths = @(`$preExisting); createdAt = [DateTimeOffset]::Now.ToString('o') })
    while (`$true) {
        if ([IO.File]::Exists(`$stopPath)) { break }
        try {
            `$process = Get-Process -Id ([int]`$request.parentPid) -ErrorAction Stop
            if ([long]`$process.StartTime.ToUniversalTime().Ticks -ne [long]`$request.parentStartTicks) { break }
        } catch { break }
        Start-Sleep -Milliseconds 250
    }
} catch {
    Write-State `$readyPath ([ordered]@{ ready = `$false; error = `$_.Exception.Message; ownedPaths = @(`$owned); preExistingPaths = @(`$preExisting) })
} finally {
    try { foreach (`$path in @(`$owned)) { Remove-MpPreference -ExclusionPath `$path -ErrorAction Stop } } catch { `$cleanupSucceeded = `$false; `$cleanupError = `$_.Exception.Message }
    Write-State `$resultPath ([ordered]@{ cleanupSucceeded = `$cleanupSucceeded; cleanupError = `$cleanupError; ownedPaths = @(`$owned); preExistingPaths = @(`$preExisting); completedAt = [DateTimeOffset]::Now.ToString('o') })
}
"@
}

function Start-TemporaryDefenderSession {
    param(
        [Parameter(Mandatory)] [string[]] $Paths,
        [Parameter(Mandatory)] [int] $ParentPid,
        [Parameter(Mandatory)] [long] $ParentStartTicks
    )

    $coldShelfPaths = Get-ColdShelfPaths
    $testMode = [string]$env:COLDSHELF_DEFENDER_TEST_MODE
    if (-not [string]::IsNullOrWhiteSpace($testMode)) {
        [void](Assert-ColdShelfTestContext -FailureCode $script:ExitCodes.Defender)
        if ($testMode -notin @('success', 'add-fail', 'remove-fail', 'pre-existing')) {
            Stop-ColdShelf -Code $script:ExitCodes.Defender -Message "Unknown Defender test mode: $testMode"
        }
    }
    New-Item -ItemType Directory -Path $coldShelfPaths.DefenderSessions -Force | Out-Null
    $sessionId = "$(Get-Date -Format 'yyyyMMdd-HHmmss')-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $sessionDirectory = Join-Path $coldShelfPaths.DefenderSessions $sessionId
    New-Item -ItemType Directory -Path $sessionDirectory -ErrorAction Stop | Out-Null
    $requestPath = Join-Path $sessionDirectory 'request.json'
    Write-JsonAtomic -Path $requestPath -Value ([ordered]@{ version = 1; paths = $Paths; parentPid = $ParentPid; parentStartTicks = $ParentStartTicks; testMode = $testMode })

    $requestHash = (Get-FileHash -LiteralPath $requestPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    try {
        if (-not [string]::IsNullOrWhiteSpace($testMode)) {
            $escapedScript = $PSCommandPath.Replace("'", "''")
            $escapedSession = $sessionDirectory.Replace("'", "''")
            $helperCommand = "& '$escapedScript' '__defender-helper' '$escapedSession' '$requestHash'"
            $encodedCommand = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($helperCommand))
            $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedCommand)
            $process = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $arguments -PassThru -WindowStyle Hidden -ErrorAction Stop
        }
        else {
            $standaloneCommand = Get-StandaloneDefenderHelperCommand -SessionDirectory $sessionDirectory -ExpectedRequestSha256 $requestHash
            $encodedCommand = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($standaloneCommand))
            $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedCommand)
            $process = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $arguments -Verb RunAs -PassThru -WindowStyle Hidden -ErrorAction Stop
        }
    }
    catch {
        Stop-ColdShelf -Code $script:ExitCodes.Defender -Message "UAC was declined or the Defender helper could not start: $($_.Exception.Message)"
    }

    $readyPath = Join-Path $sessionDirectory 'ready.json'
    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    while (-not (Test-Path -LiteralPath $readyPath -PathType Leaf)) {
        if ($process.HasExited) { break }
        if ([DateTime]::UtcNow -ge $deadline) { break }
        Start-Sleep -Milliseconds 100
    }
    if (-not (Test-Path -LiteralPath $readyPath -PathType Leaf)) {
        [System.IO.File]::WriteAllText((Join-Path $sessionDirectory 'stop'), 'stop', [System.Text.UTF8Encoding]::new($false))
        try { [void]$process.WaitForExit(30000) } catch { }
        Stop-ColdShelf -Code $script:ExitCodes.Defender -Message "Defender helper did not become ready. Session: $sessionDirectory"
    }
    $ready = Read-JsonFile -Path $readyPath -FailureCode $script:ExitCodes.Defender
    if (-not [bool]$ready.ready) {
        try { [void]$process.WaitForExit(30000) } catch { }
        Stop-ColdShelf -Code $script:ExitCodes.Defender -Message "Defender exclusion could not be added: $([string](Get-ObjectPropertyValue -Object $ready -Name 'error' -Default 'unknown error'))"
    }
    return [pscustomobject]@{ SessionDirectory = $sessionDirectory; Process = $process; OwnedPaths = @($ready.ownedPaths); PreExistingPaths = @($ready.preExistingPaths) }
}

function Stop-TemporaryDefenderSession {
    param([Parameter(Mandatory)] $Session)

    $stopPath = Join-Path $Session.SessionDirectory 'stop'
    [System.IO.File]::WriteAllText($stopPath, 'stop', [System.Text.UTF8Encoding]::new($false))
    if (-not $Session.Process.WaitForExit(30000)) {
        return [pscustomobject]@{ Success = $false; Error = 'Defender helper did not exit within 30 seconds.'; OwnedPaths = @($Session.OwnedPaths) }
    }
    $resultPath = Join-Path $Session.SessionDirectory 'result.json'
    if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
        return [pscustomobject]@{ Success = $false; Error = 'Defender helper did not write cleanup status.'; OwnedPaths = @($Session.OwnedPaths) }
    }
    $result = Read-JsonFile -Path $resultPath -FailureCode $script:ExitCodes.Defender
    return [pscustomobject]@{ Success = [bool]$result.cleanupSucceeded; Error = [string](Get-ObjectPropertyValue -Object $result -Name 'cleanupError' -Default ''); OwnedPaths = @($result.ownedPaths) }
}

function Invoke-HotOperation {
    param(
        [Parameter(Mandatory)] [string] $Query,
        [switch] $DefenderExclusion
    )

    $config = Get-ColdShelfConfig
    $archive = Resolve-ColdShelfArchive -Config $config -Query $Query
    $metadata = Read-JsonFile -Path $archive.MetaPath -FailureCode $script:ExitCodes.Integrity
    $verification = Test-ColdShelfArchive -Archive $archive
    $target = Assert-SafeRestoreTarget -Target ([string]$metadata.sourcePath) -ExpectedName ([string]$metadata.name) -Config $config

    if (Test-Path -LiteralPath $target) {
        Write-Host 'Target path already exists:'
        Write-Host $target
        Write-Host 'Refusing to overwrite existing data.'
        Stop-ColdShelf -Code $script:ExitCodes.Conflict -Message 'Restore target already exists.'
    }

    $parent = Split-Path -Path $target -Parent
    if ([string]::IsNullOrWhiteSpace($parent)) {
        Stop-ColdShelf -Code $script:ExitCodes.Safety -Message "Invalid restore target: $target"
    }
    $targetMutex = $null
    $targetMutexAcquired = $false
    if ($DefenderExclusion) {
        $targetMutexName = "Global\ColdShelf-Defender-Target-$((Get-StableHash -Value $target).Substring(0, 20))"
        $targetMutex = [System.Threading.Mutex]::new($false, $targetMutexName)
        try { $targetMutexAcquired = $targetMutex.WaitOne([TimeSpan]::FromSeconds(30)) }
        catch [System.Threading.AbandonedMutexException] { $targetMutexAcquired = $true }
        if (-not $targetMutexAcquired) {
            $targetMutex.Dispose()
            Stop-ColdShelf -Code $script:ExitCodes.Conflict -Message 'Another Defender-assisted restore is already using this target.'
        }
        if (Test-Path -LiteralPath $target) {
            $targetMutex.ReleaseMutex()
            $targetMutex.Dispose()
            Stop-ColdShelf -Code $script:ExitCodes.Conflict -Message 'Restore target appeared while waiting for the Defender session lock.'
        }
    }
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $staging = Join-Path $parent ".coldshelf-restore-$($archive.Id)-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    New-Item -ItemType Directory -Path $staging -ErrorAction Stop | Out-Null

    Write-ColdShelfMessage "Restoring $($archive.Name)"
    Write-Host
    Write-Host "Archive: $($verification.ArchivePath)"
    Write-Host "Target:  $target"
    Write-Host
    Show-OperationEstimate -Operation hot -Bytes ([long]$metadata.originalSize)
    Write-Host 'Restoring...'

    $restoreStarted = [DateTimeOffset]::Now
    $archiveLock = $null
    $defenderSession = $null
    $defenderCleanup = $null
    $published = $false
    try {
        $archivePath = Join-Path $archive.ArchiveDirectory ([string]$metadata.archiveFile)
        $archiveLock = [System.IO.File]::Open($archivePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        $verification = Test-ColdShelfArchive -Archive $archive -Full
        if ($DefenderExclusion) {
            Write-ColdShelfMessage 'Requesting temporary Microsoft Defender exclusions (UAC)...'
            $parentProcess = Get-Process -Id $PID
            $defenderSession = Start-TemporaryDefenderSession -Paths @($staging, $target) -ParentPid $PID -ParentStartTicks $parentProcess.StartTime.ToUniversalTime().Ticks
            Write-ColdShelfMessage 'Temporary Defender exclusions are active.'
        }
        $tar = Get-ColdShelfTarPath
        $result = Invoke-NativeProcess -FilePath $tar -Arguments @('-xf', $verification.ArchivePath, '-C', $staging)
        $restoreCompleted = [DateTimeOffset]::Now
        if ($result.ExitCode -ne 0) {
            Stop-ColdShelf -Code $script:ExitCodes.Tar -Message "tar extraction failed (exit $($result.ExitCode)): $($result.StdErr.Trim())"
        }

        $restoredRoot = Join-Path $staging ([string]$metadata.name)
        if (-not (Test-Path -LiteralPath $restoredRoot -PathType Container)) {
            Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'Restored archive root is missing.'
        }
        $children = @(Get-ChildItem -LiteralPath $staging -Force)
        if ($children.Count -ne 1 -or -not $children[0].PSIsContainer -or -not [string]::Equals($children[0].Name, [string]$metadata.name, [System.StringComparison]::OrdinalIgnoreCase)) {
            Stop-ColdShelf -Code $script:ExitCodes.Integrity -Message 'Restored staging directory contains unexpected top-level entries.'
        }
        Assert-NoReparsePoints -Path $restoredRoot
        $restoredManifest = Get-DirectoryManifest -Path $restoredRoot
        Compare-ManifestEntries -Expected $verification.Manifest -Actual $restoredManifest -Context 'Restored staging'
        if (Test-Path -LiteralPath $target) {
            Stop-ColdShelf -Code $script:ExitCodes.Conflict -Message "Restore target appeared during extraction: $target"
        }

        [System.IO.Directory]::Move($restoredRoot, $target)
        $published = $true
        Set-MetadataProperty -Metadata $metadata -Name status -Value 'hot'
        Set-MetadataProperty -Metadata $metadata -Name sourceRemoved -Value $false
        Set-MetadataProperty -Metadata $metadata -Name sourceRemovalPending -Value $false
        Set-MetadataProperty -Metadata $metadata -Name sourceQuarantine -Value $null
        Set-MetadataProperty -Metadata $metadata -Name restoredAt -Value ([DateTimeOffset]::Now.ToString('o'))
        Write-JsonAtomic -Path $archive.MetaPath -Value $metadata
        Remove-RestoreStagingSafely -StagingPath $staging -ExpectedParent $parent -ArchiveId $archive.Id
        if ($null -ne $defenderSession) {
            $defenderCleanup = Stop-TemporaryDefenderSession -Session $defenderSession
            $defenderSession = $null
            if (-not $defenderCleanup.Success) {
                $commands = @($defenderCleanup.OwnedPaths | ForEach-Object { "Remove-MpPreference -ExclusionPath '$($_.Replace("'", "''"))'" }) -join [Environment]::NewLine
                Write-ColdShelfWarning "Restore data was published, but temporary Defender exclusions may remain: $($defenderCleanup.Error)"
                if (-not [string]::IsNullOrWhiteSpace($commands)) { Write-Host "Run as administrator to clean them:`n$commands" }
                Stop-ColdShelf -Code $script:ExitCodes.Degraded -Message 'Restore completed, but Defender exclusion cleanup is degraded.'
            }
            Write-ColdShelfMessage 'Temporary Defender exclusions removed.'
        }
        $historyResult = Add-HistoryRecord -Operation hot -ArchiveId $archive.Id -Bytes ([long]$metadata.originalSize) -StartedAt $restoreStarted -CompletedAt $restoreCompleted
        [void](Try-RebuildIndex -Config $config)

        $duration = ($restoreCompleted - $restoreStarted).TotalSeconds
        Write-ColdShelfMessage 'Restore completed.'
        Write-Host
        Write-Host "Size:          $(Format-ByteSize ([long]$metadata.originalSize))"
        Write-Host "Time:          $(Format-Duration $duration)"
        if ($duration -gt 0) { Write-Host "Average speed: $(Format-Speed ([long]$metadata.originalSize / $duration))" }
        if ($null -ne $historyResult) {
            Write-Host
            Write-Host "Historical hot average: $(Format-Speed ([double]$historyResult.Aggregate.emaBytesPerSecond))"
        }
        Write-Host 'Archive retained on cold storage.'
    }
    catch {
        $originalError = $_
        $defenderCleanupFailed = $false
        if ($null -ne $defenderSession) {
            try {
                $defenderCleanup = Stop-TemporaryDefenderSession -Session $defenderSession
                if (-not $defenderCleanup.Success) {
                    $defenderCleanupFailed = $true
                    Write-ColdShelfWarning "Temporary Defender exclusion cleanup failed: $($defenderCleanup.Error)"
                    foreach ($path in @($defenderCleanup.OwnedPaths)) { Write-Host "Remove-MpPreference -ExclusionPath '$($path.Replace("'", "''"))'" }
                }
            }
            catch {
                $defenderCleanupFailed = $true
                Write-ColdShelfWarning "Could not stop Defender helper. Session: $($defenderSession.SessionDirectory)"
            }
        }
        if (Test-Path -LiteralPath $staging -PathType Container) {
            try { Remove-RestoreStagingSafely -StagingPath $staging -ExpectedParent $parent -ArchiveId $archive.Id }
            catch { Write-ColdShelfWarning "Could not clean restore staging directory: $staging" }
        }
        if ($published) {
            if ($originalError.Exception.Data.Contains('ColdShelfExitCode') -and [int]$originalError.Exception.Data['ColdShelfExitCode'] -eq $script:ExitCodes.Degraded) {
                throw $originalError
            }
            Write-ColdShelfWarning "Restore target was published successfully, but post-processing failed: $($originalError.Exception.Message)"
            Stop-ColdShelf -Code $script:ExitCodes.Degraded -Message 'Restore data is available at the target, but ColdShelf state is degraded.'
        }
        if ($defenderCleanupFailed) {
            Stop-ColdShelf -Code $script:ExitCodes.Defender -Message "Restore failed before publication, and temporary Defender exclusions may remain. Original error: $($originalError.Exception.Message)"
        }
        throw $originalError
    }
    finally {
        if ($null -ne $archiveLock) { $archiveLock.Dispose() }
        if ($targetMutexAcquired -and $null -ne $targetMutex) {
            try { $targetMutex.ReleaseMutex() } catch { }
        }
        if ($null -ne $targetMutex) { $targetMutex.Dispose() }
    }
}

function Show-ColdShelfList {
    $config = Get-ColdShelfConfig
    $archives = @(Get-ColdShelfArchives -Config $config)
    if ($archives.Count -eq 0) {
        Write-ColdShelfMessage 'No archives found.'
        return
    }

    $archives | Select-Object @{Name='ID';Expression={$_.Id}}, @{Name='STATUS';Expression={$_.Status}}, @{Name='NAME';Expression={$_.Name}}, @{Name='SIZE';Expression={Format-ByteSize $_.OriginalSize}}, @{Name='CREATED';Expression={([DateTimeOffset]$_.CreatedAt).ToString('yyyy-MM-dd')}}, @{Name='ORIGINAL PATH';Expression={$_.SourcePath}} | Format-Table -AutoSize | Out-String | Write-Host
}

function Show-ColdShelfInfo {
    param([Parameter(Mandatory)] [string] $Query)
    $config = Get-ColdShelfConfig
    $archive = Resolve-ColdShelfArchive -Config $config -Query $Query
    $archive.Metadata | ConvertTo-Json -Depth 20 | Write-Host
    Write-Host "archiveDirectory: $($archive.ArchiveDirectory)"
}

function Invoke-VerifyCommand {
    param(
        [Parameter(Mandatory)] [string] $Query,
        [switch] $Full
    )
    $config = Get-ColdShelfConfig
    $archive = Resolve-ColdShelfArchive -Config $config -Query $Query
    $result = Test-ColdShelfArchive -Archive $archive -Full:$Full
    Write-ColdShelfMessage 'Archive verified successfully.'
    Write-Host "Archive: $($result.ArchivePath)"
    Write-Host "Size:    $(Format-ByteSize $result.ArchiveSize)"
    Write-Host "Entries: $($result.EntryCount)"
    if ($Full) { Write-Host "SHA-256: $($result.Sha256)" }
}

function Invoke-Doctor {
    $config = Get-ColdShelfConfig
    $tar = Get-ColdShelfTarPath
    $valid = 0
    $invalid = 0
    $interrupted = 0

    Write-ColdShelfMessage 'Running diagnostics...'
    Write-Host "archiveRoot: $($config.ArchiveRoot)"
    Write-Host "tar.exe:     $tar"

    $sessionRoot = (Get-ColdShelfPaths).DefenderSessions
    if (Test-Path -LiteralPath $sessionRoot -PathType Container) {
        foreach ($session in Get-ChildItem -LiteralPath $sessionRoot -Directory -Force) {
            $requestPath = Join-Path $session.FullName 'request.json'
            $readyPath = Join-Path $session.FullName 'ready.json'
            $resultPath = Join-Path $session.FullName 'result.json'
            if ((Test-Path -LiteralPath $requestPath -PathType Leaf) -and -not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
                Write-ColdShelfWarning "Unfinished Defender session: $($session.FullName)"
                try {
                    if (Test-Path -LiteralPath $readyPath -PathType Leaf) {
                        $ready = Read-JsonFile -Path $readyPath -FailureCode $script:ExitCodes.Defender
                        foreach ($path in @($ready.ownedPaths)) { Write-Host "  Remove-MpPreference -ExclusionPath '$(([string]$path).Replace("'", "''"))'" }
                    }
                    else {
                        Write-Host '  Ownership was not established; inspect Get-MpPreference before removing any exclusion.'
                    }
                }
                catch { }
            }
            elseif (Test-Path -LiteralPath $resultPath -PathType Leaf) {
                try {
                    $result = Read-JsonFile -Path $resultPath -FailureCode $script:ExitCodes.Defender
                    if (-not [bool]$result.cleanupSucceeded) {
                        Write-ColdShelfWarning "Defender exclusion cleanup was incomplete: $($session.FullName)"
                        foreach ($path in @($result.ownedPaths)) { Write-Host "  Remove-MpPreference -ExclusionPath '$(([string]$path).Replace("'", "''"))'" }
                    }
                }
                catch { }
            }
        }
    }

    foreach ($directory in Get-ChildItem -LiteralPath $config.ArchivesRoot -Directory -Force) {
        if ($directory.Name.EndsWith('.tmp', [System.StringComparison]::OrdinalIgnoreCase)) {
            $interrupted++
            Write-ColdShelfWarning "Incomplete archive directory found: $($directory.FullName)"
            continue
        }
        if ($directory.Name.StartsWith('.coldshelf-remove-archive-', [System.StringComparison]::OrdinalIgnoreCase)) {
            $interrupted++
            Write-ColdShelfWarning "Interrupted archive removal quarantine found: $($directory.FullName)"
            continue
        }
        $metaPath = Join-Path $directory.FullName 'meta.json'
        try {
            $metadata = Read-JsonFile -Path $metaPath -FailureCode $script:ExitCodes.Integrity
            Test-ColdShelfArchiveData -Metadata $metadata -ArchiveDirectory $directory.FullName | Out-Null
            $valid++
            if ([bool](Get-ObjectPropertyValue -Object $metadata -Name 'sourceRemovalPending' -Default $false)) {
                $interrupted++
                $sourceQuarantine = [string](Get-ObjectPropertyValue -Object $metadata -Name 'sourceQuarantine' -Default '')
                Write-ColdShelfWarning "Source removal is pending for archive '$($directory.Name)'."
                if ([string]::IsNullOrWhiteSpace($sourceQuarantine)) {
                    Write-Host '  No source quarantine path was recorded; inspect meta.json and the original source parent.'
                }
                elseif (Test-Path -LiteralPath $sourceQuarantine -PathType Container) {
                    Write-Host "  Recorded source quarantine exists: $sourceQuarantine"
                }
                else {
                    Write-Host "  Recorded source quarantine is no longer present: $sourceQuarantine"
                }
                Write-Host '  Inspect the archive and recorded path manually; doctor will not delete or restore either location.'
            }
        }
        catch {
            $invalid++
            Write-ColdShelfWarning "Invalid archive '$($directory.Name)': $($_.Exception.Message)"
        }
    }

    Rebuild-ColdShelfIndex -Config $config | Out-Null
    Write-ColdShelfMessage "Index rebuilt. Valid archives: $valid; invalid archives: $invalid; interrupted states: $interrupted."
    if ($invalid -gt 0 -or $interrupted -gt 0) {
        Stop-ColdShelf -Code $script:ExitCodes.Degraded -Message 'Doctor found invalid archives or interrupted operations that require manual inspection.'
    }
}

function Get-RecordsAggregate {
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Records)

    $valid = @($Records | Where-Object { [double]$_.durationSeconds -gt 0 -and [long]$_.bytes -ge 0 })
    $recent = @($valid | Select-Object -Last 5)
    [double]$ema = 0
    [int]$emaSamples = 0
    foreach ($record in $valid) {
        $speed = [double]$record.averageBytesPerSecond
        $ema = if ($emaSamples -gt 0) { ($ema * 0.7) + ($speed * 0.3) } else { $speed }
        $emaSamples++
    }
    [long]$totalBytes = 0
    [double]$average = 0
    [double]$recentAverage = 0
    if ($valid.Count -gt 0) {
        $totalBytes = [long](($valid | Measure-Object bytes -Sum).Sum)
        $totalDuration = [double](($valid | Measure-Object durationSeconds -Sum).Sum)
        if ($totalDuration -gt 0) { $average = $totalBytes / $totalDuration }
    }
    if ($recent.Count -gt 0) {
        $recentBytes = [long](($recent | Measure-Object bytes -Sum).Sum)
        $recentDuration = [double](($recent | Measure-Object durationSeconds -Sum).Sum)
        if ($recentDuration -gt 0) { $recentAverage = $recentBytes / $recentDuration }
    }

    return [pscustomobject]@{
        Samples = $valid.Count
        Bytes   = $totalBytes
        Average = $average
        Recent  = $recentAverage
        Ema     = $ema
    }
}

function Show-ColdShelfStats {
    param([string] $Query)

    $history = Read-HistorySafe
    $records = @($history.records)
    $title = 'ColdShelf Storage Statistics'
    if (-not [string]::IsNullOrWhiteSpace($Query)) {
        $config = Get-ColdShelfConfig
        $archive = Resolve-ColdShelfArchive -Config $config -Query $Query
        $records = @($records | Where-Object { $_.archiveId -eq $archive.Id })
        $title += " — $($archive.Name) [$($archive.Id)]"
    }

    $cold = Get-RecordsAggregate -Records @($records | Where-Object operation -eq 'cold')
    $hot = Get-RecordsAggregate -Records @($records | Where-Object operation -eq 'hot')
    Write-Host $title
    Write-Host
    Write-Host "Cold operations:    $($cold.Samples)"
    Write-Host "Average cold speed: $(Format-Speed $cold.Average)"
    Write-Host "Recent cold speed:  $(Format-Speed $cold.Recent)"
    Write-Host "EMA cold speed:     $(Format-Speed $cold.Ema)"
    Write-Host
    Write-Host "Hot operations:     $($hot.Samples)"
    Write-Host "Average hot speed:  $(Format-Speed $hot.Average)"
    Write-Host "Recent hot speed:   $(Format-Speed $hot.Recent)"
    Write-Host "EMA hot speed:      $(Format-Speed $hot.Ema)"
    Write-Host
    Write-Host "Total archived:     $(Format-ByteSize $cold.Bytes)"
    Write-Host "Total restored:     $(Format-ByteSize $hot.Bytes)"
}

function Move-ArchiveToDeletionQuarantine {
    param(
        [Parameter(Mandatory)] $Archive,
        [Parameter(Mandatory)] $Config
    )

    $directory = Get-NormalizedPath -Path $Archive.ArchiveDirectory
    $parent = Get-NormalizedPath -Path (Split-Path -Path $directory -Parent)
    if (-not (Test-PathEqual -Left $parent -Right $Config.ArchivesRoot)) {
        Stop-ColdShelf -Code $script:ExitCodes.Safety -Message "Archive directory is outside archives root: $directory"
    }
    if (-not [string]::Equals((Split-Path -Path $directory -Leaf), $Archive.Id, [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-ColdShelf -Code $script:ExitCodes.Safety -Message 'Archive directory name does not match metadata ID.'
    }
    Assert-NoReparsePointAncestors -Path $directory
    Assert-NoReparsePoints -Path $directory
    $metadata = Read-JsonFile -Path $Archive.MetaPath -FailureCode $script:ExitCodes.Integrity
    if (-not [string]::Equals([string]$metadata.id, $Archive.Id, [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-ColdShelf -Code $script:ExitCodes.Safety -Message 'Archive metadata identity check failed.'
    }

    $nonce = [guid]::NewGuid().ToString('N')
    $token = [guid]::NewGuid().ToString('N')
    $quarantine = Join-Path $parent ".coldshelf-remove-archive-$($Archive.Id)-$nonce"
    if (Test-Path -LiteralPath $quarantine) {
        Stop-ColdShelf -Code $script:ExitCodes.Conflict -Message "Archive deletion quarantine already exists: $quarantine"
    }
    [System.IO.Directory]::Move($directory, $quarantine)
    $ownershipHandle = $null
    try {
        $ownershipHandle = Open-QuarantineOwnership -QuarantinePath $quarantine -Token $token
        return [pscustomobject]@{ Path = $quarantine; Token = $token; OwnershipHandle = $ownershipHandle }
    }
    catch {
        if (-not (Test-Path -LiteralPath $directory) -and (Test-Path -LiteralPath $quarantine -PathType Container)) {
            try { [System.IO.Directory]::Move($quarantine, $directory) }
            catch { Write-ColdShelfWarning "Could not restore archive quarantine: $quarantine" }
        }
        if ($null -ne $ownershipHandle) { $ownershipHandle.Dispose() }
        throw
    }
}

function Remove-ArchiveQuarantineSafely {
    param(
        [Parameter(Mandatory)] [string] $QuarantinePath,
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string] $ArchiveId,
        [Parameter(Mandatory)] [string] $OwnershipToken,
        [Parameter(Mandatory)] [System.IO.FileStream] $OwnershipHandle,
        [Parameter(Mandatory)] [object[]] $ExpectedSourceManifest
    )

    $path = Get-NormalizedPath -Path $QuarantinePath
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        Assert-QuarantineOwnership -OwnershipHandle $OwnershipHandle -Token $OwnershipToken
        Stop-ColdShelf -Code $script:ExitCodes.Safety -Message "Archive deletion quarantine disappeared before deletion: $path"
    }
    $expectedPath = Join-Path (Get-NormalizedPath -Path $Config.ArchivesRoot) (Split-Path -Path $QuarantinePath -Leaf)
    if (-not (Test-PathEqual -Left $path -Right $expectedPath) -or -not (Split-Path -Path $path -Leaf).StartsWith(".coldshelf-remove-archive-$ArchiveId-", [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-ColdShelf -Code $script:ExitCodes.Safety -Message "Refusing to remove unrecognized archive quarantine: $path"
    }
    Assert-QuarantineOwnership -OwnershipHandle $OwnershipHandle -Token $OwnershipToken
    Assert-NoReparsePointAncestors -Path $path
    Assert-NoReparsePoints -Path $path
    $metadata = Read-JsonFile -Path (Join-Path $path 'meta.json') -FailureCode $script:ExitCodes.Integrity
    if (-not [string]::Equals([string]$metadata.id, $ArchiveId, [System.StringComparison]::OrdinalIgnoreCase)) {
        Stop-ColdShelf -Code $script:ExitCodes.Safety -Message 'Quarantined archive metadata identity check failed.'
    }
    $verification = Test-ColdShelfArchiveData -Metadata $metadata -ArchiveDirectory $path -Full
    Compare-ManifestEntries -Expected $ExpectedSourceManifest -Actual $verification.Manifest -Context 'Archive quarantine immediately before deletion'
    Assert-QuarantineOwnership -OwnershipHandle $OwnershipHandle -Token $OwnershipToken
    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
    Close-QuarantineOwnership -OwnershipHandle $OwnershipHandle -Token $OwnershipToken
}

function Invoke-RemoveCommand {
    param(
        [Parameter(Mandatory)] [string] $Query,
        [switch] $Yes
    )

    $config = Get-ColdShelfConfig
    $archive = Resolve-ColdShelfArchive -Config $config -Query $Query
    $verification = Test-ColdShelfArchive -Archive $archive -Full
    $source = Get-NormalizedPath -Path $archive.SourcePath
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        Stop-ColdShelf -Code $script:ExitCodes.Safety -Message 'Refusing to remove the archive because the restored source directory is not present.'
    }
    Assert-SafeSourcePath -Path $source -ArchiveRoot $config.ArchiveRoot
    $sourceManifest = Get-DirectoryManifest -Path $source
    Compare-ManifestEntries -Expected $verification.Manifest -Actual $sourceManifest -Context 'Restored source'

    if (-not $Yes) {
        if ([Console]::IsInputRedirected) {
            Stop-ColdShelf -Code $script:ExitCodes.Usage -Message 'Confirmation is required. Re-run with --yes in non-interactive mode.'
        }
        $answer = Read-Host "Permanently remove cold archive $($archive.Id)? [y/N]"
        if ($answer -notmatch '^(?i:y|yes)$') {
            Write-ColdShelfMessage 'Archive kept.'
            return
        }
    }

    $sourceQuarantine = $null
    $archiveQuarantine = $null
    $sourceParent = Split-Path -Path $source -Parent
    try {
        $sourceQuarantine = Move-SourceToDeletionQuarantine -OriginalResolvedPath $source -ExpectedManifest $verification.Manifest -Config $config -ArchiveId $archive.Id
        $archive = Resolve-ColdShelfArchive -Config $config -Query $archive.Id
        $verification = Test-ColdShelfArchive -Archive $archive -Full
        $frozenSourceManifest = Get-DirectoryManifest -Path $sourceQuarantine.Path
        Compare-ManifestEntries -Expected $verification.Manifest -Actual $frozenSourceManifest -Context 'Frozen restored source'
        $archiveQuarantine = Move-ArchiveToDeletionQuarantine -Archive $archive -Config $config
        $quarantinedMetadata = Read-JsonFile -Path (Join-Path $archiveQuarantine.Path 'meta.json') -FailureCode $script:ExitCodes.Integrity
        $quarantinedVerification = Test-ColdShelfArchiveData -Metadata $quarantinedMetadata -ArchiveDirectory $archiveQuarantine.Path -Full
        $frozenSourceManifest = Get-DirectoryManifest -Path $sourceQuarantine.Path
        Compare-ManifestEntries -Expected $quarantinedVerification.Manifest -Actual $frozenSourceManifest -Context 'Frozen source and quarantined archive'
        Assert-QuarantineOwnership -OwnershipHandle $sourceQuarantine.OwnershipHandle -Token $sourceQuarantine.Token
        [System.IO.Directory]::Move($sourceQuarantine.Path, $source)
        Close-QuarantineOwnership -OwnershipHandle $sourceQuarantine.OwnershipHandle -Token $sourceQuarantine.Token
        $sourceQuarantine = $null
        Remove-ArchiveQuarantineSafely -QuarantinePath $archiveQuarantine.Path -Config $config -ArchiveId $archive.Id -OwnershipToken $archiveQuarantine.Token -OwnershipHandle $archiveQuarantine.OwnershipHandle -ExpectedSourceManifest $frozenSourceManifest
        $archiveQuarantine = $null
    }
    catch {
        if ($null -ne $archiveQuarantine -and (Test-Path -LiteralPath $archiveQuarantine.Path -PathType Container) -and -not (Test-Path -LiteralPath $archive.ArchiveDirectory)) {
            try {
                Assert-QuarantineOwnership -OwnershipHandle $archiveQuarantine.OwnershipHandle -Token $archiveQuarantine.Token
                [System.IO.Directory]::Move($archiveQuarantine.Path, $archive.ArchiveDirectory)
            }
            catch { Write-ColdShelfWarning "Could not restore archive quarantine: $($archiveQuarantine.Path)" }
            finally { $archiveQuarantine.OwnershipHandle.Dispose() }
        }
        elseif ($null -ne $archiveQuarantine) {
            $archiveQuarantine.OwnershipHandle.Dispose()
        }
        if ($null -ne $sourceQuarantine -and (Test-Path -LiteralPath $sourceQuarantine.Path -PathType Container) -and -not (Test-Path -LiteralPath $source)) {
            try {
                Assert-QuarantineOwnership -OwnershipHandle $sourceQuarantine.OwnershipHandle -Token $sourceQuarantine.Token
                [System.IO.Directory]::Move($sourceQuarantine.Path, $source)
            }
            catch { Write-ColdShelfWarning "Could not restore source quarantine: $($sourceQuarantine.Path)" }
            finally { $sourceQuarantine.OwnershipHandle.Dispose() }
        }
        elseif ($null -ne $sourceQuarantine) {
            $sourceQuarantine.OwnershipHandle.Dispose()
        }
        throw
    }
    [void](Try-RebuildIndex -Config $config)
    Write-ColdShelfMessage "Archive removed: $($archive.Id)"
}

function Show-Usage {
    @'
ColdShelf v1

Usage:
  coldshelf init <archiveRoot>
  coldshelf cold <path> [--remove|--keep]
  coldshelf hot <id-or-name> [-d|--defender-exclusion]
  coldshelf list
  coldshelf info <id-or-name>
  coldshelf verify <id-or-name> [--full]
  coldshelf remove <id-or-name> [--yes]
  coldshelf doctor
  coldshelf stats [id-or-name]
'@ | Write-Host
}

function Assert-ArgumentCount {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Arguments,
        [Parameter(Mandatory)] [int] $Minimum,
        [Parameter(Mandatory)] [int] $Maximum,
        [Parameter(Mandatory)] [string] $Usage
    )
    if ($Arguments.Count -lt $Minimum -or $Arguments.Count -gt $Maximum) {
        Stop-ColdShelf -Code $script:ExitCodes.Usage -Message "Usage: $Usage"
    }
}

$exitCode = $script:ExitCodes.Success
try {
    $allArguments = @($args)
    if ($allArguments.Count -eq 0 -or $allArguments[0] -in @('-h', '--help', 'help')) {
        Show-Usage
    }
    else {
        $command = ([string](@($allArguments)[0])).ToLowerInvariant()
        $commandArguments = @($allArguments | Select-Object -Skip 1)
        switch ($command) {
            '__defender-helper' {
                Assert-ArgumentCount -Arguments $commandArguments -Minimum 2 -Maximum 2 -Usage 'internal defender helper'
                Invoke-DefenderSessionHelper -SessionDirectory ([string](@($commandArguments)[0])) -ExpectedRequestSha256 ([string](@($commandArguments)[1]))
            }
            'init' {
                Assert-ArgumentCount -Arguments $commandArguments -Minimum 1 -Maximum 1 -Usage 'coldshelf init <archiveRoot>'
                Initialize-ColdShelf -ArchiveRoot ([string](@($commandArguments)[0]))
            }
            'cold' {
                Assert-ArgumentCount -Arguments $commandArguments -Minimum 1 -Maximum 2 -Usage 'coldshelf cold <path> [--remove|--keep]'
                $mode = 'prompt'
                if ($commandArguments.Count -eq 2) {
                    $mode = switch ([string](@($commandArguments)[1])) {
                        '--remove' { 'remove' }
                        '--keep' { 'keep' }
                        default { Stop-ColdShelf -Code $script:ExitCodes.Usage -Message "Unknown cold option: $(@($commandArguments)[1])" }
                    }
                }
                Invoke-ColdOperation -SourceArgument ([string](@($commandArguments)[0])) -RemovalMode $mode
            }
            'hot' {
                Assert-ArgumentCount -Arguments $commandArguments -Minimum 1 -Maximum 2 -Usage 'coldshelf hot <id-or-name> [-d|--defender-exclusion]'
                $defenderExclusion = $false
                if ($commandArguments.Count -eq 2) {
                    if (@($commandArguments)[1] -notin @('-d', '--defender-exclusion')) { Stop-ColdShelf -Code $script:ExitCodes.Usage -Message "Unknown hot option: $(@($commandArguments)[1])" }
                    $defenderExclusion = $true
                }
                Invoke-HotOperation -Query ([string](@($commandArguments)[0])) -DefenderExclusion:$defenderExclusion
            }
            'list' {
                Assert-ArgumentCount -Arguments $commandArguments -Minimum 0 -Maximum 0 -Usage 'coldshelf list'
                Show-ColdShelfList
            }
            'info' {
                Assert-ArgumentCount -Arguments $commandArguments -Minimum 1 -Maximum 1 -Usage 'coldshelf info <id-or-name>'
                Show-ColdShelfInfo -Query ([string](@($commandArguments)[0]))
            }
            'verify' {
                Assert-ArgumentCount -Arguments $commandArguments -Minimum 1 -Maximum 2 -Usage 'coldshelf verify <id-or-name> [--full]'
                $full = $false
                if ($commandArguments.Count -eq 2) {
                    if (@($commandArguments)[1] -ne '--full') { Stop-ColdShelf -Code $script:ExitCodes.Usage -Message "Unknown verify option: $(@($commandArguments)[1])" }
                    $full = $true
                }
                Invoke-VerifyCommand -Query ([string](@($commandArguments)[0])) -Full:$full
            }
            'remove' {
                Assert-ArgumentCount -Arguments $commandArguments -Minimum 1 -Maximum 2 -Usage 'coldshelf remove <id-or-name> [--yes]'
                $yes = $false
                if ($commandArguments.Count -eq 2) {
                    if (@($commandArguments)[1] -ne '--yes') { Stop-ColdShelf -Code $script:ExitCodes.Usage -Message "Unknown remove option: $(@($commandArguments)[1])" }
                    $yes = $true
                }
                Invoke-RemoveCommand -Query ([string](@($commandArguments)[0])) -Yes:$yes
            }
            'doctor' {
                Assert-ArgumentCount -Arguments $commandArguments -Minimum 0 -Maximum 0 -Usage 'coldshelf doctor'
                Invoke-Doctor
            }
            'stats' {
                Assert-ArgumentCount -Arguments $commandArguments -Minimum 0 -Maximum 1 -Usage 'coldshelf stats [id-or-name]'
                $query = if ($commandArguments.Count -eq 1) { [string](@($commandArguments)[0]) } else { $null }
                Show-ColdShelfStats -Query $query
            }
            default {
                Show-Usage
                Stop-ColdShelf -Code $script:ExitCodes.Usage -Message "Unknown command: $command"
            }
        }
    }
}
catch {
    if ($_.Exception.Data.Contains('ColdShelfExitCode')) {
        $exitCode = [int]$_.Exception.Data['ColdShelfExitCode']
    }
    else {
        $exitCode = $script:ExitCodes.General
    }
    [Console]::Error.WriteLine("[ColdShelf] ERROR: $($_.Exception.Message)")
}

exit $exitCode
