import { randomUUID, createHash } from "node:crypto";
import type sql from "mssql";
import { z } from "zod";
import { assertVersion, invariant, draftSchema, ingredientSchema, shoppingItemSchema, idSchema,
  type Principal, type Book, type Recipe, type ShoppingList, type Role, type BookKind } from "./contracts.js";
import { query, serializable } from "./database.js";
import { canEditRecipe, preserveLastOwner, requireOwner, requireShared } from "./policies.js";
import { combineShopping } from "./shopping.js";
import { generatedSections } from "./planner-service.js";

interface BookRow { id: string; name: string; kind: BookKind; version: number }
interface Access extends BookRow { role: Role }
interface RecipeRow { id: string; bookId: string; authorId: string; draft: string; version: number }
interface ListRow { id: string; name: string; items: string; version: number }
const nameSchema = z.string().trim().min(1).max(120);
export const pendingAccountLimit = 100;
export const createBookSchema = z.object({ name: nameSchema, kind: z.enum(["personal", "shared"]) }).strict();
export const copyLocalBookSchema = z.object({ name: nameSchema, kind: z.enum(["personal", "shared"]),
  recipes: z.array(draftSchema).max(500) }).strict();
export const createListSchema = z.object({ name: nameSchema }).strict();
export const replaceItemsSchema = z.object({ items: z.array(shoppingItemSchema).max(1000) }).strict()
  .refine(value => new Set(value.items.map(item => item.id)).size === value.items.length, "Item identifiers must be unique.");
export const addRecipeSchema = z.object({ recipeId: idSchema, recipeVersion: z.number().int().positive(), alreadyHave: z.array(z.number().int().min(0)).max(200) }).strict();

export async function account(transaction: sql.Transaction, principal: Principal): Promise<string> {
  const invitations = await query<{ subject: string }>(transaction, `
    SELECT Subject AS subject FROM dbo.AccessInvites WITH (UPDLOCK,HOLDLOCK)
    WHERE Issuer=@issuer AND Subject=@subject AND Revoked=0 AND ExpiresAt>SYSUTCDATETIME()`, { ...principal });
  invariant(invitations.length > 0, 403, "invite_required", "Your Recipe Book invitation is missing, expired or revoked.");
  const rows = await query<{ id: string; active: boolean; deleted: boolean }>(transaction, `
    SELECT CONVERT(varchar(36),Id) AS id, Active AS active,Deleted AS deleted FROM dbo.Accounts WITH (UPDLOCK,HOLDLOCK)
    WHERE Issuer=@issuer AND Subject=@subject`, { ...principal });
  if (rows[0]) {
    invariant(!rows[0].deleted, 403, "account_deleted", "This account has been deleted.");
    if (!rows[0].active) await query(transaction, "UPDATE dbo.Accounts SET Active=1 WHERE Id=@id", { id: rows[0].id });
    return rows[0].id.toLowerCase();
  }
  const id = randomUUID();
  await query(transaction, "INSERT dbo.Accounts(Id,Issuer,Subject) VALUES(@id,@issuer,@subject)", { id, ...principal });
  return id;
}

