USE StableClassDemo;
GO

/*
===============================================================================
 BENCHMARK V2 - SEPARATED SCENARIOS
===============================================================================

Goal
----
Measure the framework in scenarios that isolate different properties:

A) APPEND-ONLY
   Shows the direct effect of the rotating window:
       many INSERTs
       zero UPDATE
       zero DELETE
       dirty classes <= window size

B) APPEND-HEAVY
   Target-style workload:
       many INSERTs
       few UPDATEs
       very few DELETEs

C) HIGH-CHURN
   Adversarial workload:
       many INSERTs
       many UPDATEs
       many DELETEs
   It is expected that dirty classes can approach total_classes.

D) ROTATING CYCLE
   Multiple INSERT-only runs.
   Shows how a temporary imbalance produced by one active window is
   redistributed as the window rotates through the full class space.

This is a performance benchmark, not a production-capacity claim.
Run each configuration multiple times and report the median.

FINALIZE LIFECYCLE
------------------
In the current framework, a successful FINALIZE also removes the operational
staging for that RunId:

    refresh_run_row
    refresh_run_delete
    refresh_run_dirty_class

while refresh_run remains as lightweight audit history.

Therefore finalize_ms includes the cost of this cleanup. Results generated
with this version should not be compared directly with benchmark results
captured before staging cleanup was added to FINALIZE.

IMPORTANT
---------
Change the configuration ONLY ONCE in the CONFIG section below.
===============================================================================
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;

/*
Optional diagnostics:

SET STATISTICS TIME ON;
SET STATISTICS IO ON;
*/

/* ============================================================================
   CLEANUP PREVIOUS BENCHMARK OBJECTS / STATE

   Cleanup is performed per RunId instead of DELETE ... JOIN against the
   potentially large global staging tables.

   This avoids requesting a large memory grant just to remove the relatively
   small set of runs belonging to these benchmark processes.
============================================================================ */
DECLARE @BenchProcessIds TABLE
(
    process_id int PRIMARY KEY
);

DECLARE @CleanupRunId uniqueidentifier;

INSERT @BenchProcessIds(process_id)
SELECT process_id
FROM dbo.refresh_process
WHERE process_name IN
(
    N'bench_append_only',
    N'bench_append_heavy',
    N'bench_high_churn',
    N'bench_rotation_cycle'
);

DECLARE benchmark_cleanup_cursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT r.run_id
    FROM dbo.refresh_run AS r
    INNER JOIN @BenchProcessIds AS x
        ON x.process_id = r.process_id;

OPEN benchmark_cleanup_cursor;

FETCH NEXT FROM benchmark_cleanup_cursor INTO @CleanupRunId;

WHILE @@FETCH_STATUS = 0
BEGIN
    DELETE FROM dbo.refresh_run_dirty_class
    WHERE run_id = @CleanupRunId;

    DELETE FROM dbo.refresh_run_delete
    WHERE run_id = @CleanupRunId;

    DELETE FROM dbo.refresh_run_row
    WHERE run_id = @CleanupRunId;

    DELETE FROM dbo.refresh_run
    WHERE run_id = @CleanupRunId;

    FETCH NEXT FROM benchmark_cleanup_cursor INTO @CleanupRunId;
END;

CLOSE benchmark_cleanup_cursor;
DEALLOCATE benchmark_cleanup_cursor;

DELETE m
FROM dbo.class_memory AS m
INNER JOIN @BenchProcessIds AS x
    ON x.process_id = m.process_id;

DELETE p
FROM dbo.refresh_process AS p
INNER JOIN @BenchProcessIds AS x
    ON x.process_id = p.process_id;

DROP VIEW IF EXISTS dbo.vw_bench_v2_adapter;
DROP TABLE IF EXISTS dbo.bench_v2_source;
GO

CREATE TABLE dbo.bench_v2_source
(
    source_key       nvarchar(100) NOT NULL
        CONSTRAINT PK_bench_v2_source PRIMARY KEY,
    event_timestamp  datetime2(7) NOT NULL,
    value_text       nvarchar(200) NOT NULL
);
GO

CREATE VIEW dbo.vw_bench_v2_adapter
AS
SELECT
    CONVERT(nvarchar(450), source_key) AS source_key,
    event_timestamp,
    (
        SELECT
            source_key AS [source_key],
            event_timestamp AS [event_timestamp],
            value_text AS [value_text]
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    ) AS payload_json
FROM dbo.bench_v2_source;
GO

/* ============================================================================
   CONFIG
   Change values here only.
============================================================================ */
DECLARE
    @BaseRows              int = 100000,
    @TotalClasses          int = 100,
    @WindowSize            int = 10,

    @AppendOnlyInserts     int = 5000,

    @AppendHeavyInserts    int = 5000,
    @AppendHeavyUpdates    int = 10,
    @AppendHeavyDeletes    int = 10,

    @HighChurnInserts      int = 5000,
    @HighChurnUpdates      int = 5000,
    @HighChurnDeletes      int = 1000,

    @RotationRuns          int = 10,
    @RotationInsertPerRun  int = 5000;

IF @BaseRows < 1
    THROW 57300, 'BaseRows must be > 0.', 1;

