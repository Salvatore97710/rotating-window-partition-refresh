/*
===============================================================================
 ROTATING WINDOW PARTITION REFRESH - GUIDED DEMO / FUNCTIONAL SMOKE TEST
===============================================================================

PREREQUISITES

Run first, in this order:

1. schema.sql
2. demo_source.sql
3. register_process.sql
4. prepare_bootstrap.sql
5. prepare_incremental.sql
6. prepare_full.sql
7. get_dirty_class.sql
8. finalize_run.sql

This demo uses:

    total_classes = 3
    insert_window_size = 2

IMPORTANT
---------
Run ONE BLOCK AT A TIME and verify the results indicated in the comments.

Expected initial state:

    dbo.demo_rotating_source     -> 6 rows
    dbo.class_memory             -> 0 rows
    dbo.refresh_run              -> 0 rows

===============================================================================
*/


/* ============================================================================
   STEP 0 - VERIFY INITIAL STATE

   RUN THIS BLOCK FIRST.

   EXPECTED:
   - source_count = 6
   - memory_count = 0
   - run_count    = 0
============================================================================ */

SELECT COUNT(*) AS source_count
FROM dbo.demo_rotating_source;

SELECT COUNT(*) AS memory_count
FROM dbo.class_memory;

SELECT COUNT(*) AS run_count
FROM dbo.refresh_run;


/* ============================================================================
   STEP 1 - REGISTER PROCESS

   Registers the refresh process.

   Configuration:
   - 3 total classes
   - rotating window of 2 classes

   AFTER EXECUTION CHECK refresh_process.

   EXPECTED:
   total_classes              = 3
   default_insert_window_size = 2
   next_window_start_class    = 1
   last_successful_run_id     = NULL
============================================================================ */

EXEC dbo.usp_register_refresh_process
    @ProcessName = N'demo_rotating',
    @AdapterSchema = N'dbo',
    @AdapterView = N'vw_demo_rotating_adapter',
    @TotalClasses = 3,
    @DefaultInsertWindowSize = 2;

SELECT *
FROM dbo.refresh_process
WHERE process_name = N'demo_rotating';

GO

/* ============================================================================
   STEP 2 - PREPARE BOOTSTRAP

   Bootstrap assigns an initial class to all source records.

   EXPECTED:
   - refresh_run_row       -> 6 rows
   - change_type           -> BOOTSTRAP for all rows
   - class_id              -> values between 1 and 3
   - dirty classes         -> 1, 2, 3

   WARNING:
   The source_key -> class_id association is NOT deterministic.
============================================================================ */

DECLARE @BootstrapRun uniqueidentifier;

EXEC dbo.usp_prepare_bootstrap_run
    @ProcessName = N'demo_rotating',
    @RunId = @BootstrapRun OUTPUT;

SELECT @BootstrapRun AS bootstrap_run_id;

SELECT *
FROM dbo.refresh_run
WHERE run_id = @BootstrapRun;

SELECT *
FROM dbo.refresh_run_row
WHERE run_id = @BootstrapRun;

SELECT *
FROM dbo.refresh_run_dirty_class
WHERE run_id = @BootstrapRun;


/* ============================================================================
   CHECK BOOTSTRAP

   The following checks must return:

   run_rows      = 6
   dirty_classes = 3
============================================================================ */

SELECT COUNT(*) AS run_rows
FROM dbo.refresh_run_row
WHERE run_id = @BootstrapRun;

SELECT COUNT(*) AS dirty_classes
FROM dbo.refresh_run_dirty_class
WHERE run_id = @BootstrapRun;

GO

/* ============================================================================
   STEP 3 - FINALIZE BOOTSTRAP

   The BOOTSTRAP run is currently PREPARED.

   In a real system this must be called ONLY after successful
   downstream loading.

   In the demo we simulate that the consumer completed successfully.

   EXPECTED AFTER FINALIZE:
   - refresh_run.status                 = COMPLETED
   - class_memory                       = 6 rows
   - last_successful_run_id             = bootstrap RunId
   - next_window_start_class            = 1
   - refresh_run_row                    = 0 rows for this RunId
   - refresh_run_delete                 = 0 rows for this RunId
   - refresh_run_dirty_class            = 0 rows for this RunId
============================================================================ */
DECLARE @BootstrapRun uniqueidentifier;

/* Retrieves the run left PREPARED by the previous step */
SELECT
    @BootstrapRun = r.run_id
FROM dbo.refresh_run AS r
INNER JOIN dbo.refresh_process AS p
    ON p.process_id = r.process_id
