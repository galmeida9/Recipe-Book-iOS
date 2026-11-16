import { BlobServiceClient } from "@azure/storage-blob";
import { DefaultAzureCredential } from "@azure/identity";
import { AppError, invariant, requiredSetting } from "./contracts.js";
import { query } from "./database.js";
import { bookAccess, RecipeBookService } from "./service.js";
import { createHash, randomUUID } from "node:crypto";
import { z } from "zod";
import jpeg from "jpeg-js";

export function validateCoverJPEG(data: Buffer, maximumSide = 1600): void {
  invariant(data.length >= 12 && data.length <= 2_097_152 && data[0] === 0xff && data[1] === 0xd8 &&
    data[data.length - 2] === 0xff && data[data.length - 1] === 0xd9, 400, "invalid_cover", "Choose a JPEG up to 2 MiB and 1600 pixels per side.");
  let offset = 2;
  while (offset + 4 <= data.length) {
    invariant(data[offset] === 0xff, 400, "invalid_cover", "Invalid JPEG marker.");
    while (data[offset] === 0xff) offset++;
    const marker = data[offset++]!;
    if (marker === 0xda || marker === 0xd9) break;
    invariant(offset + 2 <= data.length, 400, "invalid_cover", "Truncated JPEG.");
    const length = data.readUInt16BE(offset);
    invariant(length >= 2 && offset + length <= data.length, 400, "invalid_cover", "Invalid JPEG segment.");
    if ([0xc0, 0xc1, 0xc2].includes(marker)) {
      invariant(length >= 8 && data[offset + 2] === 8 &&
        data.readUInt16BE(offset + 3) > 0 && data.readUInt16BE(offset + 3) <= maximumSide &&
        data.readUInt16BE(offset + 5) > 0 && data.readUInt16BE(offset + 5) <= maximumSide,
      400, "invalid_cover", `Cover input must be at most ${maximumSide} pixels per side.`);
      return;
    }
    offset += length;
  }
  invariant(false, 400, "invalid_cover", "JPEG dimensions were not supported.");
}
export function sanitizeCoverJPEG(data: Buffer, imported = false): Buffer {
  validateCoverJPEG(data, imported ? 2048 : 1600);
  let decoded: { width: number; height: number; data: Uint8Array };
  try { decoded = jpeg.decode(data, { useTArray: true, tolerantDecoding: false, maxResolutionInMP: imported ? 4.2 : 2.56, maxMemoryUsageInMB: 96 }); }
  catch { throw new AppError(400, "invalid_cover", "The JPEG could not be decoded within the cover-photo limits."); }
  if (imported && Math.max(decoded.width, decoded.height) > 1600) {
    const scale = 1600 / Math.max(decoded.width, decoded.height);
    const width = Math.max(1, Math.floor(decoded.width * scale)), height = Math.max(1, Math.floor(decoded.height * scale));
    const pixels = new Uint8Array(width * height * 4);
    for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
      const source = (Math.floor(y / scale) * decoded.width + Math.floor(x / scale)) * 4;
      pixels.set(decoded.data.subarray(source, source + 4), (y * width + x) * 4);
    }
    decoded = { width, height, data: pixels };
  }
  invariant(decoded.width <= 1600 && decoded.height <= 1600, 400, "invalid_cover", "Cover photos must be at most 1600 pixels per side.");
  // Encode only pixel data: never retain uploaded EXIF/location/thumbnail data.
  const encoded = jpeg.encode({ data: decoded.data, width: decoded.width, height: decoded.height }, 85).data;
  invariant(encoded.length <= 2_097_152, 400, "invalid_cover", "The decoded cover photo exceeds 2 MiB.");
  return encoded;
}
function privateBlobs() {
  const endpoint = new URL(requiredSetting("BLOB_SERVICE_URL"));
  invariant(endpoint.protocol === "https:" && endpoint.hostname.endsWith(".blob.core.windows.net") &&
    !endpoint.search && !endpoint.username && !endpoint.password, 503, "configuration", "A private Azure Blob endpoint is required.");
  return new BlobServiceClient(endpoint.toString(), new DefaultAzureCredential()).getContainerClient("recipe-images");
}
export async function uploadRecipeImage(service: RecipeBookService, input: unknown, key: string, expectedAccountId?: string) {
  const { jpegBase64 } = z.object({ jpegBase64: z.string().max(2_796_204) }).strict().parse(input);
  await service.execute(async () => undefined);
  const inputData = Buffer.from(jpegBase64, "base64");
  invariant(inputData.toString("base64") === jpegBase64, 400, "invalid_cover", "Send canonical JPEG base64.");
  const data = sanitizeCoverJPEG(inputData);
  const hash = createHash("sha256").update(data).digest("hex");
  const id = await service.execute(async (transaction, userId) => {
    invariant(!expectedAccountId || expectedAccountId === userId, 409, "account_changed", "The signed-in account changed during the image copy.");
    const previous = await query<{ imageId: string; hash: string }>(transaction, `SELECT CONVERT(varchar(36),ImageId) AS imageId,
      ContentHash AS hash FROM dbo.ImageUploadRequests WITH(UPDLOCK,HOLDLOCK) WHERE UserId=@userId AND RequestKey=@key`, { userId, key });
    if (previous[0]) {
      invariant(previous[0].hash === hash, 409, "idempotency_conflict", "This photo-upload key belongs to different pixels.");
      const current = await query(transaction, "SELECT Id FROM dbo.RecipeImages WHERE Id=@id AND OwnerId=@userId", { id: previous[0].imageId, userId });
      invariant(current.length === 1, 409, "image_deleted", "This photo upload was deleted and will not be recreated by retrying.");
      return previous[0].imageId.toLowerCase();
    }
    const limits = await query<{ count: number }>(transaction, "SELECT COUNT(*) AS count FROM dbo.RecipeImages WITH(UPDLOCK,HOLDLOCK) WHERE OwnerId=@userId", { userId });
    invariant(limits[0]!.count < 500, 409, "image_limit", "This account has reached its cover-photo limit.");
    const budget = await query(transaction, `UPDATE dbo.Accounts SET CoverUploads=CoverUploads+1 OUTPUT inserted.Id
      WHERE Id=@userId AND CoverUploads<500`, { userId });
    invariant(budget.length === 1, 409, "image_limit", "This account's trial cover-upload allowance is exhausted. Failed uploads also consume this bounded storage allowance.");
    const id = randomUUID();
    const blobName = "covers/" + id + ".jpg";
    await query(transaction, "INSERT dbo.RecipeImages(Id,RecipeId,OwnerId,BlobName,ContentType,SizeBytes) VALUES(@id,NULL,@userId,@blobName,'image/jpeg',@size)",
      { id, userId, blobName, size: data.length });
    await query(transaction, "INSERT dbo.ImageUploadRequests(UserId,RequestKey,ContentHash,ImageId) VALUES(@userId,@key,@hash,@id)", { userId, key, hash, id });
    return id;
  });
  // Persist the reservation before external I/O. A database retry cannot create
  // untracked blobs; failed/unknown uploads retain their quota reservation.
  await privateBlobs().getBlockBlobClient("covers/" + id + ".jpg").uploadData(data, { blobHTTPHeaders: { blobContentType: "image/jpeg" } });
  return { id };
}

export async function readRecipeImage(service: RecipeBookService, id: string) {
  return service.execute(async (transaction, userId) => {
    const images = await query<{ bookId: string | null; ownerId: string | null; currentCover: string | null; blobName: string; contentType: string; size: number }>(transaction, `
      SELECT CONVERT(varchar(36),r.BookId) AS bookId,JSON_VALUE(r.Draft,'$.coverImageID') AS currentCover,
      CONVERT(varchar(36),i.OwnerId) AS ownerId,i.BlobName AS blobName,i.ContentType AS contentType,i.SizeBytes AS size
      FROM dbo.RecipeImages i LEFT JOIN dbo.Recipes r ON r.Id=i.RecipeId
      WHERE i.Id=@id`, { id });
    invariant(images[0], 404, "image_not_found", "Image not found.");
    const image = images[0];
    if (image.bookId) {
      await bookAccess(transaction, image.bookId, userId);
      invariant(image.currentCover?.toLowerCase() === id.toLowerCase(), 404, "image_not_found", "Image not found.");
    }
    else invariant(image.ownerId?.toLowerCase() === userId, 404, "image_not_found", "Image not found.");
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
