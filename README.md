# SQL Server I/O Profiler

A small PowerShell script that profiles real SQL Server I/O — per-database-file IOPS, throughput, and latency — by sampling `sys.dm_io_virtual_file_stats` on a schedule and computing deltas between runs. Built for sizing storage (e.g. AWS EBS volumes) ahead of a migration, when you want real numbers instead of a guess.

It also captures OS-level disk counters (via PerfMon) alongside the SQL-level numbers, so you can cross-check the two.

## Why this exists

Before resizing or migrating a SQL Server instance, it helps to know your actual peak IOPS and throughput — not an estimate. This script answers that by sampling SQL Server's own I/O counters at an interval you control (e.g. every 5 minutes) over a representative window (a week is a reasonable default), then lets you sort the results to find real peaks. If you're working with an on-prem server, this may not be useful. But in my case, I needed to provision a new AWS EC2 instance to host SQL Server 2025. I wanted to make sure the provisioned IOPS for the EBS volumes would be sufficient to support anticipated production levels. I had no baseline data, so I created this script.

## How it works

The script is designed to run as a **single, short-lived execution**, triggered repeatedly by Windows Task Scheduler — not as a long-running loop. Each run:

1. Loads the previous snapshot from a small state file (`SqlIoState.xml`), if one exists.
2. Takes a fresh snapshot of `sys.dm_io_virtual_file_stats` joined to `sys.master_files`.
3. If a previous snapshot exists, computes the delta (reads, writes, bytes, I/O stall time) and divides by the elapsed time to get real per-second rates.
4. Appends one row per database file to `SqlIoStats.csv`.
5. Captures current PerfMon disk counters and appends them to `DiskCounters.csv`.
6. Saves the current snapshot as the new baseline for the next run.
7. Exits.

Because each run is independent, a reboot, crash, or missed trigger between runs only costs you one missed sample — there's no long-running process to lose.

The first run after a fresh start only establishes a baseline; it won't produce a delta row in `SqlIoStats.csv` until the second run.

## Requirements

- Windows Server (or Windows desktop) with PowerShell — tested on Windows PowerShell 5.1 (Desktop edition).
- A SQL Server login with `VIEW SERVER STATE` permission (or `sysadmin`) on the target instance.
- Permission to read PerfMon counters on the local machine.
- Run as a user/service account with rights to both of the above; running as `SYSTEM` or a dedicated service account via Task Scheduler is recommended so it works whether or not anyone is logged in.

## Setup

1. Copy `Profile-SqlServerIO.ps1` to a folder on the target server, e.g. `C:\SqlIoProfiling`.
2. Open the script and fill in the configuration block at the top:

   ```powershell
   $SqlServerInstance = "<SQL_SERVER_INSTANCE_NAME>"   # e.g. "SQLPROD01" or "SQLPROD01\INSTANCENAME"
   $SqlDatabase       = "master"
   $SqlAuthMode       = "Windows"                       # "Windows" or "SQL"
   $SqlUsername       = "<SQL_LOGIN_USERNAME>"           # only used if $SqlAuthMode = "SQL"
   $SqlPassword       = "<SQL_LOGIN_PASSWORD>"           # only used if $SqlAuthMode = "SQL"
   $DisksToMonitor    = @("*")                           # or e.g. @("D:", "E:", "L:")
   $OutputFolder      = "C:\SqlIoProfiling"
   ```

   If you use SQL authentication, consider replacing the plaintext `$SqlPassword` with a credential prompt or a securely stored secret rather than hardcoding it in the file.

3. Run it once manually to confirm it connects and writes to `ProfileRun.log` without errors.

## Scheduling with Windows Task Scheduler

This script is meant to be triggered repeatedly, not run as a standing process.

1. **Create Task** (not "Basic Task," to get the full set of options).
2. **General tab**: run whether the user is logged on or not; run with highest privileges.
3. **Triggers tab**: On a schedule → Daily → Advanced settings → **Repeat task every** `5 minutes`, for a duration of `1 day` (this repeats indefinitely day over day).
4. **Actions tab**: Start a program →
   - Program: `powershell.exe`
   - Arguments: `-NoProfile -ExecutionPolicy Bypass -File "C:\SqlIoProfiling\Profile-SqlServerIO.ps1"`
5. **Conditions tab**: uncheck "Start the task only if the computer is on AC power" if running on a server.
6. **Settings tab**:
   - Check "Run task as soon as possible after a scheduled start is missed" (resilience against missed triggers).
   - Allow the task to run on demand, and set a generous "stop if it runs longer than" limit (e.g. 10 minutes) rather than a short one.
7. Set "Run as" to a service account (or `SYSTEM`) with the SQL/PerfMon permissions described above.

Let it run for a representative period — a week is a reasonable default — before analyzing results.

## Output

All files are written to `$OutputFolder` (default `C:\SqlIoProfiling`):

| File               | Contents                                                                                                                                                                                                      |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `SqlIoStats.csv`   | One row per database file per run: `Timestamp`, `DatabaseName`, `PhysicalName`, `FileType`, `ElapsedSeconds`, `ReadIOPS`, `WriteIOPS`, `TotalIOPS`, `ThroughputMBps`, `AvgReadLatencyMs`, `AvgWriteLatencyMs` |
| `DiskCounters.csv` | One row per logical disk per run: `Timestamp`, `Disk`, `ReadIOPS`, `WriteIOPS`, `ReadThroughputMBps`, `WriteThroughputMBps`, `AvgDiskSecPerRead`, `AvgDiskSecPerWrite`, `CurrentDiskQueueLength`              |
| `ProfileRun.log`   | One line per execution: connects, errors, and row counts written                                                                                                                                              |
| `SqlIoState.xml`   | Internal — the previous snapshot, used to compute the next delta. Don't edit or delete mid-run.                                                                                                               |

To find your real peaks, sort `SqlIoStats.csv` by `TotalIOPS` and `ThroughputMBps` descending. `ElapsedSeconds` should stay close to your scheduled interval (e.g. ~300 for a 5-minute schedule) once Task Scheduler is running it on its own; large or inconsistent gaps usually mean missed triggers rather than a script problem.

## Notes on the implementation

A couple of details worth knowing if you're modifying this script:

- **The SQL connection type is resolved dynamically** (`System.Data.SqlClient.SqlConnection` or `Microsoft.Data.SqlClient.SqlConnection`), since availability differs between Windows PowerShell 5.1 and PowerShell 7+.
- **The result table is built manually from the `SqlDataReader`** rather than via `DataTable.Load($reader)`, which was observed to produce a corrupted table on at least one tested environment.
- **`Get-SqlIoSnapshot` returns its `DataTable` via `Write-Output -NoEnumerate`.** `DataTable` implements `IEnumerable`, and PowerShell will otherwise unroll it into its individual `DataRow` objects on return — a subtle gotcha worth knowing if you see a function returning loose rows instead of the table you built.

## License

No license specified yet — add one (e.g. MIT) before treating this as open source others can freely reuse.
