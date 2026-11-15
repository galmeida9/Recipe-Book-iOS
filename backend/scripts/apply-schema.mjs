import { readFile } from "node:fs/promises";
import { database } from "../dist/database.js";

const pool = await database();
try {
  const result = await pool.request().query("SELECT COUNT(*) AS count FROM sys.tables WHERE schema_id=SCHEMA_ID('dbo')");
  if (result.recordset[0].count !== 0) throw new Error("Initial migration requires an empty dbo schema. Do not overwrite an existing database.");
  const migration = await readFile(new URL("../sql/001-foundation.sql", import.meta.url), "utf8");
  await pool.request().batch(migration);
  console.log("Applied the initial Recipe Book schema to the configured empty database.");
} finally { await pool.close(); }
