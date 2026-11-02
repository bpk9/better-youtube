import asyncio
import importlib.util
import os
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

os.environ['BETTER_TOKEN'] = 'test-token-with-at-least-thirty-two-characters'
temporary = tempfile.TemporaryDirectory()
os.environ['BETTER_DATA'] = temporary.name
spec = importlib.util.spec_from_file_location('companion', Path(__file__).with_name('app.py'))
app = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app)
from fastapi.testclient import TestClient

class CompanionTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        app.initialize()
        with app.db() as c:
            for table in ['jobs','channels','seen']:
                c.execute('DELETE FROM ' + table)
        for path in app.MEDIA.iterdir():
            path.unlink()
        self.client = TestClient(app.app)
        self.headers = {'Authorization': 'Bearer ' + app.TOKEN}
        self.video = app.VideoInput(id='abcdefghijk', title='Test clip', channel='Test channel', channelID='UC' + 'x' * 22)

    def test_auth_and_idempotent_queue(self):
        self.assertEqual(self.client.get('/v1/jobs').status_code, 401)
        for _ in range(2):
            self.assertEqual(self.client.post('/v1/jobs', headers=self.headers, json=self.video.model_dump()).status_code, 200)
        rows = self.client.get('/v1/jobs', headers=self.headers).json()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['state'], 'queued')

    def test_full_queue_still_accepts_existing_job(self):
        app.enqueue(self.video)
        for number in range(99):
            app.enqueue(app.VideoInput(id=f'{number:011d}', title='Queued'))
        self.assertEqual(self.client.post('/v1/jobs', headers=self.headers,
            json=self.video.model_dump()).status_code, 200)
        self.assertEqual(self.client.post('/v1/jobs', headers=self.headers,
            json={'id': 'newvideo123', 'title': 'New'}).status_code, 429)

    def test_input_validation_and_ssrf(self):
        self.assertEqual(self.client.post('/v1/jobs', headers=self.headers, json={'id': '../secret', 'title': 'bad'}).status_code, 422)
        for url in ['http://127.0.0.1', 'https://www.youtube.com.evil.test/@x', 'https://www.youtube.com/redirect?q=http://127.0.0.1']:
            self.assertEqual(self.client.post('/v1/resolve-channel', headers=self.headers, json={'url': url}).status_code, 400)

    async def test_channel_baseline_and_new_upload_exactly_once(self):
        cid = self.video.channelID
        with app.db() as c:
            c.execute('INSERT INTO channels(id,title,enabled,added) VALUES(?,?,1,?)', (cid, 'Channel', time.time()))
            row = dict(c.execute('SELECT * FROM channels WHERE id=?', (cid,)).fetchone())
        with patch.object(app, 'channel_entries', AsyncMock(return_value=('Channel', [self.video]))):
            await app.check_channel(row)
        with app.db() as c:
            self.assertEqual(c.execute('SELECT count(*) FROM jobs').fetchone()[0], 0)
            row = dict(c.execute('SELECT * FROM channels WHERE id=?', (cid,)).fetchone())
        new = app.VideoInput(id='zyxwvutsrqp', title='New', channelID=cid)
        with patch.object(app, 'channel_entries', AsyncMock(return_value=('Channel', [new,self.video]))):
            await app.check_channel(row)
            await app.check_channel(row)
        with app.db() as c:
            jobs = c.execute('SELECT * FROM jobs').fetchall()
        self.assertEqual(len(jobs), 1)
        self.assertEqual(jobs[0]['id'], new.id)
        self.assertEqual(jobs[0]['automatic'], 1)

    def test_media_range_and_cache_expiration(self):
        app.enqueue(self.video)
        path = app.MEDIA / (self.video.id + '.mp4')
        path.write_bytes(b'fake-video-bytes' * 200)
        with app.db() as c:
            c.execute("UPDATE jobs SET state='ready',bytes=? WHERE id=?", (path.stat().st_size, self.video.id))
        response = self.client.get('/v1/media/' + self.video.id, headers={**self.headers,'Range':'bytes=0-9'})
        self.assertEqual(response.status_code, 206)
        self.assertEqual(len(response.content), 10)
        with app.db() as c:
            c.execute('UPDATE jobs SET updated=?', (time.time() - app.TTL - 1,))
        app.prune()
        self.assertFalse(path.exists())
        self.assertEqual(self.client.get('/v1/media/' + self.video.id, headers=self.headers).status_code, 404)

    def test_restart_requeues_incomplete_job(self):
        app.enqueue(self.video)
        with app.db() as c:
            c.execute("UPDATE jobs SET state='preparing'")
        app.initialize()
        with app.db() as c:
            self.assertEqual(c.execute('SELECT state FROM jobs').fetchone()[0], 'queued')

if __name__ == '__main__':
    unittest.main()