IF @TotalClasses < 1
    THROW 57301, 'TotalClasses must be > 0.', 1;

IF @WindowSize < 1 OR @WindowSize > @TotalClasses
    THROW 57302, 'Invalid WindowSize.', 1;

IF @AppendHeavyUpdates + @AppendHeavyDeletes > @BaseRows
    THROW 57303, 'Scenario B: UPDATE + DELETE exceeds BaseRows.', 1;

IF @HighChurnUpdates + @HighChurnDeletes > @BaseRows
    THROW 57304, 'Scenario C: UPDATE + DELETE exceeds BaseRows.', 1;

IF @RotationRuns < 1 OR @RotationInsertPerRun < 1
    THROW 57305, 'Scenario D: invalid configuration.', 1;


/* ============================================================================
   RESULT TABLES

   The DROP statements make the benchmark safely rerunnable in the same SSMS
   session after a timeout or an interrupted execution.
============================================================================ */
DROP TABLE IF EXISTS #Rotation;
DROP TABLE IF EXISTS #Balance;
DROP TABLE IF EXISTS #Metrics;

CREATE TABLE #Metrics
(
    scenario          varchar(30) NOT NULL,
    phase             varchar(40) NOT NULL,
    source_rows       bigint NULL,
    run_rows          bigint NULL,
    dirty_classes     int NULL,
    insert_count      bigint NULL,
    update_count      bigint NULL,
    delete_count      bigint NULL,
    elapsed_ms        bigint NOT NULL
);

CREATE TABLE #Balance
(
    scenario              varchar(30) NOT NULL,
    classes_with_rows     int NOT NULL,
    min_rows_per_class    bigint NOT NULL,
    max_rows_per_class    bigint NOT NULL,
    avg_rows_per_class    decimal(19,2) NOT NULL,
    max_min_spread        bigint NOT NULL
);

CREATE TABLE #Rotation
(
    run_number                  int NOT NULL,
    window_start_class          int NOT NULL,
    candidate_next_start        int NOT NULL,
    dirty_classes               int NOT NULL,
    inserted_rows               bigint NOT NULL,
    prepare_ms                  bigint NOT NULL,
    finalize_ms                 bigint NOT NULL,
    min_rows_per_class          bigint NOT NULL,
    max_rows_per_class          bigint NOT NULL,
    avg_rows_per_class          decimal(19,2) NOT NULL,
    max_min_spread              bigint NOT NULL
);


/* ============================================================================
   SCENARIO A - APPEND ONLY
============================================================================ */
PRINT '============================================================';
PRINT 'SCENARIO A - APPEND ONLY';
PRINT '============================================================';

TRUNCATE TABLE dbo.bench_v2_source;

DECLARE
    @T0 datetime2(7),
    @T1 datetime2(7),
    @RunId uniqueidentifier;

SET @T0 = SYSDATETIME();

;WITH n AS
(
    SELECT TOP (@BaseRows)
        ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS rn
    FROM sys.all_objects AS a
    CROSS JOIN sys.all_objects AS b
)
INSERT dbo.bench_v2_source
(
    source_key,
    event_timestamp,
    value_text
)
SELECT
    N'B' + RIGHT(REPLICATE(N'0', 12) + CONVERT(nvarchar(20), rn), 12),
    DATEADD(second, CONVERT(int, rn % 86400),
        CONVERT(datetime2(7), '2026-01-01T00:00:00')),
    N'base-' + CONVERT(nvarchar(20), rn)
FROM n;

SET @T1 = SYSDATETIME();

INSERT #Metrics
VALUES
(
    'A_APPEND_ONLY',
    'source_generation',
    @BaseRows,
    NULL, NULL, NULL, NULL, NULL,
    DATEDIFF_BIG(millisecond, @T0, @T1)
);

EXEC dbo.usp_register_refresh_process
    @ProcessName = N'bench_append_only',
    @AdapterSchema = N'dbo',
    @AdapterView = N'vw_bench_v2_adapter',
    @TotalClasses = @TotalClasses,
    @DefaultInsertWindowSize = @WindowSize;

SET @T0 = SYSDATETIME();

EXEC dbo.usp_prepare_bootstrap_run
    @ProcessName = N'bench_append_only',
    @RunId = @RunId OUTPUT;

SET @T1 = SYSDATETIME();

INSERT #Metrics
SELECT
    'A_APPEND_ONLY',
    'bootstrap_prepare',
    (SELECT COUNT_BIG(*) FROM dbo.bench_v2_source),
    (SELECT COUNT_BIG(*) FROM dbo.refresh_run_row WHERE run_id = @RunId),
    (SELECT COUNT(*) FROM dbo.refresh_run_dirty_class WHERE run_id = @RunId),
    r.insert_count,
    r.update_count,
    r.delete_count,
    DATEDIFF_BIG(millisecond, @T0, @T1)
FROM dbo.refresh_run AS r
WHERE r.run_id = @RunId;

SET @T0 = SYSDATETIME();

EXEC dbo.usp_finalize_refresh_run
    @RunId = @RunId;

SET @T1 = SYSDATETIME();

