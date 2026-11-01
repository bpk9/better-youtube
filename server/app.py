"""Single-user download companion. One worker, bounded storage, no transcoding."""
import asyncio
import contextlib
import hmac
import json
import os
import re
import shutil
import sqlite3
import sys
import time
import xml.etree.ElementTree as ET
from contextlib import asynccontextmanager
from pathlib import Path
from urllib.parse import urlparse

import httpx
from fastapi import Depends, FastAPI, Header, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field

ROOT = Path(os.getenv('BETTER_DATA', str(Path(__file__).parent / 'state')))
ROOT.mkdir(parents=True, exist_ok=True)
MEDIA = ROOT / 'media'
MEDIA.mkdir(exist_ok=True)
TOKEN = os.environ.get('BETTER_TOKEN', '')
MAX_CACHE = int(os.getenv('BETTER_CACHE_BYTES', str(5 * 1024**3)))
MAX_FILE = 500 * 1024**2
POLL = max(900, int(os.getenv('BETTER_POLL_SECONDS', '1800')))
TTL = 7 * 86400
VIDEO = re.compile(r'^[A-Za-z0-9_-]{11}$')
CHANNEL = re.compile(r'^UC[A-Za-z0-9_-]{22}$')

def db():
    connection = sqlite3.connect(ROOT / 'library.sqlite', timeout=20)
    connection.row_factory = sqlite3.Row
    return connection

def initialize():
    with db() as c:
        c.execute('PRAGMA journal_mode=WAL')
        c.executescript('''
          CREATE TABLE IF NOT EXISTS jobs (
            id TEXT PRIMARY KEY, title TEXT NOT NULL, channel TEXT NOT NULL DEFAULT '',
            channelID TEXT NOT NULL DEFAULT '', state TEXT NOT NULL DEFAULT 'queued',
            created REAL NOT NULL, updated REAL NOT NULL, error TEXT, bytes INTEGER DEFAULT 0,
            attempts INTEGER DEFAULT 0, retryAt REAL DEFAULT 0, automatic INTEGER DEFAULT 0);
          CREATE TABLE IF NOT EXISTS channels (
            id TEXT PRIMARY KEY, title TEXT NOT NULL, enabled INTEGER DEFAULT 0,
            added REAL NOT NULL, checked REAL DEFAULT 0, error TEXT);
          CREATE TABLE IF NOT EXISTS seen (channelID TEXT, videoID TEXT, PRIMARY KEY(channelID,videoID));
        ''')
        c.execute("UPDATE jobs SET state='queued' WHERE state='preparing'")

def row_job(row):
    d = dict(row)
    d['video'] = {k: d[k] for k in ('id', 'title', 'channel', 'channelID')}
    d['automatic'] = bool(d['automatic'])
    return d

def enqueue(video, automatic=False):
    with db() as c:
        if c.execute("SELECT count(*) FROM jobs WHERE state IN ('queued','preparing')").fetchone()[0] >= 100:
            raise HTTPException(429, 'The queue is full. Let existing downloads finish first.')
        old = c.execute('SELECT * FROM jobs WHERE id=?', (video.id,)).fetchone()
        if old and old['state'] in ('queued', 'preparing', 'ready'):
            return row_job(old)
        now = time.time()
        c.execute('''INSERT INTO jobs(id,title,channel,channelID,created,updated,automatic)
          VALUES(?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET state='queued',error=NULL,
          updated=excluded.updated,attempts=0,retryAt=0''',
          (video.id, video.title, video.channel, video.channelID or '', now, now, int(automatic)))
        return row_job(c.execute('SELECT * FROM jobs WHERE id=?', (video.id,)).fetchone())

