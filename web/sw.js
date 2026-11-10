// Kubo's own service worker.
//
// Flutter's generated one (flutter_service_worker.js) now does nothing but
// unregister itself — the framework deprecated it — which left the app with
// no cache at all. Two things were wrong with that. Every launch re-fetched
// about ten megabytes, which on a phone on mobile data is the difference
// between opening the till and waiting for it; and the app could not start
// without internet, which is the one promise it makes.
//
// So: everything this origin serves is cached on first use and served from
// the cache from then on, with nothing re-fetched behind it. A launch costs
// one small request instead of ten megabytes, and works with no signal.
//
// What makes that safe is the check below. Stale files for ever would be
// worse than slow ones, so each launch quietly fetches `flutter_bootstrap.js`
// — thirteen kilobytes — and reads the build id Flutter stamps into it. When
// that id changes, the whole cache is dropped, and the next launch picks the
// new app up in full. An update lands one launch after it is published,
// which for a till that is opened every morning is the right trade.
//
// Anything that is not a plain same-origin GET is left alone entirely, so
// Firebase, Firestore and every other cross-origin call go to the network.

const CACHE = 'kubo';
const BUILD_KEY = 'https://kubo.invalid/build-id';
const BOOTSTRAP = 'flutter_bootstrap.js';

// Worth having before the first launch finishes, because nothing renders
// without them. Everything else — CanvasKit, fonts, sqlite, pdf.js — is
// cached as it is used, since which CanvasKit build gets picked depends on
// the browser and caching all of them would be wasteful.
const SHELL = ['./', 'index.html', BOOTSTRAP, 'flutter.js', 'main.dart.js'];

self.addEventListener('install', (event) => {
  self.skipWaiting();
  event.waitUntil(
    caches.open(CACHE).then((cache) =>
      // addAll would fail the whole install if one file 404'd, leaving her
      // with no cache at all, so each is allowed to fail on its own.
      Promise.all(SHELL.map((url) => cache.add(url).catch(() => {})))
    )
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      const names = await caches.keys();
      await Promise.all(
        names.filter((n) => n !== CACHE).map((n) => caches.delete(n))
      );
      await self.clients.claim();
    })()
  );
});

/// The build id Flutter stamps into the bootstrap, or null if it is not there.
function buildIdOf(source) {
  const found = source.match(/serviceWorkerVersion:\s*"([^"]+)"/);
  return found ? found[1] : null;
}

/// Drops the cache when a new build has been published.
///
/// Runs in the background, after the page has already been served, so it
/// never puts a request between her and the till. Any failure — no signal,
/// most often — leaves the cache exactly as it was, which is the point.
async function dropCacheIfStale() {
  try {
    const cache = await caches.open(CACHE);
    const response = await fetch(BOOTSTRAP, { cache: 'no-store' });
    if (!response || response.status !== 200) return;

    const live = buildIdOf(await response.clone().text());
    if (!live) return;

    const known = await cache.match(BUILD_KEY);
    const seen = known ? await known.text() : null;

    if (seen === null) {
      await cache.put(BUILD_KEY, new Response(live));
      return;
    }
    if (seen === live) return;

    await caches.delete(CACHE);
    const fresh = await caches.open(CACHE);
    await fresh.put(BUILD_KEY, new Response(live));
  } catch (e) {
    // Offline, or the file moved. Keep what we have.
  }
}

self.addEventListener('fetch', (event) => {
  const request = event.request;
  if (request.method !== 'GET') return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;

  // The bootstrap is how staleness is detected, so it is never answered
  // from the cache by this path — it is fetched fresh, in the background.
  if (request.mode === 'navigate') {
    event.waitUntil(dropCacheIfStale());
  }

  event.respondWith(
    (async () => {
      const cache = await caches.open(CACHE);
      const hit = await cache.match(request, { ignoreSearch: true });
      if (hit) return hit;

      try {
        const response = await fetch(request);
        // Opaque and error responses are never worth keeping: caching one
        // would pin a failure in place until the next build.
        if (response && response.status === 200 && response.type === 'basic') {
          cache.put(request, response.clone()).catch(() => {});
        }
        return response;
      } catch (e) {
        // No cache, no network. For a navigation this is still recoverable:
        // the shell is what matters, not the URL within it.
        if (request.mode === 'navigate') {
          const shell = await cache.match('index.html');
          if (shell) return shell;
        }
        throw e;
      }
    })()
  );
});

/// Takes in whatever the page actually loaded, and makes sure it is kept.
///
/// Some of the heaviest files never reach the handler above. CanvasKit is
/// fetched before this worker has taken control on the very first launch,
/// and the renderer, the fonts and the sqlite module are each loaded in
/// ways that can sidestep it afterwards. Left at that, the app only ever
/// started offline because the browser's own HTTP cache happened to still
/// hold them — and that cache is evicted whenever the phone is short of
/// space, which is exactly when she would discover it.
///
/// So once the app is up, the page sends the list of everything it loaded
/// and anything missing is fetched into the cache properly. It costs one
/// background pass on the first launch and nothing on any launch after.
self.addEventListener('message', (event) => {
  const data = event.data;
  if (!data || data.kind !== 'keep' || !Array.isArray(data.urls)) return;

  event.waitUntil(
    (async () => {
      const cache = await caches.open(CACHE);
      for (const raw of data.urls) {
        try {
          const url = new URL(raw, self.location.href);
          if (url.origin !== self.location.origin) continue;
          if (await cache.match(url.href)) continue;
          await cache.add(url.href);
        } catch (e) {
          // One file failing to cache is not worth losing the rest over.
        }
      }
    })()
  );
});
