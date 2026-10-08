USE StableClassDemo;
GO

/*
===============================================================================
 NEGATIVE / BREAK TESTS
===============================================================================

These tests intentionally perform invalid or failure-prone operations.

A test PASSES when the framework rejects the operation with the expected
error or preserves state after an injected failure.

The script uses isolated process names.
===============================================================================
*/

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* Helper test source ------------------------------------------------------- */
DECLARE @ProcessId int;

SELECT @ProcessId = process_id
FROM dbo.refresh_process
WHERE process_name IN (N'test_break_ci', N'test_empty_ci');

DECLARE @ids TABLE(process_id int PRIMARY KEY);
INSERT @ids(process_id)
SELECT process_id
FROM dbo.refresh_process
WHERE process_name IN (N'test_break_ci', N'test_empty_ci');

DELETE d
FROM dbo.refresh_run_dirty_class AS d
INNER JOIN dbo.refresh_run AS r ON r.run_id = d.run_id
INNER JOIN @ids AS x ON x.process_id = r.process_id;

DELETE d
FROM dbo.refresh_run_delete AS d
INNER JOIN dbo.refresh_run AS r ON r.run_id = d.run_id
INNER JOIN @ids AS x ON x.process_id = r.process_id;

DELETE rr
FROM dbo.refresh_run_row AS rr
INNER JOIN dbo.refresh_run AS r ON r.run_id = rr.run_id
INNER JOIN @ids AS x ON x.process_id = r.process_id;

DELETE r
FROM dbo.refresh_run AS r
INNER JOIN @ids AS x ON x.process_id = r.process_id;

DELETE m
FROM dbo.class_memory AS m
INNER JOIN @ids AS x ON x.process_id = m.process_id;

DELETE p
FROM dbo.refresh_process AS p
INNER JOIN @ids AS x ON x.process_id = p.process_id;
GO

DROP VIEW IF EXISTS dbo.vw_test_break_adapter;
DROP TABLE IF EXISTS dbo.test_break_source;
GO

CREATE TABLE dbo.test_break_source
(
    source_key       nvarchar(100) NOT NULL
        CONSTRAINT PK_test_break_source PRIMARY KEY,
    event_timestamp  datetime2(7) NOT NULL,
    value_text       nvarchar(200) NOT NULL
);
GO

CREATE VIEW dbo.vw_test_break_adapter
AS
SELECT
    CONVERT(nvarchar(450), source_key) AS source_key,
    event_timestamp,
    (
        SELECT source_key, event_timestamp, value_text
        FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
    ) AS payload_json
FROM dbo.test_break_source;
GO

INSERT dbo.test_break_source VALUES
    (N'A001', '2026-08-20T08:00:00', N'A'),
    (N'B002', '2026-08-20T08:01:00', N'B'),
    (N'C003', '2026-08-20T08:02:00', N'C');
GO

/* ============================================================================
   BREAK 01 - invalid registration: total_classes = 0 -> 55000
============================================================================ */
PRINT 'BREAK 01 - invalid total_classes';

DECLARE @Caught bit = 0;

BEGIN TRY
    EXEC dbo.usp_register_refresh_process
        @ProcessName = N'invalid_zero_classes',
        @AdapterSchema = N'dbo',
        @AdapterView = N'vw_test_break_adapter',
        @TotalClasses = 0,
        @DefaultInsertWindowSize = 1;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 55000
        SET @Caught = 1;
    ELSE
        THROW;
END CATCH;

IF @Caught = 0
    THROW 57101, 'BREAK 01 FAILED: total_classes=0 was not rejected.', 1;

PRINT 'PASS BREAK 01';


/* ============================================================================
   BREAK 02 - invalid registration: window > total -> 55001
============================================================================ */
PRINT 'BREAK 02 - invalid default window';

SET @Caught = 0;

BEGIN TRY
    EXEC dbo.usp_register_refresh_process
        @ProcessName = N'invalid_window',
        @AdapterSchema = N'dbo',
        @AdapterView = N'vw_test_break_adapter',
        @TotalClasses = 3,
        @DefaultInsertWindowSize = 4;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 55001
        SET @Caught = 1;
    ELSE
        THROW;
END CATCH;

IF @Caught = 0
    THROW 57102, 'BREAK 02 FAILED: window > total was not rejected.', 1;

PRINT 'PASS BREAK 02';


