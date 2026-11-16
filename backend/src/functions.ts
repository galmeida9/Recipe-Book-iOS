import { app, type HttpRequest, type HttpResponseInit, type InvocationContext } from "@azure/functions";
import { z, ZodError } from "zod";
import { authenticate } from "./auth.js";
import { AppError, expectedVersion, idSchema, invariant } from "./contracts.js";
import { RecipeBookService } from "./service.js";
import { ImportService, importDelivery, failImportDelivery, processImport } from "./imports.js";
import { enqueueImport } from "./queue.js";
import { readRecipeImage, uploadRecipeImage } from "./images.js";
import { oauthRoute } from "./oauth.js";
import { PlannerService } from "./planner-service.js";
import { weekStartSchema } from "./planner.js";
import "./bootstrap.js";

const jsonHeaders = { "Content-Type": "application/json", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff" };
async function body(request: HttpRequest, maximum = 300_000): Promise<unknown> {
  invariant(request.headers.get("content-type")?.split(";")[0]?.trim() === "application/json",
    415, "content_type", "Send application/json.");
  const length = request.headers.get("content-length");
  invariant(length === null || (Number.isFinite(Number(length)) && Number(length) <= maximum),
    413, "request_limit", "Request body exceeded the limit.");
  const text = await request.text();
  invariant(Buffer.byteLength(text) <= maximum, 413, "request_limit", "Request body exceeded the limit.");
  try { return JSON.parse(text); }
  catch { throw new AppError(400, "invalid_json", "Send a valid JSON object."); }
}
export async function dispatch(request: HttpRequest, service: RecipeBookService,
  planner: PlannerService = new PlannerService(service)): Promise<HttpResponseInit> {
  const path = (request.params["path"] ?? "").split("/").filter(Boolean);
  const method = request.method;
  const imports = new ImportService(service);
  const id = (index: number) => idSchema.parse(path[index]);
  const version = () => expectedVersion(request.headers.get("if-match"));
  const planIdentity = () => ({
    bookId: idSchema.parse(request.query.get("bookId")),
    weekStart: weekStartSchema.parse(request.query.get("weekStart"))
  });
  let result: unknown;
  if (path.length === 1 && path[0] === "account") {
    if (method === "GET") result = await service.me();
    else if (method === "DELETE") result = await service.deleteAccount();
    else if (method === "PATCH") result = await service.completeSetup(await body(request));
  } else if (path.length === 1 && path[0] === "local-book-copies" && method === "POST") {
    result = await service.copyLocalBook(await body(request), idSchema.parse(request.headers.get("idempotency-key")),
      idSchema.parse(request.headers.get("x-recipe-account-id")));
  } else if (path[0] === "plans") {
    if (path.length === 1 && method === "POST") {
      const expected = request.headers.has("if-match") ? version() : null;
      result = await planner.generate(await body(request), expected);
    } else if (path.length === 1 && ["GET", "PATCH", "DELETE"].includes(method)) {
      const { bookId, weekStart } = planIdentity();
      if (method === "GET") result = await planner.get(bookId, weekStart);
      else if (method === "PATCH") result = await planner.replace(bookId, weekStart, await body(request), version());
      else {
        await planner.remove(bookId, weekStart, version());
        result = { removed: true };
      }
    } else if (path.length === 3 && path[1] === "items" && method === "PATCH") {
      const { bookId, weekStart } = planIdentity();
      const input = z.object({ bought: z.boolean() }).strict().parse(await body(request));
      result = await planner.check(bookId, weekStart, id(2), input.bought, version());
    }
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
      if (method === "GET") result = await imports.list(request.query.has("bookId") ? idSchema.parse(request.query.get("bookId")) : undefined);
      else if (method === "POST") {
        const key = idSchema.parse(request.headers.get("idempotency-key"));
        const job = await imports.create(await body(request), key,
          request.headers.has("x-recipe-account-id") ? idSchema.parse(request.headers.get("x-recipe-account-id")) : undefined);
        if (["queued", "running"].includes(job.state)) {
          try {
            const delivery = await importDelivery(job.id);
            if (delivery) await enqueueImport(delivery);
          }
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
      if (path[2] === "seen") result = await imports.markSeen(id(1), version());
      else if (path[2] === "retry") {
        const job = await imports.retry(id(1), version());
        const delivery = await importDelivery(job.id);
        if (delivery) await enqueueImport(delivery);
        result = job;
      }
      else if (path[2] === "approve") {
        const input = z.object({ bookId: idSchema, draft: z.unknown() }).strict().parse(await body(request));
        result = await imports.approve(id(1), input.bookId, input.draft, version());
      }
    }
  } else if (path.length === 1 && path[0] === "recipe-images" && method === "POST") {
    result = await uploadRecipeImage(service, await body(request, 2_800_000), idSchema.parse(request.headers.get("idempotency-key")),
      request.headers.has("x-recipe-account-id") ? idSchema.parse(request.headers.get("x-recipe-account-id")) : undefined);
  } else if (path.length === 2 && path[0] === "recipe-images" && method === "GET") {
    const image = await readRecipeImage(service, id(1));
    return { status: 200, body: image.data, headers: { ...jsonHeaders, "Content-Type": image.contentType } };
  }
  invariant(result !== undefined, 404, "route_not_found", "API route not found.");
  return { status: 200, jsonBody: result, headers: jsonHeaders };
}

export async function api(request: HttpRequest, context: InvocationContext): Promise<HttpResponseInit> {
  try {
    const oauth = await oauthRoute(request);
    if (oauth) return oauth;
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
    const input = z.object({ id: idSchema, deadline: z.string().datetime() }).strict().parse(typeof message === "string" ? JSON.parse(message) : message);
    await processImport(input.id, undefined, input.deadline);
    const delivery = await importDelivery(input.id, input.deadline);
    if (delivery) await enqueueImport(delivery, 30);
  }
});
app.storageQueue("importPoison", {
  queueName: "imports-poison", connection: "ImportQueue",
  handler: async (message: unknown) => {
    const input = z.object({ id: idSchema, deadline: z.string().datetime() }).strict().parse(typeof message === "string" ? JSON.parse(message) : message);
    await failImportDelivery(input.id, undefined, input.deadline);
  }
});
