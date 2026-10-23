USE StableClassDemo;
GO

/*
===============================================================================
 AUTOMATED INTEGRATION TESTS
===============================================================================

Assumptions:
- framework SQL files are already installed in StableClassDemo;
- prepare_* and finalize use the corrected @LockResource implementation;
- DELETE classes are active dirty-class contributors;
- successful FINALIZE removes operational staging for the completed RunId:
  refresh_run_row, refresh_run_delete, refresh_run_dirty_class;
- refresh_run remains as lightweight audit history.

The tests use isolated objects/process names and are rerunnable.

PASS:
    the script reaches the final summary without THROW.

FAIL:
    an assertion raises error 570xx.
===============================================================================
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* ---------------------------------------------------------------------------
   CLEAN PREVIOUS TEST STATE

   Cleanup per RunId instead of DELETE ... JOIN on the global staging tables.
   This keeps the test rerunnable without asking SQL Server for a large memory
   grant when refresh_run_row contains data from other processes/benchmarks.
--------------------------------------------------------------------------- */
DECLARE
    @ProcessId int,
    @CleanupRunId uniqueidentifier;

SELECT @ProcessId = process_id
FROM dbo.refresh_process
WHERE process_name = N'test_rotating_ci';

IF @ProcessId IS NOT NULL
BEGIN
    DECLARE cleanup_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT run_id
        FROM dbo.refresh_run
        WHERE process_id = @ProcessId;

    OPEN cleanup_cursor;

    FETCH NEXT FROM cleanup_cursor INTO @CleanupRunId;

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

        FETCH NEXT FROM cleanup_cursor INTO @CleanupRunId;
    END;

    CLOSE cleanup_cursor;
    DEALLOCATE cleanup_cursor;

    DELETE FROM dbo.class_memory
    WHERE process_id = @ProcessId;

    DELETE FROM dbo.refresh_process_insert_threshold
    WHERE process_id = @ProcessId;

    DELETE FROM dbo.refresh_process
    WHERE process_id = @ProcessId;
END;
GO

DROP VIEW IF EXISTS dbo.vw_test_rotating_adapter;
DROP TABLE IF EXISTS dbo.test_rotating_source;
GO

CREATE TABLE dbo.test_rotating_source
(
    source_key       nvarchar(100) NOT NULL
        CONSTRAINT PK_test_rotating_source PRIMARY KEY,
    event_timestamp  datetime2(7) NOT NULL,
    value_text       nvarchar(200) NOT NULL
);
GO

CREATE VIEW dbo.vw_test_rotating_adapter
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
FROM dbo.test_rotating_source;
GO

INSERT dbo.test_rotating_source
(
    source_key,
    event_timestamp,
    value_text
)
VALUES
    (N'A001', '2026-08-19T08:00:00', N'A v1'),
    (N'B002', '2026-08-19T08:01:00', N'B v1'),
    (N'C003', '2026-08-19T08:02:00', N'C v1'),
    (N'D004', '2026-08-19T08:03:00', N'D v1'),
    (N'E005', '2026-08-19T08:04:00', N'E v1'),
    (N'F006', '2026-08-19T08:05:00', N'F v1');
GO

PRINT 'TEST 01 - register process';

EXEC dbo.usp_register_refresh_process
    @ProcessName = N'test_rotating_ci',
    @AdapterSchema = N'dbo',
    @AdapterView = N'vw_test_rotating_adapter',
    @TotalClasses = 3,
    @DefaultInsertWindowSize = 2;

EXEC dbo.usp_set_insert_window_policy
    @ProcessName = N'test_rotating_ci',
    @Policy = N'1:1';

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_process
    WHERE process_name = N'test_rotating_ci'
      AND total_classes = 3
      AND default_insert_window_size = 2
      AND next_window_start_class = 1
      AND last_successful_run_id IS NULL
)
    THROW 57001, 'TEST 01 FAILED: unexpected process configuration.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_process_insert_threshold AS t
    INNER JOIN dbo.refresh_process AS p
        ON p.process_id = t.process_id
    WHERE p.process_name = N'test_rotating_ci'
      AND t.max_insert_count = 1
      AND t.insert_window_size = 1
)
    THROW 57050, 'TEST 01 FAILED: adaptive policy was not saved.', 1;

