const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync(require('node:path').join(__dirname, '../ios/BetterYouTube/YouTubeBridge.js'), 'utf8');
function environment(role = 'feed', overrides = {}) {
  const messages = [], timers = [];
  const document = { querySelectorAll: () => [], querySelector: () => null, getElementById: () => true, addEventListener() {}, documentElement: { scrollHeight: 100 } };
  const context = vm.createContext({ document, URL, Response, setTimeout: f => f(), setInterval: f => timers.push(f), location: { hostname: 'm.youtube.com', href: 'https://m.youtube.com/', pathname: '/' }, ...overrides });
  context.window = context;
  context.BetterYouTubeConfig = { role, blockAds: true, background: true };
  context.webkit = { messageHandlers: { betterYouTube: { postMessage: m => messages.push(m) } } };
  context.fetch = async () => new Response('{}');
  vm.runInContext(source, context);
  return { context, messages, timers };
}
const { context, messages } = environment();
context.ytInitialData = { contents: [
  { videoRenderer: { videoId: 'abcdefghijk', title: { runs: [{ text: 'Real video' }] }, ownerText: { simpleText: 'A creator' }, lengthText: { simpleText: '4:32' } } },
  { adSlotRenderer: { videoRenderer: { videoId: 'adadadadada', title: { simpleText: 'Advertisement' } } } },
  { lockupViewModel: { contentType: 'LOCKUP_CONTENT_TYPE_VIDEO', contentId: 'ZYXWVUTSRQP', metadata: { lockupMetadataViewModel: { title: { content: 'Modern card' }, metadata: { contentMetadataViewModel: { metadataRows: [{ metadataParts: [{ text: { content: 'Modern creator', commandRuns: [{ onTap: { innertubeCommand: { browseEndpoint: { browseId: 'UCabcdefghijklmnopqrstuv' } } } }] } }] }] } } } } } },
  { videoRenderer: { videoId: '../invalid', title: { simpleText: 'Invalid ID' } } }
] };
context.BetterYouTube.collect();
assert.equal(messages.at(-1).cards.length, 2);
assert.equal(messages.at(-1).cards[0].channel, 'A creator');
assert.equal(messages.at(-1).cards[1].title, 'Modern card');
assert.equal(messages.at(-1).cards[1].channelID, 'UCabcdefghijklmnopqrstuv', 'modern cards expose channel IDs for subscription actions');
const parsed = vm.runInContext('JSON.parse(\'{"streamingData":{"url":"kept"},"adPlacements":[1],"nested":{"playerAds":[1]}}\')', context);
assert.equal(parsed.streamingData.url, 'kept');
assert.equal(parsed.adPlacements, undefined);
assert.equal(parsed.nested.playerAds, undefined);
assert.equal(context.document.hidden, undefined, 'feed must not override page visibility');
const player = environment('player');
assert.equal(player.context.document.hidden, false);
const emptyHome = environment();
emptyHome.context.ytInitialData = { responseContext: { mainAppWebResponseContext: { loggedOut: true } }, contents: { richGridRenderer: { contents: [{ feedNudgeRenderer: { title: { simpleText: 'Try searching to get started' } } }] } } };
emptyHome.context.BetterYouTube.collect();
assert.equal(emptyHome.messages.at(-1).emptyHome, true, 'an empty YouTube home should trigger discovery instead of an endless spinner');
assert.equal(emptyHome.messages.at(-1).loggedOut, true);
const before = messages.length; context.BetterYouTube.collect();
assert.equal(messages.length, before, 'unchanged feeds do not spam the bridge');