export async function bookAccess(transaction: sql.Transaction, bookId: string, userId: string): Promise<Access> {
  // Every book mutation locks its parent before membership/recipe reads. This
  // serializes last-owner changes, departures and concurrent recipe writes.
  const books = await query<BookRow>(transaction, `
    SELECT CONVERT(varchar(36),Id) AS id, Name AS name, Kind AS kind, Version AS version
    FROM dbo.Books WITH (UPDLOCK,HOLDLOCK) WHERE Id=@bookId`, { bookId });
  const membership = await query<{ role: Role }>(transaction,
    "SELECT Role AS role FROM dbo.Memberships WHERE BookId=@bookId AND UserId=@userId", { bookId, userId });
  invariant(books[0] && membership[0], 404, "book_not_found", "Book not found.");
  return { ...books[0], id: books[0].id.toLowerCase(), role: membership[0].role };
}
async function bumpBook(transaction: sql.Transaction, book: Access): Promise<Book> {
  await query(transaction, "UPDATE dbo.Books SET Version=Version+1 WHERE Id=@id", { id: book.id });
  return { ...book, version: book.version + 1 };
}
function recipe(row: RecipeRow): Recipe {
  return { ...row, id: row.id.toLowerCase(), bookId: row.bookId.toLowerCase(), authorId: row.authorId.toLowerCase(), draft: draftSchema.parse(JSON.parse(row.draft)) };
}
async function getRecipe(transaction: sql.Transaction, bookId: string, id: string): Promise<Recipe> {
  const rows = await query<RecipeRow>(transaction, `
    SELECT CONVERT(varchar(36),Id) AS id,CONVERT(varchar(36),BookId) AS bookId,
      CONVERT(varchar(36),AuthorId) AS authorId,Draft AS draft,Version AS version
    FROM dbo.Recipes WHERE Id=@id AND BookId=@bookId`, { id, bookId });
  invariant(rows[0], 404, "recipe_not_found", "Recipe not found.");
  return recipe(rows[0]);
}
async function getList(transaction: sql.Transaction, id: string, userId: string): Promise<ShoppingList> {
  const generated = await generatedSections(transaction, userId, id);
  // Sanitization can remove revoked or stale contributions and bump Version.
  // Read the manual items/version only afterward, in this same transaction.
  const rows = await query<ListRow>(transaction, `
    SELECT CONVERT(varchar(36),Id) AS id,Name AS name,Items AS items,Version AS version
    FROM dbo.ShoppingLists WITH(UPDLOCK,HOLDLOCK) WHERE Id=@id AND UserId=@userId`, { id, userId });
  invariant(rows[0], 404, "list_not_found", "Shopping list not found.");
  return { ...rows[0], id: rows[0].id.toLowerCase(), items: z.array(shoppingItemSchema).parse(JSON.parse(rows[0].items)), generated };
}
async function createStoredBook(transaction: sql.Transaction, userId: string, body: { name: string; kind: BookKind }): Promise<Book> {
  const id = randomUUID();
  const counts = await query<{ count: number }>(transaction, "SELECT COUNT(*) AS count FROM dbo.Memberships WHERE UserId=@userId", { userId });
  invariant(counts[0]!.count < 100, 409, "book_limit", "An account can belong to at most 100 books.");
  await query(transaction, "INSERT dbo.Books(Id,Name,Kind) VALUES(@id,@name,@kind)", { id, ...body });
  await query(transaction, "INSERT dbo.Memberships(BookId,UserId,Role) VALUES(@id,@userId,'owner')", { id, userId });
  return { id, ...body, role: "owner", version: 1 };
}
export async function bindCover(transaction: sql.Transaction, userId: string, recipeId: string, imageId: string | null) {
  if (!imageId) return;
  const rows = await query(transaction, `UPDATE dbo.RecipeImages WITH(UPDLOCK,HOLDLOCK) SET RecipeId=@recipeId
    OUTPUT inserted.Id WHERE Id=@imageId AND ((RecipeId IS NULL AND OwnerId=@userId) OR RecipeId=@recipeId)`,
  { userId, recipeId, imageId });
  invariant(rows.length === 1, 403, "image_owner", "Choose a photo uploaded for this recipe by your account.");
}
export class RecipeBookService {
  constructor(private readonly principal: Principal) {}
  async execute<T>(work: (transaction: sql.Transaction, userId: string) => Promise<T>): Promise<T> {
    return serializable(async transaction => work(transaction, await account(transaction, this.principal)));
  }
  me() {
    return serializable(async transaction => {
      const invites = await query<{ count: number }>(transaction,
        `SELECT COUNT(*) AS count FROM dbo.AccessInvites WITH(UPDLOCK,HOLDLOCK) WHERE Issuer=@issuer AND Subject=@subject
        AND Revoked=0 AND ExpiresAt>SYSUTCDATETIME()`, { ...this.principal });
      let rows = await query<{ id: string; displayName: string | null; deleted: boolean }>(transaction,
        `SELECT CONVERT(varchar(36),Id) AS id,DisplayName AS displayName,Deleted AS deleted
        FROM dbo.Accounts WITH(UPDLOCK,HOLDLOCK) WHERE Issuer=@issuer AND Subject=@subject`, { ...this.principal });
      if (!rows[0]) {
        if (invites[0]!.count === 0) {
          const pending = await query<{ count: number }>(transaction,
            "SELECT COUNT(*) AS count FROM dbo.Accounts WITH(UPDLOCK,HOLDLOCK) WHERE Active=0 AND Deleted=0");
          invariant(pending[0]!.count < pendingAccountLimit, 503, "onboarding_capacity",
            "Pending invitation capacity is full. Ask the app administrator for access before signing in.");
        }
        const id = randomUUID();
        await query(transaction, "INSERT dbo.Accounts(Id,Issuer,Subject,Active) VALUES(@id,@issuer,@subject,0)", { id, ...this.principal });
        rows = [{ id, displayName: null, deleted: false }];
      }
      const row = rows[0]!;
      invariant(!row.deleted, 403, "account_deleted", "This account has been deleted.");
      const access = invites[0]!.count > 0 ? "active" : "awaitingInvite";
      if (access === "active") await query(transaction, "UPDATE dbo.Accounts SET Active=1 WHERE Id=@id", { id: row.id });
      return { id: row.id.toLowerCase(), displayName: row.displayName, access };
    });
  }
  completeSetup(input: unknown) {
    const { displayName } = z.object({ displayName: nameSchema }).strict().parse(input);
    return this.execute(async (transaction, id) => {
      await query(transaction, "UPDATE dbo.Accounts SET DisplayName=@displayName WHERE Id=@id", { id, displayName });
      return { id, displayName };
    });
  }
  books() {
    return this.execute(async (transaction, userId) => {
      const rows = await query<Book>(transaction, `
        SELECT CONVERT(varchar(36),b.Id) AS id,b.Name AS name,b.Kind AS kind,m.Role AS role,b.Version AS version
        FROM dbo.Books b JOIN dbo.Memberships m ON m.BookId=b.Id WHERE m.UserId=@userId ORDER BY b.Name,b.Id`, { userId });
      return rows.map(row => ({ ...row, id: row.id.toLowerCase() }));
    });
  }
  createBook(input: unknown) {
    const body = createBookSchema.parse(input);
    return this.execute((transaction, userId) => createStoredBook(transaction, userId, body));
  }
  copyLocalBook(input: unknown, requestKey: string, expectedAccountId: string) {
    const body = copyLocalBookSchema.parse(input);
    const key = idSchema.parse(requestKey);
    const snapshotHash = createHash("sha256").update(JSON.stringify(body)).digest("hex");
    return this.execute(async (transaction, userId): Promise<Book> => {
      invariant(userId === idSchema.parse(expectedAccountId), 409, "account_changed", "Sign-in changed before copying. Return to the intended account and retry.");
      const previous = await query<{ bookId: string; hash: string }>(transaction,
        `SELECT CONVERT(varchar(36),BookId) AS bookId,SnapshotHash AS hash FROM dbo.LocalBookCopies WITH(UPDLOCK,HOLDLOCK)
          WHERE UserId=@userId AND RequestKey=@key`, { userId, key });
      if (previous[0]) {
        invariant(previous[0].hash === snapshotHash, 409, "idempotency_conflict", "This copy request belongs to a different local snapshot.");
        return bookAccess(transaction, previous[0].bookId.toLowerCase(), userId);
      }
      const book = await createStoredBook(transaction, userId, { name: body.name, kind: body.kind });
      for (const draft of body.recipes) {
        invariant(!draft.coverImageID, 400, "copy_image", "Local photos must be copied through the dedicated image upload flow.");
        await query(transaction, "INSERT dbo.Recipes(Id,BookId,AuthorId,Draft) VALUES(@id,@bookId,@userId,@draft)",
          { id: randomUUID(), bookId: book.id, userId, draft: JSON.stringify(draft) });
      }
      await query(transaction, "INSERT dbo.LocalBookCopies(UserId,RequestKey,SnapshotHash,BookId) VALUES(@userId,@key,@hash,@bookId)",
        { userId, key, hash: snapshotHash, bookId: book.id });
      return book;
    });
  }
  deleteBook(bookId: string, version: number) {
    return this.execute(async (transaction, userId) => {
      const book = await bookAccess(transaction, bookId, userId);
      requireOwner(book.role); assertVersion(book.version, version);
      await query(transaction, "DELETE dbo.Books WHERE Id=@bookId", { bookId });
      return { id: userId };
    });
  }
  members(bookId: string) {
    return this.execute(async (transaction, userId) => {
      await bookAccess(transaction, bookId, userId);
      const rows = await query<{ userId: string; role: Role; displayName: string | null }>(transaction,
        `SELECT CONVERT(varchar(36),m.UserId) AS userId,m.Role AS role,a.DisplayName AS displayName
        FROM dbo.Memberships m JOIN dbo.Accounts a ON a.Id=m.UserId WHERE m.BookId=@bookId ORDER BY m.UserId`, { bookId });
      return rows.map(row => ({ ...row, userId: row.userId.toLowerCase() }));
    });
  }
  addMember(bookId: string, targetId: string, version: number) {
    return this.execute(async (transaction, userId) => {
      const book = await bookAccess(transaction, bookId, userId);
      requireOwner(book.role); requireShared(book.kind); assertVersion(book.version, version);
      const targets = await query<{ id: string }>(transaction, `
        SELECT CONVERT(varchar(36),a.Id) AS id FROM dbo.Accounts a JOIN dbo.AccessInvites i
        ON i.Issuer=a.Issuer AND i.Subject=a.Subject WHERE a.Id=@targetId AND a.Active=1
        AND i.Revoked=0 AND i.ExpiresAt>SYSUTCDATETIME()`, { targetId });
      invariant(targets[0], 404, "account_not_found", "An active invited account is required.");
      const memberships = await query<{ userId: string }>(transaction,
        "SELECT CONVERT(varchar(36),UserId) AS userId FROM dbo.Memberships WHERE BookId=@bookId", { bookId });
      invariant(memberships.length < 100, 409, "member_limit", "A book can contain at most 100 members.");
      invariant(!memberships.some(row => row.userId.toLowerCase() === targetId), 409, "already_member", "This account is already a member.");
      const counts = await query<{ count: number }>(transaction,
        "SELECT COUNT(*) AS count FROM dbo.Memberships WHERE UserId=@targetId", { targetId });
      invariant(counts[0]!.count < 100, 409, "book_limit", "The account already belongs to 100 books.");
      await query(transaction, "INSERT dbo.Memberships(BookId,UserId,Role) VALUES(@bookId,@targetId,'member')", { bookId, targetId });
      return bumpBook(transaction, book);
    });
  }
  changeMember(bookId: string, targetId: string, nextRole: Role | null, version: number) {
    return this.execute(async (transaction, userId) => {
      const book = await bookAccess(transaction, bookId, userId);
      requireShared(book.kind); assertVersion(book.version, version);
      if (nextRole !== null || targetId !== userId) requireOwner(book.role);
      const memberships = await query<{ userId: string; role: Role }>(transaction,
        "SELECT CONVERT(varchar(36),UserId) AS userId,Role AS role FROM dbo.Memberships WHERE BookId=@bookId", { bookId });
      const target = memberships.find(row => row.userId.toLowerCase() === targetId);
      invariant(target, 404, "member_not_found", "Member not found.");
      preserveLastOwner(target.role, nextRole, memberships.filter(row => row.role === "owner").length);
      if (nextRole === null) {
        await query(transaction, "DELETE dbo.Memberships WHERE BookId=@bookId AND UserId=@targetId", { bookId, targetId });
        await bumpBook(transaction, book);
        return { id: userId };
      }
      await query(transaction, "UPDATE dbo.Memberships SET Role=@nextRole WHERE BookId=@bookId AND UserId=@targetId", { bookId, targetId, nextRole });
      const updated = await bumpBook(transaction, book);
      return { ...updated, role: targetId === userId ? nextRole : updated.role };
    });
  }
  deleteAccount() {
    return this.execute(async (transaction, userId) => {
      await query(transaction, "DELETE dbo.WeeklyPlans WHERE UserId=@userId", { userId });
      const memberships = await query<{ bookId: string }>(transaction,
        "SELECT CONVERT(varchar(36),BookId) AS bookId FROM dbo.Memberships WHERE UserId=@userId ORDER BY BookId", { userId });
      for (const membership of memberships) {
        const book = await bookAccess(transaction, membership.bookId, userId);
        if (book.kind === "personal") {
          await query(transaction, "DELETE dbo.Books WHERE Id=@bookId", { bookId: book.id });
        } else {
          const owners = await query<{ count: number }>(transaction,
            "SELECT COUNT(*) AS count FROM dbo.Memberships WHERE BookId=@bookId AND Role='owner'", { bookId: book.id });
          preserveLastOwner(book.role, null, owners[0]!.count);
          await query(transaction, "DELETE dbo.Memberships WHERE BookId=@bookId AND UserId=@userId", { bookId: book.id, userId });
          await bumpBook(transaction, book);
        }
      }
      await query(transaction, "DELETE dbo.ShoppingLists WHERE UserId=@userId", { userId });
      // Retain a tombstone for authorship and irreversible account-access revocation.
      await query(transaction, "UPDATE dbo.Accounts SET Active=0,Deleted=1,DisplayName=NULL WHERE Id=@userId", { userId });
      await query(transaction, "UPDATE dbo.ImportJobs SET Draft=NULL,Evidence=NULL WHERE UserId=@userId", { userId });
      await query(transaction, "UPDATE dbo.AccessInvites SET Revoked=1 WHERE Issuer=@issuer AND Subject=@subject", { ...this.principal });
      return { id: userId };
    });
  }
  recipes(bookId: string) {
    return this.execute(async (transaction, userId) => {
      await bookAccess(transaction, bookId, userId);
      return (await query<RecipeRow>(transaction, `
        SELECT CONVERT(varchar(36),Id) AS id,CONVERT(varchar(36),BookId) AS bookId,
        CONVERT(varchar(36),AuthorId) AS authorId,Draft AS draft,Version AS version FROM dbo.Recipes WHERE BookId=@bookId ORDER BY Id`, { bookId })).map(recipe);
    });
  }
  saveRecipe(bookId: string, input: unknown, id?: string, version?: number) {
    const draft = draftSchema.parse(input);
    return this.execute(async (transaction, userId): Promise<Recipe> => {
      const book = await bookAccess(transaction, bookId, userId);
      if (id) {
        const existing = await getRecipe(transaction, bookId, id);
        if (existing.draft.sourceURL) draft.sourceURL = existing.draft.sourceURL;
        invariant(canEditRecipe(book.role, userId, existing.authorId), 403, "recipe_author", "Only the contributor or a book owner can edit this recipe.");
        assertVersion(existing.version, version!);
        await bindCover(transaction, userId, id, draft.coverImageID);
        await query(transaction, "UPDATE dbo.Recipes SET Draft=@draft,Version=Version+1 WHERE Id=@id", { id, draft: JSON.stringify(draft) });
        return { ...existing, draft, version: existing.version + 1 };
      }
      const counts = await query<{ count: number }>(transaction,
        "SELECT COUNT(*) AS count FROM dbo.Recipes WHERE BookId=@bookId", { bookId });
      invariant(counts[0]!.count < 1000, 409, "recipe_limit", "A book can contain at most 1000 recipes.");
      const recipeId = randomUUID();
      await query(transaction, "INSERT dbo.Recipes(Id,BookId,AuthorId,Draft) VALUES(@id,@bookId,@userId,@draft)",
        { id: recipeId, bookId, userId, draft: JSON.stringify(draft) });
      await bindCover(transaction, userId, recipeId, draft.coverImageID);
      return { id: recipeId, bookId, authorId: userId, draft, version: 1 };
    });
  }
  deleteRecipe(bookId: string, id: string, version: number) {
    return this.execute(async (transaction, userId) => {
      const book = await bookAccess(transaction, bookId, userId);
      const existing = await getRecipe(transaction, bookId, id);
      invariant(canEditRecipe(book.role, userId, existing.authorId), 403, "recipe_author", "Only the contributor or a book owner can delete this recipe.");
      assertVersion(existing.version, version);
      await query(transaction, "DELETE dbo.Recipes WHERE Id=@id", { id });
      return { id: userId };
    });
  }
  suggestions(have: string[] = []) {
    const names = z.array(z.string().trim().min(1).max(200)).max(50).parse(have).map(value => value.toLowerCase());
    return this.execute(async (transaction, userId) => (await query<RecipeRow>(transaction, `
      SELECT TOP(20) CONVERT(varchar(36),r.Id) AS id,CONVERT(varchar(36),r.BookId) AS bookId,
      CONVERT(varchar(36),r.AuthorId) AS authorId,r.Draft AS draft,r.Version AS version
      FROM dbo.Recipes r JOIN dbo.Memberships m ON m.BookId=r.BookId
      CROSS APPLY (
        SELECT COUNT(DISTINCT LOWER(LTRIM(RTRIM(JSON_VALUE(i.value,'$.name'))))) AS matches
        FROM OPENJSON(r.Draft,'$.ingredients') i
        JOIN OPENJSON(@have) h ON LOWER(LTRIM(RTRIM(JSON_VALUE(i.value,'$.name'))))=h.value
      ) matchCount
      WHERE m.UserId=@userId AND (@have='[]' OR matchCount.matches>0)
      ORDER BY matchCount.matches DESC,NEWID()`, { userId, have: JSON.stringify(names) })).map(recipe));
  }
  shoppingLists() {
    return this.execute(async (transaction, userId) => {
      const rows = await query<{ id: string }>(transaction, `
        SELECT CONVERT(varchar(36),Id) AS id FROM dbo.ShoppingLists WHERE UserId=@userId ORDER BY Name,Id`, { userId });
      const lists: ShoppingList[] = [];
      for (const row of rows) lists.push(await getList(transaction, row.id.toLowerCase(), userId));
      return lists;
    });
  }
  createShoppingList(input: unknown) {
    const { name } = createListSchema.parse(input);
    return this.execute(async (transaction, userId): Promise<ShoppingList> => {
      const counts = await query<{ count: number }>(transaction,
        "SELECT COUNT(*) AS count FROM dbo.ShoppingLists WHERE UserId=@userId", { userId });
      invariant(counts[0]!.count < 100, 409, "list_limit", "An account can have at most 100 shopping lists.");
      const id = randomUUID();
      await query(transaction, "INSERT dbo.ShoppingLists(Id,UserId,Name) VALUES(@id,@userId,@name)", { id, userId, name });
      return { id, name, items: [], generated: [], version: 1 };
    });
  }
  deleteShoppingList(id: string, version: number) {
    return this.execute(async (transaction, userId) => {
      const list = await getList(transaction, id, userId);
      assertVersion(list.version, version);
      await query(transaction, "DELETE dbo.ShoppingLists WHERE Id=@id", { id });
      return { id: userId };
    });
  }
  replaceShoppingItems(id: string, input: unknown, version: number) {
    const { items } = replaceItemsSchema.parse(input);
    return this.execute(async (transaction, userId) => {
      const list = await getList(transaction, id, userId);
      assertVersion(list.version, version);
      await query(transaction, "UPDATE dbo.ShoppingLists SET Items=@items,Version=Version+1 WHERE Id=@id", { id, items: JSON.stringify(items) });
      return { ...list, items, version: list.version + 1 };
    });
  }
  addRecipeToList(id: string, input: unknown, version: number) {
    const { recipeId, recipeVersion, alreadyHave } = addRecipeSchema.parse(input);
    return this.execute(async (transaction, userId) => {
      const rows = await query<{ bookId: string }>(transaction,
        "SELECT CONVERT(varchar(36),BookId) AS bookId FROM dbo.Recipes WHERE Id=@recipeId", { recipeId });
      invariant(rows[0], 404, "recipe_not_found", "Recipe not found.");
      await bookAccess(transaction, rows[0].bookId, userId);
      const savedRecipe = await getRecipe(transaction, rows[0].bookId, recipeId);
      assertVersion(savedRecipe.version, recipeVersion);
      const list = await getList(transaction, id, userId);
      assertVersion(list.version, version);
      const items = combineShopping(list.items, savedRecipe.draft.ingredients, alreadyHave);
      await query(transaction, "UPDATE dbo.ShoppingLists SET Items=@items,Version=Version+1 WHERE Id=@id", { id, items: JSON.stringify(items) });
      return { ...list, items, version: list.version + 1 };
    });
  }
}