WHERE p.process_name = N'demo_rotating'
  AND r.run_type = 'BOOTSTRAP'
  AND r.status = 'PREPARED';

EXEC dbo.usp_finalize_refresh_run
    @RunId = @BootstrapRun;

SELECT *
FROM dbo.class_memory;

SELECT *
FROM dbo.refresh_process
WHERE process_name = N'demo_rotating';

SELECT *
FROM dbo.refresh_run
WHERE run_id = @BootstrapRun;


/* Operational staging: after FINALIZE it must be empty for this RunId */
SELECT COUNT(*) AS run_rows_after_finalize
FROM dbo.refresh_run_row
WHERE run_id = @BootstrapRun;

SELECT COUNT(*) AS delete_rows_after_finalize
FROM dbo.refresh_run_delete
WHERE run_id = @BootstrapRun;

SELECT COUNT(*) AS dirty_classes_after_finalize
FROM dbo.refresh_run_dirty_class
WHERE run_id = @BootstrapRun;

/*
EXPECTED:
run_rows_after_finalize      = 0
delete_rows_after_finalize   = 0
dirty_classes_after_finalize = 0
*/

GO
/* ============================================================================
   STEP 4 - SIMULATE SOURCE CHANGES

   We simulate what can happen between two runs:

   - B002 is modified                     -> UPDATE
   - D004 is deleted                      -> DELETE
   - N001 ... N005 are added              -> 5 INSERTs

   BEFORE:
       6 rows

   AFTER:
       6 - 1 + 5 = 10 rows
============================================================================ */

UPDATE dbo.demo_rotating_source
SET
    event_timestamp = '2026-08-19T09:00:00',
    value_text = N'B v2'
WHERE source_key = N'B002';

DELETE dbo.demo_rotating_source
WHERE source_key = N'D004';

INSERT dbo.demo_rotating_source
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

SELECT *
FROM dbo.demo_rotating_source
ORDER BY source_key;

SELECT COUNT(*) AS source_count
FROM dbo.demo_rotating_source;

-- EXPECTED: 10
GO
/* ============================================================================
   STEP 5 - PREPARE INCREMENTAL

   Compares the current source with class_memory.

   EXPECTED:

       insert_count = 5
       update_count = 1
       delete_count = 1

       refresh_run_row = 10 rows

   B002:
       change_type = UPDATE
       keeps the historical class

   N001 ... N005:
       change_type = INSERT
       are assigned ONLY to classes 1 and 2

   D004:
       does not appear in refresh_run_row
       appears in refresh_run_delete

   Rotating window:

       current window = 1,2
       candidate_next_window_start = 3
============================================================================ */

DECLARE @IncrementalRun uniqueidentifier;

EXEC dbo.usp_prepare_incremental_run
    @ProcessName = N'demo_rotating',
    @RunId = @IncrementalRun OUTPUT;

SELECT @IncrementalRun AS incremental_run_id;


/* Run header */
SELECT *
FROM dbo.refresh_run
WHERE run_id = @IncrementalRun;


/* Current classified snapshot */
SELECT *
FROM dbo.refresh_run_row
WHERE run_id = @IncrementalRun
ORDER BY source_key;


/* Classes actually to be updated */
SELECT *
FROM dbo.refresh_run_dirty_class
WHERE run_id = @IncrementalRun;


/* Detected deletes and their dirty classes */
SELECT *
FROM dbo.refresh_run_delete
WHERE run_id = @IncrementalRun;

GO
/* ============================================================================
   STEP 6 - FINALIZE INCREMENTAL

   The previous STEP left the run in PREPARED state.

   Simulates consumer success.

   EXPECTED:

   - class_memory                       = 10 rows
   - D004 is no longer present in memory
   - N001 ... N005 are present
   - refresh_run.status                 = COMPLETED
   - next_window_start_class            = 3
   - refresh_run_row                    = 0 rows for this RunId
   - refresh_run_delete                 = 0 rows for this RunId
   - refresh_run_dirty_class            = 0 rows for this RunId
============================================================================ */
DECLARE @IncrementalRun uniqueidentifier;


/* Retrieves the run left PREPARED by the previous step */
SELECT @IncrementalRun = r.run_id
FROM dbo.refresh_run AS r
INNER JOIN dbo.refresh_process AS p
    ON p.process_id = r.process_id
WHERE p.process_name = N'demo_rotating'
  AND r.run_type = 'INCREMENTAL'
  AND r.status = 'PREPARED';


EXEC dbo.usp_finalize_refresh_run
    @RunId = @IncrementalRun;

SELECT *
FROM dbo.class_memory
ORDER BY source_key;