PRINT 'PASS 01';


/* ============================================================================
   TEST 02 - BOOTSTRAP
============================================================================ */
PRINT 'TEST 02 - bootstrap prepare/finalize';

DECLARE @BootstrapRun uniqueidentifier;

EXEC dbo.usp_prepare_bootstrap_run
    @ProcessName = N'test_rotating_ci',
    @RunId = @BootstrapRun OUTPUT;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_run
    WHERE run_id = @BootstrapRun
      AND run_type = 'BOOTSTRAP'
      AND insert_count = 6
      AND update_count = 0
      AND delete_count = 0
      AND dirty_class_count = 3
      AND status = 'PREPARED'
)
    THROW 57002, 'TEST 02 FAILED: unexpected BOOTSTRAP header.', 1;

IF (SELECT COUNT(*) FROM dbo.refresh_run_row WHERE run_id = @BootstrapRun) <> 6
    THROW 57003, 'TEST 02 FAILED: Bootstrap must materialize 6 rows.', 1;

IF EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_row
    WHERE run_id = @BootstrapRun
      AND (change_type <> 'BOOTSTRAP' OR class_id NOT BETWEEN 1 AND 3)
)
    THROW 57004, 'TEST 02 FAILED: invalid BOOTSTRAP change_type/class_id.', 1;

IF (SELECT COUNT(*) FROM dbo.refresh_run_dirty_class WHERE run_id = @BootstrapRun) <> 3
    THROW 57005, 'TEST 02 FAILED: Bootstrap must make 3 classes dirty.', 1;

/* With 6 rows / 3 classes, the distribution must be 2-2-2. */
IF EXISTS
(
    SELECT class_id
    FROM dbo.refresh_run_row
    WHERE run_id = @BootstrapRun
    GROUP BY class_id
    HAVING COUNT(*) <> 2
)
    THROW 57006, 'TEST 02 FAILED: Bootstrap distribution is not balanced 2-2-2.', 1;

EXEC dbo.usp_finalize_refresh_run
    @RunId = @BootstrapRun;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_run
    WHERE run_id = @BootstrapRun
      AND status = 'COMPLETED'
      AND completed_at IS NOT NULL
)
    THROW 57007, 'TEST 02 FAILED: Bootstrap is not COMPLETED.', 1;

IF
(
    SELECT COUNT(*)
    FROM dbo.class_memory AS m
    INNER JOIN dbo.refresh_process AS p ON p.process_id = m.process_id
    WHERE p.process_name = N'test_rotating_ci'
) <> 6
    THROW 57008, 'TEST 02 FAILED: class_memory must contain 6 rows.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_process
    WHERE process_name = N'test_rotating_ci'
      AND next_window_start_class = 1
      AND last_successful_run_id = @BootstrapRun
)
    THROW 57009, 'TEST 02 FAILED: unexpected process state after Bootstrap.', 1;


/* Successful FINALIZE must remove operational staging for this RunId. */
IF EXISTS (SELECT 1 FROM dbo.refresh_run_row WHERE run_id = @BootstrapRun)
   OR EXISTS (SELECT 1 FROM dbo.refresh_run_delete WHERE run_id = @BootstrapRun)
   OR EXISTS (SELECT 1 FROM dbo.refresh_run_dirty_class WHERE run_id = @BootstrapRun)
    THROW 57038, 'TEST 02 FAILED: BOOTSTRAP staging was not cleaned after FINALIZE.', 1;

PRINT 'PASS 02';


/* ============================================================================
   TEST 03 - MIXED INCREMENTAL: INSERT + UPDATE + DELETE
============================================================================ */
PRINT 'TEST 03 - mixed incremental';

UPDATE dbo.test_rotating_source
SET
    event_timestamp = '2026-08-19T09:00:00',
    value_text = N'B v2'
WHERE source_key = N'B002';

DELETE dbo.test_rotating_source
WHERE source_key = N'D004';