/* ============================================================================
   BREAK 03 - unknown process Bootstrap -> 55100
============================================================================ */
PRINT 'BREAK 03 - bootstrap unknown process';

DECLARE @RunId uniqueidentifier;
SET @Caught = 0;

BEGIN TRY
    EXEC dbo.usp_prepare_bootstrap_run
        @ProcessName = N'process_does_not_exist',
        @RunId = @RunId OUTPUT;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 55100
        SET @Caught = 1;
    ELSE
        THROW;
END CATCH;

IF @Caught = 0
    THROW 57103, 'BREAK 03 FAILED: unknown process was not rejected.', 1;

PRINT 'PASS BREAK 03';


/* Setup valid process ------------------------------------------------------ */
EXEC dbo.usp_register_refresh_process
    @ProcessName = N'test_break_ci',
    @AdapterSchema = N'dbo',
    @AdapterView = N'vw_test_break_adapter',
    @TotalClasses = 3,
    @DefaultInsertWindowSize = 2;


/* ============================================================================
   BREAK 04 - Incremental before Bootstrap -> 55201
============================================================================ */
PRINT 'BREAK 04 - incremental before bootstrap';

SET @Caught = 0;

BEGIN TRY
    EXEC dbo.usp_prepare_incremental_run
        @ProcessName = N'test_break_ci',
        @RunId = @RunId OUTPUT;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 55201
        SET @Caught = 1;
    ELSE
        THROW;
END CATCH;

IF @Caught = 0
    THROW 57104, 'BREAK 04 FAILED: incremental without memory was not rejected.', 1;

PRINT 'PASS BREAK 04';


/* ============================================================================
   BREAK 05 - Full before Bootstrap -> 55301
============================================================================ */
PRINT 'BREAK 05 - full before bootstrap';

SET @Caught = 0;

BEGIN TRY
    EXEC dbo.usp_prepare_full_run
        @ProcessName = N'test_break_ci',
        @RunId = @RunId OUTPUT;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 55301
        SET @Caught = 1;
    ELSE
        THROW;
END CATCH;

IF @Caught = 0
    THROW 57105, 'BREAK 05 FAILED: full without memory was not rejected.', 1;

PRINT 'PASS BREAK 05';


/* ============================================================================
   BREAK 06 - second PREPARED run must be rejected
============================================================================ */
PRINT 'BREAK 06 - duplicate PREPARED run';

DECLARE @BootstrapRun uniqueidentifier;

EXEC dbo.usp_prepare_bootstrap_run
    @ProcessName = N'test_break_ci',
    @RunId = @BootstrapRun OUTPUT;

SET @Caught = 0;

BEGIN TRY
    EXEC dbo.usp_prepare_bootstrap_run
        @ProcessName = N'test_break_ci',
        @RunId = @RunId OUTPUT;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 55102
        SET @Caught = 1;
    ELSE
        THROW;
END CATCH;

IF @Caught = 0
    THROW 57106, 'BREAK 06 FAILED: second PREPARED run was not rejected.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_run
    WHERE run_id = @BootstrapRun
      AND status = 'PREPARED'
)
    THROW 57107, 'BREAK 06 FAILED: the original PREPARED run was altered.', 1;

PRINT 'PASS BREAK 06';

EXEC dbo.usp_finalize_refresh_run @RunId = @BootstrapRun;


/* ============================================================================
   BREAK 07 - Bootstrap with non-empty memory -> 55101
============================================================================ */
PRINT 'BREAK 07 - bootstrap after bootstrap';

SET @Caught = 0;

BEGIN TRY
    EXEC dbo.usp_prepare_bootstrap_run
        @ProcessName = N'test_break_ci',
        @RunId = @RunId OUTPUT;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 55101
        SET @Caught = 1;
    ELSE
        THROW;
END CATCH;

IF @Caught = 0
    THROW 57108, 'BREAK 07 FAILED: bootstrap with populated memory was not rejected.', 1;

PRINT 'PASS BREAK 07';


/* ============================================================================
   BREAK 08 - invalid per-run window -> 55203
============================================================================ */
PRINT 'BREAK 08 - invalid incremental override';

SET @Caught = 0;

BEGIN TRY
    EXEC dbo.usp_prepare_incremental_run
        @ProcessName = N'test_break_ci',
        @InsertWindowSize = 99,
        @RunId = @RunId OUTPUT;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 55203
        SET @Caught = 1;
    ELSE
        THROW;
END CATCH;

