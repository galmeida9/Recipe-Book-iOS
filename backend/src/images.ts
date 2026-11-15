import { BlobServiceClient } from "@azure/storage-blob";
import { DefaultAzureCredential } from "@azure/identity";
import { invariant, requiredSetting } from "./contracts.js";
import { query } from "./database.js";
import { bookAccess, RecipeBookService } from "./service.js";

export async function readRecipeImage(service: RecipeBookService, id: string) {
  return service.execute(async (transaction, userId) => {
    const images = await query<{ bookId: string; blobName: string; contentType: string; size: number }>(transaction, `
      SELECT CONVERT(varchar(36),r.BookId) AS bookId,i.BlobName AS blobName,i.ContentType AS contentType,i.SizeBytes AS size
      FROM dbo.RecipeImages i JOIN dbo.Recipes r ON r.Id=i.RecipeId WHERE i.Id=@id`, { id });
    invariant(images[0], 404, "image_not_found", "Image not found.");
    const image = images[0];
    await bookAccess(transaction, image.bookId, userId);
    const endpoint = new URL(requiredSetting("BLOB_SERVICE_URL"));
    invariant(endpoint.protocol === "https:" && endpoint.hostname.endsWith(".blob.core.windows.net")
      && !endpoint.search && !endpoint.username && !endpoint.password,
    503, "configuration", "A private Azure Blob service endpoint is required.");
    const blobs = new BlobServiceClient(endpoint.toString(), new DefaultAzureCredential());
    const blob = blobs.getContainerClient("recipe-images").getBlockBlobClient(image.blobName);
    const properties = await blob.getProperties();
    invariant(properties.contentLength === image.size && image.size <= 5_242_880
      && properties.contentType === image.contentType, 502, "image_integrity", "Stored image metadata does not match.");
    // Download under the same book lock as authorization. Never issue a public
    // URL or SAS that could outlive membership revocation.
    const data = await blob.downloadToBuffer(0, image.size);
    return { data, contentType: image.contentType };
  });
}