def prune():
    with db() as c:
        rows = c.execute("SELECT * FROM jobs WHERE state='ready' ORDER BY updated ASC").fetchall()
        total = sum(r['bytes'] for r in rows)
        for r in rows:
            path = MEDIA / (r['id'] + '.mp4')
            if time.time() - r['updated'] > TTL or total + MAX_FILE > MAX_CACHE or not path.exists():
                path.unlink(missing_ok=True)
                total -= r['bytes']
                c.execute("UPDATE jobs SET state='expired',bytes=0 WHERE id=?", (r['id'],))
    for p in MEDIA.iterdir():
        if p.is_file() and '.part' in p.name and time.time() - p.stat().st_mtime > 86400:
            p.unlink(missing_ok=True)

async def run_download(job):
    prune()
    if shutil.disk_usage(ROOT).free < MAX_FILE + 1024**3:
        raise RuntimeError('Server storage is low. Free space before retrying.')
    command = [sys.executable, '-m', 'yt_dlp', '--ignore-config', '--no-playlist',
        '--no-progress', '--no-warnings', '--socket-timeout', '20', '--retries', '2',
        '--fragment-retries', '2', '--concurrent-fragments', '1', '--limit-rate', '4M',
        '--max-filesize', str(MAX_FILE), '--match-filter', 'duration <= 7200 & !is_live',
        '-f', 'b[ext=mp4][height<=720]/b[ext=mp4]', '--no-mtime',
        '-o', str(MEDIA / (job['id'] + '.%(ext)s'))]
    node = os.environ.get('BETTER_NODE') or shutil.which('node')
    if node:
        command += ['--js-runtimes', 'node:' + node]
    command += ['https://www.youtube.com/watch?v=' + job['id']]
    process = await asyncio.create_subprocess_exec(*command, stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE, env={**os.environ, 'NODE_OPTIONS': '--max-old-space-size=192'})
    try:
        os.setpriority(os.PRIO_PROCESS, process.pid, 10)
    except (AttributeError, PermissionError, ProcessLookupError):
        pass
    try:
        _, error = await asyncio.wait_for(process.communicate(), timeout=1800)
    except (asyncio.TimeoutError, asyncio.CancelledError):
        process.kill()
        await process.wait()
        raise
    path = MEDIA / (job['id'] + '.mp4')
    if process.returncode or not path.is_file() or path.stat().st_size < 1024:
        # Store a useful bounded error, excluding signed media URLs and cookie material.
        detail = error.decode(errors='replace')[-700:]
        detail = re.sub(r'https?://\S+', '[URL]', detail)
        raise RuntimeError(detail or 'No compatible MP4 was available within the download limits.')
    size = path.stat().st_size
    if size > MAX_FILE:
        path.unlink()
        raise RuntimeError('This video exceeds the 500 MB per-video limit.')
    with db() as c:
        c.execute("UPDATE jobs SET state='ready',bytes=?,updated=?,error=NULL WHERE id=?", (size, time.time(), job['id']))

async def worker():
    while True:
        with db() as c:
            job = c.execute("SELECT * FROM jobs WHERE state='queued' AND retryAt<=? ORDER BY automatic,created LIMIT 1", (time.time(),)).fetchone()
            if job:
                c.execute("UPDATE jobs SET state='preparing',attempts=attempts+1,updated=? WHERE id=?", (time.time(), job['id']))
        if not job:
            await asyncio.sleep(3)
            continue
        try:
            await run_download(job)
        except asyncio.CancelledError:
            raise
        except Exception as error:
            attempts = job['attempts'] + 1
            with db() as c:
                c.execute('UPDATE jobs SET state=?,error=?,updated=?,retryAt=? WHERE id=?',
                    ('failed' if attempts >= 3 else 'queued', str(error)[:700], time.time(), time.time() + min(3600, 120 * 2**attempts), job['id']))

