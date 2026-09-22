[CmdletBinding()]
param(
    # Optional output directory. Without this, CSV files are written next to inputs.
    [Alias('o')]
    [string]$OutDir,

    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$InputFile,

    [switch]$Help
)

# FastLog2CSV-DragDrop.ps1
# Windows PowerShell 5.1-compatible converter for F.A.S.T. Classic binary logs.
# It can be launched by dropping one or more .log files onto this script.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Show-Usage {
    @'
FastLog2CSV-DragDrop.ps1 - convert F.A.S.T. Classic logs to CSV.

Drag one or more .log files onto this script, or run:
  powershell.exe -File .\FastLog2CSV-DragDrop.ps1 file1.log file2.log

Optional output directory:
  powershell.exe -File .\FastLog2CSV-DragDrop.ps1 -OutDir C:\CSV file1.log
'@ | Write-Host
}

function Read-UInt16LE([byte[]]$Bytes, [int]$Offset) {
    return [BitConverter]::ToUInt16($Bytes, $Offset)
}

function Read-UInt32LE([byte[]]$Bytes, [int]$Offset) {
    return [BitConverter]::ToUInt32($Bytes, $Offset)
}

function Read-SingleLE([byte[]]$Bytes, [int]$Offset) {
    return [BitConverter]::ToSingle($Bytes, $Offset)
}

function Read-AsciiField([byte[]]$Bytes, [int]$Offset, [int]$Length) {
    $value = [Text.Encoding]::ASCII.GetString($Bytes, $Offset, $Length)
    $nul = $value.IndexOf([char]0)
    if ($nul -ge 0) { $value = $value.Substring(0, $nul) }
    return $value.Trim()
}

# Write one CSV field without Export-Csv. Quoting is still required for valid CSV.
function Write-CsvField([Text.StringBuilder]$Builder, [object]$Value) {
    $text = [string]$Value
    [void]$Builder.Append('"')
    [void]$Builder.Append($text.Replace('"', '""'))
    [void]$Builder.Append('"')
}

function Write-CsvRow([Text.StringBuilder]$Builder, [object[]]$Values) {
    for ($i = 0; $i -lt $Values.Count; $i++) {
        if ($i -gt 0) { [void]$Builder.Append(',') }
        Write-CsvField $Builder $Values[$i]
    }
    [void]$Builder.AppendLine()
}

if ($Help -or ($InputFile.Count -eq 0)) {
    Show-Usage
    if ($Help) { exit 0 }
    Write-Warning 'No input files were supplied.'
    if ([Environment]::UserInteractive) {
        Read-Host 'Press Enter to close'
    }
    exit 1
}

if ($OutDir) {
    if (-not (Test-Path -LiteralPath $OutDir -PathType Container)) {
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    }
    $OutDir = (Resolve-Path -LiteralPath $OutDir).Path
}

$converted = 0
$failed = 0

foreach ($inputName in $InputFile) {
    try {
        $source = Get-Item -LiteralPath $inputName -ErrorAction Stop
        if ($source.PSIsContainer) { throw 'input is a directory, not a file' }

        $bytes = [IO.File]::ReadAllBytes($source.FullName)
        if ($bytes.Length -lt 0x210) {
            throw 'file too small to be a FAST log'
        }

        $channelCount = Read-UInt16LE $bytes 2
        if ($channelCount -lt 1 -or $channelCount -gt 32) {
            throw "implausible channel count $channelCount; not a FAST Classic log?"
        }

        $definitionOffset = 0x204
        $definitionSize = 58
        $dataOffset = $definitionOffset + ($definitionSize * $channelCount) + 22
        if ($dataOffset -gt $bytes.Length) {
            throw 'file ends before the channel definitions or data'
        }

        $channels = @()
        for ($i = 0; $i -lt $channelCount; $i++) {
            $offset = $definitionOffset + ($definitionSize * $i)
            $name = Read-AsciiField $bytes $offset 16
            $units = Read-AsciiField $bytes ($offset + 16) 8
            $scale = Read-SingleLE $bytes ($offset + 30)
            $channelOffset = Read-SingleLE $bytes ($offset + 34)

            if ($name.ToUpperInvariant().StartsWith('MAP') -and $scale -eq 1.0) {
                $scale = 14.7 / 245.0
            }

            $column = $name
            if ($units -and -not $name.Contains($units)) {
                $column = "$name [$units]"
            }

            $channels += [PSCustomObject]@{
                Name = $column
                Scale = [double]$scale
                Offset = [double]$channelOffset
            }
        }

        $recordSize = (2 * $channelCount) + 4
        $recordCount = [math]::Floor(($bytes.Length - $dataOffset) / $recordSize)
        $previousTimestamp = [int64]-1
        $firstTime = $null
        $lastTime = $null
        $recordsWritten = 0
        $csv = New-Object Text.StringBuilder

        Write-CsvRow $csv (@('Time_s') + @($channels | ForEach-Object { $_.Name }))

        for ($record = 0; $record -lt $recordCount; $record++) {
            $offset = $dataOffset + ($record * $recordSize)
            $timestamp = [int64](Read-UInt32LE $bytes ($offset + (2 * $channelCount)))
            if ($timestamp -lt $previousTimestamp) { break }
            $previousTimestamp = $timestamp

            $time = $timestamp / 1000.0
            if ($null -eq $firstTime) { $firstTime = $time }
            $lastTime = $time

            $values = New-Object object[] ($channelCount + 1)
            $values[0] = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.####}', $time)

            for ($channel = 0; $channel -lt $channelCount; $channel++) {
                $raw = Read-UInt16LE $bytes ($offset + (2 * $channel))
                $value = ($raw * $channels[$channel].Scale) + $channels[$channel].Offset
                $values[$channel + 1] = [string]::Format(
                    [Globalization.CultureInfo]::InvariantCulture,
                    '{0:0.####}',
                    $value
                )
            }

            Write-CsvRow $csv $values
            $recordsWritten++
        }

        if ($recordsWritten -eq 0) {
            throw 'no valid data records found'
        }

        if ($OutDir) {
            $destination = Join-Path $OutDir ($source.BaseName + '.csv')
        } else {
            $destination = Join-Path $source.DirectoryName ($source.BaseName + '.csv')
        }

        # UTF-8 without a BOM, compatible with the shell version and common tools.
        [IO.File]::WriteAllText($destination, $csv.ToString(), (New-Object Text.UTF8Encoding($false)))

        $duration = $lastTime - $firstTime
        Write-Host ('{0}: {1} records, {2} channels, {3:0.0}s -> {4}' -f `
            $source.FullName, $recordsWritten, $channelCount, $duration, $destination)
        $converted++
    }
    catch {
        Write-Warning ('{0}: {1}' -f $inputName, $_.Exception.Message)
        $failed++
    }
}

Write-Host ("Completed: {0} converted, {1} failed." -f $converted, $failed)

# Keep a drag-and-drop console window open long enough to read the result.
if ([Environment]::UserInteractive) {
    Read-Host 'Press Enter to close'
}

if ($failed -gt 0) { exit 1 }