INSERT #Metrics
VALUES
(
    'A_APPEND_ONLY',
    'bootstrap_finalize',
    (SELECT COUNT_BIG(*) FROM dbo.bench_v2_source),
    (SELECT COUNT_BIG(*)
     FROM dbo.class_memory AS m
     INNER JOIN dbo.refresh_process AS p ON p.process_id = m.process_id
     WHERE p.process_name = N'bench_append_only'),
    NULL, NULL, NULL, NULL,
    DATEDIFF_BIG(millisecond, @T0, @T1)
);

/* INSERT only ------------------------------------------------------------- */
SET @T0 = SYSDATETIME();

;WITH n AS
(
    SELECT TOP (@AppendOnlyInserts)
        ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS rn
    FROM sys.all_objects AS a
    CROSS JOIN sys.all_objects AS b
)
INSERT dbo.bench_v2_source
(
    source_key,
    event_timestamp,
    value_text
)
SELECT
    N'A' + RIGHT(REPLICATE(N'0', 12) + CONVERT(nvarchar(20), rn), 12),
    DATEADD(second, CONVERT(int, rn % 86400),
        CONVERT(datetime2(7), '2026-02-01T00:00:00')),
    N'append-only-' + CONVERT(nvarchar(20), rn)
FROM n;

SET @T1 = SYSDATETIME();

INSERT #Metrics
VALUES
(
    'A_APPEND_ONLY',
    'source_mutation',
    (SELECT COUNT_BIG(*) FROM dbo.bench_v2_source),
    NULL, NULL, NULL, NULL, NULL,
    DATEDIFF_BIG(millisecond, @T0, @T1)
);

SET @RunId = NULL;
SET @T0 = SYSDATETIME();

EXEC dbo.usp_prepare_incremental_run
    @ProcessName = N'bench_append_only',
    @RunId = @RunId OUTPUT;

SET @T1 = SYSDATETIME();

INSERT #Metrics
SELECT
    'A_APPEND_ONLY',
    'incremental_prepare',
    (SELECT COUNT_BIG(*) FROM dbo.bench_v2_source),
    (SELECT COUNT_BIG(*) FROM dbo.refresh_run_row WHERE run_id = @RunId),
    (SELECT COUNT(*) FROM dbo.refresh_run_dirty_class WHERE run_id = @RunId),
    r.insert_count,
    r.update_count,
    r.delete_count,
    DATEDIFF_BIG(millisecond, @T0, @T1)
FROM dbo.refresh_run AS r
WHERE r.run_id = @RunId;

/* Main invariant of Scenario A. */
IF
(
    SELECT COUNT(*)
    FROM dbo.refresh_run_dirty_class
    WHERE run_id = @RunId
) > @WindowSize
    THROW 57310, 'Scenario A FAILED: INSERT-only exceeded WindowSize dirty classes.', 1;

SET @T0 = SYSDATETIME();

EXEC dbo.usp_finalize_refresh_run
    @RunId = @RunId;

SET @T1 = SYSDATETIME();

INSERT #Metrics
VALUES
(
    'A_APPEND_ONLY',
    'incremental_finalize',
    (SELECT COUNT_BIG(*) FROM dbo.bench_v2_source),
    (SELECT COUNT_BIG(*)
     FROM dbo.class_memory AS m
     INNER JOIN dbo.refresh_process AS p ON p.process_id = m.process_id
     WHERE p.process_name = N'bench_append_only'),
    NULL, NULL, NULL, NULL,
    DATEDIFF_BIG(millisecond, @T0, @T1)
);

/* Full comparison --------------------------------------------------------- */
SET @RunId = NULL;
SET @T0 = SYSDATETIME();

EXEC dbo.usp_prepare_full_run
    @ProcessName = N'bench_append_only',
    @RunId = @RunId OUTPUT;

SET @T1 = SYSDATETIME();

INSERT #Metrics
SELECT
    'A_APPEND_ONLY',
    'full_prepare',
    (SELECT COUNT_BIG(*) FROM dbo.bench_v2_source),
    (SELECT COUNT_BIG(*) FROM dbo.refresh_run_row WHERE run_id = @RunId),
    (SELECT COUNT(*) FROM dbo.refresh_run_dirty_class WHERE run_id = @RunId),
    r.insert_count,
    r.update_count,
    r.delete_count,
    DATEDIFF_BIG(millisecond, @T0, @T1)
FROM dbo.refresh_run AS r
WHERE r.run_id = @RunId;

SET @T0 = SYSDATETIME();

EXEC dbo.usp_finalize_refresh_run
    @RunId = @RunId;

SET @T1 = SYSDATETIME();

INSERT #Metrics
VALUES
(
    'A_APPEND_ONLY',
    'full_finalize',
    (SELECT COUNT_BIG(*) FROM dbo.bench_v2_source),
    (SELECT COUNT_BIG(*)
     FROM dbo.class_memory AS m
     INNER JOIN dbo.refresh_process AS p ON p.process_id = m.process_id
     WHERE p.process_name = N'bench_append_only'),
    NULL, NULL, NULL, NULL,
    DATEDIFF_BIG(millisecond, @T0, @T1)
);

