/**
 * Browser image helpers for the media library. The server has no image tools,
 * so resizing, cropping and rotating happen here on a <canvas>, and the result
 * is uploaded as a normal image.
 */

export const UPLOAD_ACCEPT = 'image/jpeg,image/png,image/webp,image/gif,image/svg+xml';
export const MAX_UPLOAD_BYTES = 8 * 1024 * 1024;
/** Photos wider or taller than this are scaled down before upload. */
const MAX_EDGE = 2560;

export interface CropArea {
  x: number;
  y: number;
  width: number;
  height: number;
}

export function loadImage(src: string, crossOrigin = false): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const img = new Image();
    if (crossOrigin) img.crossOrigin = 'anonymous';
    img.onload = () => resolve(img);
    img.onerror = () => reject(new Error('The image could not be loaded.'));
    img.src = src;
  });
}

function toBlob(canvas: HTMLCanvasElement, type: string, quality = 0.9): Promise<Blob> {
  return new Promise((resolve, reject) => {
    canvas.toBlob((b) => (b ? resolve(b) : reject(new Error('The image could not be saved.'))), type, quality);
  });
}

function canvas2d(width: number, height: number) {
  const canvas = document.createElement('canvas');
  canvas.width = width;
  canvas.height = height;
  const ctx = canvas.getContext('2d');
  if (!ctx) throw new Error('Your browser cannot edit images.');
  ctx.imageSmoothingQuality = 'high';
  return { canvas, ctx };
}

/**
 * Get a picked file ready to upload: read its size in pixels, scale big photos
 * down to MAX_EDGE, and re-encode every JPEG (that drops the camera's EXIF data,
 * including GPS location). GIF and SVG go up unchanged.
 */
export async function prepareImage(
  file: File,
): Promise<{ blob: Blob; filename: string; width?: number; height?: number }> {
  const url = URL.createObjectURL(file);
  try {
    const img = await loadImage(url);
    const w = img.naturalWidth;
    const h = img.naturalHeight;
    const raster = ['image/jpeg', 'image/png', 'image/webp'].includes(file.type);
    const scale = Math.min(1, MAX_EDGE / Math.max(w || 1, h || 1));
    if (!raster || !w || !h || (scale === 1 && file.type !== 'image/jpeg')) {
      return { blob: file, filename: file.name, width: w || undefined, height: h || undefined };
    }
    const width = Math.round(w * scale);
    const height = Math.round(h * scale);
    const { canvas, ctx } = canvas2d(width, height);
    ctx.drawImage(img, 0, 0, width, height);
    return { blob: await toBlob(canvas, file.type), filename: file.name, width, height };
  } catch {
    // Not decodable here (e.g. an odd SVG): let the server decide.
    return { blob: file, filename: file.name };
  } finally {
    URL.revokeObjectURL(url);
  }
}

/**
 * Crop (area in pixels of the rotated image, as react-easy-crop reports it),
 * rotate by 0/90/180/270 and scale to `outWidth`. GIF and SVG come out as PNG.
 */
export async function renderEdit(
  src: string,
  area: CropArea,
  rotation: number,
  outWidth: number,
  mime: string,
): Promise<{ blob: Blob; width: number; height: number; type: string }> {
  const img = await loadImage(src, true);
  const turn = ((rotation % 360) + 360) % 360;
  const sideways = turn === 90 || turn === 270;
  const rw = sideways ? img.naturalHeight : img.naturalWidth;
  const rh = sideways ? img.naturalWidth : img.naturalHeight;

  const rotated = canvas2d(rw, rh);
  rotated.ctx.translate(rw / 2, rh / 2);
  rotated.ctx.rotate((turn * Math.PI) / 180);
  rotated.ctx.drawImage(img, -img.naturalWidth / 2, -img.naturalHeight / 2);

  const width = Math.max(1, Math.round(outWidth));
  const height = Math.max(1, Math.round((width * area.height) / area.width));
  const out = canvas2d(width, height);
  out.ctx.drawImage(rotated.canvas, area.x, area.y, area.width, area.height, 0, 0, width, height);

  const type = ['image/jpeg', 'image/png', 'image/webp'].includes(mime) ? mime : 'image/png';
  // toBlob throws a SecurityError when the image came from a site without CORS.
  return { blob: await toBlob(out.canvas, type), width, height, type };
}

/** A library URL a browser can load: site-relative paths (/img/x.jpg) live on the public website. */
export function displayUrl(url: string, siteUrl?: string | null): string | null {
  if (/^https?:\/\//i.test(url)) return url;
  if (url.startsWith('/') && !url.startsWith('//') && siteUrl) return siteUrl.replace(/\/+$/, '') + url;
  return null;
}

export function formatBytes(n?: number | null): string {
  if (!n) return '';
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${Math.round(n / 1024)} KB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MB`;
}

/** The server's plain-words message from an axios error, else a fallback. */
export function apiErrorText(e: unknown, fallback: string): string {
  const data = (e as { response?: { data?: { error?: unknown; message?: unknown } } })?.response?.data;
  const raw = data?.error ?? data?.message;
  const msg = raw && typeof raw === 'object' ? (raw as { message?: unknown }).message : raw;
  if (typeof msg === 'string' && msg) return msg;
  return e instanceof Error && e.message ? e.message : fallback;
}
