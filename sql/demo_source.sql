DROP VIEW IF EXISTS dbo.vw_demo_rotating_adapter;
DROP TABLE IF EXISTS dbo.demo_rotating_source;
GO

CREATE TABLE dbo.demo_rotating_source
(
    source_key       nvarchar(100) NOT NULL
        CONSTRAINT PK_demo_rotating_source PRIMARY KEY,
    event_timestamp  datetime2(7) NOT NULL,
    value_text       nvarchar(200) NOT NULL
);
GO

CREATE VIEW dbo.vw_demo_rotating_adapter
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
FROM dbo.demo_rotating_source;
GO

INSERT dbo.demo_rotating_source
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