;WITH class_sizes AS
(
    SELECT
        m.class_id,
        COUNT_BIG(*) AS rows_in_class
    FROM dbo.class_memory AS m
    INNER JOIN dbo.refresh_process AS p ON p.process_id = m.process_id
    WHERE p.process_name = N'bench_append_only'
    GROUP BY m.class_id
)
INSERT #Balance
SELECT
    'A_APPEND_ONLY',
    COUNT(*),
    MIN(rows_in_class),
    MAX(rows_in_class),
    CAST(AVG(CONVERT(decimal(19,4), rows_in_class)) AS decimal(19,2)),
    MAX(rows_in_class) - MIN(rows_in_class)
FROM class_sizes;


/* ============================================================================
   SCENARIO B - APPEND HEAVY
============================================================================ */
PRINT '============================================================';
PRINT 'SCENARIO B - APPEND HEAVY';
PRINT '============================================================';

TRUNCATE TABLE dbo.bench_v2_source;

SET @T0 = SYSDATETIME();

;WITH n AS
(
    SELECT TOP (@BaseRows)
        ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS rn
    FROM sys.all_objects AS a
    CROSS JOIN sys.all_objects AS b
)
INSERT dbo.bench_v2_source
(
    source_key,
    event_timestamp,
    value_text
)
SELECT
    N'B' + RIGHT(REPLICATE(N'0', 12) + CONVERT(nvarchar(20), rn), 12),
    DATEADD(second, CONVERT(int, rn % 86400),
        CONVERT(datetime2(7), '2026-01-01T00:00:00')),
    N'base-' + CONVERT(nvarchar(20), rn)
FROM n;

SET @T1 = SYSDATETIME();

INSERT #Metrics
VALUES
(
    'B_APPEND_HEAVY',
    'source_generation',
    @BaseRows,
    NULL, NULL, NULL, NULL, NULL,
    DATEDIFF_BIG(millisecond, @T0, @T1)
);

EXEC dbo.usp_register_refresh_process
    @ProcessName = N'bench_append_heavy',
    @AdapterSchema = N'dbo',
    @AdapterView = N'vw_bench_v2_adapter',
    @TotalClasses = @TotalClasses,
    @DefaultInsertWindowSize = @WindowSize;

SET @RunId = NULL;
SET @T0 = SYSDATETIME();

EXEC dbo.usp_prepare_bootstrap_run
    @ProcessName = N'bench_append_heavy',
    @RunId = @RunId OUTPUT;

SET @T1 = SYSDATETIME();

INSERT #Metrics
SELECT
    'B_APPEND_HEAVY',
    'bootstrap_prepare',
    @BaseRows,
    (SELECT COUNT_BIG(*) FROM dbo.refresh_run_row WHERE run_id = @RunId),
    (SELECT COUNT(*) FROM dbo.refresh_run_dirty_class WHERE run_id = @RunId),
    r.insert_count,
    r.update_count,
    r.delete_count,
    DATEDIFF_BIG(millisecond, @T0, @T1)
FROM dbo.refresh_run AS r
WHERE r.run_id = @RunId;

SET @T0 = SYSDATETIME();
EXEC dbo.usp_finalize_refresh_run @RunId = @RunId;
SET @T1 = SYSDATETIME();

INSERT #Metrics
VALUES
(
    'B_APPEND_HEAVY',
    'bootstrap_finalize',
    @BaseRows,
    @BaseRows,
    NULL, NULL, NULL, NULL,
    DATEDIFF_BIG(millisecond, @T0, @T1)
);

/* Few UPDATEs. */
SET @T0 = SYSDATETIME();

;WITH target AS
(
    SELECT TOP (@AppendHeavyUpdates) *
    FROM dbo.bench_v2_source
    ORDER BY source_key
)
UPDATE target
SET
    event_timestamp = DATEADD(day, 1, event_timestamp),
    value_text = N'append-heavy-updated-' + source_key;

/* Very few DELETEs, after update range. */
;WITH target AS
(
    SELECT source_key
    FROM
    (
        SELECT
            source_key,
            ROW_NUMBER() OVER (ORDER BY source_key) AS rn
        FROM dbo.bench_v2_source
    ) AS x
    WHERE x.rn > @AppendHeavyUpdates
      AND x.rn <= @AppendHeavyUpdates + @AppendHeavyDeletes
)
DELETE s
FROM dbo.bench_v2_source AS s
INNER JOIN target AS t
    ON t.source_key = s.source_key;

/* Many INSERTs. */
;WITH n AS
(
    SELECT TOP (@AppendHeavyInserts)
        ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS rn
    FROM sys.all_objects AS a
    CROSS JOIN sys.all_objects AS b
)
INSERT dbo.bench_v2_source
(
    source_key,
    event_timestamp,
    value_text
)
SELECT
    N'H' + RIGHT(REPLICATE(N'0', 12) + CONVERT(nvarchar(20), rn), 12),
    DATEADD(second, CONVERT(int, rn % 86400),
        CONVERT(datetime2(7), '2026-02-01T00:00:00')),
    N'append-heavy-insert-' + CONVERT(nvarchar(20), rn)
FROM n;

SET @T1 = SYSDATETIME();

