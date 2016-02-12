<#
.SYNOPSIS
    Retores NuGet package
.DESCRIPTION
    The script allows to restore the specific version of NuGet package and dependences. Currently only strongly typed version are supported.
.PARAMETER PackageId
    A specific package id to restore
.PARAMETER Version
    A specific version of the package to restore
.PARAMETER Source
    Comma separeted list of sources
.PARAMETER OutputDirectory
    Destination location of the restored packages
.PARAMETER NoCache
    Indicates that no cache should be used
#>

Param(
    [Parameter(Mandatory=$True)]
    [ValidateNotNull()]
    [String]$PackageId,

    [Parameter(Mandatory=$True)]
    [ValidateNotNull()]
    [String]$Version,

    [String]$Source = "https://www.nuget.org/api/v2/",

    [String]$OutputDirectory = (Get-Location),
    
    [switch]$NoCache)

Add-Type -Assembly "WindowsBase"

if (!(Test-Path $OutputDirectory)) {
    $outputDir = New-Item $OutputDirectory -ItemType directory   
}
else {
    $outputDir = Get-Item $OutputDirectory
}

$services = New-Object System.Collections.Generic.HashSet[object]

$Source.Split(';') | Foreach {
    if ($_.StartsWith("http")) {
        [void]$services.Add((New-Object Uri -ArgumentList $_))
    }
    else {
        [void]$services.Add((Get-Item $_))
    }
}

function ExtractPackage($stream, $packageId, $version) {
    $directory = New-Item (Join-Path $outputDir "$packageId.$version") -ItemType directory
        
    $nupkgStartPosition = $stream.Position;
    $archive = [System.IO.Packaging.Package]::Open($stream)

    foreach ($part in $archive.GetParts()) {
        
        if ($part.ContentType -eq "application/vnd.openxmlformats-package.relationships+xml") {
            continue
        }
        
        if ($part.ContentType -eq "application/vnd.openxmlformats-package.core-properties+xml") {
            continue
        }

        if ($part.Uri.OriginalString -eq "/$packageId.nuspec") {
            $reader = New-Object System.IO.StreamReader -ArgumentList $part.GetStream()
            $spec = [xml] $reader.ReadToEnd()
            continue
        }

        $partPath = Join-Path $directory ([Uri]::UnescapeDataString($part.Uri.OriginalString))

        $file = New-Item $partPath -ItemType file -Force
        $writer = $file.OpenWrite()
        [void]$part.GetStream().CopyTo($writer)
        [void]$writer.Close()
    }

    [void]$archive.Close()

    [void]$stream.Seek($nupkgStartPosition, [System.IO.SeekOrigin]::Begin);

    $partPath = Join-Path $directory "$packageId.$version.nupkg"

    $file = New-Item $partPath -ItemType file -Force
    $writer = $file.OpenWrite()
    [void]$stream.CopyTo($writer)
    [void]$writer.Close()

    return $spec
}

function GetSpec($nupkg) {
    $archive = [System.IO.Packaging.Package]::Open($nupkg)
    $packageId = $archive.PackageProperties.Identifier

    $specPart = $archive.GetPart((New-Object Uri -ArgumentList @( "/$packageId.nuspec", [UriKind]::Relative )));

    $reader = New-Object System.IO.StreamReader -ArgumentList $specPart.GetStream()
    $spec = [xml] $reader.ReadToEnd()

    [void]$archive.Close()

    return $spec
}

function RestorePackage($packageId, $version) {
    $directory = Join-Path $outputDir "$packageId.$version"
    $cachePath = Join-Path $env:LOCALAPPDATA "NuGet\Cache"
    $cachePackagePath = Join-Path $cachePath "$packageId.$version.nupkg"

    if (Test-Path $directory) {
        $spec = GetSpec((Join-Path $directory "$packageId.$version.nupkg"))
        
        Write-Host $packageId $version already installed
    }
    elseif ((-not $NoCache) -and (Test-Path $cachePackagePath)) {
            $stream =  [System.IO.File]::OpenRead($cachePackagePath)

            $spec = ExtractPackage -stream $stream -packageId $packageId -version $version

            $stream.Close()
            
            Write-Host Successfully installed $packageId $version from cache
    }
    else {
        $packageLocation = $null

        foreach ($service in $services) {
            
            if ($service -is [Uri]) {
                try {
                    $packageResponce = Invoke-RestMethod (New-Object Uri -ArgumentList @( $service, "Packages(Id='$packageId',Version='$version')" ))
                }
                catch {
                    continue
                }

                $packageLocation = $packageResponce.entry.content.src
                break
            }
            else {
                $tmp = Join-Path $service "$packageId.$version.nupkg"
                if (Test-Path $tmp) {
                    $packageLocation = $tmp
                    break
                }
            }
        }

        if ($packageLocation -eq $null) {
            throw "Unable to find version $version of package $packageId"
        }

        if ($packageLocation -is [string] -and $packageLocation.StartsWith("http")) {
            $packageContent = (New-Object Net.WebClient).DownloadData($packageLocation)
        }
        elseif ($packageLocation -is [string]) {
            $packageContent = [System.IO.File]::ReadAllBytes($packageLocation)
        }
        else {
            throw "Unable to retrieve the package"
        }

        if ((-not $NoCache)) {
            if (!(Test-Path $cachePath)) {
                New-Item $cachePath -ItemType directory | Out-Null
            }

            [System.IO.File]::WriteAllBytes($cachePackagePath, $packageContent)
        }

        try {
            $stream = New-Object System.IO.MemoryStream -ArgumentList @(, $packageContent)

            $spec = ExtractPackage -stream $stream -packageId $packageId -version $version
        }
        finally {
            $stream.Close()
        }
            
        Write-Host Successfully installed $packageId $version from source
    }

    return $spec
}

$installedPackages = @{}
$requiredPackages = @{}

$requiredPackages.Add($PackageId, $Version)

while ($requiredPackages.Count -gt 0) {
    $packageId = $requiredPackages.Keys | select -First 1
    $version = $requiredPackages[$packageId]

    Write-Host Restoring $packageId $version

    $spec = RestorePackage $packageId $version

    $requiredPackages.Remove($packageId)
    $installedPackages.Add($packageId, $version)

    foreach ($dependency in ($spec.package.metadata.dependencies | foreach { $_.dependency })) {
        $dependencyPackageId = $dependency.id
        $dependencyVersion = $dependency.version

        if ($installedPackages.ContainsKey($dependencyPackageId)) {
            #TODO check the version
        }
        elseif ($requiredPackages.ContainsKey($dependencyPackageId)){
            #TODO check the version
        }
        else {
            $requiredPackages.Add($dependencyPackageId, $dependencyVersion)
        }
    }
}

$result = @()

foreach ($packageId in $installedPackages.Keys) {
    $version = $installedPackages[$packageId]

    $pkg = New-Object System.Object
    $pkg | Add-Member -MemberType NoteProperty -Name "Id" -Value $packageId
    $pkg | Add-Member -MemberType NoteProperty -Name "Version" -Value $version
    $pkg | Add-Member -MemberType NoteProperty -Name "Location" -Value (Join-Path $outputDir "$packageId.$version")

    $result += $pkg
}

$result