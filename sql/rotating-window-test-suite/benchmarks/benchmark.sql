USE StableClassDemo;
GO

/*
===============================================================================
 BENCHMARK V3 - FIXED VS ADAPTIVE ROTATING WINDOW
===============================================================================

Goal
----
Measure the framework in three focused scenarios:

A) MASSIVE APPEND-ONLY
   Measures the normal fixed-window incremental path after Bootstrap:
       many INSERTs
       zero UPDATE
       zero DELETE
       dirty classes <= default window size

B) APPEND-HEAVY
   Target-style workload:
       many INSERTs
       few UPDATEs
       very few DELETEs
   Historical UPDATE/DELETE classes may add dirty partitions outside the
   insert window.

C) ADAPTIVE WINDOW
   Ten consecutive INSERT-only runs on the same process.
   Runs alternate between:
       - a large batch that falls back to the default window;
       - a small batch that activates the configured threshold window.

   This scenario verifies both the adaptive window decision and the fact that
   the rotating pointer advances by the effective window used by each run.

Bootstrap timings are recorded as an accessory metric. The main benchmark
focus is the behavior and cost of Incremental refreshes.

This is a performance benchmark, not a production-capacity claim.
Run each configuration multiple times and report the median.

FINALIZE LIFECYCLE
------------------
A successful FINALIZE also removes the operational staging for that RunId:

    refresh_run_row
    refresh_run_delete
    refresh_run_dirty_class

while refresh_run remains as lightweight audit history.

Therefore finalize_ms includes the cost of this cleanup.

IMPORTANT
---------
Change benchmark values ONLY in the CONFIG section below.
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

   The legacy process names are also included so this benchmark can be run
   after the previous V2 benchmark without manual cleanup.
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
    N'bench_adaptive_cycle',
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

DELETE t
FROM dbo.refresh_process_insert_threshold AS t
INNER JOIN @BenchProcessIds AS x
    ON x.process_id = t.process_id;

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
    @BaseRows                       int = 100000,
    @TotalClasses                   int = 100,
    @WindowSize                     int = 10,

    @AppendOnlyInserts              int = 5000,

    @AppendHeavyInserts             int = 5000,
    @AppendHeavyUpdates             int = 10,
    @AppendHeavyDeletes             int = 10,

    @AdaptiveRuns                   int = 10,
    @AdaptiveDefaultBatchInserts    int = 5000,
    @AdaptiveThresholdBatchInserts  int = 500,
    @AdaptiveThresholdMaxInserts    bigint = 500,
    @AdaptiveThresholdWindowSize    int = 1;

IF @BaseRows < 1
    THROW 57300, 'BaseRows must be > 0.', 1;

IF @TotalClasses < 1
    THROW 57301, 'TotalClasses must be > 0.', 1;

IF @WindowSize < 1 OR @WindowSize > @TotalClasses
    THROW 57302, 'Invalid WindowSize.', 1;

IF @AppendHeavyUpdates + @AppendHeavyDeletes > @BaseRows
    THROW 57303, 'Scenario B: UPDATE + DELETE exceeds BaseRows.', 1;

IF @AdaptiveRuns < 1
    THROW 57304, 'Scenario C: AdaptiveRuns must be > 0.', 1;

IF @AdaptiveDefaultBatchInserts < 1 OR @AdaptiveThresholdBatchInserts < 1
    THROW 57305, 'Scenario C: INSERT batches must be > 0.', 1;

IF @AdaptiveThresholdMaxInserts < 1
    THROW 57306, 'Scenario C: the threshold must be > 0.', 1;

IF @AdaptiveThresholdWindowSize < 1
   OR @AdaptiveThresholdWindowSize >= @WindowSize
    THROW 57307, 'Scenario C: the threshold window must be > 0 and < WindowSize.', 1;

IF @AdaptiveThresholdBatchInserts > @AdaptiveThresholdMaxInserts
    THROW 57308, 'Scenario C: the threshold batch must fall within the configured threshold.', 1;

IF @AdaptiveDefaultBatchInserts <= @AdaptiveThresholdMaxInserts
    THROW 57309, 'Scenario C: the default batch must exceed the threshold to use the fallback.', 1;

/* ============================================================================
   RESULT TABLES
============================================================================ */
DROP TABLE IF EXISTS #Adaptive;
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