INSERT #Metrics
VALUES
(
    'B_APPEND_HEAVY',
    'source_mutation',
    (SELECT COUNT_BIG(*) FROM dbo.bench_v2_source),
    NULL, NULL, NULL, NULL, NULL,
    DATEDIFF_BIG(millisecond, @T0, @T1)
);

SET @RunId = NULL;
SET @T0 = SYSDATETIME();

EXEC dbo.usp_prepare_incremental_run
    @ProcessName = N'bench_append_heavy',
    @RunId = @RunId OUTPUT;

SET @T1 = SYSDATETIME();

INSERT #Metrics
SELECT
    'B_APPEND_HEAVY',
    'incremental_prepare',
    (SELECT COUNT_BIG(*) FROM dbo.bench_v2_source),
    (SELECT COUNT_BIG(*) FROM dbo.refresh_run_row WHERE run_id = @RunId),
    (SELECT COUNT(*) FROM dbo.refresh_run_dirty_class WHERE run_id = @RunId),
    r.insert_count,
    r.update_count,
    r.delete_count,
    DATEDIFF_BIG(millisecond, @T0, @T1)
FROM dbo.refresh_run AS r
WHERE r.run_id = @RunId;

SELECT
    *
FROM dbo.bench_v2_source


SET @T0 = SYSDATETIME();
EXEC dbo.usp_finalize_refresh_run @RunId = @RunId;
SET @T1 = SYSDATETIME();

INSERT #Metrics
VALUES
(
    'B_APPEND_HEAVY',
    'incremental_finalize',
    (SELECT COUNT_BIG(*) FROM dbo.bench_v2_source),
    (SELECT COUNT_BIG(*)
     FROM dbo.class_memory AS m
     INNER JOIN dbo.refresh_process AS p ON p.process_id = m.process_id
     WHERE p.process_name = N'bench_append_heavy'),
    NULL, NULL, NULL, NULL,
    DATEDIFF_BIG(millisecond, @T0, @T1)
);

SET @RunId = NULL;
SET @T0 = SYSDATETIME();

EXEC dbo.usp_prepare_full_run
    @ProcessName = N'bench_append_heavy',
    @RunId = @RunId OUTPUT;

SET @T1 = SYSDATETIME();

INSERT #Metrics
SELECT
    'B_APPEND_HEAVY',
    'full_prepare',
    (SELECT COUNT_BIG(*) FROM dbo.bench_v2_source),
    (SELECT COUNT_BIG(*) FROM dbo.refresh_run_row WHERE run_id = @RunId),
    (SELECT COUNT(*) FROM dbo.refresh_run_dirty_class WHERE run_id = @RunId),
    r.insert_count,
    r.update_count,
    r.delete_count,
    DATEDIFF_BIG(millisecond, @T0, @T1)
FROM dbo.refresh_run AS r
WHERE r.run_id = @RunId;

SET @T0 = SYSDATETIME();
EXEC dbo.usp_finalize_refresh_run @RunId = @RunId;
SET @T1 = SYSDATETIME();

INSERT #Metrics
VALUES
(
    'B_APPEND_HEAVY',
    'full_finalize',
    (SELECT COUNT_BIG(*) FROM dbo.bench_v2_source),
    (SELECT COUNT_BIG(*)
     FROM dbo.class_memory AS m
     INNER JOIN dbo.refresh_process AS p ON p.process_id = m.process_id
     WHERE p.process_name = N'bench_append_heavy'),
    NULL, NULL, NULL, NULL,
    DATEDIFF_BIG(millisecond, @T0, @T1)
);

;WITH class_sizes AS
(
    SELECT
        m.class_id,
        COUNT_BIG(*) AS rows_in_class
    FROM dbo.class_memory AS m
    INNER JOIN dbo.refresh_process AS p ON p.process_id = m.process_id
    WHERE p.process_name = N'bench_append_heavy'
    GROUP BY m.class_id
)
INSERT #Balance
SELECT
    'B_APPEND_HEAVY',
    COUNT(*),
    MIN(rows_in_class),
    MAX(rows_in_class),
    CAST(AVG(CONVERT(decimal(19,4), rows_in_class)) AS decimal(19,2)),
    MAX(rows_in_class) - MIN(rows_in_class)
FROM class_sizes;


/* ============================================================================
   SCENARIO C - HIGH CHURN
============================================================================ */
PRINT '============================================================';
PRINT 'SCENARIO C - HIGH CHURN';
PRINT '============================================================';

TRUNCATE TABLE dbo.bench_v2_source;

SET @T0 = SYSDATETIME();

;WITH n AS
(
    SELECT TOP (@BaseRows)
        ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS rn
    FROM sys.all_objects AS a
    CROSS JOIN sys.all_objects AS b
)
INSERT dbo.bench_v2_source
(
    source_key,
    event_timestamp,
    value_text
)
SELECT
    N'B' + RIGHT(REPLICATE(N'0', 12) + CONVERT(nvarchar(20), rn), 12),
    DATEADD(second, CONVERT(int, rn % 86400),
        CONVERT(datetime2(7), '2026-01-01T00:00:00')),
    N'base-' + CONVERT(nvarchar(20), rn)
