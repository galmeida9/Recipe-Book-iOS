import { database, serializable, query } from "../backend/dist/database.js";

const name = process.env.API_SQL_USER;
const clientID = process.env.API_SQL_CLIENT_ID;
if (!name || !/^[A-Za-z0-9-]{1,128}$/.test(name) || !clientID ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(clientID)) {
  throw new Error("Verified owned API SQL user name and managed-identity CLIENT ID are required.");
}
try {
  const result = await serializable(async transaction => {
    await query(transaction, `
      DECLARE @sid VARBINARY(16)=CONVERT(VARBINARY(16),CONVERT(UNIQUEIDENTIFIER,@clientId));
      IF EXISTS(SELECT 1 FROM sys.database_principals WHERE name=@name AND (sid IS NULL OR sid<>@sid OR type<>'E'))
        THROW 50000,'Existing SQL principal does not match the verified managed identity.',1;
      IF NOT EXISTS(SELECT 1 FROM sys.database_principals WHERE name=@name)
      BEGIN
        DECLARE @create NVARCHAR(MAX)=N'CREATE USER '+QUOTENAME(@name)+N' WITH SID='+
          CONVERT(VARCHAR(MAX),@sid,1)+N', TYPE=E;';
        EXEC(@create);
      END;
      DECLARE @grant NVARCHAR(MAX)=N'GRANT SELECT,INSERT,UPDATE,DELETE ON SCHEMA::dbo TO '+QUOTENAME(@name);
      EXEC(@grant);`, { name, clientId: clientID });
    const permissions = await query(transaction, `
      SELECT p.permission_name AS permission,p.state_desc AS state,p.class_desc AS scope,
        SCHEMA_NAME(p.major_id) AS schemaName
      FROM sys.database_permissions p JOIN sys.database_principals u ON u.principal_id=p.grantee_principal_id
      WHERE u.name=@name ORDER BY p.permission_name`, { name });
    const roles = await query(transaction, `
      SELECT r.name FROM sys.database_role_members m JOIN sys.database_principals u ON u.principal_id=m.member_principal_id
      JOIN sys.database_principals r ON r.principal_id=m.role_principal_id WHERE u.name=@name`, { name });
    const dataPermissions = permissions.filter(p => p.scope === "SCHEMA");
    const other = permissions.filter(p => p.scope !== "SCHEMA");
    if (roles.length || dataPermissions.length !== 4 ||
        dataPermissions.some(p => p.state !== "GRANT" || p.schemaName !== "dbo") ||
        dataPermissions.map(p => p.permission).join(",") !== "DELETE,INSERT,SELECT,UPDATE" ||
        other.some(p => p.permission !== "CONNECT" || p.state !== "GRANT" || p.scope !== "DATABASE")) {
      throw new Error("Workload SQL permissions are not the required four dbo CRUD grants; no broader role is accepted.");
    }
    return permissions;
  });
  console.log("Verified managed-identity SQL CLIENT-ID SID and dbo CRUD-only grants:", result);
} finally {
  await (await database()).close();
}
