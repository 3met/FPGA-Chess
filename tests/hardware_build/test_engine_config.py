import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools.hardware_build.common import BuildError
from tools.hardware_build.engine_config import engine_rtl_parameter_values, load_engine_config


class EngineConfigTests(unittest.TestCase):
    def load_temporary_config(self, search_updates=None, engine_updates=None):
        """Load a temporary profile derived from the checked-in defaults."""
        root = Path(self.temp_dir.name)
        search = json.loads(Path("hardware/config/search/default.json").read_text(encoding="utf-8"))
        engine = json.loads(Path("hardware/config/engine/de1-soc.json").read_text(encoding="utf-8"))
        for section, updates in (search_updates or {}).items():
            search[section].update(updates)
        for section, updates in (engine_updates or {}).items():
            engine[section].update(updates)
        search_path = root / "search.json"
        engine_path = root / "engine.json"
        search_path.write_text(json.dumps(search), encoding="utf-8")
        engine["search_config"] = str(search_path)
        engine_path.write_text(json.dumps(engine), encoding="utf-8")
        with mock.patch("tools.hardware_build.engine_config.repo_path", side_effect=lambda value: Path(value).resolve()), \
                mock.patch("tools.hardware_build.engine_config.rel", side_effect=lambda value: str(value)):
            return load_engine_config(str(engine_path))

    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.temp_dir.cleanup()

    def test_checked_in_profile_resolves_and_quantizes_search_policy(self):
        engine = json.loads(Path("hardware/config/engine/de1-soc.json").read_text(encoding="utf-8"))
        search = json.loads(Path(engine["search_config"]).read_text(encoding="utf-8"))
        config = load_engine_config("hardware/config/engine/de1-soc.json")
        self.assertEqual(config["threads"], engine["engine"]["threads"])
        self.assertEqual(config["stack_depth"], engine["engine"]["stack_depth"])
        self.assertEqual(config["clock_frequency_hz"], engine["engine"]["clock_frequency_hz"])
        self.assertEqual(config["search"]["aspiration_delta_multiplier_q3"], round(search["aspiration"]["delta_multiplier"] * 8))
        self.assertEqual(config["search"]["lmr_a_q8"], round(search["lmr"]["base"] * 256))
        self.assertEqual(config["search"]["lmr_b_q8"], round(search["lmr"]["divisor"] * 256))
        self.assertEqual(config["search"]["rfp_base_margin"], search["rfp"]["base_margin"])
        self.assertEqual(config["search"]["rfp_margin_per_depth"], search["rfp"]["margin_per_depth"])
        self.assertEqual(config["search"]["rfp_maximum_depth"], search["rfp"]["maximum_depth"])
        self.assertEqual(config["search"]["futility_base_margin"], search["futility"]["base_margin"])
        self.assertEqual(config["search"]["futility_margin_per_depth"], search["futility"]["margin_per_depth"])
        self.assertEqual(config["search"]["futility_maximum_depth"], search["futility"]["maximum_depth"])
        self.assertEqual(
            config["search"]["qdelta_margin"],
            search["qsearch_delta_pruning"]["margin"],
        )
        rtl_parameters = engine_rtl_parameter_values(config)
        self.assertEqual(rtl_parameters["RFP_BASE_MARGIN"], search["rfp"]["base_margin"])
        self.assertEqual(rtl_parameters["RFP_MARGIN_PER_DEPTH"], search["rfp"]["margin_per_depth"])
        self.assertEqual(rtl_parameters["RFP_MAXIMUM_DEPTH"], search["rfp"]["maximum_depth"])
        self.assertEqual(rtl_parameters["FUTILITY_BASE_MARGIN"], search["futility"]["base_margin"])
        self.assertEqual(rtl_parameters["FUTILITY_MARGIN_PER_DEPTH"], search["futility"]["margin_per_depth"])
        self.assertEqual(rtl_parameters["FUTILITY_MAXIMUM_DEPTH"], search["futility"]["maximum_depth"])
        self.assertEqual(
            rtl_parameters["QDELTA_MARGIN"],
            search["qsearch_delta_pruning"]["margin"],
        )
        self.assertEqual(len(config["digest"]), 64)

    def test_structural_values_have_no_policy_ceiling(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            search_path = root / "search.json"
            engine_path = root / "engine.json"
            default_search = Path("hardware/config/search/default.json").read_text(encoding="utf-8")
            search_path.write_text(default_search, encoding="utf-8")
            engine_path.write_text(
                json.dumps({
                    "search_config": str(search_path),
                    "engine": {"threads": 17, "stack_depth": 65, "clock_frequency_hz": 1},
                    "transposition_table": {"tag_bits": 32, "cache_index_bits": 10},
                    "instrumentation": {"search_statistics": False},
                }),
                encoding="utf-8",
            )
            with mock.patch("tools.hardware_build.engine_config.repo_path", side_effect=lambda value: Path(value).resolve()), \
                    mock.patch("tools.hardware_build.engine_config.rel", side_effect=lambda value: str(value)):
                config = load_engine_config(str(engine_path))
            self.assertEqual(config["threads"], 17)
            self.assertEqual(config["stack_depth"], 65)

    def test_zero_thread_count_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            engine_path = root / "engine.json"
            engine_path.write_text(
                json.dumps({
                    "search_config": "hardware/config/search/default.json",
                    "engine": {"threads": 0, "stack_depth": 1, "clock_frequency_hz": 1},
                    "transposition_table": {"tag_bits": 32, "cache_index_bits": 10},
                    "instrumentation": {"search_statistics": False},
                }),
                encoding="utf-8",
            )
            with mock.patch("tools.hardware_build.engine_config.repo_path", side_effect=lambda value: engine_path if value == str(engine_path) else Path(value).resolve()), \
                    mock.patch("tools.hardware_build.engine_config.rel", side_effect=lambda value: str(value)):
                with self.assertRaisesRegex(BuildError, "threads must be an integer of at least 1"):
                    load_engine_config(str(engine_path))

    def test_history_reward_must_fit_rtl_arithmetic(self):
        with self.assertRaisesRegex(BuildError, "between 1 and 127"):
            self.load_temporary_config({"history": {"maximum_reward": 128}})

    def test_aspiration_multiplier_must_grow_the_delta(self):
        with self.assertRaisesRegex(BuildError, "must be greater than one"):
            self.load_temporary_config({"aspiration": {"delta_multiplier": 1.0}})

    def test_null_move_deep_threshold_must_follow_minimum(self):
        with self.assertRaisesRegex(BuildError, "must not precede minimum_depth"):
            self.load_temporary_config({"null_move": {"minimum_depth": 7, "deep_depth_threshold": 6}})

    def test_null_move_reductions_must_leave_child_depth(self):
        with self.assertRaisesRegex(BuildError, "smaller than their depth thresholds"):
            self.load_temporary_config({"null_move": {"shallow_reduction": 3}})

    def test_rfp_margins_must_fit_the_evaluation_range(self):
        with self.assertRaisesRegex(BuildError, "between 0 and 32767"):
            self.load_temporary_config({"rfp": {"margin_per_depth": 32768}})

    def test_rfp_maximum_depth_must_be_positive(self):
        with self.assertRaisesRegex(BuildError, "at least 1"):
            self.load_temporary_config({"rfp": {"maximum_depth": 0}})

    def test_qdelta_margin_must_fit_the_evaluation_range(self):
        with self.assertRaisesRegex(BuildError, "between 0 and 32767"):
            self.load_temporary_config({"qsearch_delta_pruning": {"margin": 32768}})

    def test_futility_margins_must_fit_the_evaluation_range(self):
        with self.assertRaisesRegex(BuildError, "between 0 and 32767"):
            self.load_temporary_config({"futility": {"base_margin": 32768}})

    def test_futility_maximum_depth_must_be_positive(self):
        with self.assertRaisesRegex(BuildError, "at least 1"):
            self.load_temporary_config({"futility": {"maximum_depth": 0}})

    def test_rfp_maximum_depth_must_fit_the_engine_stack(self):
        with self.assertRaisesRegex(BuildError, "must not exceed the engine stack depth"):
            self.load_temporary_config(
                {"rfp": {"maximum_depth": 5}},
                {"engine": {"stack_depth": 4}},
            )

    def test_futility_maximum_depth_must_fit_the_engine_stack(self):
        with self.assertRaisesRegex(BuildError, "must be smaller than the engine stack depth"):
            self.load_temporary_config(
                {"rfp": {"maximum_depth": 4}, "futility": {"maximum_depth": 4}},
                {"engine": {"stack_depth": 4}},
            )

    def test_tt_tag_must_leave_index_entropy(self):
        with self.assertRaisesRegex(BuildError, "between 1 and 63"):
            self.load_temporary_config(engine_updates={"transposition_table": {"tag_bits": 64}})

    def test_tt_cache_index_bits_must_be_positive(self):
        with self.assertRaisesRegex(BuildError, "at least 1"):
            self.load_temporary_config(engine_updates={"transposition_table": {"cache_index_bits": 0}})


if __name__ == "__main__":
    unittest.main()