IF @Caught = 0
    THROW 57109, 'BREAK 08 FAILED: invalid window override was not rejected.', 1;

PRINT 'PASS BREAK 08';


/* ============================================================================
   BREAK 09 - change total_classes with populated memory -> 55002
============================================================================ */
PRINT 'BREAK 09 - total_classes repartition guard';

SET @Caught = 0;

BEGIN TRY
    EXEC dbo.usp_register_refresh_process
        @ProcessName = N'test_break_ci',
        @AdapterSchema = N'dbo',
        @AdapterView = N'vw_test_break_adapter',
        @TotalClasses = 4,
        @DefaultInsertWindowSize = 2;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 55002
        SET @Caught = 1;
    ELSE
        THROW;
END CATCH;

IF @Caught = 0
    THROW 57110, 'BREAK 09 FAILED: total_classes change was not rejected.', 1;

PRINT 'PASS BREAK 09';


/* ============================================================================
   BREAK 10 - get non-dirty class -> 55400
============================================================================ */
PRINT 'BREAK 10 - get non-dirty class';

UPDATE dbo.test_break_source
SET event_timestamp = '2026-08-20T09:00:00',
    value_text = N'A updated'
WHERE source_key = N'A001';

DECLARE
    @OneDirtyRun uniqueidentifier,
    @DirtyClass int,
    @NonDirtyClass int;

EXEC dbo.usp_prepare_incremental_run
    @ProcessName = N'test_break_ci',
    @RunId = @OneDirtyRun OUTPUT;

SELECT TOP (1) @DirtyClass = class_id
FROM dbo.refresh_run_dirty_class
WHERE run_id = @OneDirtyRun;

SELECT TOP (1) @NonDirtyClass = v.class_id
FROM (VALUES (1),(2),(3)) AS v(class_id)
WHERE v.class_id <> @DirtyClass
  AND NOT EXISTS
  (
      SELECT 1
      FROM dbo.refresh_run_dirty_class AS d
      WHERE d.run_id = @OneDirtyRun
        AND d.class_id = v.class_id
  )
ORDER BY v.class_id;

IF @NonDirtyClass IS NOT NULL
BEGIN
    SET @Caught = 0;

    BEGIN TRY
        EXEC dbo.usp_get_dirty_class
            @RunId = @OneDirtyRun,
            @ClassId = @NonDirtyClass;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() = 55400
            SET @Caught = 1;
        ELSE
            THROW;
    END CATCH;

    IF @Caught = 0
        THROW 57111, 'BREAK 10 FAILED: get_dirty_class accepted a non-dirty class.', 1;
END;

PRINT 'PASS BREAK 10';

EXEC dbo.usp_finalize_refresh_run @RunId = @OneDirtyRun;


/* ============================================================================
   BREAK 11 - finalize same run twice -> 55500
============================================================================ */
PRINT 'BREAK 11 - double finalize';

SET @Caught = 0;

BEGIN TRY
    EXEC dbo.usp_finalize_refresh_run
        @RunId = @OneDirtyRun;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 55500
        SET @Caught = 1;
    ELSE
        THROW;
END CATCH;

IF @Caught = 0
    THROW 57112, 'BREAK 11 FAILED: double finalize was not rejected.', 1;

PRINT 'PASS BREAK 11';


/* ============================================================================
   BREAK 12 - consumer failure semantics:
   leave a run PREPARED, next prepare must fail, same run remains reusable.

   New staging lifecycle:
   - while PREPARED, operational staging must still exist;
   - after successful FINALIZE, staging for that RunId must be removed.
============================================================================ */
PRINT 'BREAK 12 - simulated consumer failure / retry';

INSERT dbo.test_break_source VALUES
    (N'NEW1', '2026-08-20T10:00:00', N'new');

DECLARE
    @PreparedRun uniqueidentifier,
    @MemoryBefore int,
    @LastSuccessfulBefore uniqueidentifier;

SELECT @MemoryBefore = COUNT(*)
FROM dbo.class_memory AS m
INNER JOIN dbo.refresh_process AS p ON p.process_id = m.process_id
WHERE p.process_name = N'test_break_ci';

SELECT @LastSuccessfulBefore = last_successful_run_id
FROM dbo.refresh_process
WHERE process_name = N'test_break_ci';

EXEC dbo.usp_prepare_incremental_run
    @ProcessName = N'test_break_ci',
    @RunId = @PreparedRun OUTPUT;