CREATE TABLE #Adaptive
(
    run_number               int NOT NULL,
    batch_mode               varchar(20) NOT NULL,
    inserted_rows            bigint NOT NULL,
    source_rows              bigint NOT NULL,
    source_mutation_ms       bigint NOT NULL,
    window_start_class       int NOT NULL,
    effective_window_size    int NOT NULL,
    candidate_next_start     int NOT NULL,
    dirty_classes            int NOT NULL,
    prepare_ms               bigint NOT NULL,
    finalize_ms              bigint NOT NULL,
    min_rows_per_class       bigint NOT NULL,
    max_rows_per_class       bigint NOT NULL,
    avg_rows_per_class       decimal(19,2) NOT NULL,
    max_min_spread           bigint NOT NULL
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
   SCENARIO C - ADAPTIVE WINDOW
============================================================================ */
PRINT '============================================================';
PRINT 'SCENARIO C - ADAPTIVE WINDOW';
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
    'C_ADAPTIVE',
    'source_generation',
    @BaseRows,
    NULL, NULL, NULL, NULL, NULL,
    DATEDIFF_BIG(millisecond, @T0, @T1)
);

EXEC dbo.usp_register_refresh_process
    @ProcessName = N'bench_adaptive_cycle',
    @AdapterSchema = N'dbo',
    @AdapterView = N'vw_bench_v2_adapter',
    @TotalClasses = @TotalClasses,
    @DefaultInsertWindowSize = @WindowSize;

DECLARE @AdaptivePolicy nvarchar(max) =
    CONVERT(nvarchar(30), @AdaptiveThresholdMaxInserts)
    + N':'
    + CONVERT(nvarchar(30), @AdaptiveThresholdWindowSize);

EXEC dbo.usp_set_insert_window_policy
    @ProcessName = N'bench_adaptive_cycle',
    @Policy = @AdaptivePolicy;

SET @RunId = NULL;
SET @T0 = SYSDATETIME();

EXEC dbo.usp_prepare_bootstrap_run
    @ProcessName = N'bench_adaptive_cycle',
    @RunId = @RunId OUTPUT;

SET @T1 = SYSDATETIME();

INSERT #Metrics
SELECT
    'C_ADAPTIVE',
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
    'C_ADAPTIVE',
    'bootstrap_finalize',
    @BaseRows,
    @BaseRows,
    NULL, NULL, NULL, NULL,
    DATEDIFF_BIG(millisecond, @T0, @T1)
);

DECLARE
    @AdaptiveRun int = 1,
    @AdaptiveBatchInserts int,
    @ExpectedWindow int,
    @BatchMode varchar(20),
    @MutationMs bigint,
    @PrepareMs bigint,
    @FinalizeMs bigint,
    @WindowStart int,
    @EffectiveWindow int,
    @CandidateStart int,
    @DirtyClasses int,
    @ActualInsertCount bigint,
    @ExpectedCandidateStart int;

