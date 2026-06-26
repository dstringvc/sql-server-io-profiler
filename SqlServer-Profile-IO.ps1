<#
.SYNOPSIS
    Takes ONE snapshot of SQL Server I/O (via DMV) and Windows disk counters (via PerfMon),
    computes deltas against the previous run, and appends one row per file/disk to CSV.

.DESCRIPTION
    Designed to be triggered repeatedly by Windows Task Scheduler (e.g. every 5 minutes)
    rather than running as a long-lived loop. Each run is independent and short-lived:
    it loads the prior snapshot from a state file, takes a new snapshot, computes the
    delta (IOPS / throughput / latency), appends results to CSV, then saves the new
    snapshot as the baseline for the next run and exits.

    This means a reboot, crash, or logoff between runs only costs you one missed sample
    instead of losing a week-long in-memory loop.

    Produces (in $OutputFolder, fixed filenames so every run appends to the same files):
      - SqlIoStats.csv      : per-database-file IOPS/throughput/latency deltas
      - DiskCounters.csv    : OS-level disk IOPS/throughput/latency
      - ProfileRun.log      : run log (one line per execution)
      - SqlIoState.xml      : internal state file (previous snapshot) - do not edit/delete mid-run

.NOTES
    Fill in the placeholders in the CONFIGURATION section below before running.
    Requires: PerfMon access and SQL Server connectivity from the host running this script.
    Run this as a SYSTEM or service-account scheduled task so it works whether or not
    anyone is logged in.
#>

# =========================== CONFIGURATION ===========================

# --- SQL Server connection info (fill these in) ---
$SqlServerInstance = "<SQL_SERVER_INSTANCE_NAME>"   # e.g. "SQLPROD01" or "SQLPROD01\INSTANCENAME"
$SqlDatabase       = "master"
$SqlAuthMode       = "Windows"                       # "Windows" or "SQL"
$SqlUsername       = "<SQL_LOGIN_USERNAME>"           # only used if $SqlAuthMode = "SQL"
$SqlPassword       = "<SQL_LOGIN_PASSWORD>"           # only used if $SqlAuthMode = "SQL"
$DisksToMonitor    = @("*")                           # or e.g. @("D:", "E:", "L:")

# --- Output location (fixed filenames - every scheduled run appends to the same files) ---
$OutputFolder      = "C:\SqlIoProfiling"

# --- Disk(s) to monitor via PerfMon ---
# Use "*" for all logical disks, or specify drive letters hosting SQL data/log/tempdb files, e.g. @("D:", "E:", "L:")
$DisksToMonitor = @("*")

# =======================================================================

$ErrorActionPreference = "Stop"

if (-not (Test-Path $OutputFolder)) {
    New-Item -ItemType Directory -Path $OutputFolder | Out-Null
}

$SqlCsvPath   = Join-Path $OutputFolder "SqlIoStats.csv"
$DiskCsvPath  = Join-Path $OutputFolder "DiskCounters.csv"
$LogPath      = Join-Path $OutputFolder "ProfileRun.log"
$StatePath    = Join-Path $OutputFolder "SqlIoState.xml"

function Write-Log {
    param([string]$Message)
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Message"
    Add-Content -Path $LogPath -Value $line
}

# ----------------------- SQL DMV query -----------------------

$SqlIoQuery = @"
SELECT
    DB_NAME(vfs.database_id) AS database_name,
    mf.physical_name,
    mf.type_desc,
    vfs.file_id,
    vfs.database_id,
    vfs.num_of_reads,
    vfs.num_of_writes,
    vfs.num_of_bytes_read,
    vfs.num_of_bytes_written,
    vfs.io_stall_read_ms,
    vfs.io_stall_write_ms
FROM sys.dm_io_virtual_file_stats(NULL, NULL) vfs
JOIN sys.master_files mf
    ON vfs.database_id = mf.database_id AND vfs.file_id = mf.file_id;
"@