SELECT *
FROM dbo.refresh_process
WHERE process_name = N'demo_rotating';

SELECT *
FROM dbo.refresh_run
WHERE run_id = @IncrementalRun;


/* Operational staging: after FINALIZE it must be empty for this RunId */
SELECT COUNT(*) AS run_rows_after_finalize
FROM dbo.refresh_run_row
WHERE run_id = @IncrementalRun;

SELECT COUNT(*) AS delete_rows_after_finalize
FROM dbo.refresh_run_delete
WHERE run_id = @IncrementalRun;

SELECT COUNT(*) AS dirty_classes_after_finalize
FROM dbo.refresh_run_dirty_class
WHERE run_id = @IncrementalRun;

/*
EXPECTED:
run_rows_after_finalize      = 0
delete_rows_after_finalize   = 0
dirty_classes_after_finalize = 0
*/

GO
/* ============================================================================
   STEP 7 - FULL PREPARATION

   We insert a completely new key.

   FULL-NEW does NOT exist in class_memory.

   We also modify A001.

   EXPECTED:
       source = 11 rows
       class_memory = 10 rows
============================================================================ */

INSERT dbo.demo_rotating_source
(
    source_key,
    event_timestamp,
    value_text
)
VALUES
(
    N'FULL-NEW',
    '2026-08-19T11:00:00',
    N'not classified during full'
);

UPDATE dbo.demo_rotating_source
SET
    event_timestamp = '2026-08-19T11:05:00',
    value_text = N'A changed before full'
WHERE source_key = N'A001';

SELECT COUNT(*) AS source_count
FROM dbo.demo_rotating_source;

-- EXPECTED: 11

GO
/* ============================================================================
   STEP 8 - PREPARE FULL

   FULL uses:

       current snapshot
           INNER JOIN
       class_memory

   Therefore FULL-NEW is ignored because it does not yet have a class.

   EXPECTED:

       source                 = 11
       refresh_run_row       = 10
       FULL-NEW in the run    = 0
       dirty classes         = 1,2,3

   All included rows:
       change_type = FULL
============================================================================ */

DECLARE @FullRun uniqueidentifier;

EXEC dbo.usp_prepare_full_run
    @ProcessName = N'demo_rotating',
    @RunId = @FullRun OUTPUT;

SELECT @FullRun AS full_run_id;

SELECT *
FROM dbo.refresh_run
WHERE run_id = @FullRun;

SELECT *
FROM dbo.refresh_run_row
WHERE run_id = @FullRun;

SELECT *
FROM dbo.refresh_run_dirty_class
WHERE run_id = @FullRun;

GO

/* ============================================================================
   STEP 9 - FINALIZE FULL

   The previous STEP left the FULL run in PREPARED state.

   EXPECTED AFTER FINALIZE:
   - refresh_run.status                 = COMPLETED
   - class_memory                       = 10 rows
   - FULL-NEW remains outside memory
   - next_window_start_class            = 3
   - refresh_run_row                    = 0 rows for this RunId
   - refresh_run_delete                 = 0 rows for this RunId
   - refresh_run_dirty_class            = 0 rows for this RunId
============================================================================ */

DECLARE @FullRun uniqueidentifier;

SELECT
    @FullRun = r.run_id
FROM dbo.refresh_run AS r
INNER JOIN dbo.refresh_process AS p
    ON p.process_id = r.process_id
WHERE p.process_name = N'demo_rotating'
  AND r.run_type = 'FULL'
  AND r.status = 'PREPARED';


EXEC dbo.usp_finalize_refresh_run
    @RunId = @FullRun;


/* Memory after FINALIZE */
SELECT *
FROM dbo.class_memory
ORDER BY source_key;


/* Process state */
SELECT *
FROM dbo.refresh_process
WHERE process_name = N'demo_rotating';


/* The same run must now be COMPLETED */
SELECT *
FROM dbo.refresh_run
WHERE run_id = @FullRun;


/* Operational staging: after FINALIZE it must be empty for this RunId */
SELECT COUNT(*) AS run_rows_after_finalize
FROM dbo.refresh_run_row
WHERE run_id = @FullRun;

SELECT COUNT(*) AS delete_rows_after_finalize
FROM dbo.refresh_run_delete
WHERE run_id = @FullRun;

SELECT COUNT(*) AS dirty_classes_after_finalize
FROM dbo.refresh_run_dirty_class
WHERE run_id = @FullRun;

/*
EXPECTED:
run_rows_after_finalize      = 0
delete_rows_after_finalize   = 0
dirty_classes_after_finalize = 0
*/

GO