FROM n;

SET @T1 = SYSDATETIME();

INSERT #Metrics
VALUES
(
    'C_HIGH_CHURN',
    'source_generation',
    @BaseRows,
    NULL, NULL, NULL, NULL, NULL,
    DATEDIFF_BIG(millisecond, @T0, @T1)
);

EXEC dbo.usp_register_refresh_process
    @ProcessName = N'bench_high_churn',
    @AdapterSchema = N'dbo',
    @AdapterView = N'vw_bench_v2_adapter',
    @TotalClasses = @TotalClasses,
    @DefaultInsertWindowSize = @WindowSize;

SET @RunId = NULL;
SET @T0 = SYSDATETIME();

EXEC dbo.usp_prepare_bootstrap_run
    @ProcessName = N'bench_high_churn',
    @RunId = @RunId OUTPUT;

SET @T1 = SYSDATETIME();

INSERT #Metrics
SELECT
    'C_HIGH_CHURN',
    'bootstrap_prepare',
    @BaseRows,
    (SELECT COUNT_BIG(*) FROM dbo.refresh_run_row WHERE run_id = @RunId),
    (SELECT COUNT(*) FROM dbo.refresh_run_dirty_class WHERE run_id = @RunId),
    r.insert_count,
    r.update_count,
    r.delete_count,
    DATEDIFF_BIG(millisecond, @T0, @T1)
FROM dbo.refresh_run AS r
WHERE r.run_id = @RunId;

SET @T0 = SYSDATETIME();
EXEC dbo.usp_finalize_refresh_run @RunId = @RunId;
SET @T1 = SYSDATETIME();

INSERT #Metrics
VALUES
(
    'C_HIGH_CHURN',
    'bootstrap_finalize',
    @BaseRows,
    @BaseRows,
    NULL, NULL, NULL, NULL,
    DATEDIFF_BIG(millisecond, @T0, @T1)
);

SET @T0 = SYSDATETIME();

;WITH target AS
(
    SELECT TOP (@HighChurnUpdates) *
    FROM dbo.bench_v2_source
    ORDER BY source_key
)
UPDATE target
SET
    event_timestamp = DATEADD(day, 1, event_timestamp),
    value_text = N'high-churn-updated-' + source_key;

;WITH target AS
(
    SELECT source_key
    FROM
    (
        SELECT
            source_key,
            ROW_NUMBER() OVER (ORDER BY source_key) AS rn
        FROM dbo.bench_v2_source
    ) AS x
    WHERE x.rn > @HighChurnUpdates
      AND x.rn <= @HighChurnUpdates + @HighChurnDeletes
)
DELETE s
FROM dbo.bench_v2_source AS s
INNER JOIN target AS t
    ON t.source_key = s.source_key;

;WITH n AS
(
    SELECT TOP (@HighChurnInserts)
        ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS rn
    FROM sys.all_objects AS a
    CROSS JOIN sys.all_objects AS b
)
INSERT dbo.bench_v2_source
(
    source_key,
    event_timestamp,
    value_text
)
SELECT
    N'C' + RIGHT(REPLICATE(N'0', 12) + CONVERT(nvarchar(20), rn), 12),
    DATEADD(second, CONVERT(int, rn % 86400),
        CONVERT(datetime2(7), '2026-02-01T00:00:00')),
    N'high-churn-insert-' + CONVERT(nvarchar(20), rn)
FROM n;

SET @T1 = SYSDATETIME();

INSERT #Metrics
VALUES
(
    'C_HIGH_CHURN',
    'source_mutation',
    (SELECT COUNT_BIG(*) FROM dbo.bench_v2_source),
    NULL, NULL, NULL, NULL, NULL,
    DATEDIFF_BIG(millisecond, @T0, @T1)
);

SET @RunId = NULL;
SET @T0 = SYSDATETIME();

EXEC dbo.usp_prepare_incremental_run
    @ProcessName = N'bench_high_churn',
    @RunId = @RunId OUTPUT;

SET @T1 = SYSDATETIME();

INSERT #Metrics
SELECT
    'C_HIGH_CHURN',
    'incremental_prepare',
    (SELECT COUNT_BIG(*) FROM dbo.bench_v2_source),
    (SELECT COUNT_BIG(*) FROM dbo.refresh_run_row WHERE run_id = @RunId),
    (SELECT COUNT(*) FROM dbo.refresh_run_dirty_class WHERE run_id = @RunId),
    r.insert_count,
    r.update_count,
    r.delete_count,
    DATEDIFF_BIG(millisecond, @T0, @T1)
FROM dbo.refresh_run AS r
WHERE r.run_id = @RunId;

SET @T0 = SYSDATETIME();
EXEC dbo.usp_finalize_refresh_run @RunId = @RunId;
SET @T1 = SYSDATETIME();

INSERT #Metrics
VALUES
(
    'C_HIGH_CHURN',
    'incremental_finalize',
    (SELECT COUNT_BIG(*) FROM dbo.bench_v2_source),
    (SELECT COUNT_BIG(*)
     FROM dbo.class_memory AS m
     INNER JOIN dbo.refresh_process AS p ON p.process_id = m.process_id
     WHERE p.process_name = N'bench_high_churn'),
    NULL, NULL, NULL, NULL,
    DATEDIFF_BIG(millisecond, @T0, @T1)
);

