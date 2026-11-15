import { createRequire } from "node:module";
import { randomUUID } from "node:crypto";
const require = createRequire(new URL("../backend/package.json", import.meta.url));
const { QueueClient } = require("@azure/storage-queue");
const { AzureCliCredential } = require("@azure/identity");
const url = process.env.CORE_PROBE_QUEUE_URL;
if (!url || !/^https:\/\/[a-z0-9]+\.queue\.core\.windows\.net\/imports$/.test(url)) {
  throw new Error("Verified owned imports queue URL is required.");
}
const queue = new QueueClient(url, new AzureCliCredential());
const before = await queue.getProperties();
if (before.approximateMessagesCount !== 0) throw new Error("Refusing to probe a queue containing existing messages.");
// An unknown synthetic job executes the deployed worker's SQL transaction/read
// and returns before any provider access. Host configuration uses encoding=none.
const sent = await queue.sendMessage(JSON.stringify({
  id: randomUUID(), deadline: new Date(Date.now() + 300000).toISOString()
}), { messageTimeToLive: 300 });
for (let attempt = 0; attempt < 15; attempt++) {
  await new Promise(resolve => setTimeout(resolve, 3000));
  if ((await queue.getProperties()).approximateMessagesCount === 0) {
    console.log("Deployed worker consumed the synthetic SQL probe before its TTL; managed-identity SQL/network query succeeded.", sent.messageId);
    process.exit(0);
  }
}
throw new Error("The deployed worker did not complete the SQL probe within 45 seconds; no live-backend success is claimed.");
