// Service Worker for Claude Dashboard PWA
const CACHE_NAME = 'claude-dashboard-v1';

self.addEventListener('install', (event) => {
    self.skipWaiting();
});

self.addEventListener('activate', (event) => {
    event.waitUntil(clients.claim());
});

self.addEventListener('fetch', (event) => {
    // Always fetch from network for fresh data
    event.respondWith(fetch(event.request));
});
