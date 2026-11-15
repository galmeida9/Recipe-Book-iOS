SET XACT_ABORT ON;
BEGIN TRANSACTION;

CREATE TABLE dbo.Accounts (
    Id uniqueidentifier NOT NULL PRIMARY KEY,
    Issuer nvarchar(300) COLLATE Latin1_General_100_BIN2 NOT NULL,
    Subject nvarchar(200) COLLATE Latin1_General_100_BIN2 NOT NULL,
    DisplayName nvarchar(120) NULL,
    Active bit NOT NULL DEFAULT 1,
    Deleted bit NOT NULL DEFAULT 0,
    CreatedAt datetime2 NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_Accounts_Identity UNIQUE (Issuer, Subject)
);
-- Invite-only access is independent of membership. Operators bind an invitation
-- to a verified immutable provider subject; no unverified email auto-enrolment.
CREATE TABLE dbo.AccessInvites (
    Issuer nvarchar(300) COLLATE Latin1_General_100_BIN2 NOT NULL,
    Subject nvarchar(200) COLLATE Latin1_General_100_BIN2 NOT NULL,
    ExpiresAt datetime2 NOT NULL,
    Revoked bit NOT NULL DEFAULT 0,
    PRIMARY KEY (Issuer, Subject)
);
CREATE TABLE dbo.Books (
    Id uniqueidentifier NOT NULL PRIMARY KEY,
    Name nvarchar(120) NOT NULL,
    Kind varchar(10) NOT NULL CHECK (Kind IN ('personal', 'shared')),
    Version int NOT NULL DEFAULT 1 CHECK (Version > 0)
);
CREATE TABLE dbo.Memberships (
    BookId uniqueidentifier NOT NULL REFERENCES dbo.Books(Id) ON DELETE CASCADE,
    UserId uniqueidentifier NOT NULL REFERENCES dbo.Accounts(Id),
    Role varchar(10) NOT NULL CHECK (Role IN ('owner', 'member')),
    PRIMARY KEY (BookId, UserId)
);
CREATE INDEX IX_Memberships_User ON dbo.Memberships(UserId, BookId);
CREATE TABLE dbo.Recipes (
    Id uniqueidentifier NOT NULL PRIMARY KEY,
    BookId uniqueidentifier NOT NULL REFERENCES dbo.Books(Id) ON DELETE CASCADE,
    AuthorId uniqueidentifier NOT NULL REFERENCES dbo.Accounts(Id),
    Draft nvarchar(max) NOT NULL CHECK (ISJSON(Draft) = 1),
    Version int NOT NULL DEFAULT 1 CHECK (Version > 0)
);
CREATE INDEX IX_Recipes_Book ON dbo.Recipes(BookId, Id);
CREATE TABLE dbo.ShoppingLists (
    Id uniqueidentifier NOT NULL PRIMARY KEY,
    UserId uniqueidentifier NOT NULL REFERENCES dbo.Accounts(Id),
    Name nvarchar(120) NOT NULL,
    Items nvarchar(max) NOT NULL DEFAULT N'[]' CHECK (ISJSON(Items) = 1),
    Version int NOT NULL DEFAULT 1 CHECK (Version > 0)
);
CREATE INDEX IX_ShoppingLists_User ON dbo.ShoppingLists(UserId, Id);
CREATE TABLE dbo.ImportBudget (
    Month char(7) NOT NULL PRIMARY KEY,
    CapMicros int NOT NULL CHECK (CapMicros BETWEEN 0 AND 5000000),
    SpentMicros int NOT NULL DEFAULT 0 CHECK (SpentMicros >= 0),
    ReservedMicros int NOT NULL DEFAULT 0 CHECK (ReservedMicros >= 0),
    CONSTRAINT CK_Budget_Total CHECK (SpentMicros + ReservedMicros <= CapMicros)
);
CREATE TABLE dbo.ImportJobs (
    Id uniqueidentifier NOT NULL PRIMARY KEY,
    UserId uniqueidentifier NOT NULL REFERENCES dbo.Accounts(Id),
    IdempotencyKey uniqueidentifier NOT NULL,
    SourceURL nvarchar(300) NOT NULL,
    State varchar(10) NOT NULL CHECK (State IN ('queued', 'running', 'review', 'failed', 'completed', 'discarded')),
    Draft nvarchar(max) NULL CHECK (Draft IS NULL OR ISJSON(Draft) = 1),
    Evidence nvarchar(max) NULL CHECK (Evidence IS NULL OR ISJSON(Evidence) = 1),
    Error nvarchar(500) NULL,
    Version int NOT NULL DEFAULT 1,
    BudgetMonth char(7) NOT NULL REFERENCES dbo.ImportBudget(Month),
    ReservedMicros int NOT NULL CHECK (ReservedMicros > 0),
    ProviderRunId nvarchar(100) NULL,
    DispatchStarted bit NOT NULL DEFAULT 0,
    DispatchStartedAt datetime2 NULL,
    CompletedRecipeId uniqueidentifier NULL,
    CompletedBookId uniqueidentifier NULL,
    Deadline datetime2 NOT NULL,
    CreatedAt datetime2 NOT NULL DEFAULT SYSUTCDATETIME(),
    CONSTRAINT UQ_Import_Idempotency UNIQUE (UserId, IdempotencyKey)
);
CREATE INDEX IX_Import_User_Source ON dbo.ImportJobs(UserId, SourceURL, CreatedAt);
CREATE INDEX IX_Import_Work ON dbo.ImportJobs(State, Deadline);
CREATE TABLE dbo.ImportRequests (
    UserId uniqueidentifier NOT NULL REFERENCES dbo.Accounts(Id),
    IdempotencyKey uniqueidentifier NOT NULL,
    JobId uniqueidentifier NOT NULL REFERENCES dbo.ImportJobs(Id),
    SourceURL nvarchar(300) NOT NULL,
    PRIMARY KEY(UserId, IdempotencyKey)
);
CREATE TABLE dbo.RecipeImages (
    Id uniqueidentifier NOT NULL PRIMARY KEY,
    RecipeId uniqueidentifier NOT NULL REFERENCES dbo.Recipes(Id) ON DELETE CASCADE,
    BlobName nvarchar(200) NOT NULL UNIQUE,
    ContentType varchar(30) NOT NULL CHECK (ContentType IN ('image/jpeg', 'image/png', 'image/webp')),
    SizeBytes int NOT NULL CHECK (SizeBytes BETWEEN 1 AND 5242880)
);

COMMIT TRANSACTION;