async def channel_entries(channel_id):
    async with httpx.AsyncClient(timeout=20, follow_redirects=True) as client:
        response = await client.get('https://www.youtube.com/feeds/videos.xml', params={'channel_id': channel_id})
        response.raise_for_status()
    if len(response.content) > 2_000_000:
        raise ValueError('Unexpected channel feed size')
    root = ET.fromstring(response.content)
    ns = {'a': 'http://www.w3.org/2005/Atom', 'yt': 'http://www.youtube.com/xml/schemas/2015'}
    title = root.findtext('a:title', '', ns)
    entries = []
    for entry in root.findall('a:entry', ns):
        video_id = entry.findtext('yt:videoId', '', ns)
        if VIDEO.fullmatch(video_id):
            entries.append(VideoInput(id=video_id, title=entry.findtext('a:title', '', ns), channel=title, channelID=channel_id))
    return title, entries

async def check_channel(row):
    try:
        _, entries = await channel_entries(row['id'])
        # First poll establishes the baseline. It never downloads the channel backlog.
        for entry in reversed(entries):
            with db() as c:
                known = c.execute('SELECT 1 FROM seen WHERE channelID=? AND videoID=?', (row['id'], entry.id)).fetchone()
            if not known and row['checked'] and row['enabled']:
                with db() as c:
                    enabled = c.execute('SELECT enabled FROM channels WHERE id=?', (row['id'],)).fetchone()
                if enabled and enabled['enabled']:
                    enqueue(entry, automatic=True)
            with db() as c:
                c.execute('INSERT OR IGNORE INTO seen VALUES(?,?)', (row['id'], entry.id))
        with db() as c:
            c.execute('UPDATE channels SET checked=?,error=NULL WHERE id=?', (time.time(), row['id']))
    except Exception as error:
        with db() as c:
            c.execute('UPDATE channels SET error=? WHERE id=?', (str(error)[:300], row['id']))

async def monitor():
    while True:
        with db() as c:
            rows = c.execute('SELECT * FROM channels WHERE enabled=1').fetchall()
        for row in rows:
            await check_channel(row)
            await asyncio.sleep(1)
        prune()
        await asyncio.sleep(POLL)

@asynccontextmanager
async def lifespan(app):
    if len(TOKEN) < 32:
        raise RuntimeError('Set BETTER_TOKEN to a random secret of at least 32 characters.')
    initialize()
    tasks = [asyncio.create_task(worker()), asyncio.create_task(monitor())]
    yield
    for task in tasks:
        task.cancel()
    await asyncio.gather(*tasks, return_exceptions=True)

app = FastAPI(title='Better YouTube Companion', docs_url=None, redoc_url=None, lifespan=lifespan)

async def authorized(authorization: str = Header(default='')):
    if not TOKEN or not hmac.compare_digest(authorization, 'Bearer ' + TOKEN):
        raise HTTPException(401, 'Pair this iPhone with the companion server.')

class VideoInput(BaseModel):
    id: str = Field(pattern=r'^[A-Za-z0-9_-]{11}$')
    title: str = Field(min_length=1, max_length=500)
    channel: str = Field(default='', max_length=200)
    channelID: str | None = Field(default=None, pattern=r'^UC[A-Za-z0-9_-]{22}$')

class ChannelInput(BaseModel):
    id: str = Field(pattern=r'^UC[A-Za-z0-9_-]{22}$')
    title: str = Field(min_length=1, max_length=200)
    enabled: bool = False

class ResolveInput(BaseModel):
    url: str = Field(min_length=1, max_length=300)

@app.get('/health')
def health():
    return {'status': 'ok', 'version': '0.2'}

