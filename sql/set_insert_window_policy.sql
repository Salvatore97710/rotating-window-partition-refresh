CREATE OR ALTER PROCEDURE dbo.usp_set_insert_window_policy
    @ProcessName sysname,
    @Policy       nvarchar(max) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE
        @ProcessId int,
        @DefaultWindowSize int;

    SELECT
        @ProcessId = process_id,
        @DefaultWindowSize = default_insert_window_size
    FROM dbo.refresh_process
    WHERE process_name = @ProcessName;

    IF @ProcessId IS NULL
        THROW 55010, 'Unknown process.', 1;

    /*
      @Policy uses the format:

          max_insert_count:insert_window_size,...

      Example:

          500:1,2000:2,5000:3,20000:4

      means:

          INSERT <=    500 -> window 1
          INSERT <=  2,000 -> window 2
          INSERT <=  5,000 -> window 3
          INSERT <= 20,000 -> window 4
          otherwise         -> default_insert_window_size

      NULL or an empty string removes the adaptive policy and leaves
      the default as the fallback.
    */

    DECLARE @ParsedPolicy TABLE
    (
        max_insert_count    bigint NULL,
        insert_window_size  int NULL,
        raw_token           nvarchar(4000) NOT NULL
    );

    IF NULLIF(LTRIM(RTRIM(@Policy)), N'') IS NOT NULL
    BEGIN
        ;WITH tokens AS
        (
            SELECT LTRIM(RTRIM(value)) AS token
            FROM STRING_SPLIT(@Policy, N',')
            WHERE NULLIF(LTRIM(RTRIM(value)), N'') IS NOT NULL
        ),
        parsed AS
        (
            SELECT
                token,
                CHARINDEX(N':', token) AS separator_pos
            FROM tokens
        )
        INSERT @ParsedPolicy
        (
            max_insert_count,
            insert_window_size,
            raw_token
        )
        SELECT
            TRY_CONVERT
            (
                bigint,
                CASE
                    WHEN separator_pos > 1
                        THEN LTRIM(RTRIM(LEFT(token, separator_pos - 1)))
                END
            ),
            TRY_CONVERT
            (
                int,
                CASE
                    WHEN separator_pos > 1
                        THEN LTRIM(RTRIM(SUBSTRING(token, separator_pos + 1, 4000)))
                END
            ),
            token
        FROM parsed;

        IF EXISTS
        (
            SELECT 1
            FROM @ParsedPolicy
            WHERE max_insert_count IS NULL
               OR insert_window_size IS NULL
               OR CHARINDEX(N':', raw_token) <= 1
               OR CHARINDEX
                  (
                      N':',
                      raw_token,
                      CHARINDEX(N':', raw_token) + 1
                  ) > 0
        )
            THROW 55011, 'Invalid policy. Expected format: threshold:window,threshold:window.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM @ParsedPolicy
            WHERE max_insert_count <= 0
        )
            THROW 55012, 'Every max_insert_count must be greater than zero.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM @ParsedPolicy
            WHERE insert_window_size <= 0
               OR insert_window_size >= @DefaultWindowSize
        )
            THROW 55013, 'Every policy window must be > 0 and < default_insert_window_size.', 1;

        IF EXISTS
        (
            SELECT max_insert_count
            FROM @ParsedPolicy
            GROUP BY max_insert_count
            HAVING COUNT(*) > 1
        )
        OR EXISTS
        (
            SELECT insert_window_size
            FROM @ParsedPolicy
            GROUP BY insert_window_size
            HAVING COUNT(*) > 1
        )
            THROW 55014, 'Invalid policy: thresholds and windows must be unique.', 1;

        IF EXISTS
        (
            SELECT 1
            FROM
            (
                SELECT
                    max_insert_count,
                    insert_window_size,
                    LAG(insert_window_size) OVER
                        (ORDER BY max_insert_count) AS previous_window_size
                FROM @ParsedPolicy
            ) AS x
            WHERE previous_window_size IS NOT NULL
              AND insert_window_size <= previous_window_size
        )
            THROW 55015, 'Invalid policy: the window must increase as the threshold increases.', 1;
    END;

    BEGIN TRY
        BEGIN TRANSACTION;

        DELETE FROM dbo.refresh_process_insert_threshold
        WHERE process_id = @ProcessId;

        INSERT dbo.refresh_process_insert_threshold
        (
            process_id,
            max_insert_count,
            insert_window_size
        )
        SELECT
            @ProcessId,
            max_insert_count,
            insert_window_size
        FROM @ParsedPolicy;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        THROW;
    END CATCH;

    SELECT
        p.process_name,
        p.default_insert_window_size,
        t.max_insert_count,
        t.insert_window_size
    FROM dbo.refresh_process AS p
    LEFT JOIN dbo.refresh_process_insert_threshold AS t
        ON t.process_id = p.process_id
    WHERE p.process_id = @ProcessId
    ORDER BY t.max_insert_count;
END;
GO