// Reproduce the race: navigation finishes before YouTube creates its video.
let clock = 0, activeVideo = null;
const documentEvents = {};
function fakeVideo() {
  const events = {};
  return {
    paused: true, ended: false, readyState: 0, currentTime: 0, duration: 120, attempts: 0, muted: true, volume: 1,
    setAttribute() {}, addEventListener(name, callback) { events[name] = callback; },
    play() { this.attempts++; return { catch() {} }; },
    pause() { this.paused = true; },
    emit(name) { events[name]?.({ isTrusted: true }); }
  };
}
const delayed = environment('player', {
  Date: { now: () => clock },
  location: { hostname: 'm.youtube.com', href: 'https://m.youtube.com/watch?v=abcdefghijk', pathname: '/watch' },
  document: { title: 'Test video', readyState: 'complete', querySelectorAll: () => [], querySelector: selector => selector === 'video' ? activeVideo : null,
    getElementById: () => true, addEventListener(name, callback) { documentEvents[name] = callback; }, documentElement: {} }
});
const bridge = delayed.context.BetterYouTube;
assert.equal(delayed.messages[0].type, 'playerReady');
bridge.setPlaybackRequested(true); // No video yet; request must survive.
clock += 750; activeVideo = fakeVideo(); delayed.timers[0]();
assert.equal(activeVideo.attempts, 1, 'late video starts without another tap');
assert.equal(activeVideo.preload, 'auto');
assert.equal(activeVideo.muted, false, 'selection requests audible playback');
clock += 750; activeVideo.emit('canplay');
assert.equal(activeVideo.attempts, 2, 'retry when media becomes ready after an unsuccessful start');
activeVideo.paused = false; activeVideo.readyState = 3; activeVideo.emit('playing');
activeVideo.paused = true; // YouTube pauses again while finishing initialization.
clock += 750; delayed.timers[0]();
assert.equal(activeVideo.attempts, 3, 'a transient playing event must not disable startup recovery');
activeVideo.paused = false;
for (let i = 0; i < 9; i++) { clock += 750; activeVideo.currentTime += .75; delayed.timers[0](); }
const settledAttempts = activeVideo.attempts;
activeVideo.paused = true;
clock += 750; bridge.setPlaybackRequested(true); delayed.timers[0]();
assert.equal(activeVideo.attempts, settledAttempts, 'after sustained playback, a pause stays paused');
bridge.play(); assert.equal(activeVideo.attempts, settledAttempts + 1, 'explicit resume still works');
bridge.pause(); clock += 750; activeVideo.emit('canplay'); delayed.timers[0]();
assert.equal(activeVideo.attempts, settledAttempts + 1, 'pause cancels startup retries');
activeVideo = null; bridge.play(); bridge.pause();
clock += 750; activeVideo = fakeVideo(); delayed.timers[0]();
assert.equal(activeVideo.attempts, 0, 'dismissal before media creation must prevent playback');
bridge.play();
activeVideo.paused = false; activeVideo.emit('playing');
clock += 750; activeVideo = fakeVideo(); delayed.timers[0]();
assert.equal(activeVideo.attempts, 1, 'replacement media inherits startup even after a transient playing event');
const earlyState = delayed.messages.filter(m => m.type === 'playback').at(-1);
assert.equal(earlyState.playing, false, 'unready media must not be labeled playing');
clock += 31000; delayed.timers[0]();
assert.equal(activeVideo.attempts, 1, 'startup recovery has a deadline');
bridge.play(); activeVideo.paused = false;
documentEvents.click({ isTrusted: true, target: { closest: () => ({}) } });
activeVideo.paused = true;
const manuallyPausedAttempts = activeVideo.attempts;
clock += 750; delayed.timers[0]();
assert.equal(activeVideo.attempts, manuallyPausedAttempts, 'web pause controls cancel recovery during startup');
assert.equal(delayed.messages.filter(m => m.type === 'playbackIntent').at(-1).requested, false);
bridge.pause();
activeVideo = fakeVideo(); activeVideo.paused = false; activeVideo.readyState = 4;
clock += 750; delayed.timers[0]();
assert.equal(activeVideo.muted, false, 'a late YouTube mute is corrected');
bridge.setMuted(true); clock += 750; delayed.timers[0]();
assert.equal(activeVideo.muted, true, 'an explicit user mute survives playback polling');
bridge.setMuted(false); activeVideo.volume = 0; clock += 750; delayed.timers[0]();
assert.equal(activeVideo.muted, false);
assert.equal(activeVideo.volume, 1, 'unmute also restores an initially silent web volume');
if (process.argv[2]) {
  const html = fs.readFileSync(process.argv[2], 'utf8');
  const match = html.match(/var ytInitialData = (.*?);<\/script>/s);
  assert.ok(match, 'live YouTube response includes initial data');
  context.ytInitialData = JSON.parse(match[1]);
  context.location.href = 'https://m.youtube.com/results?search_query=veritasium';
  context.BetterYouTube.collect();
  assert.ok(messages.at(-1).cards.length >= 10);
  console.log('Live response parsed:', messages.at(-1).cards.length, 'videos');
}
console.log('Bridge tests passed: feed parsing, ad exclusion, delayed autoplay, transient-playing recovery, sustained progress, pause/dismiss cancellation, replacement media, bounded retries, web pause controls.');

