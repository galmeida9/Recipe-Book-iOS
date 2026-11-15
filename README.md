# Recipe Book

Native Swift/SwiftUI recipe books, bounded Instagram Reel imports and personal
shopping lists, with an Azure Functions TypeScript API and Azure SQL.

The foundation contains portable Swift DTOs/API contracts, hosted OAuth PKCE,
native share-inbox plumbing, a concrete app/extension Xcode project, SQL-backed
authorization/CRUD, optimistic writes, import budget/idempotency/outbox handling,
shopping arithmetic, infrastructure and focused tests. Product SwiftUI lives in
the separate `ios/RecipeBookUI` presentation/UI package.

```powershell
npm.cmd --prefix backend ci --no-audit --no-fund
npm.cmd --prefix backend run check
```

**Not yet deployed or device-proven.** Imports are disabled until a provider and
its free-plan cost/output contract are verified. Apple SDK terms prohibit the
planned Windows SDK execution; licensed build-host authorization, signing and
actual iPhone/share/SideStore checks are required. SQL integration tests require
a real configured test database and are skipped otherwise.

See [operations and verification gates](docs/operations.md) for configuration,
account access, build-host/licensing, deployment and device requirements.
