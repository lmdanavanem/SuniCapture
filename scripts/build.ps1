param([switch]$SkipTests, [switch]$RunUiChecks)
$ErrorActionPreference = 'Stop'
if ($SkipTests -and $RunUiChecks) { throw 'SkipTests et RunUiChecks ne peuvent pas être combinés.' }
$taskRoot = Split-Path -Parent $PSScriptRoot
$project = Join-Path $taskRoot 'src\SuniCapture\SuniCapture.csproj'
$projectMetadata = [xml](Get-Content -LiteralPath $project -Raw)
$appVersion = [string]$projectMetadata.Project.PropertyGroup.Version
$destination = Join-Path $taskRoot ("dist\SuniCapture-$appVersion-win-x64")
& (Join-Path $PSScriptRoot 'generate-icon.ps1')
& dotnet publish $project -c Release -r win-x64 --self-contained true -o $destination -p:DebugType=None -p:DebugSymbols=false --nologo
if ($LASTEXITCODE -ne 0) { throw 'La compilation a échoué.' }
$symbolDirectory = Join-Path $taskRoot ("artifacts\symbols\$appVersion")
$absoluteDestination = [System.IO.Path]::GetFullPath($destination).TrimEnd('\') + '\'
foreach ($symbol in @(Get-ChildItem -LiteralPath $destination -Recurse -File -Filter '*.pdb')) {
    if (!$symbol.FullName.StartsWith($absoluteDestination, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'Un symbole est hors du dossier de distribution.' }
    $relativeSymbol = $symbol.FullName.Substring($absoluteDestination.Length)
    $savedSymbol = Join-Path $symbolDirectory $relativeSymbol
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $savedSymbol)) | Out-Null
    Copy-Item -LiteralPath $symbol.FullName -Destination $savedSymbol -Force
    Remove-Item -LiteralPath $symbol.FullName -Force
}
$licenseDirectory = Join-Path $destination 'licenses'
[System.IO.Directory]::CreateDirectory($licenseDirectory) | Out-Null
Copy-Item -LiteralPath (Join-Path $taskRoot 'THIRD-PARTY-NOTICES.md') -Destination $destination -Force
Copy-Item -LiteralPath (Join-Path $taskRoot 'licenses\ScreenRecorderLib-MIT.txt') -Destination $licenseDirectory -Force
Copy-Item -LiteralPath (Join-Path $taskRoot 'README.md') -Destination $destination -Force
Copy-Item -LiteralPath (Join-Path $taskRoot 'README.en.md') -Destination $destination -Force
Copy-Item -LiteralPath (Join-Path $taskRoot 'CHANGELOG.md') -Destination $destination -Force
$documentationDirectory = Join-Path $destination 'docs'
[System.IO.Directory]::CreateDirectory($documentationDirectory) | Out-Null
foreach ($document in @('development.md', 'design.md', 'video-engine.md', "release-$appVersion.md", "verification-$appVersion.md", "verification-$appVersion.json")) {
    $sourceDocument = Join-Path $taskRoot ('docs\' + $document)
    if (Test-Path -LiteralPath $sourceDocument) { Copy-Item -LiteralPath $sourceDocument -Destination $documentationDirectory -Force }
}
foreach ($documentFolder in @('images', 'releases')) {
    $sourceFolder = Join-Path $taskRoot ('docs\' + $documentFolder)
    if (Test-Path -LiteralPath $sourceFolder) { Copy-Item -LiteralPath $sourceFolder -Destination $documentationDirectory -Recurse -Force }
}
$dotnetRoot = Split-Path -Parent (Get-Command dotnet).Source
foreach ($licenseFile in @('LICENSE.txt', 'ThirdPartyNotices.txt')) {
    $sourceLicense = Join-Path $dotnetRoot $licenseFile
    if (Test-Path -LiteralPath $sourceLicense) { Copy-Item -LiteralPath $sourceLicense -Destination (Join-Path $licenseDirectory ('dotnet-' + $licenseFile)) -Force }
}
if (!$SkipTests) {
    $verificationRoot = Join-Path $taskRoot 'artifacts\qa-data\packaged'
    $verificationArgs = @('--self-test', '--data-dir', ('"' + $verificationRoot + '"'))
    $verification = Start-Process -FilePath (Join-Path $destination 'SuniCapture.exe') -ArgumentList $verificationArgs -WindowStyle Hidden -Wait -PassThru
    $verificationReport = Join-Path $verificationRoot 'latest-report.json'
    if ($verification.ExitCode -ne 0 -or !(Test-Path -LiteralPath $verificationReport)) { throw 'La vérification de la version portable a échoué. Consultez artifacts/qa-data/packaged/latest-report.json.' }
    if ((Get-Content -LiteralPath $verificationReport -Raw -Encoding utf8 | ConvertFrom-Json).success -ne $true) { throw 'Le rapport de vérification signale un échec.' }
}
if ($RunUiChecks) {
    $uiReports = Join-Path $taskRoot 'artifacts\qa-data\packaged-ui'
    $uiRoot = Join-Path $uiReports ('run-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    $uiArgs = @('--ui-self-test', '--data-dir', ('"' + $uiRoot + '"'))
    $uiVerification = Start-Process -FilePath (Join-Path $destination 'SuniCapture.exe') -ArgumentList $uiArgs -WindowStyle Hidden -Wait -PassThru
    $uiReport = Join-Path $uiRoot 'ui-report.json'
    if (Test-Path -LiteralPath $uiReport) { Copy-Item -LiteralPath $uiReport -Destination (Join-Path $uiReports 'ui-report.json') -Force }
    if ($uiVerification.ExitCode -ne 0 -or !(Test-Path -LiteralPath $uiReport)) { throw ('Les parcours d’interface ont échoué : ' + $uiRoot) }
    if ((Get-Content -LiteralPath $uiReport -Raw -Encoding utf8 | ConvertFrom-Json).success -ne $true) { throw 'Le rapport des parcours d’interface signale un échec.' }
}
$archive = Join-Path $taskRoot ("dist\SuniCapture-$appVersion-win-x64.zip")
Compress-Archive -LiteralPath $destination -DestinationPath $archive -Force
$manifest = Get-FileHash -LiteralPath (Join-Path $destination 'SuniCapture.exe'), $archive -Algorithm SHA256 | ForEach-Object { [pscustomobject]@{ File = Split-Path -Leaf $_.Path; SHA256 = $_.Hash } }
$manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $taskRoot 'dist\SHA256.json') -Encoding utf8
$manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $taskRoot ("dist\SHA256-$appVersion.json")) -Encoding utf8
$archiveHash = Get-FileHash -LiteralPath $archive -Algorithm SHA256
[System.IO.File]::WriteAllText((Join-Path $taskRoot 'dist\SHA256SUMS.txt'), ($archiveHash.Hash.ToLowerInvariant() + '  ' + (Split-Path -Leaf $archive) + "`n"), [System.Text.UTF8Encoding]::new($false))
Write-Output "Application prête : $destination\SuniCapture.exe"
Write-Output "Archive portable : $archive"
