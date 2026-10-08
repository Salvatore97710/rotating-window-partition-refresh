CREATE OR ALTER PROCEDURE dbo.usp_prepare_bootstrap_run
    @ProcessName sysname,
    @RunId       uniqueidentifier OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

DECLARE
    @ProcessId int,
    @AdapterSchema sysname,
    @AdapterView sysname,
    @TotalClasses int,
    @Sql nvarchar(max),
    @LockResult int,
    @LockResource nvarchar(255),
    @RowCount bigint;

    SELECT
        @ProcessId = process_id,
        @AdapterSchema = adapter_schema,
        @AdapterView = adapter_view,
        @TotalClasses = total_classes
    FROM dbo.refresh_process
    WHERE process_name = @ProcessName;

    IF @ProcessId IS NULL
        THROW 55100, 'Unknown process.', 1;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.class_memory
        WHERE process_id = @ProcessId
    )
        THROW 55101, 'Bootstrap is allowed only with empty memory.', 1;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.refresh_run
        WHERE process_id = @ProcessId
          AND status = 'PREPARED'
    )
        THROW 55102, 'A PREPARED run already exists.', 1;

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
            THROW 55103, 'Process is locked.', 1;

        CREATE TABLE #snapshot
        (
            source_key       nvarchar(450) NOT NULL
                CONSTRAINT PK_bootstrap_snapshot PRIMARY KEY,
            event_timestamp  datetime2(7) NOT NULL,
            payload_json     nvarchar(max) NOT NULL,
            technical_offset bigint NULL,
            class_id         int NULL
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

        ;WITH numbered AS
        (
            SELECT
                source_key,
                ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1
                    AS technical_offset
            FROM #snapshot
        )
        UPDATE s
        SET
            technical_offset = n.technical_offset,
            class_id =
                CONVERT(int, n.technical_offset % @TotalClasses) + 1
        FROM #snapshot AS s
        INNER JOIN numbered AS n
            ON n.source_key = s.source_key;

        SELECT @RowCount = COUNT_BIG(*)
        FROM #snapshot;

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
            'BOOTSTRAP',
            @TotalClasses,
            NULL,
            NULL,
            NULL,
            @RowCount,
            0,
            0,
            @TotalClasses,
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
            'BOOTSTRAP'
        FROM #snapshot;

        INSERT dbo.refresh_run_dirty_class
        (
            run_id,
            class_id
        )
        SELECT
            @RunId,
            CONVERT(int, n.class_id)
        FROM
        (
            SELECT TOP (@TotalClasses)
                ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS class_id
            FROM sys.all_objects AS a
            CROSS JOIN sys.all_objects AS b
        ) AS n;

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