INSERT dbo.test_rotating_source
(
    source_key,
    event_timestamp,
    value_text
)
VALUES
    (N'N001', '2026-08-19T10:00:00', N'new 1'),
    (N'N002', '2026-08-19T10:01:00', N'new 2'),
    (N'N003', '2026-08-19T10:02:00', N'new 3'),
    (N'N004', '2026-08-19T10:03:00', N'new 4'),
    (N'N005', '2026-08-19T10:04:00', N'new 5');

DECLARE @IncrementalRun uniqueidentifier;

EXEC dbo.usp_prepare_incremental_run
    @ProcessName = N'test_rotating_ci',
    @RunId = @IncrementalRun OUTPUT;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_run
    WHERE run_id = @IncrementalRun
      AND run_type = 'INCREMENTAL'
      AND insert_window_size = 2
      AND window_start_class = 1
      AND candidate_next_window_start = 3
      AND insert_count = 5
      AND update_count = 1
      AND delete_count = 1
      AND status = 'PREPARED'
)
    THROW 57010, 'TEST 03 FAILED: unexpected Incremental header.', 1;

IF (SELECT COUNT(*) FROM dbo.refresh_run_row WHERE run_id = @IncrementalRun) <> 10
    THROW 57011, 'TEST 03 FAILED: Incremental snapshot must contain 10 rows.', 1;

IF EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_row
    WHERE run_id = @IncrementalRun
      AND change_type = 'INSERT'
      AND class_id NOT IN (1,2)
)
    THROW 57012, 'TEST 03 FAILED: INSERT outside rotating window 1,2.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_row AS rr
    INNER JOIN dbo.class_memory AS m
        ON m.source_key = rr.source_key
    INNER JOIN dbo.refresh_process AS p
        ON p.process_id = m.process_id
    WHERE rr.run_id = @IncrementalRun
      AND p.process_name = N'test_rotating_ci'
      AND rr.source_key = N'B002'
      AND rr.change_type = 'UPDATE'
      AND rr.class_id = m.class_id
)
    THROW 57013, 'TEST 03 FAILED: B002 must keep its historical class.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_delete AS d
    INNER JOIN dbo.class_memory AS m
        ON m.source_key = d.source_key
       AND m.class_id = d.class_id
    INNER JOIN dbo.refresh_process AS p
        ON p.process_id = m.process_id
    WHERE d.run_id = @IncrementalRun
      AND p.process_name = N'test_rotating_ci'
      AND d.source_key = N'D004'
)
    THROW 57014, 'TEST 03 FAILED: D004 was not detected with its historical class.', 1;

/* Every class required by INSERT/UPDATE/DELETE must be dirty. */
IF EXISTS
(
    SELECT expected.class_id
    FROM
    (
        SELECT DISTINCT class_id
        FROM dbo.refresh_run_row
        WHERE run_id = @IncrementalRun
          AND change_type IN ('INSERT','UPDATE')

        UNION

        SELECT DISTINCT class_id
        FROM dbo.refresh_run_delete
        WHERE run_id = @IncrementalRun
    ) AS expected
    WHERE NOT EXISTS
    (
        SELECT 1
        FROM dbo.refresh_run_dirty_class AS d
        WHERE d.run_id = @IncrementalRun
          AND d.class_id = expected.class_id
    )
)
    THROW 57015, 'TEST 03 FAILED: an expected dirty class is missing.', 1;

/* There must be no dirty classes unrelated to INSERT/UPDATE/DELETE. */
IF EXISTS
(
    SELECT d.class_id
    FROM dbo.refresh_run_dirty_class AS d
    WHERE d.run_id = @IncrementalRun
      AND NOT EXISTS
      (
          SELECT 1
          FROM
          (
              SELECT DISTINCT class_id
              FROM dbo.refresh_run_row
              WHERE run_id = @IncrementalRun
                AND change_type IN ('INSERT','UPDATE')

              UNION

              SELECT DISTINCT class_id
              FROM dbo.refresh_run_delete
              WHERE run_id = @IncrementalRun
          ) AS expected
          WHERE expected.class_id = d.class_id
      )
)
    THROW 57016, 'TEST 03 FAILED: unjustified dirty class.', 1;

EXEC dbo.usp_finalize_refresh_run
    @RunId = @IncrementalRun;

