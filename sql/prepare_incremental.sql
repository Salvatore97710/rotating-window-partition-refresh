CREATE OR ALTER PROCEDURE dbo.usp_prepare_incremental_run
    @ProcessName       sysname,
    @InsertWindowSize  int = NULL,
    @RunId             uniqueidentifier OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

DECLARE
    @ProcessId int,
    @AdapterSchema sysname,
    @AdapterView sysname,
    @TotalClasses int,
    @DefaultWindowSize int,
    @WindowSize int,
    @WindowStart int,
    @CandidateNextWindowStart int,
    @Sql nvarchar(max),
    @LockResult int,
    @LockResource nvarchar(255),
    @InsertCount bigint,
    @UpdateCount bigint,
    @DeleteCount bigint,
    @UsedInsertClasses int,
    @DirtyCount int;

    SELECT
        @ProcessId = process_id,
        @AdapterSchema = adapter_schema,
        @AdapterView = adapter_view,
        @TotalClasses = total_classes,
        @DefaultWindowSize = default_insert_window_size,
        @WindowStart = next_window_start_class
    FROM dbo.refresh_process
    WHERE process_name = @ProcessName;

    IF @ProcessId IS NULL
        THROW 55200, 'Unknown process.', 1;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.class_memory
        WHERE process_id = @ProcessId
    )
        THROW 55201, 'Empty memory: run Bootstrap first.', 1;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.refresh_run
        WHERE process_id = @ProcessId
          AND status = 'PREPARED'
    )
        THROW 55202, 'A PREPARED run already exists.', 1;

    /*
      An explicit override still takes precedence over the adaptive policy.
      If the override is NULL, the effective window will be resolved after
      counting the INSERTs in the run.
    */
    IF @InsertWindowSize IS NOT NULL
       AND (@InsertWindowSize <= 0 OR @InsertWindowSize > @TotalClasses)
        THROW 55203, 'Invalid insert_window_size.', 1;

    SET @RunId = NEWID();

    BEGIN TRY
        BEGIN TRANSACTION;

SET @LockResource =
    N'class-refresh:' + CONVERT(nvarchar(20), @ProcessId);

