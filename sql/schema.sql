SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID(N'dbo.refresh_process', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.refresh_process
    (
        process_id                  int IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_refresh_process PRIMARY KEY,
        process_name                sysname NOT NULL
            CONSTRAINT UQ_refresh_process_name UNIQUE,
        adapter_schema              sysname NOT NULL,
        adapter_view                sysname NOT NULL,
        total_classes               int NOT NULL,
        default_insert_window_size  int NOT NULL,
        next_window_start_class     int NOT NULL
            CONSTRAINT DF_refresh_process_window_start DEFAULT (1),
        last_successful_run_id      uniqueidentifier NULL,
        created_at                  datetime2(7) NOT NULL
            CONSTRAINT DF_refresh_process_created DEFAULT SYSUTCDATETIME(),
        updated_at                  datetime2(7) NOT NULL
            CONSTRAINT DF_refresh_process_updated DEFAULT SYSUTCDATETIME(),

        CONSTRAINT CK_refresh_process_total_classes
            CHECK (total_classes > 0),

        CONSTRAINT CK_refresh_process_window_size
            CHECK (
                default_insert_window_size > 0
                AND default_insert_window_size <= total_classes
            ),

        CONSTRAINT CK_refresh_process_window_start
            CHECK (
                next_window_start_class >= 1
                AND next_window_start_class <= total_classes
            )
    );
END;
GO

IF OBJECT_ID(N'dbo.class_memory', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.class_memory
    (
        process_id       int NOT NULL,
        source_key       nvarchar(450) NOT NULL,
        last_timestamp   datetime2(7) NOT NULL,
        class_id         int NOT NULL,
        updated_at       datetime2(7) NOT NULL
            CONSTRAINT DF_class_memory_updated DEFAULT SYSUTCDATETIME(),

        CONSTRAINT PK_class_memory
            PRIMARY KEY (process_id, source_key),

        CONSTRAINT FK_class_memory_process
            FOREIGN KEY (process_id)
            REFERENCES dbo.refresh_process(process_id)
    );

    CREATE INDEX IX_class_memory_class
        ON dbo.class_memory(process_id, class_id);
END;
GO

IF OBJECT_ID(N'dbo.refresh_run', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.refresh_run
    (
        run_id                         uniqueidentifier NOT NULL
            CONSTRAINT PK_refresh_run PRIMARY KEY,
        process_id                     int NOT NULL,
        run_type                       varchar(20) NOT NULL,
        total_classes                  int NOT NULL,
        insert_window_size             int NULL,
        window_start_class             int NULL,
        candidate_next_window_start    int NULL,
        insert_count                   bigint NOT NULL,
        update_count                   bigint NOT NULL,
        delete_count                   bigint NOT NULL,
        dirty_class_count              int NOT NULL,
        status                         varchar(20) NOT NULL,
        created_at                     datetime2(7) NOT NULL,
        completed_at                   datetime2(7) NULL,

        CONSTRAINT FK_refresh_run_process
            FOREIGN KEY (process_id)
            REFERENCES dbo.refresh_process(process_id),

        CONSTRAINT CK_refresh_run_type
            CHECK (run_type IN ('BOOTSTRAP','INCREMENTAL','FULL')),

        CONSTRAINT CK_refresh_run_status
            CHECK (status IN ('PREPARED','COMPLETED','FAILED'))
    );
END;
GO

IF OBJECT_ID(N'dbo.refresh_run_row', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.refresh_run_row
    (
        run_id           uniqueidentifier NOT NULL,
        source_key       nvarchar(450) NOT NULL,
        event_timestamp  datetime2(7) NOT NULL,
        payload_json     nvarchar(max) NOT NULL,
        class_id         int NOT NULL,
        change_type      varchar(20) NOT NULL,

        CONSTRAINT PK_refresh_run_row
            PRIMARY KEY (run_id, source_key),

        CONSTRAINT FK_refresh_run_row_run
            FOREIGN KEY (run_id)
            REFERENCES dbo.refresh_run(run_id),

        CONSTRAINT CK_refresh_run_row_change
            CHECK (
                change_type IN (
                    'BOOTSTRAP',
                    'INSERT',
                    'UPDATE',
                    'UNCHANGED',
                    'FULL'
                )
            )
    );

    CREATE INDEX IX_refresh_run_row_class
        ON dbo.refresh_run_row(run_id, class_id);
END;
GO

IF OBJECT_ID(N'dbo.refresh_run_dirty_class', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.refresh_run_dirty_class
    (
        run_id    uniqueidentifier NOT NULL,
        class_id  int NOT NULL,

        CONSTRAINT PK_refresh_run_dirty_class
            PRIMARY KEY (run_id, class_id),

        CONSTRAINT FK_refresh_run_dirty_class_run
            FOREIGN KEY (run_id)
            REFERENCES dbo.refresh_run(run_id)
    );
END;
GO

IF OBJECT_ID(N'dbo.refresh_run_delete', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.refresh_run_delete
    (
        run_id      uniqueidentifier NOT NULL,
        source_key  nvarchar(450) NOT NULL,
        class_id    int NOT NULL,

        CONSTRAINT PK_refresh_run_delete
            PRIMARY KEY (run_id, source_key),

        CONSTRAINT FK_refresh_run_delete_run
            FOREIGN KEY (run_id)
            REFERENCES dbo.refresh_run(run_id)
    );
END;
GO
