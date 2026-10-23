CREATE OR ALTER PROCEDURE dbo.usp_get_dirty_class
    @RunId    uniqueidentifier,
    @ClassId  int
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS
    (
        SELECT 1
        FROM dbo.refresh_run_dirty_class
        WHERE run_id = @RunId
          AND class_id = @ClassId
    )
        THROW 55400, 'The requested class is not dirty for this run.', 1;

    /*
      No ORDER BY.
      A dirty class may return zero rows.
    */
    SELECT
        source_key,
        event_timestamp,
        payload_json,
        class_id
    FROM dbo.refresh_run_row
    WHERE run_id = @RunId
      AND class_id = @ClassId;
END;
GO
