<#
.SYNOPSIS

.DESCRIPTION

.NOTES

#>

Param(
    [Parameter(Mandatory=$True)]
    [ValidateNotNull()]
    [String]$PackageId,

    [Parameter(Mandatory=$True)]
    [ValidateNotNull()]
    [String]$Version,

    [String]$Source = "https://www.nuget.org/api/v2/",

    [String]$OutputDirectory = (Get-Location))

$ErrorActionPreference = "stop"

Add-Type -Assembly "WindowsBase"

if (!(Test-Path $OutputDirectory)) {
    $outputDir = New-Item $OutputDirectory -ItemType directory   
}
else {
    $outputDir = Get-Item $OutputDirectory
}

$serviceUrls = $Source.Split(';') | Select -Property @{ Name = "Url"; Expression = { New-Object Uri -ArgumentList $_ } } | Select -ExpandProperty Url

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
    $packageLocation = Join-Path $outputDir "$packageId.$version"
    if (Test-Path $packageLocation) {
        $spec = GetSpec((Join-Path $packageLocation "$packageId.$version.nupkg"))
        
        Write-Host $packageId $version already installed
    }
    else {
        $cachePath = Join-Path $env:LOCALAPPDATA "NuGet\Cache"
        $cachePackagePath = Join-Path $cachePath "$packageId.$version.nupkg"

        if (Test-Path $cachePackagePath) {
            $stream =  [System.IO.File]::OpenRead($cachePackagePath)

            $spec = ExtractPackage -stream $stream -packageId $packageId -version $version

            $stream.Close()
            
            Write-Host Successfully installed $packageId $version from cache
        }
        else {
            $packageUrl = $null

            foreach ($serviceUrl in $serviceUrls) {
                try {        
                    $packageResponce = Invoke-RestMethod (New-Object Uri -ArgumentList @( $serviceUrl, "Packages(Id='$packageId',Version='$version')" ))
                    $packageUrl = $packageResponce.entry.content.src
                }
                catch {
                    continue
                }
            }

            if ($packageUrl -eq $null) {
                Write-Error -Message "Unable to find version $version of package $packageId"
            }

            $packageContent = Invoke-WebRequest $packageUrl

            if (!(Test-Path $cachePath)) {
                New-Item $cachePath -ItemType directory | Out-Null
            }

            [System.IO.File]::WriteAllBytes($cachePackagePath, $packageContent.Content)

            try {
                $stream = New-Object System.IO.MemoryStream -ArgumentList @(,($packageContent.Content))

                $spec = ExtractPackage -stream $stream -packageId $packageId -version $version
            }
            finally {
                $stream.Close()
            }
            
            Write-Host Successfully installed $packageId $version from source
        }
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

$result = @{}

foreach ($packageId in $installedPackages.Keys) {
    $version = $installedPackages[$packageId]
    $result.Add($packageId, @{ 
        Id = $packageId;
        Version = $version;
        Location = Join-Path $outputDir "$packageId.$version"
    })
}

return $result