// Settings can arrive before the media and survive replacement without resuming a paused video.
let optionVideo = null, selectedCaption = {}, optionPlayer = null;
const captionRaw = [
  { vssId: '.en', languageCode: 'en', name: { simpleText: 'English' } },
  { vssId: 'a.es', languageCode: 'es', kind: 'asr', name: { simpleText: 'Spanish' } }
];
const optionEnv = environment('player', {
  location: { hostname: 'm.youtube.com', href: 'https://m.youtube.com/watch?v=abcdefghijk', pathname: '/watch' },
  document: { title: 'Options', readyState: 'complete', querySelectorAll: () => [],
    querySelector: s => s === 'video' ? optionVideo : s === '#movie_player' ? optionPlayer : null,
    getElementById: () => true, addEventListener() {}, documentElement: {} }
});
const optionsBridge = optionEnv.context.BetterYouTube;
optionsBridge.setOptions({ rate: 1.5, captions: true, language: 'es' });
optionVideo = fakeVideo(); optionVideo.readyState = 4;
optionPlayer = { classList: { contains: () => false }, getOption: (_, key) => key === 'track' ? selectedCaption : [],
  loadModule() {}, unloadModule() { selectedCaption = {}; }, setOption(_, key, value) { selectedCaption = value; },
  getPlayerResponse: () => ({ videoDetails: { videoId: 'abcdefghijk' }, captions: { playerCaptionsTracklistRenderer: { captionTracks: captionRaw } } }) };
optionEnv.timers[0](); optionEnv.timers[0]();
assert.equal(optionVideo.playbackRate, 1.5);
assert.equal(optionVideo.paused, true, 'changing settings must not start paused media');
assert.equal(optionVideo.attempts, 0);
assert.equal(selectedCaption.languageCode, 'es', 'late player receives preferred language');
let optionState = optionEnv.messages.filter(m => m.type === 'playback').at(-1);
assert.equal(optionState.captionID, 'a.es');
assert.equal(optionState.captionTracks[1].name, 'Spanish (auto-generated)');
optionsBridge.setOptions({ rate: 2, captions: false }); optionEnv.timers[0]();
assert.equal(selectedCaption.languageCode, undefined, 'Off unloads captions');
assert.equal(optionVideo.playbackRate, 2);
optionsBridge.setOptions({ rate: -1, captions: false });
assert.equal(optionVideo.playbackRate, 2, 'invalid speed is ignored');
optionVideo = fakeVideo(); optionEnv.timers[0]();
assert.equal(optionVideo.playbackRate, 2, 'replacement media inherits playback speed');
console.log('Playback settings passed: delayed captions, language selection, captions off, rate validation, paused media, replacement media.');

// Deep links must wait for actual media metadata, survive replacement before readiness,
// and seek once without dragging later user scrubs back to the initial timestamp.
let linkedVideo = null, linkedAd = false;
const linkEnv = environment('player', {
  location: { hostname: 'm.youtube.com', pathname: '/watch', href: 'https://m.youtube.com/watch?v=abcdefghijk&by_request=test-request&by_start=90&by_end=100' },
  document: { title: 'Timestamp test', readyState: 'complete', querySelectorAll: () => [],
    querySelector: s => s === 'video' ? linkedVideo : s === '#movie_player' ? { classList: { contains: () => linkedAd } } : null,
    getElementById: () => true, addEventListener() {}, documentElement: {} }
});
linkEnv.context.BetterYouTube.setPlaybackRequested(true);
linkedVideo = fakeVideo(); linkEnv.timers[0]();
assert.equal(linkedVideo.currentTime, 0, 'no seek before metadata');
assert.equal(linkedVideo.attempts, 0, 'no autoplay before the requested seek');
linkedVideo = fakeVideo(); linkedVideo.readyState = 3; linkedAd = true;
linkEnv.timers[0]();
assert.equal(linkEnv.messages.filter(m => m.type === 'playback').at(-1).initialSeekPending, true, 'ad must not consume the timestamp');
linkedAd = false; linkedVideo.currentTime = 0;
linkEnv.timers[0](); linkEnv.timers[0]();
assert.equal(linkedVideo.currentTime, 90, 'late replacement media seeks to link time');
assert.equal(linkedVideo.attempts, 1, 'autoplay follows successful seek');
assert.equal(linkEnv.messages.filter(m => m.type === 'playback').at(-1).initialSeekPending, false);
assert.equal(linkEnv.messages[0].requestID, 'test-request', 'messages identify the selection, including repeated links to the same video');
linkEnv.context.BetterYouTube.seekTo(95); linkEnv.timers[0]();
assert.equal(linkedVideo.currentTime, 95, 'polling does not undo manual seeks');
linkedVideo.currentTime = 100; linkedVideo.paused = false; linkEnv.timers[0]();
assert.equal(linkedVideo.paused, true, 'end timestamp pauses playback');
assert.equal(linkEnv.messages.filter(m => m.type === 'playback').at(-1).linkEnded, true);
console.log('Deep-link bridge tests passed: delayed metadata, replacement media, ads, seek-before-autoplay, request isolation, manual seeking, end timestamp.');
