import { invariant, type BookKind, type Role } from "./contracts.js";

export function canEditRecipe(role: Role, actorId: string, authorId: string): boolean {
  return role === "owner" || actorId === authorId;
}
export function requireOwner(role: Role): void {
  invariant(role === "owner", 403, "owner_required", "Only book owners can manage membership.");
}
export function requireShared(kind: BookKind): void {
  invariant(kind === "shared", 409, "personal_book", "Personal books cannot have other members.");
}
export function preserveLastOwner(targetRole: Role, nextRole: Role | null, owners: number): void {
  invariant(!(targetRole === "owner" && nextRole !== "owner" && owners <= 1),
    409, "last_owner", "Transfer ownership or explicitly delete the shared book first.");
}