WHILE @AdaptiveRun <= @AdaptiveRuns
BEGIN
    IF @AdaptiveRun % 2 = 1
    BEGIN
        SET @AdaptiveBatchInserts = @AdaptiveDefaultBatchInserts;
        SET @ExpectedWindow = @WindowSize;
        SET @BatchMode = 'DEFAULT';
    END
    ELSE
    BEGIN
        SET @AdaptiveBatchInserts = @AdaptiveThresholdBatchInserts;
        SET @ExpectedWindow = @AdaptiveThresholdWindowSize;
        SET @BatchMode = 'THRESHOLD';
    END;

    PRINT CONCAT
    (
        'Adaptive run ', @AdaptiveRun, ' / ', @AdaptiveRuns,
        ' - ', @BatchMode,
        ' - inserts=', @AdaptiveBatchInserts,
        ' - expected window=', @ExpectedWindow
    );

    SET @T0 = SYSDATETIME();

    ;WITH n AS
    (
        SELECT TOP (@AdaptiveBatchInserts)
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
        N'W'
        + RIGHT(REPLICATE(N'0', 3)
            + CONVERT(nvarchar(10), @AdaptiveRun), 3)
        + N'-'
        + RIGHT(REPLICATE(N'0', 9)
            + CONVERT(nvarchar(20), rn), 9),
        DATEADD(second, CONVERT(int, rn % 86400),
            DATEADD(day, @AdaptiveRun,
                CONVERT(datetime2(7), '2026-03-01T00:00:00'))),
        N'adaptive-'
        + CONVERT(nvarchar(10), @AdaptiveRun)
        + N'-'
        + CONVERT(nvarchar(20), rn)
    FROM n;

    SET @T1 = SYSDATETIME();
    SET @MutationMs = DATEDIFF_BIG(millisecond, @T0, @T1);

    SET @RunId = NULL;
    SET @T0 = SYSDATETIME();

    EXEC dbo.usp_prepare_incremental_run
        @ProcessName = N'bench_adaptive_cycle',
        @RunId = @RunId OUTPUT;

    SET @T1 = SYSDATETIME();
    SET @PrepareMs = DATEDIFF_BIG(millisecond, @T0, @T1);

    SELECT
        @WindowStart = window_start_class,
        @EffectiveWindow = insert_window_size,
        @CandidateStart = candidate_next_window_start,
        @DirtyClasses = dirty_class_count,
        @ActualInsertCount = insert_count
    FROM dbo.refresh_run
    WHERE run_id = @RunId;

    IF @ActualInsertCount <> @AdaptiveBatchInserts
        THROW 57320, 'Scenario C FAILED: insert_count differs from the expected batch.', 1;

    IF @EffectiveWindow <> @ExpectedWindow
        THROW 57321, 'Scenario C FAILED: effective window differs from the expected value.', 1;

    IF @DirtyClasses <> @ExpectedWindow
        THROW 57322, 'Scenario C FAILED: dirty classes differ from the expected window.', 1;

    SET @ExpectedCandidateStart =
        ((@WindowStart - 1 + @ExpectedWindow) % @TotalClasses) + 1;

    IF @CandidateStart <> @ExpectedCandidateStart
        THROW 57323, 'Scenario C FAILED: candidate_next_window_start is inconsistent with the effective window.', 1;

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
        WHERE p.process_name = N'bench_adaptive_cycle'
        GROUP BY m.class_id
    )
    INSERT #Adaptive
    SELECT
        @AdaptiveRun,
        @BatchMode,
        @ActualInsertCount,
        (SELECT COUNT_BIG(*) FROM dbo.bench_v2_source),
        @MutationMs,
        @WindowStart,
        @EffectiveWindow,
        @CandidateStart,
        @DirtyClasses,
        @PrepareMs,
        @FinalizeMs,
        MIN(rows_in_class),
        MAX(rows_in_class),
        CAST(AVG(CONVERT(decimal(19,4), rows_in_class)) AS decimal(19,2)),
        MAX(rows_in_class) - MIN(rows_in_class)
    FROM class_sizes;

    SET @AdaptiveRun += 1;
END;

/* ============================================================================
   OUTPUT
============================================================================ */
SELECT
    @BaseRows AS base_rows,
    @TotalClasses AS total_classes,
    @WindowSize AS default_insert_window_size,
    @AppendOnlyInserts AS append_only_inserts,
    @AppendHeavyInserts AS append_heavy_inserts,
    @AppendHeavyUpdates AS append_heavy_updates,
    @AppendHeavyDeletes AS append_heavy_deletes,
    @AdaptiveRuns AS adaptive_runs,
    @AdaptiveDefaultBatchInserts AS adaptive_default_batch_inserts,
    @AdaptiveThresholdBatchInserts AS adaptive_threshold_batch_inserts,
    @AdaptiveThresholdMaxInserts AS adaptive_threshold_max_inserts,
    @AdaptiveThresholdWindowSize AS adaptive_threshold_window_size;

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
        WHEN 'C_ADAPTIVE' THEN 3
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
    batch_mode,
    inserted_rows,
    source_rows,
    source_mutation_ms,
    window_start_class,
    effective_window_size,
    candidate_next_start,
    dirty_classes,
    prepare_ms,
    finalize_ms,
    min_rows_per_class,
    max_rows_per_class,
    avg_rows_per_class,
    max_min_spread
FROM #Adaptive
ORDER BY run_number;

/*
Expected qualitative behavior with defaults:

Scenario A:
    5,000 INSERTs use the fixed default window of 10 classes.
    dirty_classes = 10.

Scenario B:
    5,000 INSERTs still use at most 10 insert classes.
    UPDATE/DELETE can add historical dirty classes outside the window.

Scenario C:
    Bootstrap creates 100 classes with about 1,000 rows each.

    Odd runs:
        5,000 INSERTs
        no threshold matches
        effective_window_size = 10
        dirty_classes = 10
        pointer advances by 10

    Even runs:
        500 INSERTs
        threshold 500:1 matches
        effective_window_size = 1
        dirty_classes = 1
        pointer advances by 1

    Expected effective-window sequence:
        10, 1, 10, 1, 10, 1, 10, 1, 10, 1

The exact SQL timings are machine-specific.
Repeat each benchmark configuration 3-5 times and report medians.
*/

/*
SET STATISTICS TIME OFF;
SET STATISTICS IO OFF;
*/
GO