function Get-SqlIoSnapshot {
    if ($SqlAuthMode -eq "Windows") {
        $connString = "Server=$SqlServerInstance;Database=$SqlDatabase;Integrated Security=True;Connection Timeout=15;"
    }
    else {
        $connString = "Server=$SqlServerInstance;Database=$SqlDatabase;User Id=$SqlUsername;Password=$SqlPassword;Connection Timeout=15;"
    }

    # Resolve a usable SqlConnection type across PowerShell editions.
    # Windows PowerShell 5.1 ships System.Data.SqlClient in the GAC.
    # PowerShell 7+ does not load it by default - Microsoft.Data.SqlClient
    # (from the SqlServer module / NuGet) or an explicit assembly load is needed.
    $connectionTypeName = $null
    foreach ($candidate in @("System.Data.SqlClient.SqlConnection", "Microsoft.Data.SqlClient.SqlConnection")) {
        if (([System.Management.Automation.PSTypeName]$candidate).Type) {
            $connectionTypeName = $candidate
            break
        }
    }

    if (-not $connectionTypeName) {
        try {
            Add-Type -AssemblyName "System.Data" -ErrorAction SilentlyContinue
        } catch { }
        if (([System.Management.Automation.PSTypeName]"System.Data.SqlClient.SqlConnection").Type) {
            $connectionTypeName = "System.Data.SqlClient.SqlConnection"
        }
    }

    if (-not $connectionTypeName) {
        throw "Neither System.Data.SqlClient.SqlConnection nor Microsoft.Data.SqlClient.SqlConnection could be resolved in this PowerShell session (PSVersion: $($PSVersionTable.PSVersion)). Install the 'SqlServer' module (Install-Module SqlServer -Scope CurrentUser) or run this script under Windows PowerShell 5.1 (powershell.exe, not pwsh.exe)."
    }

    $conn = New-Object -TypeName $connectionTypeName -ArgumentList $connString
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $SqlIoQuery
        $reader = $cmd.ExecuteReader()

        # Build the DataTable manually rather than via DataTable.Load($reader).
        # On this environment, .Load() was observed to produce a corrupted table
        # (21 unnamed columns instead of the actual 11 named columns) even though
        # the reader itself reports the correct schema via FieldCount/GetName.
        $table = New-Object System.Data.DataTable
        for ($i = 0; $i -lt $reader.FieldCount; $i++) {
            [void]$table.Columns.Add($reader.GetName($i), [string])
        }

        & {
            while ($reader.Read()) {
                $newRow = $table.NewRow()
                for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                    if ($reader.IsDBNull($i)) {
                        $newRow[$i] = [DBNull]::Value
                    }
                    else {
                        $newRow[$i] = $reader.GetValue($i).ToString()
                    }
                }
                $table.Rows.Add($newRow)
            }
        } | Out-Null

        # IMPORTANT: DataTable implements IEnumerable. PowerShell automatically unrolls
        # any enumerable placed in the output/return stream into its individual elements
        # (here, into 21 separate DataRow objects) unless explicitly prevented.
        # Write-Output -NoEnumerate is the reliable fix for DataTable specifically -
        # the unary comma operator is a commonly cited workaround but has known edge-case
        # failures with DataTable's particular enumeration behavior.
        Write-Output -NoEnumerate $table
        return
    }
    finally {
        if ($conn.State -ne 'Closed') { $conn.Close() }
        if ($reader -and -not $reader.IsClosed) { $reader.Close() }
    }
}

