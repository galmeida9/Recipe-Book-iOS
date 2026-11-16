SET XACT_ABORT ON;
BEGIN TRANSACTION;
IF COL_LENGTH('dbo.ImportJobs','DestinationBookId') IS NULL
  ALTER TABLE dbo.ImportJobs ADD DestinationBookId uniqueidentifier NULL;
IF COL_LENGTH('dbo.ImportJobs','ReviewSeenVersion') IS NULL
  ALTER TABLE dbo.ImportJobs ADD ReviewSeenVersion int NOT NULL
    CONSTRAINT DF_ImportJobs_ReviewSeenVersion DEFAULT 0;
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE object_id=OBJECT_ID('dbo.ImportJobs') AND name='IX_Import_Book_User')
  CREATE INDEX IX_Import_Book_User ON dbo.ImportJobs(UserId,DestinationBookId,State);
COMMIT TRANSACTION;
