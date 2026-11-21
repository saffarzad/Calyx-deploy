// This worker handles only tagged, versioned requests for menu films. The
// browser still loads HTML, the menu catalog and the application normally.
const CACHE = 'calyx-original-loops-v1';
const FLAG = '_calyx_loop';

self.addEventListener('install', (event) => event.waitUntil(self.skipWaiting()));
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()));

async function originalRange(request, source) {
  const cached = await (await caches.open(CACHE)).match(source);
  if (!cached) return fetch(request);
  const range = request.headers.get('range');
  if (!range) return cached;
  const blob = await cached.blob();
  const headers = new Headers({
    'Accept-Ranges': 'bytes',
    'Content-Type': blob.type,
    'Cache-Control': 'no-store',
  });
  const match = /^bytes=(\d*)-(\d*)$/i.exec(range);
  const start = match?.[1] ? Number(match[1]) : Math.max(0, blob.size - Number(match?.[2]));
  const end = match?.[1] && match[2] ? Math.min(blob.size - 1, Number(match[2])) : blob.size - 1;
  if (!match || (!match[1] && !match[2]) || !Number.isSafeInteger(start) || start > end || start >= blob.size) {
    headers.set('Content-Range', `bytes */${blob.size}`);
    return new Response(null, { status: 416, headers });
  }
  headers.set('Content-Range', `bytes ${start}-${end}/${blob.size}`);
  headers.set('Content-Length', String(end - start + 1));
  return new Response(blob.slice(start, end + 1, blob.type), { status: 206, headers });
}

self.addEventListener('fetch', (event) => {
  const { request } = event;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);
  const path = new URL('assets/items/', self.registration.scope).pathname;
  if (url.origin !== self.location.origin || !url.pathname.startsWith(path)
      || !/\/spin\.(?:mp4|webm)$/.test(url.pathname) || !url.searchParams.has(FLAG)) return;
  url.searchParams.delete(FLAG);
  event.respondWith(originalRange(request, url.href));
});