SET @RunId = NULL;
SET @T0 = SYSDATETIME();

EXEC dbo.usp_prepare_full_run
    @ProcessName = N'bench_high_churn',
    @RunId = @RunId OUTPUT;

SET @T1 = SYSDATETIME();

INSERT #Metrics
SELECT
    'C_HIGH_CHURN',
    'full_prepare',
    (SELECT COUNT_BIG(*) FROM dbo.bench_v2_source),
    (SELECT COUNT_BIG(*) FROM dbo.refresh_run_row WHERE run_id = @RunId),
    (SELECT COUNT(*) FROM dbo.refresh_run_dirty_class WHERE run_id = @RunId),
    r.insert_count,
    r.update_count,
    r.delete_count,
    DATEDIFF_BIG(millisecond, @T0, @T1)
FROM dbo.refresh_run AS r
WHERE r.run_id = @RunId;

SET @T0 = SYSDATETIME();
EXEC dbo.usp_finalize_refresh_run @RunId = @RunId;
SET @T1 = SYSDATETIME();

INSERT #Metrics
VALUES
(
    'C_HIGH_CHURN',
    'full_finalize',
    (SELECT COUNT_BIG(*) FROM dbo.bench_v2_source),
    (SELECT COUNT_BIG(*)
     FROM dbo.class_memory AS m
     INNER JOIN dbo.refresh_process AS p ON p.process_id = m.process_id
     WHERE p.process_name = N'bench_high_churn'),
    NULL, NULL, NULL, NULL,
    DATEDIFF_BIG(millisecond, @T0, @T1)
);

;WITH class_sizes AS
(
    SELECT
        m.class_id,
        COUNT_BIG(*) AS rows_in_class
    FROM dbo.class_memory AS m
    INNER JOIN dbo.refresh_process AS p ON p.process_id = m.process_id
    WHERE p.process_name = N'bench_high_churn'
    GROUP BY m.class_id
)
INSERT #Balance
SELECT
    'C_HIGH_CHURN',
    COUNT(*),
    MIN(rows_in_class),
    MAX(rows_in_class),
    CAST(AVG(CONVERT(decimal(19,4), rows_in_class)) AS decimal(19,2)),
    MAX(rows_in_class) - MIN(rows_in_class)
FROM class_sizes;


/* ============================================================================
   SCENARIO D - FULL ROTATING CYCLE
============================================================================ */
PRINT '============================================================';
PRINT 'SCENARIO D - ROTATING CYCLE';
PRINT '============================================================';

TRUNCATE TABLE dbo.bench_v2_source;

;WITH n AS
(
    SELECT TOP (@BaseRows)
        ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS rn
    FROM sys.all_objects AS a
    CROSS JOIN sys.all_objects AS b
)
INSERT dbo.bench_v2_source
(
    source_key,
    event_timestamp,
    value_text
)
SELECT
    N'B' + RIGHT(REPLICATE(N'0', 12) + CONVERT(nvarchar(20), rn), 12),
    DATEADD(second, CONVERT(int, rn % 86400),
        CONVERT(datetime2(7), '2026-01-01T00:00:00')),
    N'base-' + CONVERT(nvarchar(20), rn)
FROM n;

EXEC dbo.usp_register_refresh_process
    @ProcessName = N'bench_rotation_cycle',
    @AdapterSchema = N'dbo',
    @AdapterView = N'vw_bench_v2_adapter',
    @TotalClasses = @TotalClasses,
    @DefaultInsertWindowSize = @WindowSize;

SET @RunId = NULL;

EXEC dbo.usp_prepare_bootstrap_run
    @ProcessName = N'bench_rotation_cycle',
    @RunId = @RunId OUTPUT;

EXEC dbo.usp_finalize_refresh_run
    @RunId = @RunId;

DECLARE
    @RotationRun int = 1,
    @PrepareMs bigint,
    @FinalizeMs bigint,
    @WindowStart int,
    @CandidateStart int,
    @DirtyClasses int;