IF EXISTS
(
    SELECT 1
    FROM dbo.class_memory AS m
    INNER JOIN dbo.refresh_process AS p ON p.process_id = m.process_id
    WHERE p.process_name = N'test_rotating_ci'
      AND m.source_key = N'D004'
)
    THROW 57017, 'TEST 03 FAILED: D004 must disappear from class_memory.', 1;

IF
(
    SELECT COUNT(*)
    FROM dbo.class_memory AS m
    INNER JOIN dbo.refresh_process AS p ON p.process_id = m.process_id
    WHERE p.process_name = N'test_rotating_ci'
) <> 10
    THROW 57018, 'TEST 03 FAILED: memory after Incremental must contain 10 rows.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_process
    WHERE process_name = N'test_rotating_ci'
      AND next_window_start_class = 3
      AND last_successful_run_id = @IncrementalRun
)
    THROW 57019, 'TEST 03 FAILED: rotating window did not advance to 3.', 1;


IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_run
    WHERE run_id = @IncrementalRun
      AND status = 'COMPLETED'
)
    THROW 57039, 'TEST 03 FAILED: Incremental is not COMPLETED.', 1;

IF EXISTS (SELECT 1 FROM dbo.refresh_run_row WHERE run_id = @IncrementalRun)
   OR EXISTS (SELECT 1 FROM dbo.refresh_run_delete WHERE run_id = @IncrementalRun)
   OR EXISTS (SELECT 1 FROM dbo.refresh_run_dirty_class WHERE run_id = @IncrementalRun)
    THROW 57040, 'TEST 03 FAILED: Incremental staging was not cleaned after FINALIZE.', 1;

PRINT 'PASS 03';


/* ============================================================================
   TEST 04 - DELETE-ONLY
   Explicitly verifies the current policy:
   DELETE -> historical class becomes dirty.
============================================================================ */
PRINT 'TEST 04 - delete-only incremental';

DECLARE @DeletedClass int;

SELECT @DeletedClass = m.class_id
FROM dbo.class_memory AS m
INNER JOIN dbo.refresh_process AS p ON p.process_id = m.process_id
WHERE p.process_name = N'test_rotating_ci'
  AND m.source_key = N'C003';

DELETE dbo.test_rotating_source
WHERE source_key = N'C003';

DECLARE @DeleteOnlyRun uniqueidentifier;

EXEC dbo.usp_prepare_incremental_run
    @ProcessName = N'test_rotating_ci',
    @RunId = @DeleteOnlyRun OUTPUT;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_run
    WHERE run_id = @DeleteOnlyRun
      AND insert_count = 0
      AND update_count = 0
      AND delete_count = 1
      AND dirty_class_count = 1
      AND window_start_class = 3
      AND candidate_next_window_start = 3
      AND status = 'PREPARED'
)
    THROW 57020, 'TEST 04 FAILED: unexpected DELETE-only header.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_dirty_class
    WHERE run_id = @DeleteOnlyRun
      AND class_id = @DeletedClass
)
    THROW 57021, 'TEST 04 FAILED: the DELETE historical class must be dirty.', 1;

IF EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_row
    WHERE run_id = @DeleteOnlyRun
      AND source_key = N'C003'
)
    THROW 57022, 'TEST 04 FAILED: deleted C003 must not be in the snapshot.', 1;

EXEC dbo.usp_finalize_refresh_run
    @RunId = @DeleteOnlyRun;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_process
    WHERE process_name = N'test_rotating_ci'
      AND next_window_start_class = 3
)
    THROW 57023, 'TEST 04 FAILED: DELETE-only must not consume the window.', 1;


IF EXISTS (SELECT 1 FROM dbo.refresh_run_row WHERE run_id = @DeleteOnlyRun)
   OR EXISTS (SELECT 1 FROM dbo.refresh_run_delete WHERE run_id = @DeleteOnlyRun)
   OR EXISTS (SELECT 1 FROM dbo.refresh_run_dirty_class WHERE run_id = @DeleteOnlyRun)
    THROW 57041, 'TEST 04 FAILED: DELETE-only staging was not cleaned after FINALIZE.', 1;

PRINT 'PASS 04';


