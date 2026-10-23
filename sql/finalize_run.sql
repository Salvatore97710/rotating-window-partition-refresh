CREATE OR ALTER PROCEDURE dbo.usp_finalize_refresh_run
    @RunId uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @ProcessId int,
        @RunType varchar(20),
        @CandidateNextWindowStart int,
        @LockResult int,
        @LockResource nvarchar(255);

    /*
      Initial read required to identify the process
      and build the application-lock resource.
    */
    SELECT
        @ProcessId = process_id,
        @RunType = run_type,
        @CandidateNextWindowStart = candidate_next_window_start
    FROM dbo.refresh_run
    WHERE run_id = @RunId
      AND status = 'PREPARED';

    IF @ProcessId IS NULL
        THROW 55500, 'Run does not exist or has already been finalized.', 1;

    BEGIN TRY
        BEGIN TRANSACTION;

        /* ---------------------------------------------------------------
           Exclusive lock on the process
        ---------------------------------------------------------------- */
        SET @LockResource =
            N'class-refresh:' + CONVERT(nvarchar(20), @ProcessId);

        EXEC @LockResult = sys.sp_getapplock
            @Resource = @LockResource,
            @LockMode = 'Exclusive',
            @LockOwner = 'Transaction',
            @LockTimeout = 0;

        IF @LockResult < 0
            THROW 55501, 'Process is locked.', 1;


        /* ---------------------------------------------------------------
           Re-check after acquiring the lock.

           This also protects against two concurrent FINALIZE operations
           that both read PREPARED before acquiring the lock.
        ---------------------------------------------------------------- */
        IF NOT EXISTS
        (
            SELECT 1
            FROM dbo.refresh_run
            WHERE run_id = @RunId
              AND process_id = @ProcessId
              AND status = 'PREPARED'
        )
            THROW 55502, 'Run is in an invalid state.', 1;


        /* ---------------------------------------------------------------
           PROMOTION OF CANDIDATE MEMORY

           Call ONLY after downstream success
           for all dirty classes.

           In the current framework version, refresh_run_row
           represents the complete candidate memory for the process.
        ---------------------------------------------------------------- */
        DELETE FROM dbo.class_memory
        WHERE process_id = @ProcessId;

        INSERT dbo.class_memory
        (
            process_id,
            source_key,
            last_timestamp,
            class_id,
            updated_at
        )
        SELECT
            @ProcessId,
            source_key,
            event_timestamp,
            class_id,
            SYSUTCDATETIME()
        FROM dbo.refresh_run_row
        WHERE run_id = @RunId;


        /* ---------------------------------------------------------------
           PROCESS STATE UPDATE

           The rotating window can change only for INCREMENTAL.
           For BOOTSTRAP and FULL it remains unchanged.
        ---------------------------------------------------------------- */
        UPDATE dbo.refresh_process
        SET
            next_window_start_class =
                CASE
                    WHEN @RunType = 'INCREMENTAL'
                        THEN @CandidateNextWindowStart
                    ELSE next_window_start_class
                END,
            last_successful_run_id = @RunId,
            updated_at = SYSUTCDATETIME()
        WHERE process_id = @ProcessId;


        /* ---------------------------------------------------------------
           RUN STAGING CLEANUP

           At this point:
           - the consumer has completed successfully;
           - refresh_run_row has already been promoted into class_memory;
           - dirty classes and deletes are no longer needed.

           dbo.refresh_run is retained as lightweight history.
        ---------------------------------------------------------------- */

        DELETE FROM dbo.refresh_run_dirty_class
        WHERE run_id = @RunId;

        DELETE FROM dbo.refresh_run_delete
        WHERE run_id = @RunId;

        DELETE FROM dbo.refresh_run_row
        WHERE run_id = @RunId;


        /* ---------------------------------------------------------------
           RUN COMPLETION

           The header remains available as historical audit data:
           counts, run type, window, status, and timestamp.
        ---------------------------------------------------------------- */
        UPDATE dbo.refresh_run
        SET
            status = 'COMPLETED',
            completed_at = SYSUTCDATETIME()
        WHERE run_id = @RunId
          AND status = 'PREPARED';

        IF @@ROWCOUNT = 0
            THROW 55502, 'Run is in an invalid state.', 1;


        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;

        THROW;
    END CATCH;
END;
GO