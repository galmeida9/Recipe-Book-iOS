import Testing
import Foundation
@testable import RecipeBookCore

@Test func backendRecipeShapeDecodesWithoutInventingMissingAmounts() throws {
    let data = Data("""
    {"id":"00000000-0000-4000-8000-000000000001",
     "bookId":"00000000-0000-4000-8000-000000000002",
     "authorId":"00000000-0000-4000-8000-000000000003",
     "draft":{"title":"Soup","ingredients":[{"name":"salt","quantity":null,"unit":null,"preparation":null}],
              "steps":[],"servings":null,"totalMinutes":null,"sourceURL":null},
     "version":1}
    """.utf8)
    let recipe = try JSONDecoder().decode(Recipe.self, from: data)
    #expect(recipe.draft.ingredients.first?.quantity == nil)
    #expect(recipe.draft.servings == nil)
    #expect(recipe.draft.totalMinutes == nil)
}

@Test func backendImportAndAccountShapesDecode() throws {
    let data = Data("""
    {"id":"00000000-0000-4000-8000-000000000001","state":"review",
     "sourceURL":"https://www.instagram.com/reel/Ab/",
     "draft":null,"evidence":{"caption":null,"comments":[],"transcript":null},
     "error":null,"version":2,"createdAt":"2026-11-15T18:00:00.000Z",
     "recipeId":null,"bookId":null}
    """.utf8)
    #expect(try JSONDecoder().decode(ImportJob.self, from: data).state == .review)
    let account = try JSONDecoder().decode(SessionAccount.self, from: Data("""
    {"id":"00000000-0000-4000-8000-000000000001","displayName":null,"access":"awaitingInvite"}
    """.utf8))
    #expect(account.access == "awaitingInvite")
}
