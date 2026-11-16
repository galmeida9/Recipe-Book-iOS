SET XACT_ABORT ON;
BEGIN TRANSACTION;
IF OBJECT_ID('dbo.ImageUploadRequests','U') IS NULL
BEGIN
  CREATE TABLE dbo.ImageUploadRequests(
    UserId uniqueidentifier NOT NULL REFERENCES dbo.Accounts(Id) ON DELETE CASCADE,
    RequestKey uniqueidentifier NOT NULL,
    ContentHash char(64) NOT NULL,
    ImageId uniqueidentifier NOT NULL,
    PRIMARY KEY(UserId,RequestKey)
  );
END;
COMMIT TRANSACTION;
