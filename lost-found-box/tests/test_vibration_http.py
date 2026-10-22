"""Admin vibration controls use the real detector with fake input edges only."""

import time
import unittest
import uuid

import test_admin
import test_vibration
import vibration


class VibrationHTTPTests(unittest.TestCase):
    request = test_admin.AdminHTTPTests.request
    stop_server = test_admin.AdminHTTPTests.stop_server
    get = test_admin.AdminHTTPTests.get
    post = test_admin.AdminHTTPTests.post
    login = test_admin.AdminHTTPTests.login
    tearDown = test_admin.AdminHTTPTests.tearDown

    def setUp(self):
        test_admin.AdminHTTPTests.setUp(self)
        self.disabled = self.server.vibration.snapshot()
        self.server.vibration.close()
        self.clock = test_vibration.FakeClock()
        self.gpio = test_vibration.FakeGPIO(self.clock)
        self.server.vibration = vibration.VibrationMonitor(
            self.server.connect_db, enabled=True, api=self.gpio,
            clock=self.clock, wall_clock=self.clock.wall)
        self.server.vibration.start()

    def burst(self, count=5):
        for _ in range(count):
            self.gpio.emit(1)
            self.clock.advance(.002)
            self.gpio.emit(0)
            self.clock.advance(.118)
        deadline = time.monotonic() + 2
        while self.server.vibration._queue.unfinished_tasks and time.monotonic() < deadline:
            time.sleep(.005)
        self.assertEqual(self.server.vibration._queue.unfinished_tasks, 0)

    def test_overview_and_clear_are_authenticated_and_never_open_a_lock(self):
        self.assertEqual(self.disabled['status'], 'disabled')
        self.assertEqual(self.disabled['gpio'], 21)
        self.burst()
        alert = self.server.vibration.snapshot()['active_alert']
        self.assertIsNotNone(alert)
        self.assertEqual(self.get('/api/admin/overview')[0], 401)
        self.assertEqual(self.post('/api/admin/vibration/clear', {'alert_id': alert['id']})[0], 401)
        self.login()
        overview = self.get('/api/admin/overview')[2]
        self.assertEqual(overview['vibration']['status'], 'alert')
        self.assertEqual(overview['vibration']['active_alert'], alert)
        self.assertTrue(overview['capabilities']['vibration_sensor'])
        self.assertEqual(overview['vibration']['total_triggers'], 5)
        self.assertEqual(self.post('/api/admin/vibration/clear', {})[0], 400)
        self.assertEqual(self.post('/api/admin/vibration/clear', {'alert_id': []})[0], 400)
        self.assertEqual(self.post('/api/admin/vibration/clear', {'alert_id': str(uuid.uuid4())})[0], 404)
        self.assertEqual(self.post('/api/admin/vibration/clear', {'alert_id': alert['id']},
                                   headers={'Origin': 'https://foreign.invalid'})[0], 403)
        status, _, result = self.post('/api/admin/vibration/clear', {'alert_id': alert['id']})
        self.assertEqual(status, 200)
        self.assertEqual(result['vibration']['status'], 'monitoring')
        self.assertIsNone(result['vibration']['active_alert'])
        self.assertIsNotNone(result['vibration']['events'][0]['cleared_at'])
        self.assertEqual(self.post('/api/admin/vibration/clear', {'alert_id': alert['id']})[0], 200)
        updated = self.get('/api/admin/overview')[2]
        self.assertEqual(updated['inventory'], overview['inventory'])
        self.assertEqual(updated['lockers'], overview['lockers'])
        self.assertEqual(self.driver.pulses, [])

    def test_late_clear_does_not_dismiss_new_alert(self):
        self.login()
        self.burst()
        first = self.server.vibration.snapshot()['active_alert']['id']
        self.assertEqual(self.post('/api/admin/vibration/clear', {'alert_id': first})[0], 200)
        self.clock.advance(.2)
        self.burst()
        second = self.server.vibration.snapshot()['active_alert']['id']
        self.assertNotEqual(first, second)
        self.assertEqual(self.post('/api/admin/vibration/clear', {'alert_id': first})[0], 409)
        self.assertEqual(self.get('/api/admin/overview')[2]['vibration']['active_alert']['id'], second)
        self.assertEqual(self.driver.pulses, [])

    def test_lock_pulse_filters_mechanical_impact_then_monitoring_resumes(self):
        self.login()
        self.burst(4)
        status, _, result = self.post('/api/admin/manual-open', {
            'request_id': str(uuid.uuid4()), 'compartment_id': '03'})
        self.assertEqual(status, 201)
        self.assertEqual(result['operation']['state'], 'completed')
        self.assertTrue(self.server.vibration.snapshot()['suppressed'])
        self.assertEqual(self.server.vibration.snapshot()['recent_triggers'], 0)
        self.burst()
        self.assertEqual(self.server.vibration.snapshot()['total_triggers'], 4)
        self.assertIsNone(self.server.vibration.snapshot()['active_alert'])
        self.clock.advance(3)
        self.burst()
        self.assertEqual(self.server.vibration.snapshot()['status'], 'alert')
        self.assertEqual(self.driver.pulses, ['03'])


if __name__ == '__main__':
    unittest.main()
