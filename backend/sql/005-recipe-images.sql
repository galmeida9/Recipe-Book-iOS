SET XACT_ABORT ON;
BEGIN TRANSACTION;
IF COL_LENGTH('dbo.RecipeImages','OwnerId') IS NULL
  ALTER TABLE dbo.RecipeImages ADD OwnerId uniqueidentifier NULL;
IF EXISTS(SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('dbo.RecipeImages') AND name='RecipeId' AND is_nullable=0)
  ALTER TABLE dbo.RecipeImages ALTER COLUMN RecipeId uniqueidentifier NULL;
IF COL_LENGTH('dbo.RecipeImages','CreatedAt') IS NULL
  ALTER TABLE dbo.RecipeImages ADD CreatedAt datetime2 NOT NULL CONSTRAINT DF_RecipeImages_Created DEFAULT SYSUTCDATETIME();
COMMIT;