/* Simulate downstream failure: DO NOT finalize. */
SET @Caught = 0;

BEGIN TRY
    EXEC dbo.usp_prepare_incremental_run
        @ProcessName = N'test_break_ci',
        @RunId = @RunId OUTPUT;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 55202
        SET @Caught = 1;
    ELSE
        THROW;
END CATCH;

IF @Caught = 0
    THROW 57113, 'BREAK 12 FAILED: new prepare was allowed with an existing PREPARED run.', 1;

IF
(
    SELECT COUNT(*)
    FROM dbo.class_memory AS m
    INNER JOIN dbo.refresh_process AS p ON p.process_id = m.process_id
    WHERE p.process_name = N'test_break_ci'
) <> @MemoryBefore
    THROW 57114, 'BREAK 12 FAILED: PREPARE modified official memory.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_process
    WHERE process_name = N'test_break_ci'
      AND last_successful_run_id = @LastSuccessfulBefore
)
    THROW 57115, 'BREAK 12 FAILED: last_successful_run_id changed before finalize.', 1;

/*
   A PREPARED run must still own the operational staging needed
   by the consumer and by FINALIZE.
*/
IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_row
    WHERE run_id = @PreparedRun
)
    THROW 57123, 'BREAK 12 FAILED: refresh_run_row disappeared before finalize.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_dirty_class
    WHERE run_id = @PreparedRun
)
    THROW 57124, 'BREAK 12 FAILED: dirty classes disappeared before finalize.', 1;

/* Retry uses the same materialized run. */
EXEC dbo.usp_finalize_refresh_run @RunId = @PreparedRun;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_process
    WHERE process_name = N'test_break_ci'
      AND last_successful_run_id = @PreparedRun
)
    THROW 57116, 'BREAK 12 FAILED: retry/finalize of the same run did not succeed.', 1;

/*
   Successful FINALIZE must remove all operational staging.
   refresh_run remains as lightweight audit history.
*/
IF EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_row
    WHERE run_id = @PreparedRun
)
    THROW 57125, 'BREAK 12 FAILED: refresh_run_row was not cleaned after finalize.', 1;

IF EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_delete
    WHERE run_id = @PreparedRun
)
    THROW 57126, 'BREAK 12 FAILED: refresh_run_delete was not cleaned after finalize.', 1;

IF EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_dirty_class
    WHERE run_id = @PreparedRun
)
    THROW 57127, 'BREAK 12 FAILED: dirty classes were not cleaned after finalize.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_run
    WHERE run_id = @PreparedRun
      AND status = 'COMPLETED'
)
    THROW 57137, 'BREAK 12 FAILED: historical refresh_run was not preserved as COMPLETED.', 1;

PRINT 'PASS BREAK 12';


/* ============================================================================
   BREAK 13 - source changes after PREPARE:
   FINALIZE must promote the materialized snapshot, not reread the source.

   After successful FINALIZE, the old run staging must be removed.
============================================================================ */
PRINT 'BREAK 13 - source mutation between prepare and finalize';

UPDATE dbo.test_break_source
SET event_timestamp = '2026-08-20T11:00:00',
    value_text = N'B prepared value'
WHERE source_key = N'B002';

DECLARE
    @SnapshotRun uniqueidentifier,
    @PreparedTimestamp datetime2(7);

EXEC dbo.usp_prepare_incremental_run
    @ProcessName = N'test_break_ci',
    @RunId = @SnapshotRun OUTPUT;

SELECT @PreparedTimestamp = event_timestamp
FROM dbo.refresh_run_row
WHERE run_id = @SnapshotRun
  AND source_key = N'B002';

/* Source changes AFTER prepare. */
UPDATE dbo.test_break_source
SET event_timestamp = '2026-08-20T11:30:00',
    value_text = N'B changed after prepare'
WHERE source_key = N'B002';

EXEC dbo.usp_finalize_refresh_run @RunId = @SnapshotRun;

/*
   FINALIZE must promote the PREPARED snapshot (11:00),
   not reread the source value changed later (11:30).
*/
IF NOT EXISTS
(
    SELECT 1
    FROM dbo.class_memory AS m
    INNER JOIN dbo.refresh_process AS p ON p.process_id = m.process_id
    WHERE p.process_name = N'test_break_ci'
      AND m.source_key = N'B002'
      AND m.last_timestamp = @PreparedTimestamp
)
    THROW 57117, 'BREAK 13 FAILED: finalize did not promote the materialized snapshot.', 1;