/* ============================================================================
   TEST 05 - ZERO CHANGE
============================================================================ */
PRINT 'TEST 05 - zero-change incremental';

DECLARE @NoChangeRun uniqueidentifier;

EXEC dbo.usp_prepare_incremental_run
    @ProcessName = N'test_rotating_ci',
    @RunId = @NoChangeRun OUTPUT;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_run
    WHERE run_id = @NoChangeRun
      AND insert_count = 0
      AND update_count = 0
      AND delete_count = 0
      AND dirty_class_count = 0
      AND window_start_class = 3
      AND candidate_next_window_start = 3
)
    THROW 57024, 'TEST 05 FAILED: unexpected zero-change run.', 1;

EXEC dbo.usp_finalize_refresh_run @RunId = @NoChangeRun;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_process
    WHERE process_name = N'test_rotating_ci'
      AND next_window_start_class = 3
)
    THROW 57025, 'TEST 05 FAILED: zero-change must not consume the window.', 1;


IF EXISTS (SELECT 1 FROM dbo.refresh_run_row WHERE run_id = @NoChangeRun)
   OR EXISTS (SELECT 1 FROM dbo.refresh_run_delete WHERE run_id = @NoChangeRun)
   OR EXISTS (SELECT 1 FROM dbo.refresh_run_dirty_class WHERE run_id = @NoChangeRun)
    THROW 57042, 'TEST 05 FAILED: zero-change staging was not cleaned after FINALIZE.', 1;

PRINT 'PASS 05';


/* ============================================================================
   TEST 06 - ONE INSERT PER RUN, ADAPTIVE WINDOW = 1
   Policy 1:1 must automatically resolve the effective window to 1.
   Starting from 3, it must visit 3 -> 1 -> 2 and then return to 3.
============================================================================ */
PRINT 'TEST 06 - adaptive window_size=1 rotation';

DECLARE
    @R1 uniqueidentifier,
    @R2 uniqueidentifier,
    @R3 uniqueidentifier;

INSERT dbo.test_rotating_source VALUES
    (N'X001', '2026-08-19T12:00:00', N'x1');

EXEC dbo.usp_prepare_incremental_run
    @ProcessName = N'test_rotating_ci',
    @RunId = @R1 OUTPUT;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_run
    WHERE run_id = @R1
      AND insert_count = 1
      AND insert_window_size = 1
      AND window_start_class = 3
      AND candidate_next_window_start = 1
)
    THROW 57051, 'TEST 06 FAILED: policy 1:1 did not produce effective window 1.', 1;

IF NOT EXISTS
(
    SELECT 1 FROM dbo.refresh_run_row
    WHERE run_id = @R1
      AND source_key = N'X001'
      AND change_type = 'INSERT'
      AND class_id = 3
)
    THROW 57026, 'TEST 06 FAILED: X001 must enter class 3.', 1;

EXEC dbo.usp_finalize_refresh_run @RunId = @R1;

INSERT dbo.test_rotating_source VALUES
    (N'X002', '2026-08-19T12:01:00', N'x2');

EXEC dbo.usp_prepare_incremental_run
    @ProcessName = N'test_rotating_ci',
    @RunId = @R2 OUTPUT;

IF NOT EXISTS
(
    SELECT 1 FROM dbo.refresh_run_row
    WHERE run_id = @R2
      AND source_key = N'X002'
      AND change_type = 'INSERT'
      AND class_id = 1
)
    THROW 57027, 'TEST 06 FAILED: X002 must enter class 1.', 1;

EXEC dbo.usp_finalize_refresh_run @RunId = @R2;

INSERT dbo.test_rotating_source VALUES
    (N'X003', '2026-08-19T12:02:00', N'x3');

EXEC dbo.usp_prepare_incremental_run
    @ProcessName = N'test_rotating_ci',
    @RunId = @R3 OUTPUT;

IF NOT EXISTS
(
    SELECT 1 FROM dbo.refresh_run_row
    WHERE run_id = @R3
      AND source_key = N'X003'
      AND change_type = 'INSERT'
      AND class_id = 2
)
    THROW 57028, 'TEST 06 FAILED: X003 must enter class 2.', 1;