EXEC @LockResult = sys.sp_getapplock
    @Resource = @LockResource,
    @LockMode = 'Exclusive',
    @LockOwner = 'Transaction',
    @LockTimeout = 0;

        IF @LockResult < 0
            THROW 55204, 'Process is locked.', 1;

        CREATE TABLE #snapshot
        (
            source_key       nvarchar(450) NOT NULL
                CONSTRAINT PK_incremental_snapshot PRIMARY KEY,
            event_timestamp  datetime2(7) NOT NULL,
            payload_json     nvarchar(max) NOT NULL,
            class_id         int NULL,
            change_type      varchar(20) NULL,
            local_offset     bigint NULL
        );

        SET @Sql = N'
            INSERT #snapshot
            (
                source_key,
                event_timestamp,
                payload_json
            )
            SELECT
                CONVERT(nvarchar(450), source_key),
                CONVERT(datetime2(7), event_timestamp),
                CONVERT(nvarchar(max), payload_json)
            FROM ' + QUOTENAME(@AdapterSchema) + N'.' + QUOTENAME(@AdapterView) + N'
            WHERE source_key IS NOT NULL
              AND event_timestamp IS NOT NULL
              AND ISJSON(payload_json) = 1;';

        EXEC sys.sp_executesql @Sql;

        /*
          Existing keys: same historical class.
        */
        UPDATE s
        SET
            class_id = m.class_id,
            change_type =
                CASE
                    WHEN s.event_timestamp <> m.last_timestamp
                        THEN 'UPDATE'
                    ELSE 'UNCHANGED'
                END
        FROM #snapshot AS s
        INNER JOIN dbo.class_memory AS m
            ON m.process_id = @ProcessId
           AND m.source_key = s.source_key;

        /*
          Before assigning new keys, count the INSERT batch.
          Rows already present in class_memory have a populated class_id;
          rows still NULL are new keys.
        */
        SELECT @InsertCount = COUNT_BIG(*)
        FROM #snapshot
        WHERE class_id IS NULL;

        /*
          Effective-window resolution.

          Precedence:
          1. explicit per-run @InsertWindowSize;
          2. first threshold >= @InsertCount;
          3. default_insert_window_size as fallback.

          With zero INSERTs the policy is not needed and the default is retained
          as the descriptive run value; the window will not advance.
        */
        IF @InsertWindowSize IS NOT NULL
        BEGIN
            SET @WindowSize = @InsertWindowSize;
        END
        ELSE IF @InsertCount = 0
        BEGIN
            SET @WindowSize = @DefaultWindowSize;
        END
        ELSE
        BEGIN
            SELECT TOP (1)
                @WindowSize = t.insert_window_size
            FROM dbo.refresh_process_insert_threshold AS t
            WHERE t.process_id = @ProcessId
              AND @InsertCount <= t.max_insert_count
            ORDER BY t.max_insert_count ASC;

            SET @WindowSize = COALESCE(@WindowSize, @DefaultWindowSize);
        END;

        IF @WindowSize <= 0 OR @WindowSize > @TotalClasses
            THROW 55203, 'Invalid effective insert_window_size.', 1;

        /*
          New keys:
          no ordering by PK or timestamp.
          ROW_NUMBER only generates a technical offset.
        */
        ;WITH inserted AS
        (
            SELECT
                s.source_key,
                ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1
                    AS local_offset
            FROM #snapshot AS s
            WHERE NOT EXISTS
            (
                SELECT 1
                FROM dbo.class_memory AS m
                WHERE m.process_id = @ProcessId
                  AND m.source_key = s.source_key
            )
        )
        UPDATE s
        SET
            local_offset = i.local_offset,
            class_id =
                (
                    (
                        @WindowStart - 1
                        + CONVERT(int, i.local_offset % @WindowSize)
                    ) % @TotalClasses
                ) + 1,
            change_type = 'INSERT'
        FROM #snapshot AS s
        INNER JOIN inserted AS i
            ON i.source_key = s.source_key;

        SELECT @UpdateCount = COUNT_BIG(*)
        FROM #snapshot
        WHERE change_type = 'UPDATE';

        SELECT @DeleteCount = COUNT_BIG(*)
        FROM dbo.class_memory AS m
        WHERE m.process_id = @ProcessId
          AND NOT EXISTS
          (
              SELECT 1
              FROM #snapshot AS s
              WHERE s.source_key = m.source_key
          );

        SET @CandidateNextWindowStart =
            CASE
                WHEN @InsertCount = 0
                    THEN @WindowStart
                ELSE
                    ((@WindowStart - 1 + @WindowSize) % @TotalClasses) + 1
            END;

        INSERT dbo.refresh_run
        (
            run_id,
            process_id,
            run_type,
            total_classes,
            insert_window_size,
            window_start_class,
            candidate_next_window_start,
            insert_count,
            update_count,
            delete_count,
            dirty_class_count,
            status,
            created_at
        )
        VALUES
        (
            @RunId,
            @ProcessId,
            'INCREMENTAL',
            @TotalClasses,
            @WindowSize,
            @WindowStart,
            @CandidateNextWindowStart,
            @InsertCount,
            @UpdateCount,
            @DeleteCount,
            0,
            'PREPARED',
            SYSUTCDATETIME()
        );

        INSERT dbo.refresh_run_row
        (
            run_id,
            source_key,
            event_timestamp,
            payload_json,
            class_id,
            change_type
        )
        SELECT
            @RunId,
            source_key,
            event_timestamp,
            payload_json,
            class_id,
            change_type
        FROM #snapshot;

        INSERT dbo.refresh_run_delete
        (
            run_id,
            source_key,
            class_id
        )
        SELECT
            @RunId,
            m.source_key,
            m.class_id
        FROM dbo.class_memory AS m
        WHERE m.process_id = @ProcessId
          AND NOT EXISTS
          (
              SELECT 1
              FROM #snapshot AS s
              WHERE s.source_key = m.source_key
          );

        /*
          Dirty classes INSERT:
          generated directly from the window.
        */
        SET @UsedInsertClasses =
            CASE
                WHEN @InsertCount >= @WindowSize
                    THEN @WindowSize
                ELSE CONVERT(int, @InsertCount)
            END;

        IF @UsedInsertClasses > 0
        BEGIN
            INSERT dbo.refresh_run_dirty_class
            (
                run_id,
                class_id
            )
            SELECT
                @RunId,
                (
                    (
                        @WindowStart - 1
                        + CONVERT(int, n.offset_value)
                    ) % @TotalClasses
                ) + 1
            FROM
            (
                SELECT TOP (@UsedInsertClasses)
                    ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1
                        AS offset_value
                FROM sys.all_objects AS a
                CROSS JOIN sys.all_objects AS b
            ) AS n;
        END;

        /*
          UPDATE dirty classes.
        */
        INSERT dbo.refresh_run_dirty_class
        (
            run_id,
            class_id
        )
        SELECT DISTINCT
            @RunId,
            s.class_id
        FROM #snapshot AS s
        WHERE s.change_type = 'UPDATE'
          AND NOT EXISTS
          (
              SELECT 1
              FROM dbo.refresh_run_dirty_class AS d
              WHERE d.run_id = @RunId
                AND d.class_id = s.class_id
          );

        /*
          DELETE dirty classes.
        */
        INSERT dbo.refresh_run_dirty_class
        (
            run_id,
            class_id
        )
        SELECT DISTINCT
            @RunId,
            d.class_id
        FROM dbo.refresh_run_delete AS d
        WHERE d.run_id = @RunId
          AND NOT EXISTS
          (
              SELECT 1
              FROM dbo.refresh_run_dirty_class AS x
              WHERE x.run_id = @RunId
                AND x.class_id = d.class_id
          );

        SELECT @DirtyCount = COUNT(*)
        FROM dbo.refresh_run_dirty_class
        WHERE run_id = @RunId;

        UPDATE dbo.refresh_run
        SET dirty_class_count = @DirtyCount
        WHERE run_id = @RunId;

        COMMIT TRANSACTION;

        SELECT *
        FROM dbo.refresh_run
        WHERE run_id = @RunId;

        SELECT class_id
        FROM dbo.refresh_run_dirty_class
        WHERE run_id = @RunId;

    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH;
END;
GO