/* The promoted snapshot is no longer needed after successful FINALIZE. */
IF EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_row
    WHERE run_id = @SnapshotRun
)
    THROW 57128, 'BREAK 13 FAILED: materialized snapshot was not cleaned after finalize.', 1;

IF EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_dirty_class
    WHERE run_id = @SnapshotRun
)
    THROW 57129, 'BREAK 13 FAILED: dirty classes were not cleaned after finalize.', 1;

IF EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_delete
    WHERE run_id = @SnapshotRun
)
    THROW 57130, 'BREAK 13 FAILED: delete staging was not cleaned after finalize.', 1;

/* The later source change must be visible to the NEXT incremental. */
DECLARE @NextRun uniqueidentifier;

EXEC dbo.usp_prepare_incremental_run
    @ProcessName = N'test_break_ci',
    @RunId = @NextRun OUTPUT;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_row
    WHERE run_id = @NextRun
      AND source_key = N'B002'
      AND change_type = 'UPDATE'
      AND event_timestamp = '2026-08-20T11:30:00'
)
    THROW 57118, 'BREAK 13 FAILED: post-PREPARE change was not detected in the next run.', 1;

EXEC dbo.usp_finalize_refresh_run @RunId = @NextRun;

IF EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_row
    WHERE run_id = @NextRun
)
    THROW 57138, 'BREAK 13 FAILED: next-run staging was not cleaned after finalize.', 1;

PRINT 'PASS BREAK 13';


/* ============================================================================
   BREAK 14 - injected FINALIZE failure / transaction rollback

   The failure is injected AFTER the operational staging cleanup has executed,
   by throwing from an AFTER UPDATE trigger on refresh_run when the run is
   being marked COMPLETED.

   This proves that rollback restores:
   - class_memory;
   - refresh_process state;
   - refresh_run status;
   - refresh_run_row;
   - refresh_run_delete;
   - refresh_run_dirty_class.
============================================================================ */
PRINT 'BREAK 14 - injected finalize failure rollback';

INSERT dbo.test_break_source VALUES
    (N'ROLLBACK1', '2026-08-20T12:00:00', N'rollback test');

DECLARE @RollbackRun uniqueidentifier;

EXEC dbo.usp_prepare_incremental_run
    @ProcessName = N'test_break_ci',
    @RunId = @RollbackRun OUTPUT;

GO

/*
   Temporary trigger used only by this test.

   In the updated FINALIZE, refresh_run is marked COMPLETED only AFTER:
   - class_memory promotion;
   - process-state update;
   - deletion of run staging.

   Throwing here therefore exercises rollback after the cleanup has already
   happened inside the transaction.
*/
CREATE OR ALTER TRIGGER dbo.trg_test_force_finalize_failure
ON dbo.refresh_run
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF TRY_CONVERT(int, SESSION_CONTEXT(N'force_finalize_failure')) = 1
       AND EXISTS
       (
           SELECT 1
           FROM inserted AS i
           INNER JOIN dbo.refresh_process AS p
               ON p.process_id = i.process_id
           WHERE p.process_name = N'test_break_ci'
             AND i.status = 'COMPLETED'
       )
    BEGIN
        THROW 57999, 'Injected finalize failure after staging cleanup.', 1;
    END;
END;
GO

DECLARE
    @RollbackRun uniqueidentifier,
    @BreakProcessId int,
    @MemoryBeforeFailure int,
    @LastRunBeforeFailure uniqueidentifier,
    @RunRowsBeforeFailure int,
    @DirtyBeforeFailure int,
    @DeletesBeforeFailure int,
    @Caught bit = 0;

SELECT @RollbackRun = r.run_id
FROM dbo.refresh_run AS r
INNER JOIN dbo.refresh_process AS p ON p.process_id = r.process_id
WHERE p.process_name = N'test_break_ci'
  AND r.run_type = 'INCREMENTAL'
  AND r.status = 'PREPARED';

IF @RollbackRun IS NULL
    THROW 57139, 'BREAK 14 FAILED: PREPARED run not found for failure injection.', 1;

SELECT
    @BreakProcessId = process_id,
    @LastRunBeforeFailure = last_successful_run_id
FROM dbo.refresh_process
WHERE process_name = N'test_break_ci';

