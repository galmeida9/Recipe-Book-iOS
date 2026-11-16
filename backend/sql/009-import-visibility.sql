SET XACT_ABORT ON;
BEGIN TRANSACTION;
IF COL_LENGTH('dbo.ImportJobs','OperatorOnly') IS NULL
  ALTER TABLE dbo.ImportJobs ADD OperatorOnly bit NOT NULL
    CONSTRAINT DF_ImportJobs_OperatorOnly DEFAULT 0;
IF COL_LENGTH('dbo.ImportJobs','SupersededById') IS NULL
  ALTER TABLE dbo.ImportJobs ADD SupersededById uniqueidentifier NULL;
IF COL_LENGTH('dbo.ImportJobs','ModelResultJson') IS NULL
  ALTER TABLE dbo.ImportJobs ADD ModelResultJson nvarchar(max) NULL
    CONSTRAINT CK_ImportJobs_ModelResultJson CHECK (ModelResultJson IS NULL OR ISJSON(ModelResultJson)=1);
COMMIT TRANSACTION;
