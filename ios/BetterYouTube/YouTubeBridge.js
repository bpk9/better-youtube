// Runs only on YouTube, at document start. No account data leaves the device.
(() => {
  if (!/(^|\.)youtube\.com$/.test(location.hostname)) return;
  const config = window.BetterYouTubeConfig;
  const send = data => { try { window.webkit.messageHandlers.betterYouTube.postMessage(data); } catch (_) {} };
  const originalParse = JSON.parse;
  const adKeys = new Set(['adPlacements', 'playerAds', 'adSlots', 'adBreakHeartbeatParams']);
  function clean(value, depth = 0) {
    if (!value || typeof value !== 'object' || depth > 70) return value;
    for (const key of Object.keys(value)) {
      if (adKeys.has(key)) delete value[key];
      else clean(value[key], depth + 1);
    }
    return value;
  }
  if (config.blockAds) {
    JSON.parse = function(...args) { return clean(originalParse.apply(this, args)); };
    for (const name of ['ytInitialPlayerResponse']) {
      let value;
      Object.defineProperty(window, name, { configurable: true, get: () => value, set: v => { value = clean(v); } });
    }
  }
  if (config.background && config.role === 'player') {
    try {
      Object.defineProperty(document, 'hidden', { configurable: true, get: () => false });
      Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => 'visible' });
      document.addEventListener('visibilitychange', e => e.stopImmediatePropagation(), true);
    } catch (_) {}
  }
  const asText = v => typeof v === 'string' ? v : v?.simpleText || v?.content || (v?.runs || []).map(x => x.text || '').join('');
  const cards = new Map();
  let lastCards = '', lastState = '', lastURL = location.href, scheduled = false;
  function card(id, title, channel = '', detail = '', duration = '', channelID = null) {
    if (!/^[a-zA-Z0-9_-]{11}$/.test(id || '') || !title) return;
    const prior = cards.get(id);
    cards.set(id, { id, title, channel: channel || prior?.channel || '', detail: detail || prior?.detail || '', duration: duration || prior?.duration || '', channelID: channelID || prior?.channelID || null });
  }
  function channelID(value, depth = 0) {
    if (!value || typeof value !== 'object' || depth > 15) return null;
    const id = value.browseEndpoint?.browseId;
    if (/^UC[A-Za-z0-9_-]{22}$/.test(id || '')) return id;
    for (const child of Object.values(value)) {
      const found = channelID(child, depth + 1);
      if (found) return found;
    }
    return null;
  }
  function walk(value, depth = 0) {
    if (!value || typeof value !== 'object' || depth > 65) return;
    if (value.adSlotRenderer || value.promotedSparklesWebRenderer || value.promotedVideoRenderer) return;
    const v = value.videoRenderer || value.compactVideoRenderer || value.videoWithContextRenderer || value.gridVideoRenderer;
    if (v) card(v.videoId, asText(v.title || v.headline), asText(v.ownerText || v.shortBylineText || v.longBylineText), [asText(v.viewCountText || v.shortViewCountText), asText(v.publishedTimeText)].filter(Boolean).join(' · '), asText(v.lengthText), (v.ownerText || v.shortBylineText || v.longBylineText)?.runs?.[0]?.navigationEndpoint?.browseEndpoint?.browseId);
    const l = value.lockupViewModel;
    if (l?.contentType === 'LOCKUP_CONTENT_TYPE_VIDEO') {
      const meta = l.metadata?.lockupMetadataViewModel;
      const rows = meta?.metadata?.contentMetadataViewModel?.metadataRows || [];
      const parts = rows.flatMap(r => (r.metadataParts || []).map(p => asText(p.text)));
      const badges = l.contentImage?.thumbnailViewModel?.overlays || [];
      let duration = '';
      for (const b of badges) for (const badge of b.thumbnailOverlayBadgeViewModel?.thumbnailBadges || []) duration = badge.thumbnailBadgeViewModel?.text || duration;
      card(l.contentId, asText(meta?.title), parts[0] || '', parts.slice(1).join(' · '), duration, channelID(meta));
    }
    for (const [k, child] of Object.entries(value)) if (!adKeys.has(k)) walk(child, depth + 1);
  }
  function scanDOM() {
    for (const a of document.querySelectorAll('a[href*="/watch?v="]')) {
      const container = a.closest('ytm-video-with-context-renderer, ytm-rich-item-renderer, ytm-compact-video-renderer, ytd-rich-item-renderer, ytd-video-renderer, yt-lockup-view-model') || a;
      if (container.closest('ytm-promoted-sparkles-web-renderer, ytd-ad-slot-renderer')) continue;
      const id = new URL(a.href, location.href).searchParams.get('v');
      const title = container.querySelector('h3, h4, #video-title, .yt-lockup-metadata-view-model__title')?.textContent?.trim() || a.getAttribute('title');
      const channel = container.querySelector('.ytm-badge-and-byline-item-byline, .yt-content-metadata-view-model__metadata-text, #channel-name')?.textContent?.trim();
      const duration = container.querySelector('ytm-thumbnail-overlay-time-status-renderer, .yt-badge-shape__text')?.textContent?.trim();
      const channelLink = container.querySelector('a[href*="/channel/UC"]')?.getAttribute('href');
      const channelId = channelLink?.match(/\/channel\/(UC[A-Za-z0-9_-]{22})(?:[/?#]|$)/)?.[1];
      if (!cards.has(id) || (!cards.get(id).channelID && channelId)) card(id, title || cards.get(id)?.title, channel, '', duration, channelId);
    }
  }
  function collect() {
    scheduled = false;
    if (location.href !== lastURL) { cards.clear(); lastCards = ''; lastURL = location.href; }
    if (config.role === 'feed') {
      walk(window.ytInitialData);
      scanDOM();
      const result = Array.from(cards.values()).slice(0, 150);
      const encoded = JSON.stringify(result);
      if (encoded !== lastCards) {
        lastCards = encoded;
        const loggedOut = window.ytInitialData?.responseContext?.mainAppWebResponseContext?.loggedOut;
        send({ type: 'feed', cards: result, url: location.href, loggedOut: typeof loggedOut === 'boolean' ? loggedOut : window.ytcfg?.get?.('LOGGED_IN') !== true,
          emptyHome: result.length === 0 && location.pathname === '/' && !!window.ytInitialData });
      }
    }
  }
  function schedule() { if (!scheduled) { scheduled = true; setTimeout(collect, 500); } }
  const originalFetch = window.fetch;
  window.fetch = async function(...args) {
    const response = await originalFetch.apply(this, args);
    const requestURL = typeof args[0] === 'string' ? args[0] : args[0]?.url || '';
    if (requestURL.includes('/youtubei/v1/')) {
      try {
        const text = await response.clone().text();
        const data = originalParse(text);
        if (config.blockAds) clean(data);
        if (config.role === 'feed') { walk(data); schedule(); }
        return new Response(JSON.stringify(data), { status: response.status, statusText: response.statusText, headers: response.headers });
      } catch (_) {}
    }
    return response;
  };
  function installStyle() {
    if (document.getElementById('better-youtube-style') || !document.documentElement) return;
    const style = document.createElement('style'); style.id = 'better-youtube-style';
    style.textContent = (config.blockAds ? 'ytm-promoted-sparkles-web-renderer,ytm-promoted-video-renderer,ytd-ad-slot-renderer,ytd-display-ad-renderer,ytm-ad-slot-renderer,.ytp-ad-overlay-container,.ytp-ad-module{display:none!important;}' : '') +
      (config.role === 'player' ? 'html,body{background:#000!important;margin:0!important;overflow:hidden!important;} #movie_player,.html5-video-player{position:fixed!important;top:0!important;left:0!important;width:100vw!important;height:100vh!important;max-height:none!important;z-index:2147483000!important;} .html5-video-container{position:absolute!important;inset:0!important;width:100%!important;height:100%!important;} video{object-fit:contain!important;width:100%!important;height:100%!important;left:0!important;top:0!important;visibility:visible!important;} ytm-mobile-topbar-renderer,ytm-pivot-bar-renderer,.ytp-unmute,.ytp-unmute-button,.ytp-muted-autoplay-overlay{display:none!important;}' : '');
    document.documentElement.appendChild(style);
  }
  // YouTube can emit playing, then pause or replace the media during hydration.
  // Startup is complete only after sustained progress, not the first event.
  let wantsPlayback = false, startPending = false, lastStartAttempt = -Infinity;
  let startDeadline = 0, stableSince = null, stableTime = 0, startupVideo = null;
  let sampledVideo = null, sampledTime = 0, lastProgressAt = -Infinity;
  let userMuted = false;
  let desiredRate = 1, captionPreference = { enabled: false, language: '', id: '' };
  let lastCaptionAttempt = -Infinity, captionRevision = '';
  function playbackOptions(player, video, response) {
    if (video && video.playbackRate !== desiredRate) {
      try { player?.setPlaybackRate?.(desiredRate); } catch (_) {}
      video.defaultPlaybackRate = desiredRate; video.playbackRate = desiredRate;
    }
    let raw = response?.captions?.playerCaptionsTracklistRenderer?.captionTracks || [];
    let selected = {};
    try {
      const loaded = player?.getOption?.('captions', 'tracklist');
      if (loaded?.length) raw = loaded;
      selected = player?.getOption?.('captions', 'track') || {};
    } catch (_) {}
    const tracks = raw.map(t => ({ id: t.vss_id || t.vssId || `${t.languageCode}:${t.kind || ''}`,
      language: t.languageCode || '', name: (asText(t.displayName || t.name) || t.languageName || t.languageCode || 'Captions') +
        (t.kind === 'asr' && !/auto/i.test(asText(t.displayName || t.name)) ? ' (auto-generated)' : ''), raw: t }));
    const chosen = captionPreference.enabled ? (tracks.find(t => t.id === captionPreference.id) || tracks.find(t => t.language === captionPreference.language) || tracks[0]) : null;
    const selectedTrack = tracks.find(t => (selected.vss_id || selected.vssId) ? t.id === (selected.vss_id || selected.vssId) :
      t.language === selected.languageCode && (t.raw.kind || '') === (selected.kind || ''));
    const revision = `${response?.videoDetails?.videoId || ''}:${chosen?.id || 'off'}`;
    if (revision !== captionRevision) { captionRevision = revision; lastCaptionAttempt = -Infinity; }
    if (Date.now() - lastCaptionAttempt >= 1500 && (chosen ? selectedTrack?.id !== chosen.id : !!selected.languageCode)) {
      lastCaptionAttempt = Date.now();
      try {
        if (chosen) {
          player?.loadModule?.('captions');
          player?.setOption?.('captions', 'track', { ...chosen.raw, vss_id: chosen.id, languageCode: chosen.language });
        } else { player?.setOption?.('captions', 'track', {}); player?.unloadModule?.('captions'); }
      } catch (_) {}
    }
    return { captionTracks: tracks.map(({ raw, ...track }) => track), captionID: selectedTrack?.id || '',
      rate: video?.playbackRate || 1, captionsLoaded: !!response && (video?.readyState || 0) >= 1,
      captionVisible: !!document.querySelector('.ytp-caption-segment')?.textContent?.trim() };
  }
  function applyAudio(video) {
    if (!video) return;
    const player = document.querySelector('#movie_player');
    try {
      if (userMuted) { if (player?.isMuted?.() === false) player.mute?.(); }
      else if (video.muted || video.volume === 0 || player?.isMuted?.() === true) player?.unMute?.();
    } catch (_) {}
    video.muted = userMuted;
    if (!userMuted && video.volume === 0) video.volume = 1;
  }
  const observedPlayback = new WeakSet();
  function traceMedia(name, video, extra = {}) {
    if (config.diagnostics) send({ type: 'diagnostic', name, paused: video?.paused, muted: video?.muted,
      ready: video?.readyState, network: video?.networkState, time: video?.currentTime,
      presentation: video?.webkitPresentationMode, pending: startPending, wants: wantsPlayback, ...extra });
  }
  function cancelStartup() { startPending = false; stableSince = null; }
  function userPaused() {
    wantsPlayback = false; cancelStartup();
    send({ type: 'playbackIntent', requested: false, videoID: new URL(location.href).searchParams.get('v') || '' });
  }
  // An explicit web control tap must cancel recovery even during initial loading.
  document.addEventListener('click', event => {
    if (!event.isTrusted || !wantsPlayback) return;
    const control = event.target?.closest?.('.ytp-play-button, button[aria-label^="Pause"], button[title^="Pause"]');
    const video = document.querySelector('video');
    if (control && video && !video.paused) userPaused();
  }, true);
  document.addEventListener('keydown', event => {
    if (event.isTrusted && (event.code === 'Space' || event.code === 'KeyK') &&
        !/INPUT|TEXTAREA/.test(event.target?.tagName || '') && document.querySelector('video')?.paused === false) userPaused();
  }, true);
  function startPlayback() {
    if (!startPending || !wantsPlayback) return;
    const now = Date.now();
    if (now >= startDeadline) { cancelStartup(); return; }
    const video = document.querySelector('video');
    if (video !== startupVideo) { startupVideo = video; stableSince = null; }
    if (video) {
      video.preload = 'auto';
      video.setAttribute('playsinline', '');
      if (!observedPlayback.has(video)) {
        observedPlayback.add(video);
        for (const name of ['play', 'playing', 'pause', 'waiting', 'stalled', 'emptied', 'ended', 'error']) {
          video.addEventListener(name, event => traceMedia(name, video, { eventTrusted: event.isTrusted }));
        }
        for (const event of ['loadedmetadata', 'canplay']) video.addEventListener(event, startPlayback);
      }
      if (video.ended) { cancelStartup(); return; }
      if (!video.paused && video.readyState >= 3 && !video.seeking && document.readyState === 'complete') {
        if (stableSince === null) { stableSince = now; stableTime = video.currentTime; }
        if (now - stableSince >= 5000 && video.currentTime - stableTime >= 3) cancelStartup();
        return;
      }
      stableSince = null;
      // Buffering is already a pending play; don't repeatedly restart it.
      if (!video.paused) return;
    }
    // Avoid hammering play() while a source is being attached or buffered.
    if (now - lastStartAttempt < 500) return;
    lastStartAttempt = now;
    const player = document.querySelector('#movie_player');
    try { player?.playVideo?.(); } catch (_) {}
    if (video) {
      applyAudio(video);
      try { video.play()?.catch(error => traceMedia('playRejected', video, { errorName: error.name })); } catch (_) {}
    }
  }
  function requestPlayback() {
    wantsPlayback = true; startPending = true; stableSince = null;
    startDeadline = Date.now() + 30000; lastStartAttempt = -Infinity; startPlayback();
  }
  function pausePlayback() {
    wantsPlayback = false; cancelStartup();
    try { document.querySelector('#movie_player')?.pauseVideo?.(); } catch (_) {}
    document.querySelector('video')?.pause();
  }
  window.BetterYouTube = {
    collect,
    more: () => { window.scrollTo(0, document.documentElement.scrollHeight); schedule(); },
    play: requestPlayback,
    pause: pausePlayback,
    setMuted: muted => { userMuted = !!muted; applyAudio(document.querySelector('video')); },
    setOptions: options => {
      if ([0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2].includes(options.rate)) desiredRate = options.rate;
      captionPreference = { enabled: !!options.captions, language: options.language || '', id: options.captionID || '' };
      lastCaptionAttempt = -Infinity;
      tick();
    },
    setPlaybackRequested: requested => {
      if (!requested) pausePlayback();
      else if (!wantsPlayback) requestPlayback();
    },
    seek: seconds => { const v = document.querySelector('video'); if (v) v.currentTime = Math.max(0, Math.min(Number.isFinite(v.duration) ? v.duration : Infinity, v.currentTime + seconds)); },
    seekTo: seconds => { const v = document.querySelector('video'); if (v) v.currentTime = seconds; },
    pip: () => { const v = document.querySelector('video'); if (!v) return false; if (v.webkitSupportsPresentationMode?.('picture-in-picture')) { v.webkitSetPresentationMode('picture-in-picture'); return true; } return false; }
  };
  let streamSent = '', adCount = 0, wasAd = false, styledPlayer = null;
  const observedPresentation = new WeakSet();
  function tick() {
    installStyle();
    if (config.role !== 'player') return;
    startPlayback();
    const player = document.querySelector('#movie_player');
    const video = document.querySelector('video');
    if (player && styledPlayer !== player) {
      let child = player;
      while (child.parentElement && child.parentElement !== document.documentElement) {
        const parent = child.parentElement;
        for (const sibling of parent.children) if (sibling !== child && sibling.tagName !== 'SCRIPT' && sibling.tagName !== 'STYLE') sibling.style.setProperty('display', 'none', 'important');
        for (const [property, value] of Object.entries({ transform: 'none', overflow: 'visible', 'max-height': 'none', height: '100%', width: '100%' })) parent.style.setProperty(property, value, 'important');
        child = parent;
      }
      styledPlayer = player;
    }
    const ad = !!player?.classList.contains('ad-showing');
    if (config.blockAds && ad) {
      if (!wasAd) { adCount++; send({ type: 'ads', count: adCount }); }
      document.querySelector('.ytp-ad-skip-button, .ytp-skip-ad-button, .ytp-ad-skip-button-modern')?.click();
      if (video && Number.isFinite(video.duration) && video.duration > 0) video.currentTime = video.duration;
    }
    wasAd = ad;
    let response = window.ytInitialPlayerResponse;
    try { response = player?.getPlayerResponse?.() || response; } catch (_) {}
    const options = playbackOptions(player, video, response);
    const stream = response?.streamingData;
    const url = stream?.hlsManifestUrl || stream?.formats?.filter(f => f.url && f.mimeType?.includes('video/mp4') && f.audioQuality).sort((a, b) => b.height - a.height)[0]?.url;
    if (url && url !== streamSent) { streamSent = url; send({ type: 'stream', url, videoID: response?.videoDetails?.videoId || '' }); }
    if (video) {
      video.setAttribute('playsinline', '');
      if (!observedPresentation.has(video)) {
        observedPresentation.add(video);
        const reportPresentation = () => send({ type: 'pip', videoID: new URL(location.href).searchParams.get('v') || '',
          active: video.webkitPresentationMode === 'picture-in-picture' || document.pictureInPictureElement === video });
        video.addEventListener('webkitpresentationmodechanged', reportPresentation);
        video.addEventListener('enterpictureinpicture', reportPresentation);
        video.addEventListener('leavepictureinpicture', reportPresentation);
        reportPresentation();
      }
      if (!video.paused && video.readyState >= 2) applyAudio(video);
      if (sampledVideo !== video) { sampledVideo = video; sampledTime = video.currentTime; lastProgressAt = -Infinity; }
      if (video.currentTime > sampledTime && !video.seeking) lastProgressAt = Date.now();
      sampledTime = video.currentTime;
      const actuallyPlaying = !video.paused && !video.ended && !video.seeking && video.readyState >= 3 && Date.now() - lastProgressAt < 1500;
      const state = { type: 'playback', playing: actuallyPlaying, starting: startPending && wantsPlayback, muted: video.muted || video.volume === 0,
        ...options,
        time: Number.isFinite(video.currentTime) ? video.currentTime : 0, duration: Number.isFinite(video.duration) ? video.duration : 0, title: response?.videoDetails?.title || document.title.replace(/ - YouTube$/, ''), videoID: response?.videoDetails?.videoId || new URL(location.href).searchParams.get('v') || '' };
      const encoded = JSON.stringify(state);
      if (encoded !== lastState) { lastState = encoded; send(state); }
    }
  }
  document.addEventListener('DOMContentLoaded', () => {
    installStyle(); collect(); tick();
    new MutationObserver(() => { schedule(); if (config.role === 'player') startPlayback(); }).observe(document.documentElement, { childList: true, subtree: true });
  });
  setInterval(tick, 750);
  setInterval(collect, 2500);
  if (config.role === 'player') send({ type: 'playerReady', videoID: new URL(location.href).searchParams.get('v') || '' });
})();