function Get-IoDelta {
    param($PreviousRows, $CurrentSnapshot, [double]$ElapsedSeconds, [datetime]$SampleEndTime)

    $rows = @()
    foreach ($curRow in $CurrentSnapshot.Rows) {
        $dbId   = [int]$curRow["database_id"]
        $fileId = [int]$curRow["file_id"]

        $prevRow = $PreviousRows | Where-Object {
            $_.database_id -eq $dbId -and $_.file_id -eq $fileId
        } | Select-Object -First 1

        if ($null -eq $prevRow) { continue }  # new file, or first-ever run - no baseline yet, skip

        $readsDelta  = [int64]$curRow["num_of_reads"]  - [int64]$prevRow.num_of_reads
        $writesDelta = [int64]$curRow["num_of_writes"] - [int64]$prevRow.num_of_writes
        $bytesReadDelta    = [int64]$curRow["num_of_bytes_read"]    - [int64]$prevRow.num_of_bytes_read
        $bytesWrittenDelta = [int64]$curRow["num_of_bytes_written"] - [int64]$prevRow.num_of_bytes_written
        $stallReadDelta    = [int64]$curRow["io_stall_read_ms"]     - [int64]$prevRow.io_stall_read_ms
        $stallWriteDelta   = [int64]$curRow["io_stall_write_ms"]    - [int64]$prevRow.io_stall_write_ms

        # Guard against negative deltas (SQL service restart resets counters between runs)
        if ($readsDelta -lt 0 -or $writesDelta -lt 0) { continue }

        $totalIops = if ($ElapsedSeconds -gt 0) { [math]::Round(($readsDelta + $writesDelta) / $ElapsedSeconds, 2) } else { 0 }
        $readIops  = if ($ElapsedSeconds -gt 0) { [math]::Round($readsDelta / $ElapsedSeconds, 2) } else { 0 }
        $writeIops = if ($ElapsedSeconds -gt 0) { [math]::Round($writesDelta / $ElapsedSeconds, 2) } else { 0 }
        $throughputMBps = if ($ElapsedSeconds -gt 0) {
            [math]::Round((($bytesReadDelta + $bytesWrittenDelta) / 1MB) / $ElapsedSeconds, 2)
        } else { 0 }
        $avgReadLatencyMs  = if ($readsDelta -gt 0)  { [math]::Round($stallReadDelta / $readsDelta, 2) } else { 0 }
        $avgWriteLatencyMs = if ($writesDelta -gt 0) { [math]::Round($stallWriteDelta / $writesDelta, 2) } else { 0 }

        $rows += [PSCustomObject]@{
            Timestamp          = $SampleEndTime.ToString("yyyy-MM-dd HH:mm:ss")
            DatabaseName       = $curRow["database_name"]
            PhysicalName       = $curRow["physical_name"]
            FileType           = $curRow["type_desc"]
            ElapsedSeconds     = [math]::Round($ElapsedSeconds, 1)
            ReadIOPS           = $readIops
            WriteIOPS          = $writeIops
            TotalIOPS          = $totalIops
            ThroughputMBps     = $throughputMBps
            AvgReadLatencyMs   = $avgReadLatencyMs
            AvgWriteLatencyMs  = $avgWriteLatencyMs
        }
    }
    return $rows
}

# ----------------------- PerfMon disk counters -----------------------

function Get-DiskCounterSnapshot {
    param([datetime]$SampleTime)

    $counterPaths = @()
    foreach ($disk in $DisksToMonitor) {
        $counterPaths += "\LogicalDisk($disk)\Disk Reads/sec"
        $counterPaths += "\LogicalDisk($disk)\Disk Writes/sec"
        $counterPaths += "\LogicalDisk($disk)\Disk Read Bytes/sec"
        $counterPaths += "\LogicalDisk($disk)\Disk Write Bytes/sec"
        $counterPaths += "\LogicalDisk($disk)\Avg. Disk sec/Read"
        $counterPaths += "\LogicalDisk($disk)\Avg. Disk sec/Write"
        $counterPaths += "\LogicalDisk($disk)\Current Disk Queue Length"
    }

    try {
        $samples = Get-Counter -Counter $counterPaths -ErrorAction Stop
    }
    catch {
        Write-Log "WARNING: Get-Counter failed: $($_.Exception.Message)"
        return @()
    }

    $rows = @()
    $byInstance = $samples.CounterSamples | Group-Object InstanceName

    foreach ($group in $byInstance) {
        $instanceName = $group.Name
        if ($instanceName -eq "_total" -and $DisksToMonitor -notcontains "*") { continue }

        $getVal = { param($pathFragment)
            $s = $group.Group | Where-Object { $_.Path -like "*$pathFragment*" } | Select-Object -First 1
            if ($s) { return [math]::Round($s.CookedValue, 4) } else { return $null }
        }

        $rows += [PSCustomObject]@{
            Timestamp               = $SampleTime.ToString("yyyy-MM-dd HH:mm:ss")
            Disk                    = $instanceName
            ReadIOPS                = & $getVal "Disk Reads/sec"
            WriteIOPS               = & $getVal "Disk Writes/sec"
            ReadThroughputMBps      = $(if ($v = & $getVal "Disk Read Bytes/sec") { [math]::Round($v / 1MB, 2) } else { $null })
            WriteThroughputMBps     = $(if ($v = & $getVal "Disk Write Bytes/sec") { [math]::Round($v / 1MB, 2) } else { $null })
            AvgDiskSecPerRead       = & $getVal "Avg. Disk sec/Read"
            AvgDiskSecPerWrite      = & $getVal "Avg. Disk sec/Write"
            CurrentDiskQueueLength  = & $getVal "Current Disk Queue Length"
        }
    }
    return $rows
}