WHILE @RotationRun <= @RotationRuns
BEGIN
    PRINT CONCAT('Rotation run ', @RotationRun, ' / ', @RotationRuns);

    ;WITH n AS
    (
        SELECT TOP (@RotationInsertPerRun)
            ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS rn
        FROM sys.all_objects AS a
        CROSS JOIN sys.all_objects AS b
    )
    INSERT dbo.bench_v2_source
    (
        source_key,
        event_timestamp,
        value_text
    )
    SELECT
        N'R'
        + RIGHT(REPLICATE(N'0', 3)
            + CONVERT(nvarchar(10), @RotationRun), 3)
        + N'-'
        + RIGHT(REPLICATE(N'0', 9)
            + CONVERT(nvarchar(20), rn), 9),
        DATEADD(second, CONVERT(int, rn % 86400),
            DATEADD(day, @RotationRun,
                CONVERT(datetime2(7), '2026-03-01T00:00:00'))),
        N'rotation-'
        + CONVERT(nvarchar(10), @RotationRun)
        + N'-'
        + CONVERT(nvarchar(20), rn)
    FROM n;

    SET @RunId = NULL;
    SET @T0 = SYSDATETIME();

    EXEC dbo.usp_prepare_incremental_run
        @ProcessName = N'bench_rotation_cycle',
        @RunId = @RunId OUTPUT;

    SET @T1 = SYSDATETIME();
    SET @PrepareMs = DATEDIFF_BIG(millisecond, @T0, @T1);

    SELECT
        @WindowStart = window_start_class,
        @CandidateStart = candidate_next_window_start
    FROM dbo.refresh_run
    WHERE run_id = @RunId;

    SELECT @DirtyClasses = COUNT(*)
    FROM dbo.refresh_run_dirty_class
    WHERE run_id = @RunId;

    IF @DirtyClasses > @WindowSize
        THROW 57320, 'Scenario D FAILED: INSERT-only exceeded WindowSize dirty classes.', 1;

    SET @T0 = SYSDATETIME();

    EXEC dbo.usp_finalize_refresh_run
        @RunId = @RunId;

    SET @T1 = SYSDATETIME();
    SET @FinalizeMs = DATEDIFF_BIG(millisecond, @T0, @T1);

    ;WITH class_sizes AS
    (
        SELECT
            m.class_id,
            COUNT_BIG(*) AS rows_in_class
        FROM dbo.class_memory AS m
        INNER JOIN dbo.refresh_process AS p
            ON p.process_id = m.process_id
        WHERE p.process_name = N'bench_rotation_cycle'
        GROUP BY m.class_id
    )
    INSERT #Rotation
    SELECT
        @RotationRun,
        @WindowStart,
        @CandidateStart,
        @DirtyClasses,
        @RotationInsertPerRun,
        @PrepareMs,
        @FinalizeMs,
        MIN(rows_in_class),
        MAX(rows_in_class),
        CAST(AVG(CONVERT(decimal(19,4), rows_in_class)) AS decimal(19,2)),
        MAX(rows_in_class) - MIN(rows_in_class)
    FROM class_sizes;

    SET @RotationRun += 1;
END;


/* ============================================================================
   OUTPUT
============================================================================ */
SELECT
    @BaseRows AS base_rows,
    @TotalClasses AS total_classes,
    @WindowSize AS insert_window_size,
    @AppendOnlyInserts AS append_only_inserts,
    @AppendHeavyInserts AS append_heavy_inserts,
    @AppendHeavyUpdates AS append_heavy_updates,
    @AppendHeavyDeletes AS append_heavy_deletes,
    @HighChurnInserts AS high_churn_inserts,
    @HighChurnUpdates AS high_churn_updates,
    @HighChurnDeletes AS high_churn_deletes,
    @RotationRuns AS rotation_runs,
    @RotationInsertPerRun AS rotation_insert_per_run;

SELECT
    scenario,
    phase,
    source_rows,
    run_rows,
    dirty_classes,
    insert_count,
    update_count,
    delete_count,
    elapsed_ms,
    CAST(elapsed_ms / 1000.0 AS decimal(18,3)) AS elapsed_seconds
FROM #Metrics
ORDER BY
    CASE scenario
        WHEN 'A_APPEND_ONLY' THEN 1
        WHEN 'B_APPEND_HEAVY' THEN 2
        WHEN 'C_HIGH_CHURN' THEN 3
        ELSE 99
    END,
    CASE phase
        WHEN 'source_generation' THEN 1
        WHEN 'bootstrap_prepare' THEN 2
        WHEN 'bootstrap_finalize' THEN 3
        WHEN 'source_mutation' THEN 4
        WHEN 'incremental_prepare' THEN 5
        WHEN 'incremental_finalize' THEN 6
        WHEN 'full_prepare' THEN 7
        WHEN 'full_finalize' THEN 8
        ELSE 99
    END;

SELECT
    scenario,
    classes_with_rows,
    min_rows_per_class,
    max_rows_per_class,
    avg_rows_per_class,
    max_min_spread
FROM #Balance
ORDER BY scenario;

SELECT
    run_number,
    window_start_class,
    candidate_next_start,
    dirty_classes,
    inserted_rows,
    prepare_ms,
    finalize_ms,
    min_rows_per_class,
    max_rows_per_class,
    avg_rows_per_class,
    max_min_spread
FROM #Rotation
ORDER BY run_number;

/*
Expected qualitative behavior with defaults:

Scenario A:
    dirty_classes <= 10

Scenario B:
    dirty_classes >= Scenario A in general,
    because historical UPDATE/DELETE classes can add partitions.

Scenario C:
    dirty_classes can approach 100.

Scenario D:
    run 1:
        start 1
        dirty 10
        temporary spread about 500 rows

    run 2:
        start 11
        dirty 10

    ...

    run 10:
        start 91
        dirty 10
        after finalize all 100 classes should have received
        approximately the same number of new rows,
        so the spread should return close to zero.

The exact SQL timings are machine-specific.
Repeat each benchmark configuration 3-5 times and report medians.
*/

/*
SET STATISTICS TIME OFF;
SET STATISTICS IO OFF;
*/
GO