@app.get('/v1/status', dependencies=[Depends(authorized)])
def status():
    with db() as c:
        used = c.execute("SELECT coalesce(sum(bytes),0) FROM jobs WHERE state='ready'").fetchone()[0]
    return {'cacheBytes': used, 'cacheLimit': MAX_CACHE, 'pollMinutes': POLL // 60, 'maxConcurrent': 1, 'maxVideoBytes': MAX_FILE}

@app.get('/v1/jobs', dependencies=[Depends(authorized)])
def jobs():
    with db() as c:
        return [row_job(r) for r in c.execute('SELECT * FROM jobs ORDER BY created DESC LIMIT 300')]

@app.post('/v1/jobs', dependencies=[Depends(authorized)])
def create_job(video: VideoInput):
    return enqueue(video)

@app.get('/v1/media/{video_id}', dependencies=[Depends(authorized)])
def media(video_id: str):
    if not VIDEO.fullmatch(video_id):
        raise HTTPException(400, 'Invalid video ID')
    with db() as c:
        row = c.execute("SELECT * FROM jobs WHERE id=? AND state='ready'", (video_id,)).fetchone()
    path = MEDIA / (video_id + '.mp4')
    if not row or not path.is_file():
        raise HTTPException(404, 'This file is no longer cached. Request the download again.')
    return FileResponse(path, media_type='video/mp4', filename=video_id + '.mp4')

@app.get('/v1/channels', dependencies=[Depends(authorized)])
def channels():
    with db() as c:
        return [{**dict(r), 'enabled': bool(r['enabled'])} for r in c.execute('SELECT * FROM channels ORDER BY title')]

@app.put('/v1/channels/{channel_id}', dependencies=[Depends(authorized)])
async def put_channel(channel_id: str, channel: ChannelInput):
    if channel_id != channel.id:
        raise HTTPException(400, 'Channel ID mismatch')
    with db() as c:
        count = c.execute('SELECT count(*) FROM channels').fetchone()[0]
        old = c.execute('SELECT * FROM channels WHERE id=?', (channel.id,)).fetchone()
        if count >= 100 and not old:
            raise HTTPException(429, 'The lightweight companion supports up to 100 channels.')
        # Re-enabling begins a fresh baseline, rather than grabbing an old backlog.
        checked = old['checked'] if old and old['enabled'] else 0
        c.execute('''INSERT INTO channels(id,title,enabled,added) VALUES(?,?,?,?)
          ON CONFLICT(id) DO UPDATE SET title=excluded.title,enabled=excluded.enabled,checked=?''',
          (channel.id, channel.title, int(channel.enabled), time.time(), checked))
        row = dict(c.execute('SELECT * FROM channels WHERE id=?', (channel.id,)).fetchone())
    if channel.enabled:
        await check_channel(row)
    return {'ok': True}

@app.post('/v1/resolve-channel', dependencies=[Depends(authorized)])
async def resolve_channel(value: ResolveInput):
    raw = value.url.strip()
    if CHANNEL.fullmatch(raw):
        channel_id = raw
    else:
        if raw.startswith('@'):
            raw = 'https://www.youtube.com/' + raw
        parsed = urlparse(raw)
        if parsed.scheme != 'https' or parsed.hostname not in ('youtube.com', 'www.youtube.com', 'm.youtube.com') or not re.fullmatch(r'/(?:@[\w.-]+|channel/UC[\w-]{22}|c/[\w.-]+|user/[\w.-]+)/?', parsed.path):
            raise HTTPException(400, 'Use a YouTube channel URL, @handle, or channel ID.')
        async with httpx.AsyncClient(timeout=20) as client:
            response = await client.get('https://www.youtube.com' + parsed.path)
            response.raise_for_status()
        match = re.search(r'"(?:externalId|channelId)"\s*:\s*"(UC[A-Za-z0-9_-]{22})"', response.text)
        if not match:
            raise HTTPException(422, 'Could not identify that channel. Try its /channel/UC… link.')
        channel_id = match[1]
    title, _ = await channel_entries(channel_id)
    return {'id': channel_id, 'title': title, 'enabled': False}

@app.get('/v1/feed', dependencies=[Depends(authorized)])
async def feed():
    with db() as c:
        rows = c.execute('SELECT * FROM channels ORDER BY title LIMIT 40').fetchall()
    result = []
    for row in rows:
        try:
            _, entries = await channel_entries(row['id'])
            result.extend(e.model_dump() for e in entries[:3])
        except Exception:
            pass
    return result
