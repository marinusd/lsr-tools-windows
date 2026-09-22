<#
.SYNOPSIS
    Convert the C-Com WP working log (C:\CComWP\Log\temp.log) to CSV.

.DESCRIPTION
    Fixed-path variant of fastlog2csv.ps1 for Windows PowerShell 5.1.
    Reads   C:\CComWP\Log\temp.log
    Writes  C:\CComWP\Log\FAST-YYYY-MM-DDTHHMM.csv
    The timestamp is the log file's last-modified time, i.e. when the
    logging session ended, so re-running the conversion on the same log
    produces the same file name (overwritten, not duplicated).

    Format (reverse-engineered):
      0x000   ASCII version ("22"), u16 channel count N, N u16 channel ids
      0x204   N channel definitions, 58 bytes each:
                name[16] units[8] u16 u16 u16 f32_scale f32_offset
                u16 raw_min u16 raw_max f32 disp_max f32 disp_min fmt[8]
      defs+22 data records: N x u16 raw values + u32 timestamp (ms)
      Engineering value = raw * scale + offset.
      MAP stored as raw counts (scale 1.0) is converted to psia using
      14.7/245 (calibrated from the engine-off atmospheric reading).
      Coolant and air temp remain raw sensor counts.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\fastlog2csv-temp.ps1
#>
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$src    = 'C:\CComWP\Log\temp.log'
$outDir = Split-Path -Parent $src

$inv       = [System.Globalization.CultureInfo]::InvariantCulture   # always '.' decimals
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$DEF0  = 0x204
$DEFSZ = 58
$MAP_PSIA_PER_COUNT = 14.7 / 245

function Get-CString([byte[]]$buf, [int]$off, [int]$len) {
    $end = $off
    while ($end -lt $off + $len -and $buf[$end] -ne 0) { $end++ }
    return [System.Text.Encoding]::ASCII.GetString($buf, $off, $end - $off).Trim()
}

function Format-CsvField([string]$s) {
    if ($s -match '[",\r\n]') { return '"' + $s.Replace('"', '""') + '"' }
    return $s
}

function Format-Num([double]$v) {
    return [Math]::Round($v, 4).ToString('0.0###', $inv)
}

try {
    if (-not (Test-Path -LiteralPath $src)) { throw "input not found: $src" }

    $d = [System.IO.File]::ReadAllBytes($src)
    if ($d.Length -lt 0x210) { throw "${src}: file too small to be a FAST log" }

    $nchan = [BitConverter]::ToUInt16($d, 2)
    if ($nchan -lt 1 -or $nchan -gt 32) {
        throw "${src}: implausible channel count $nchan; not a FAST Classic log?"
    }
    if ($d.Length -lt $DEF0 + $DEFSZ * $nchan + 22) { throw "${src}: truncated channel header" }

    # Channel definitions
    $cols   = New-Object string[] $nchan
    $scale  = New-Object double[] $nchan
    $offset = New-Object double[] $nchan
    for ($i = 0; $i -lt $nchan; $i++) {
        $o     = $DEF0 + $DEFSZ * $i
        $name  = Get-CString $d $o 16
        $units = Get-CString $d ($o + 16) 8
        $sc    = [double][BitConverter]::ToSingle($d, $o + 30)
        $off   = [double][BitConverter]::ToSingle($d, $o + 34)

        if (-not $units -or $name.Contains($units)) { $col = $name }
        else { $col = "$name [$units]" }

        if ($name.ToUpper().StartsWith('MAP') -and $sc -eq 1.0) { $sc = $MAP_PSIA_PER_COUNT }

        $cols[$i] = $col; $scale[$i] = $sc; $offset[$i] = $off
    }

    # Data records
    $data0 = $DEF0 + $DEFSZ * $nchan + 22
    $recsz = 2 * $nchan + 4
    $nrec  = [Math]::Floor(($d.Length - $data0) / $recsz)

    $lines = New-Object System.Collections.Generic.List[string]
    $hdr = @('Time_s') + ($cols | ForEach-Object { Format-CsvField $_ })
    $lines.Add($hdr -join ',')

    $prevTs = -1L; $firstT = $null; $lastT = $null; $count = 0
    $fields = New-Object string[] ($nchan + 1)
    $o = $data0
    for ($r = 0; $r -lt $nrec; $r++) {
        $ts = [long][BitConverter]::ToUInt32($d, $o + 2 * $nchan)
        if ($ts -lt $prevTs) { break }   # non-monotonic time: past end of data
        $prevTs = $ts
        $t = $ts / 1000.0
        if ($null -eq $firstT) { $firstT = $t }
        $lastT = $t

        $fields[0] = $t.ToString('0.0##', $inv)
        for ($c = 0; $c -lt $nchan; $c++) {
            $raw = [BitConverter]::ToUInt16($d, $o + 2 * $c)
            $fields[$c + 1] = Format-Num ($raw * $scale[$c] + $offset[$c])
        }
        $lines.Add($fields -join ',')
        $count++
        $o += $recsz
    }
    if ($count -eq 0) { throw "${src}: no valid data records found" }

    # Output name from the log's last-modified time, e.g. FAST-2025-12-07T1436.csv
    $stamp = (Get-Item -LiteralPath $src).LastWriteTime.ToString("yyyy-MM-dd'T'HHmm", $inv)
    $dst   = Join-Path $outDir "FAST-$stamp.csv"

    [System.IO.File]::WriteAllLines($dst, $lines.ToArray(), $utf8NoBom)
    $dur = ($lastT - $firstT).ToString('0.0', $inv)
    Write-Host "${src}: $count records, $nchan channels, ${dur}s -> $dst"
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
