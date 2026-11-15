import { app, type HttpRequest, type HttpResponseInit, type InvocationContext } from "@azure/functions";
import { z, ZodError } from "zod";
import { authenticate } from "./auth.js";
import { AppError, expectedVersion, idSchema, invariant } from "./contracts.js";
import { RecipeBookService } from "./service.js";
import { ImportService, importStillActive, failImportDelivery, processImport } from "./imports.js";
import { enqueueImport } from "./queue.js";
import { readRecipeImage } from "./images.js";

const jsonHeaders = { "Content-Type": "application/json", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" };
async function body(request: HttpRequest): Promise<unknown> {
  invariant(request.headers.get("content-type")?.split(";")[0]?.trim() === "application/json",
    415, "content_type", "Send application/json.");
  const length = request.headers.get("content-length");
  invariant(length === null || (Number.isFinite(Number(length)) && Number(length) <= 300_000),
    413, "request_limit", "Request body exceeded the limit.");
  const text = await request.text();
  invariant(Buffer.byteLength(text) <= 300_000, 413, "request_limit", "Request body exceeded the limit.");
  try { return JSON.parse(text); }
  catch { throw new AppError(400, "invalid_json", "Send a valid JSON object."); }
}
async function dispatch(request: HttpRequest, service: RecipeBookService): Promise<HttpResponseInit> {
  const path = (request.params["path"] ?? "").split("/").filter(Boolean);
  const method = request.method;
  const imports = new ImportService(service);
  const id = (index: number) => idSchema.parse(path[index]);
  const version = () => expectedVersion(request.headers.get("if-match"));
  let result: unknown;
  if (path.length === 1 && path[0] === "account") {
    if (method === "GET") result = await service.me();
    else if (method === "DELETE") result = await service.deleteAccount();
    else if (method === "PATCH") result = await service.completeSetup(await body(request));
  } else if (path[0] === "books") {
    if (path.length === 1) {
      if (method === "GET") result = await service.books();
      else if (method === "POST") result = await service.createBook(await body(request));
    } else if (path.length === 2 && method === "DELETE") result = await service.deleteBook(id(1), version());
    else if (path[2] === "members") {
      if (path.length === 3) {
        if (method === "GET") result = await service.members(id(1));
        else if (method === "POST") {
          const input = z.object({ userId: idSchema }).strict().parse(await body(request));
          result = await service.addMember(id(1), input.userId, version());
        }
      } else if (path.length === 4) {
        if (method === "DELETE") result = await service.changeMember(id(1), id(3), null, version());
        else if (method === "PATCH") {
          const input = z.object({ role: z.enum(["owner", "member"]) }).strict().parse(await body(request));
          result = await service.changeMember(id(1), id(3), input.role, version());
        }
      }
    } else if (path[2] === "recipes") {
      if (path.length === 3) {
        if (method === "GET") result = await service.recipes(id(1));
        else if (method === "POST") result = await service.saveRecipe(id(1), await body(request));
      } else if (path.length === 4) {
        if (method === "PUT") result = await service.saveRecipe(id(1), await body(request), id(3), version());
        else if (method === "DELETE") result = await service.deleteRecipe(id(1), id(3), version());
      }
    }
  } else if (path.length === 1 && path[0] === "suggestions") {
    if (method === "GET") result = await service.suggestions();
    else if (method === "POST") {
      const input = z.object({ have: z.array(z.string().trim().min(1).max(200)).max(50) }).strict().parse(await body(request));
      result = await service.suggestions(input.have);
    }
  }
  else if (path[0] === "shopping-lists") {
    if (path.length === 1) {
      if (method === "GET") result = await service.shoppingLists();
      else if (method === "POST") result = await service.createShoppingList(await body(request));
    } else if (path.length === 2) {
      if (method === "PUT") result = await service.replaceShoppingItems(id(1), await body(request), version());
      else if (method === "DELETE") result = await service.deleteShoppingList(id(1), version());
    } else if (path.length === 3 && path[2] === "recipes" && method === "POST") {
      result = await service.addRecipeToList(id(1), await body(request), version());
    }
  } else if (path[0] === "imports") {
    if (path.length === 1) {
      if (method === "GET") result = await imports.list();
      else if (method === "POST") {
        const key = idSchema.parse(request.headers.get("idempotency-key"));
        const job = await imports.create(await body(request), key);
        if (["queued", "running"].includes(job.state)) {
          try { await enqueueImport(job.id); }
          catch {
            throw new AppError(503, "import_delivery", "The import was reserved but queue delivery failed. Retry the same submission to recover it without another charge.");
          }
        }
        result = job;
      }
    } else if (path.length === 2) {
      if (method === "GET") result = await imports.get(id(1));
      else if (method === "DELETE") result = await imports.discard(id(1), version());
    } else if (path.length === 3 && method === "POST") {
      if (path[2] === "retry") {
        const job = await imports.retry(id(1), version());
        await enqueueImport(job.id);
        result = job;
      }
      else if (path[2] === "approve") {
        const input = z.object({ bookId: idSchema, draft: z.unknown() }).strict().parse(await body(request));
        result = await imports.approve(id(1), input.bookId, input.draft, version());
      }
    }
  } else if (path.length === 2 && path[0] === "recipe-images" && method === "GET") {
    const image = await readRecipeImage(service, id(1));
    return { status: 200, body: image.data, headers: { ...jsonHeaders, "Content-Type": image.contentType } };
  }
  invariant(result !== undefined, 404, "route_not_found", "API route not found.");
  return { status: 200, jsonBody: result, headers: jsonHeaders };
}

export async function api(request: HttpRequest, context: InvocationContext): Promise<HttpResponseInit> {
  try {
    const principal = await authenticate(request.headers.get("authorization"));
    return await dispatch(request, new RecipeBookService(principal));
  } catch (error) {
    if (error instanceof AppError) return { status: error.status, jsonBody: { code: error.code, message: error.message }, headers: jsonHeaders };
    if (error instanceof ZodError) return { status: 400, jsonBody: { code: "invalid_input", message: "Input did not match the API contract.", fields: error.issues.map(issue => issue.path.join(".")) }, headers: jsonHeaders };
    // Do not log bodies, tokens, provider credentials, SQL parameters or user evidence.
    context.error("API request failed", error instanceof Error ? error.name : "UnknownError", context.invocationId);
    if (error instanceof Error && "number" in error && typeof error.number === "number"
      && [40613, 40501, 40197, 10928, 10929].includes(error.number)) {
      return { status: 503, jsonBody: { code: "database_unavailable", message: "The database is unavailable or quota-paused. Try again after the service resumes." }, headers: jsonHeaders };
    }
    return { status: 500, jsonBody: { code: "server_error", message: "The request could not be completed.", requestId: context.invocationId }, headers: jsonHeaders };
  }
}
app.http("recipeBookApi", {
  route: "{*path}", methods: ["GET", "POST", "PUT", "PATCH", "DELETE"], authLevel: "anonymous", handler: api
});
app.storageQueue("importWorker", {
  queueName: "imports", connection: "ImportQueue",
  handler: async (message: unknown) => {
    const input = z.object({ id: idSchema }).strict().parse(typeof message === "string" ? JSON.parse(message) : message);
    await processImport(input.id);
    if (await importStillActive(input.id)) await enqueueImport(input.id, 30);
  }
});
app.storageQueue("importPoison", {
  queueName: "imports-poison", connection: "ImportQueue",
  handler: async (message: unknown) => {
    const input = z.object({ id: idSchema }).strict().parse(typeof message === "string" ? JSON.parse(message) : message);
    await failImportDelivery(input.id);
  }
});