SELECT @MemoryBeforeFailure = COUNT(*)
FROM dbo.class_memory
WHERE process_id = @BreakProcessId;

SELECT @RunRowsBeforeFailure = COUNT(*)
FROM dbo.refresh_run_row
WHERE run_id = @RollbackRun;

SELECT @DirtyBeforeFailure = COUNT(*)
FROM dbo.refresh_run_dirty_class
WHERE run_id = @RollbackRun;

SELECT @DeletesBeforeFailure = COUNT(*)
FROM dbo.refresh_run_delete
WHERE run_id = @RollbackRun;

IF @RunRowsBeforeFailure = 0
    THROW 57140, 'BREAK 14 FAILED: PREPARED run has no refresh_run_row.', 1;

IF @DirtyBeforeFailure = 0
    THROW 57141, 'BREAK 14 FAILED: PREPARED run has no dirty classes.', 1;

EXEC sys.sp_set_session_context
    @key = N'force_finalize_failure',
    @value = 1;

BEGIN TRY
    EXEC dbo.usp_finalize_refresh_run @RunId = @RollbackRun;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 57999
        SET @Caught = 1;
    ELSE
        THROW;
END CATCH;

EXEC sys.sp_set_session_context
    @key = N'force_finalize_failure',
    @value = NULL;

IF @Caught = 0
    THROW 57119, 'BREAK 14 FAILED: failure injection did not trigger.', 1;

/* Run state must have rolled back. */
IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_run
    WHERE run_id = @RollbackRun
      AND status = 'PREPARED'
)
    THROW 57120, 'BREAK 14 FAILED: run did not remain PREPARED after rollback.', 1;

/* Official memory must have rolled back. */
IF
(
    SELECT COUNT(*)
    FROM dbo.class_memory
    WHERE process_id = @BreakProcessId
) <> @MemoryBeforeFailure
    THROW 57121, 'BREAK 14 FAILED: class_memory was not rolled back.', 1;

/* Process state must have rolled back. */
IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_process
    WHERE process_id = @BreakProcessId
      AND last_successful_run_id = @LastRunBeforeFailure
)
    THROW 57122, 'BREAK 14 FAILED: process state was not rolled back.', 1;

/*
   Operational staging had already been deleted inside FINALIZE before
   the injected error. The transaction rollback must restore it exactly.
*/
IF
(
    SELECT COUNT(*)
    FROM dbo.refresh_run_row
    WHERE run_id = @RollbackRun
) <> @RunRowsBeforeFailure
    THROW 57131, 'BREAK 14 FAILED: refresh_run_row was not restored by rollback.', 1;

IF
(
    SELECT COUNT(*)
    FROM dbo.refresh_run_dirty_class
    WHERE run_id = @RollbackRun
) <> @DirtyBeforeFailure
    THROW 57132, 'BREAK 14 FAILED: dirty classes were not restored by rollback.', 1;

IF
(
    SELECT COUNT(*)
    FROM dbo.refresh_run_delete
    WHERE run_id = @RollbackRun
) <> @DeletesBeforeFailure
    THROW 57133, 'BREAK 14 FAILED: refresh_run_delete was not restored by rollback.', 1;

/* Same PREPARED run can now be finalized successfully. */
EXEC dbo.usp_finalize_refresh_run @RunId = @RollbackRun;

/* Successful retry must finally remove all operational staging. */
IF EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_row
    WHERE run_id = @RollbackRun
)
    THROW 57134, 'BREAK 14 FAILED: refresh_run_row remained after successful retry.', 1;

IF EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_dirty_class
    WHERE run_id = @RollbackRun
)
    THROW 57135, 'BREAK 14 FAILED: dirty classes remained after successful retry.', 1;

IF EXISTS
(
    SELECT 1
    FROM dbo.refresh_run_delete
    WHERE run_id = @RollbackRun
)
    THROW 57136, 'BREAK 14 FAILED: delete staging remained after successful retry.', 1;

IF NOT EXISTS
(
    SELECT 1
    FROM dbo.refresh_run
    WHERE run_id = @RollbackRun
      AND status = 'COMPLETED'
)
    THROW 57142, 'BREAK 14 FAILED: run is not COMPLETED after successful retry.', 1;

DROP TRIGGER dbo.trg_test_force_finalize_failure;

PRINT 'PASS BREAK 14';


PRINT '============================================================';
PRINT 'ALL NEGATIVE / BREAK TESTS PASSED';
PRINT '============================================================';
GO
