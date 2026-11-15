SET XACT_ABORT ON;
BEGIN TRANSACTION;
IF OBJECT_ID('dbo.OAuthFlows','U') IS NULL
BEGIN
  CREATE TABLE dbo.OAuthFlows (
    StateHash char(64) NOT NULL PRIMARY KEY,
    Nonce varchar(256) NOT NULL,
    Challenge varchar(43) NOT NULL,
    CodeHash char(64) NULL,
    ExpiresAt datetime2 NOT NULL
  );
  CREATE UNIQUE INDEX UX_OAuthFlows_Code ON dbo.OAuthFlows(CodeHash) WHERE CodeHash IS NOT NULL;
END;
COMMIT;
