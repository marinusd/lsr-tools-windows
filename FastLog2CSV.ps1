[CmdletBinding()]
param(
    # Output directory. If omitted, each CSV is written next to its input log.
    [Alias('o')]
    [string]$OutDir,

    # One or more F.A.S.T. Classic log files.
    [Parameter(Mandatory = $true, Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$InputFile
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Show-Usage {
    @"
FastLog2CSV.ps1 - convert F.A.S.T. Classic (C-Com WP) binary datalogs to CSV.

Usage:
  .\FastLog2CSV.ps1 [-OutDir <directory>] <file1.log> [<file2.log> ...]

Writes <name>.csv next to each input, or into OutDir when specified.
"@ | Write-Output
}

function Read-UInt16LE([byte[]]$Bytes, [int]$Offset) {
    [BitConverter]::ToUInt16($Bytes, $Offset)
}

function Read-UInt32LE([byte[]]$Bytes, [int]$Offset) {
    [BitConverter]::ToUInt32($Bytes, $Offset)
}

function Read-SingleLE([byte[]]$Bytes, [int]$Offset) {
    [BitConverter]::ToSingle($Bytes, $Offset)
}

function Read-AsciiField([byte[]]$Bytes, [int]$Offset, [int]$Length) {
    $value = [Text.Encoding]::ASCII.GetString($Bytes, $Offset, $Length)
    $nul = $value.IndexOf([char]0)
    if ($nul -ge 0) { $value = $value.Substring(0, $nul) }
    $value.Trim()
}

function ConvertTo-CsvField([object]$Value) {
    $text = [string]$Value
    '"' + $text.Replace('"', '""') + '"'
}

if ($OutDir) {
    if (-not (Test-Path -LiteralPath $OutDir -PathType Container)) {
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    }
    $OutDir = (Resolve-Path -LiteralPath $OutDir).Path
}

foreach ($inputName in $InputFile) {
    try {
        $source = Get-Item -LiteralPath $inputName -ErrorAction Stop
        if ($source.PSIsContainer) { throw "not a file" }
        $bytes = [IO.File]::ReadAllBytes($source.FullName)

        if ($bytes.Length -lt 0x210) {
            throw "file too small to be a FAST log"
        }

        $channelCount = Read-UInt16LE $bytes 2
        if ($channelCount -lt 1 -or $channelCount -gt 32) {
            throw "implausible channel count $channelCount; not a FAST Classic log?"
        }

        $definitionOffset = 0x204
        $definitionSize = 58
        $dataOffset = $definitionOffset + ($definitionSize * $channelCount) + 22
        if ($dataOffset -gt $bytes.Length) {
            throw "file ends before the channel definitions or data"
        }

        $channels = @()
        for ($i = 0; $i -lt $channelCount; $i++) {
            $offset = $definitionOffset + ($definitionSize * $i)
            $name = Read-AsciiField $bytes $offset 16
            $units = Read-AsciiField $bytes ($offset + 16) 8
            $scale = Read-SingleLE $bytes ($offset + 30)
            $channelOffset = Read-SingleLE $bytes ($offset + 34)

            # MAP channels with a scale of 1 are raw sensor counts in these logs.
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
        $rows = New-Object System.Collections.Generic.List[string]
        $previousTimestamp = [int64]-1
        $firstTime = $null
        $lastTime = $null

        $header = @('Time_s') + @($channels | ForEach-Object { $_.Name })
        $rows.Add(($header | ForEach-Object { ConvertTo-CsvField $_ }) -join ',')

        for ($record = 0; $record -lt $recordCount; $record++) {
            $offset = $dataOffset + ($record * $recordSize)
            $timestamp = [int64](Read-UInt32LE $bytes ($offset + (2 * $channelCount)))
            if ($timestamp -lt $previousTimestamp) { break }
            $previousTimestamp = $timestamp
            $time = $timestamp / 1000.0
            if ($null -eq $firstTime) { $firstTime = $time }
            $lastTime = $time

            $fields = New-Object System.Collections.Generic.List[string]
            $fields.Add((ConvertTo-CsvField ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.####}', $time))))
            for ($channel = 0; $channel -lt $channelCount; $channel++) {
                $raw = Read-UInt16LE $bytes ($offset + (2 * $channel))
                $value = ($raw * $channels[$channel].Scale) + $channels[$channel].Offset
                $formatted = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0:0.####}', $value)
                $fields.Add((ConvertTo-CsvField $formatted))
            }
            $rows.Add($fields -join ',')
        }

        if ($null -eq $firstTime) {
            throw 'no valid data records found'
        }

        if ($OutDir) {
            $destination = Join-Path $OutDir ($source.BaseName + '.csv')
        } else {
            $destination = Join-Path $source.DirectoryName ($source.BaseName + '.csv')
        }
        [IO.File]::WriteAllLines($destination, $rows, (New-Object Text.UTF8Encoding($false)))

        $duration = $lastTime - $firstTime
        '{0}: {1} records, {2} channels, {3:0.0}s -> {4}' -f $source.FullName, ($rows.Count - 1), $channelCount, $duration, $destination
    } catch {
        Write-Error ("{0}: {1}" -f $inputName, $_.Exception.Message)
    }
}
