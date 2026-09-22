# --- CONFIGURATION ---
$BaudRate    = 4800         # Check your GPS manual (usually 4800 or 9600)

# Local ISO-8601 offset format safe for Windows filenames (e.g., 2026-07-31T140000-0700)
$LocalOffsetName = (Get-Date).ToString("yyyy-MM-ddTHHmm").Replace(":", "")
$LogFile         = "$env:USERPROFILE\Desktop\FAST-stuff\speed-logs\$LocalOffsetName.csv"
# ---------------------

# Verify Script is Running as Administrator (Required to change system time)
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
    Write-Error "This script must be run as an Administrator to synchronize system time. Please restart PowerShell as Administrator."
    Exit
}

Write-Host "Logging MPH data directly to CSV: $LogFile" -ForegroundColor Cyan

# Create standard RFC-4180 compliant CSV headers
if (-not (Test-Path $LogFile)) {
    Add-Content -Path $LogFile -Value "Timestamp,Speed_MPH"
}

# =========================================================================
# STEP 1: SINGLE INITIALIZATION SCAN FOR THE GPS PORT
# =========================================================================
$TargetPort = $null
$AvailablePorts = [System.IO.Ports.SerialPort]::GetPortNames()

if ($AvailablePorts.Count -eq 0) {
    Write-Error "No active COM ports detected. Plug in your USB GPS and restart the script."
    Exit
}

Write-Host "Scanning active ports to find GPS: [ $($AvailablePorts -join ', ') ]" -ForegroundColor White

foreach ($PortName in $AvailablePorts) {
    Write-Host "Checking port $PortName..."
    $TestPort = New-Object System.IO.Ports.SerialPort $PortName, $BaudRate, "None", 8, "One"
    $TestPort.ReadTimeout = 1500 # Wait a max of 1.5 seconds for data
    foreach ($Attempt in (1, 2, 3, 4, 5)) {
        Write-Host " attempt $Attempt..."
        try {
            $TestPort.Open()
            $SampleLine = $TestPort.ReadLine()
            if ($SampleLine -and $SampleLine.StartsWith("$")) {
                $TargetPort = $PortName
                Write-Host " found!"
                $TestPort.Close()
                break
            }
            $TestPort.Close()
        }
        catch {
            if ($TestPort.IsOpen) { $TestPort.Close() }
        }
        if ($TargetPort) {
            Write-Host " have port, leaving loop"
            break
        }
    }
}

if (-not $TargetPort) {
    Write-Error "GPS device not found on any active COM port. Verify baud rate or connection, then restart script."
    Exit
}

Write-Host "Success! GPS locked on $TargetPort." -ForegroundColor Green
Write-Host "Starting log stream. Press Ctrl+C to stop." -ForegroundColor Yellow


# =========================================================================
# STEP 2: STREAM LOGGING ENGINE (NO RETRY WRAPPERS)
# =========================================================================
$Port = New-Object System.IO.Ports.SerialPort $TargetPort, $BaudRate, "None", 8, "One"
$TimeSynced = $false

try {
    $Port.Open()

    while ($Port.IsOpen) {
        $Line = $Port.ReadLine()

        if ($Line -like "*RMC*") {
            $Parts = $Line.Split(',')

            # --- TIME SYNCHRONIZATION ---
            if (-not $TimeSynced -and $Parts.Count -ge 10 -and $Parts[2] -eq 'A') {
                $GpsTimeStr = $Parts[1] # hhmmss.sss
                $GpsDateStr = $Parts[9] # ddmmyy

                if ($GpsTimeStr -match '^\d{6}' -and $GpsDateStr -match '^\d{6}') {
                    Write-Host "Synchronizing Laptop Time to GPS..." -ForegroundColor Yellow
                    
                    $Day   = [int]$GpsDateStr.Substring(0, 2)
                    $Month = [int]$GpsDateStr.Substring(2, 2)
                    $Year  = [int]("20" + $GpsDateStr.Substring(4, 2))
                    $Hour  = [int]$GpsTimeStr.Substring(0, 2)
                    $Min   = [int]$GpsTimeStr.Substring(2, 2)
                    $Sec   = [int]$GpsTimeStr.Substring(4, 2)

                    $GpsUtcDateTime = New-Object DateTime $Year, $Month, $Day, $Hour, $Min, $Sec, ([DateTimeKind]::Utc)
                    $GpsLocalDateTime = $GpsUtcDateTime.ToLocalTime()
                    
                    Set-Date -Date $GpsLocalDateTime | Out-Null
                    
                    Write-Host "System time successfully synchronized to: $($GpsLocalDateTime.ToString('yyyy-MM-dd HH:mm:sszzz'))" -ForegroundColor Green
                    $TimeSynced = $true
                }
            }

            # --- SPEED LOGGING ---
            if ($Parts.Count -ge 8) {
                $KnotsStr = $Parts[7]

                if ([double]::TryParse($KnotsStr, [ref]0)) {
                    $Knots = [double]$KnotsStr
                    $Mph   = [math]::Round(($Knots * 1.15078), 2)
                    
                    # ISO-8601 formatting wrapped in quotes for Excel cell compatibility
                    $LogTimestamp = (Get-Date).ToString("HH:mm:ss")
                    $LogEntry     = "$LogTimestamp,$Mph"

                    # Print cleanly to console and pipe raw string to CSV file
                    Write-Host "[$LogTimestamp] Speed: $Mph MPH" -ForegroundColor Cyan
                    Add-Content -Path $LogFile -Value $LogEntry
                }
            }
        }
    }
}
catch {
    Write-Host "`nConnection lost or port changed. Script execution terminated: $_" -ForegroundColor Red
}
finally {
    if ($Port) {
        if ($Port.IsOpen) { $Port.Close() }
        $Port.Dispose()
        Write-Host "Port $TargetPort safely closed. Goodbye." -ForegroundColor Gray
    }
}
