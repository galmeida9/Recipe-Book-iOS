import sql from "mssql";
import { requiredSetting } from "./contracts.js";

let pool: Promise<sql.ConnectionPool> | undefined;
export function database(): Promise<sql.ConnectionPool> {
  if (!pool) {
    const server = requiredSetting("SQL_SERVER");
    const database = requiredSetting("SQL_DATABASE");
    const clientId = process.env["AZURE_CLIENT_ID"];
    const connection = new sql.ConnectionPool({
      server, database, port: 1433,
      authentication: {
        type: "azure-active-directory-default",
        options: clientId ? { clientId } : {}
      },
      options: { encrypt: true, trustServerCertificate: false, abortTransactionOnError: true },
      pool: { max: 4, min: 0, idleTimeoutMillis: 10_000 },
      connectionTimeout: 60_000,
      requestTimeout: 30_000
    });
    pool = connection.connect().catch(error => { pool = undefined; throw error; });
  }
  return pool;
}

export async function serializable<T>(work: (transaction: sql.Transaction) => Promise<T>): Promise<T> {
  const transaction = new sql.Transaction(await database());
  await transaction.begin(sql.ISOLATION_LEVEL.SERIALIZABLE);
  let aborted = false;
  transaction.on("rollback", () => { aborted = true; });
  try {
    const result = await work(transaction);
    await transaction.commit();
    return result;
  } catch (error) {
    if (!aborted) await transaction.rollback();
    throw error;
  }
}

export type Parameter = string | number | boolean | Date | null;
export async function query<T>(transaction: sql.Transaction, text: string, parameters: Record<string, Parameter> = {}): Promise<T[]> {
  const request = new sql.Request(transaction);
  for (const [name, value] of Object.entries(parameters)) {
    if (typeof value === "string") request.input(name, sql.NVarChar(sql.MAX), value);
    else if (typeof value === "number") request.input(name, sql.Int, value);
    else if (typeof value === "boolean") request.input(name, sql.Bit, value);
    else if (value instanceof Date) request.input(name, sql.DateTime2, value);
    else request.input(name, sql.NVarChar(sql.MAX), null);
  }
  return (await request.query<T>(text)).recordset;
}
