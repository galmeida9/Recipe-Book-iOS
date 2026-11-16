SET XACT_ABORT ON;
BEGIN TRANSACTION;
IF OBJECT_ID('dbo.ImportValidationAudit','U') IS NULL
BEGIN
  CREATE TABLE dbo.ImportValidationAudit(
    JobId uniqueidentifier NOT NULL REFERENCES dbo.ImportJobs(Id) ON DELETE CASCADE,
    PriorVersion int NOT NULL,
    PriorState varchar(10) NOT NULL,
    PriorError nvarchar(500) NULL,
    ModelRequestId nvarchar(200) NOT NULL,
    ValidatorVersion varchar(80) NOT NULL,
    CreatedAt datetime2 NOT NULL DEFAULT SYSUTCDATETIME(),
    PRIMARY KEY(JobId,PriorVersion)
  );
END;
COMMIT TRANSACTION;
