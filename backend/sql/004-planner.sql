SET XACT_ABORT ON;
BEGIN TRANSACTION;

IF OBJECT_ID(N'dbo.WeeklyPlans', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.WeeklyPlans (
        Id uniqueidentifier NOT NULL PRIMARY KEY,
        UserId uniqueidentifier NOT NULL REFERENCES dbo.Accounts(Id),
        BookId uniqueidentifier NOT NULL REFERENCES dbo.Books(Id) ON DELETE CASCADE,
        ListId uniqueidentifier NOT NULL REFERENCES dbo.ShoppingLists(Id) ON DELETE CASCADE,
        WeekStart date NOT NULL,
        PlanData nvarchar(max) NOT NULL CHECK (ISJSON(PlanData) = 1),
        Generated nvarchar(max) NOT NULL DEFAULT N'[]' CHECK (ISJSON(Generated) = 1),
        Version int NOT NULL DEFAULT 1 CHECK (Version > 0),
        CONSTRAINT UQ_WeeklyPlans_UserBookWeek UNIQUE (UserId, BookId, WeekStart),
        CONSTRAINT CK_WeeklyPlans_Monday CHECK (DATEDIFF(day, CONVERT(date,'19000101',112), WeekStart) % 7 = 0)
    );
    CREATE INDEX IX_WeeklyPlans_UserList ON dbo.WeeklyPlans(UserId, ListId, BookId);
END;

COMMIT TRANSACTION;
