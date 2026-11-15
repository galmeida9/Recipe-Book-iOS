import test from "node:test";
import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { query, serializable, database } from "../src/database.js";
import { RecipeBookService } from "../src/service.js";
import { AppError } from "../src/contracts.js";

const enabled = process.env["RUN_SQL_INTEGRATION"] === "true";
test("SQL: member isolation, optimistic writes, last-owner race and account departure are transactional", { skip: !enabled }, async () => {
  const issuer = "https://test.invalid/" + randomUUID();
  const names = ["alice", "bob", "outsider"];
  const principals = names.map(subject => ({ issuer, subject }));
  const services = principals.map(principal => new RecipeBookService(principal));
  const [alice, bob, outsider] = services as [RecipeBookService, RecipeBookService, RecipeBookService];
  let aliceId = "";
  let bobId = "";
  let sharedId = "";
  try {
    await serializable(async transaction => {
      for (const principal of principals) {
        await query(transaction, "INSERT dbo.AccessInvites(Issuer,Subject,ExpiresAt) VALUES(@issuer,@subject,@expires)",
          { ...principal, expires: new Date(Date.now() + 60_000) });
      }
    });
    aliceId = (await alice.me()).id;
    bobId = (await bob.me()).id;
    await outsider.me();
    const privateBook = await alice.createBook({ name: "Private", kind: "personal" });
    let shared = await alice.createBook({ name: "Shared", kind: "shared" });
    sharedId = shared.id;
    await assert.rejects(() => bob.recipes(privateBook.id), (error: unknown) => error instanceof AppError && error.code === "book_not_found");
    shared = await alice.addMember(shared.id, bobId, shared.version);
    const recipe = await alice.saveRecipe(shared.id, { title: "Soup", ingredients: [], steps: [] });
    await assert.rejects(() => outsider.recipes(shared.id), (error: unknown) => error instanceof AppError && error.code === "book_not_found");
    await assert.rejects(() => bob.saveRecipe(shared.id, recipe.draft, recipe.id, recipe.version),
      (error: unknown) => error instanceof AppError && error.code === "recipe_author");
    const own = await bob.saveRecipe(shared.id, { title: "Bread", ingredients: [], steps: [] });
    await bob.saveRecipe(shared.id, { ...own.draft, title: "New bread" }, own.id, own.version);
    await assert.rejects(() => bob.deleteRecipe(shared.id, own.id, own.version),
      (error: unknown) => error instanceof AppError && error.code === "version_conflict");
    const list = await alice.createShoppingList({ name: "Private shopping" });
    await assert.rejects(() => bob.replaceShoppingItems(list.id, { items: [] }, list.version),
      (error: unknown) => error instanceof AppError && error.code === "list_not_found");
    const promoted = await alice.changeMember(shared.id, bobId, "owner", shared.version);
    assert.ok("version" in promoted);
    shared = (await alice.books()).find(book => book.id === shared.id)!;
    const outcomes = await Promise.allSettled([
      alice.changeMember(shared.id, aliceId, "member", shared.version),
      bob.changeMember(shared.id, bobId, "member", shared.version)
    ]);
    assert.equal(outcomes.filter(value => value.status === "fulfilled").length, 1);
    const owners = (await alice.members(shared.id)).filter(member => member.role === "owner");
    assert.equal(owners.length, 1);
    const lastOwner = owners[0]!.userId === aliceId ? alice : bob;
    await assert.rejects(() => lastOwner.deleteAccount(), (error: unknown) => error instanceof AppError && error.code === "last_owner");
    shared = (await alice.books()).find(book => book.id === shared.id)!;
    const ownerService = shared.role === "owner" ? alice : bob;
    await ownerService.deleteBook(shared.id, shared.version);
    sharedId = "";
    await assert.rejects(() => alice.recipes(shared.id), (error: unknown) => error instanceof AppError && error.code === "book_not_found");
    await serializable(async transaction => {
      await query(transaction, "UPDATE dbo.AccessInvites SET Revoked=1 WHERE Issuer=@issuer AND Subject='bob'", { issuer });
    });
    assert.equal((await bob.me()).access, "awaitingInvite");
    await assert.rejects(() => bob.books(), (error: unknown) => error instanceof AppError && error.code === "invite_required");
  } finally {
    await serializable(async transaction => {
      if (sharedId) await query(transaction, "DELETE dbo.Books WHERE Id=@id", { id: sharedId });
      await query(transaction, "DELETE dbo.Books WHERE Id IN(SELECT m.BookId FROM dbo.Memberships m JOIN dbo.Accounts a ON a.Id=m.UserId WHERE a.Issuer=@issuer)", { issuer });
      await query(transaction, "DELETE dbo.ShoppingLists WHERE UserId IN(SELECT Id FROM dbo.Accounts WHERE Issuer=@issuer)", { issuer });
      await query(transaction, "DELETE dbo.Accounts WHERE Issuer=@issuer", { issuer });
      await query(transaction, "DELETE dbo.AccessInvites WHERE Issuer=@issuer", { issuer });
    });
    await (await database()).close();
  }
});
