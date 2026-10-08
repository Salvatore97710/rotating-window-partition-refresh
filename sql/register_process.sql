CREATE OR ALTER PROCEDURE dbo.usp_register_refresh_process
    @ProcessName              sysname,
    @AdapterSchema            sysname,
    @AdapterView              sysname,
    @TotalClasses             int,
    @DefaultInsertWindowSize  int
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @TotalClasses <= 0
        THROW 55000, 'total_classes must be greater than zero.', 1;

    IF @DefaultInsertWindowSize <= 0
       OR @DefaultInsertWindowSize > @TotalClasses
        THROW 55001, 'Invalid insert_window_size.', 1;

    IF EXISTS
    (
        SELECT 1
        FROM dbo.refresh_process
        WHERE process_name = @ProcessName
    )
    BEGIN
        IF EXISTS
        (
            SELECT 1
            FROM dbo.refresh_process AS p
            WHERE p.process_name = @ProcessName
              AND p.total_classes <> @TotalClasses
              AND EXISTS
              (
                  SELECT 1
                  FROM dbo.class_memory AS m
                  WHERE m.process_id = p.process_id
              )
        )
            THROW 55002, 'Changing total_classes requires a full repartition.', 1;

        UPDATE dbo.refresh_process
        SET
            adapter_schema = @AdapterSchema,
            adapter_view = @AdapterView,
            total_classes = @TotalClasses,
            default_insert_window_size = @DefaultInsertWindowSize,
            next_window_start_class =
                CASE
                    WHEN next_window_start_class <= @TotalClasses
                        THEN next_window_start_class
                    ELSE 1
                END,
            updated_at = SYSUTCDATETIME()
        WHERE process_name = @ProcessName;
    END
    ELSE
    BEGIN
        INSERT dbo.refresh_process
        (
            process_name,
            adapter_schema,
            adapter_view,
            total_classes,
            default_insert_window_size,
            next_window_start_class
        )
        VALUES
        (
            @ProcessName,
            @AdapterSchema,
            @AdapterView,
            @TotalClasses,
            @DefaultInsertWindowSize,
            1
        );
    END;
END;
GO
