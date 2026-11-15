SET XACT_ABORT ON;
BEGIN TRANSACTION;
IF OBJECT_ID('dbo.LocalBookCopies','U') IS NULL
BEGIN
  CREATE TABLE dbo.LocalBookCopies(
    UserId uniqueidentifier NOT NULL REFERENCES dbo.Accounts(Id) ON DELETE CASCADE,
    RequestKey uniqueidentifier NOT NULL,
    SnapshotHash char(64) NOT NULL,
    BookId uniqueidentifier NOT NULL,
    PRIMARY KEY(UserId,RequestKey)
  );
END;
COMMIT;
