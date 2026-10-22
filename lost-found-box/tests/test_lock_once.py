"""Safety behavior checks using a fake GPIO interface; no physical outputs."""

import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location(
    "lock_once", Path(__file__).resolve().parents[1] / "tools/test_lock_once.py")
lock_once = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lock_once)


class GPIOError(Exception):
    def __init__(self, value):
        self.value = value
        super().__init__(value)


class LockOnceTests(unittest.TestCase):
    def test_default_command_only_inspects(self):
        api = self.api()
        api.gpiochip_open.return_value = 1
        with patch.dict("sys.modules", {"lgpio": api}), \
                patch.object(lock_once.signal, "signal"), patch("builtins.print"):
            lock_once.main([])
        api.gpio_claim_output.assert_not_called()
        api.tx_pulse.assert_not_called()
        api.gpiochip_close.assert_called_once_with(1)

    def test_fire_command_pulses_once_then_blocks_immediate_repeat(self):
        api = self.api()
        api.gpiochip_open.return_value = 1
        api.tx_busy.side_effect = [1, 1, 0]
        api.gpio_read.side_effect = [1, 0, 0]
        with tempfile.TemporaryDirectory() as folder, \
                patch.object(lock_once, "__file__", str(Path(folder) / "tools/test_lock_once.py")), \
                patch.dict("sys.modules", {"lgpio": api}), \
                patch.object(lock_once.signal, "signal"), \
                patch.object(lock_once.time, "sleep"), patch("builtins.print"):
            lock_once.main(["--fire"])
            with self.assertRaisesRegex(RuntimeError, "Cooling down"):
                lock_once.main(["--fire"])
        api.gpio_claim_output.assert_called_once_with(1, 17, 0, api.SET_PULL_DOWN)
        self.assertEqual(api.tx_pulse.call_args_list[0].args, (1, 17, 500000, 50000, 0, 1))
        self.assertEqual(api.tx_pulse.call_count, 2)  # Start once, then stop.
        api.gpio_write.assert_called_with(1, 17, 0)

    def api(self):
        api = Mock(SET_PULL_DOWN=64, TX_PWM=0, BAD_PWM_MICROS=-86, error=GPIOError)
        api.error_text.return_value = "bad PWM micros"
        api.gpio_get_chip_info.return_value = [0, 58, "gpiochip0", "pinctrl-bcm2711"]
        api.gpio_get_line_info.return_value = [0, 17, 0, "GPIO17", ""]
        return api

    def test_inspection_never_claims_or_drives_line(self):
        api = self.api()
        self.assertEqual(lock_once.inspect_line(api, 1)["physical_pin"], 11)
        api.gpio_claim_output.assert_not_called()
        api.tx_pulse.assert_not_called()

    def test_wrong_chip_and_busy_line_are_rejected(self):
        for chip, consumer in [("other-chip", ""), ("pinctrl-bcm2711", "other-app")]:
            api = self.api()
            api.gpio_get_chip_info.return_value[3] = chip
            api.gpio_get_line_info.return_value[4] = consumer
            with self.assertRaises(RuntimeError):
                lock_once.inspect_line(api, 1)

    def test_only_one_finite_pulse_finishes_low(self):
        api = self.api()
        api.tx_busy.side_effect = [1, 1, 0]
        api.gpio_read.side_effect = [1, 0, 0]
        with patch.object(lock_once.time, "sleep"):
            result = lock_once.pulse_once(api, 1)
        self.assertEqual(api.tx_pulse.call_args_list[0].args, (1, 17, 500000, 50000, 0, 1))
        self.assertEqual(result["final_level"], 0)
        self.assertFalse(result["door_open_verified"])
        api.gpio_write.assert_called_with(1, 17, 0)
        api.gpio_free.assert_called_once_with(1, 17)

    def test_finished_pulse_cleanup_does_not_mask_success(self):
        api = self.api()
        api.tx_busy.side_effect = [1, 1, 0]
        api.gpio_read.side_effect = [1, 0, 0]
        api.tx_pulse.side_effect = [3, GPIOError("bad PWM micros")]
        with patch.object(lock_once.time, "sleep"):
            result = lock_once.pulse_once(api, 1)
        self.assertEqual(result["final_level"], 0)
        api.gpio_write.assert_called_with(1, 17, 0)
        api.gpio_free.assert_called_once_with(1, 17)

    def test_unexpected_stop_error_still_drives_low_and_is_reported(self):
        api = self.api()
        api.tx_busy.side_effect = [1, 1, 0]
        api.gpio_read.side_effect = [1, 0, 0]
        api.tx_pulse.side_effect = [3, GPIOError("unexpected error")]
        with patch.object(lock_once.time, "sleep"):
            with self.assertRaisesRegex(GPIOError, "unexpected error"):
                lock_once.pulse_once(api, 1)
        api.gpio_write.assert_called_with(1, 17, 0)
        api.gpio_free.assert_called_once_with(1, 17)

    def test_read_failure_stops_pulse_and_drives_low(self):
        api = self.api()
        api.tx_busy.return_value = 1
        api.gpio_read.side_effect = RuntimeError("read failed")
        with self.assertRaises(RuntimeError):
            lock_once.pulse_once(api, 1)
        api.tx_pulse.assert_called_with(1, 17, 0, 0, 0, 1)
        api.gpio_write.assert_called_with(1, 17, 0)
        api.gpio_free.assert_called_once_with(1, 17)

    def test_timeout_stops_without_retriggering(self):
        api = self.api()
        api.tx_busy.return_value = 1
        with patch.object(lock_once.time, "monotonic", side_effect=[0, 1.6]):
            with self.assertRaises(TimeoutError):
                lock_once.pulse_once(api, 1)
        self.assertEqual(api.tx_pulse.call_count, 2)  # Start once, then cancel.
        api.gpio_write.assert_called_with(1, 17, 0)

    def test_failed_claim_does_not_touch_someone_elses_line(self):
        api = self.api()
        api.gpio_claim_output.side_effect = RuntimeError("busy")
        with self.assertRaises(RuntimeError):
            lock_once.pulse_once(api, 1)
        api.tx_pulse.assert_not_called()
        api.gpio_write.assert_not_called()
        api.gpio_free.assert_not_called()


if __name__ == "__main__":
    unittest.main()