EXEC dbo.usp_finalize_refresh_run @RunId = @R3;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_process
    WHERE process_name = N'test_rotating_ci'
      AND next_window_start_class = 3
      AND default_insert_window_size = 2
)
    THROW 57029, 'TEST 06 FAILED: rotation 3->1->2->3 or default window is incorrect.', 1;


IF EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_row
    WHERE run_id IN (@R1, @R2, @R3)
)
   OR EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_delete
    WHERE run_id IN (@R1, @R2, @R3)
)
   OR EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_dirty_class
    WHERE run_id IN (@R1, @R2, @R3)
)
    THROW 57043, 'TEST 06 FAILED: rotation-run staging was not cleaned.', 1;

PRINT 'PASS 06';


/* ============================================================================
   TEST 07 - FULL IGNORES NEW UNCLASSIFIED KEYS
============================================================================ */
PRINT 'TEST 07 - full semantics';

INSERT dbo.test_rotating_source VALUES
    (N'FULL-NEW', '2026-08-19T13:00:00', N'unclassified');

UPDATE dbo.test_rotating_source
SET event_timestamp = '2026-08-19T13:05:00',
    value_text = N'A changed before full'
WHERE source_key = N'A001';

DECLARE
    @MemoryBeforeFull int,
    @WindowBeforeFull int,
    @FullRun uniqueidentifier;

SELECT @MemoryBeforeFull = COUNT(*)
FROM dbo.class_memory AS m
INNER JOIN dbo.refresh_process AS p ON p.process_id = m.process_id
WHERE p.process_name = N'test_rotating_ci';

SELECT @WindowBeforeFull = next_window_start_class
FROM dbo.refresh_process
WHERE process_name = N'test_rotating_ci';

EXEC dbo.usp_prepare_full_run
    @ProcessName = N'test_rotating_ci',
    @RunId = @FullRun OUTPUT;

IF (SELECT COUNT(*) FROM dbo.refresh_run_row WHERE run_id = @FullRun) <> @MemoryBeforeFull
    THROW 57030, 'TEST 07 FAILED: FULL must include only already-classified keys.', 1;

IF EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_row
    WHERE run_id = @FullRun
      AND source_key = N'FULL-NEW'
)
    THROW 57031, 'TEST 07 FAILED: FULL-NEW must not enter the FULL run.', 1;

IF EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_row
    WHERE run_id = @FullRun
      AND change_type <> 'FULL'
)
    THROW 57032, 'TEST 07 FAILED: all FULL rows must have change_type FULL.', 1;

IF (SELECT COUNT(*) FROM dbo.refresh_run_dirty_class WHERE run_id = @FullRun) <> 3
    THROW 57033, 'TEST 07 FAILED: FULL must make all classes dirty.', 1;

EXEC dbo.usp_finalize_refresh_run @RunId = @FullRun;

IF EXISTS
(
    SELECT 1
    FROM dbo.class_memory AS m
    INNER JOIN dbo.refresh_process AS p ON p.process_id = m.process_id
    WHERE p.process_name = N'test_rotating_ci'
      AND m.source_key = N'FULL-NEW'
)
    THROW 57034, 'TEST 07 FAILED: FULL-NEW must not enter memory.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_process
    WHERE process_name = N'test_rotating_ci'
      AND next_window_start_class = @WindowBeforeFull
)
    THROW 57035, 'TEST 07 FAILED: FULL must not advance the rotating window.', 1;


IF EXISTS (SELECT 1 FROM dbo.refresh_run_row WHERE run_id = @FullRun)
   OR EXISTS (SELECT 1 FROM dbo.refresh_run_delete WHERE run_id = @FullRun)
   OR EXISTS (SELECT 1 FROM dbo.refresh_run_dirty_class WHERE run_id = @FullRun)
    THROW 57044, 'TEST 07 FAILED: FULL staging was not cleaned after FINALIZE.', 1;

PRINT 'PASS 07';


/* ============================================================================
   TEST 08 - DIRTY CLASS API
============================================================================ */
PRINT 'TEST 08 - usp_get_dirty_class';

UPDATE dbo.test_rotating_source
SET event_timestamp = DATEADD(second, 1, event_timestamp),
    value_text = N'B api test'