# ----------------------------- Single run -----------------------------

$sampleTime = Get-Date
Write-Log "Run started. PSVersion: $($PSVersionTable.PSVersion) | PSEdition: $($PSVersionTable.PSEdition)"

# --- Load previous state, if any ---
$previousRows = @()
$previousSampleTime = $null
if (Test-Path $StatePath) {
    try {
        $state = Import-Clixml -Path $StatePath
        $previousRows = $state.Rows
        $previousSampleTime = $state.SampleTime
    }
    catch {
        Write-Log "WARNING: Could not read state file, treating this run as the first baseline. Error: $($_.Exception.Message)"
    }
}

# --- SQL DMV snapshot + delta ---
try {
    $currentSnapshot = Get-SqlIoSnapshot

    if ($null -eq $previousSampleTime) {
        Write-Log "No prior state found - this run establishes the baseline only (no delta row written)."
    }
    else {
        $elapsedSeconds = ($sampleTime - $previousSampleTime).TotalSeconds
        $deltaRows = Get-IoDelta -PreviousRows $previousRows -CurrentSnapshot $currentSnapshot `
                                  -ElapsedSeconds $elapsedSeconds -SampleEndTime $sampleTime

        if ($deltaRows.Count -gt 0) {
            $deltaRows | Export-Csv -Path $SqlCsvPath -Append -NoTypeInformation
            Write-Log "Wrote $($deltaRows.Count) SQL I/O delta rows."
        }
        else {
            Write-Log "No SQL I/O delta rows produced this run (no matching files or zero elapsed time)."
        }
    }

    # Flatten current snapshot into plain objects for serialization (avoids DataTable/Clixml quirks)
    $flatRows = @()
    $rowIndex = 0
    foreach ($r in $currentSnapshot.Rows) {
        $rowIndex++
        try {
            $flatRows += [PSCustomObject]@{
                database_id        = [int]$r["database_id"]
                file_id            = [int]$r["file_id"]
                num_of_reads       = [int64]$r["num_of_reads"]
                num_of_writes      = [int64]$r["num_of_writes"]
                num_of_bytes_read  = [int64]$r["num_of_bytes_read"]
                num_of_bytes_written = [int64]$r["num_of_bytes_written"]
                io_stall_read_ms   = [int64]$r["io_stall_read_ms"]
                io_stall_write_ms  = [int64]$r["io_stall_write_ms"]
            }
        }
        catch {
            $rowDumpParts = New-Object System.Collections.Generic.List[string]
            try {
                for ($ci = 0; $ci -lt $currentSnapshot.Columns.Count; $ci++) {
                    $colName = $currentSnapshot.Columns[$ci].ColumnName
                    $rowDumpParts.Add("$colName=[$($r[$ci])]")
                }
            }
            catch {
                $rowDumpParts.Add("(dump itself failed: $($_.Exception.Message))")
            }
            $rowDump = $rowDumpParts -join ", "
            Write-Log "ERROR: Failed to flatten row $rowIndex : $($_.Exception.Message) | Row contents: $rowDump"
        }
    }

    @{ Rows = $flatRows; SampleTime = $sampleTime } | Export-Clixml -Path $StatePath
}
catch {
    $ex = $_.Exception
    $detail = "$($ex.GetType().FullName): $($ex.Message)"
    $inner = $ex.InnerException
    while ($inner) {
        $detail += " | Inner: $($inner.GetType().FullName): $($inner.Message)"
        $inner = $inner.InnerException
    }
    Write-Log "ERROR: SQL snapshot/delta step failed: $detail"
    Write-Log "ERROR: ScriptStackTrace: $($_.ScriptStackTrace)"
}

# --- Disk counters (no delta needed, these are already rates) ---
try {
    $diskRows = Get-DiskCounterSnapshot -SampleTime $sampleTime
    if ($diskRows.Count -gt 0) {
        $diskRows | Export-Csv -Path $DiskCsvPath -Append -NoTypeInformation
        Write-Log "Wrote $($diskRows.Count) disk counter rows."
    }
}
catch {
    Write-Log "ERROR: Disk counter step failed: $($_.Exception.Message)"
}

Write-Log "Run complete."
