import { QueueClient } from "@azure/storage-queue";
import { DefaultAzureCredential } from "@azure/identity";
import { invariant, requiredSetting } from "./contracts.js";

let queue: QueueClient | undefined;
export interface ImportDelivery { id: string; deadline: string }
export async function enqueueImport(delivery: ImportDelivery, delaySeconds = 0): Promise<void> {
  if (!queue) {
    const endpoint = new URL(requiredSetting("QUEUE_SERVICE_URL"));
    invariant(endpoint.protocol === "https:" && endpoint.hostname.endsWith(".queue.core.windows.net")
      && !endpoint.search && !endpoint.username && !endpoint.password,
    503, "configuration", "A managed-identity queue endpoint is required.");
    queue = new QueueClient(endpoint.toString().replace(/\/$/, "") + "/imports", new DefaultAzureCredential());
  }
  await queue.sendMessage(JSON.stringify(delivery), { visibilityTimeout: delaySeconds, messageTimeToLive: 600 });
}