WHERE source_key = N'B002';

DECLARE
    @ApiRun uniqueidentifier,
    @ApiClass int;

EXEC dbo.usp_prepare_incremental_run
    @ProcessName = N'test_rotating_ci',
    @RunId = @ApiRun OUTPUT;

SELECT TOP (1) @ApiClass = class_id
FROM dbo.refresh_run_dirty_class
WHERE run_id = @ApiRun
ORDER BY class_id;

CREATE TABLE #DirtyClassResult
(
    source_key       nvarchar(450),
    event_timestamp  datetime2(7),
    payload_json     nvarchar(max),
    class_id         int
);

INSERT #DirtyClassResult
EXEC dbo.usp_get_dirty_class
    @RunId = @ApiRun,
    @ClassId = @ApiClass;

IF (SELECT COUNT(*) FROM #DirtyClassResult) <>
   (SELECT COUNT(*) FROM dbo.refresh_run_row WHERE run_id = @ApiRun AND class_id = @ApiClass)
    THROW 57036, 'TEST 08 FAILED: usp_get_dirty_class does not match the snapshot.', 1;

IF EXISTS
(
    SELECT 1
    FROM #DirtyClassResult
    WHERE class_id <> @ApiClass
)
    THROW 57037, 'TEST 08 FAILED: usp_get_dirty_class returned a different class.', 1;

DROP TABLE #DirtyClassResult;

EXEC dbo.usp_finalize_refresh_run @RunId = @ApiRun;


IF EXISTS (SELECT 1 FROM dbo.refresh_run_row WHERE run_id = @ApiRun)
   OR EXISTS (SELECT 1 FROM dbo.refresh_run_delete WHERE run_id = @ApiRun)
   OR EXISTS (SELECT 1 FROM dbo.refresh_run_dirty_class WHERE run_id = @ApiRun)
    THROW 57045, 'TEST 08 FAILED: API-run staging was not cleaned after FINALIZE.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_run
    WHERE run_id = @ApiRun
      AND status = 'COMPLETED'
)
    THROW 57046, 'TEST 08 FAILED: refresh_run history was not preserved as COMPLETED.', 1;

PRINT 'PASS 08';


/* ============================================================================
   FINAL INVARIANT - completed runs keep only lightweight refresh_run history.
   No operational staging may survive for this test process.
============================================================================ */
IF EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_row AS rr
    INNER JOIN dbo.refresh_run AS r ON r.run_id = rr.run_id
    INNER JOIN dbo.refresh_process AS p ON p.process_id = r.process_id
    WHERE p.process_name = N'test_rotating_ci'
      AND r.status = 'COMPLETED'
)
    THROW 57047, 'FINAL CHECK FAILED: refresh_run_row exists for a COMPLETED run.', 1;

IF EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_delete AS d
    INNER JOIN dbo.refresh_run AS r ON r.run_id = d.run_id
    INNER JOIN dbo.refresh_process AS p ON p.process_id = r.process_id
    WHERE p.process_name = N'test_rotating_ci'
      AND r.status = 'COMPLETED'
)
    THROW 57048, 'FINAL CHECK FAILED: refresh_run_delete exists for a COMPLETED run.', 1;

IF EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_dirty_class AS d
    INNER JOIN dbo.refresh_run AS r ON r.run_id = d.run_id
    INNER JOIN dbo.refresh_process AS p ON p.process_id = r.process_id
    WHERE p.process_name = N'test_rotating_ci'
      AND r.status = 'COMPLETED'
)
    THROW 57049, 'FINAL CHECK FAILED: dirty class exists for a COMPLETED run.', 1;


PRINT '============================================================';PRINT 'ALL AUTOMATED INTEGRATION TESTS PASSED';
PRINT '============================================================';

SELECT
    r.run_type,
    r.status,
    COUNT(*) AS runs
FROM dbo.refresh_run AS r
INNER JOIN dbo.refresh_process AS p ON p.process_id = r.process_id
WHERE p.process_name = N'test_rotating_ci'
GROUP BY r.run_type, r.status
ORDER BY r.run_type, r.status;
GO
