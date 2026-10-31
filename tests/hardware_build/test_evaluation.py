"""Packed model validation, ROM layout, and independent build selection."""

import copy
import json
import tempfile
import unittest
from pathlib import Path

from tools.evaluation_model import (
    BASELINE_PATH, decode_model, load_model, pack_values, rom_images,
    tensor, unpack_values,
)
from tools.hardware_build.common import BuildError
from tools.hardware_build.rtl_config import evaluation_config, write_rtl_config


class EvaluationModelTests(unittest.TestCase):
    def test_packing_crosses_byte_boundaries_and_preserves_signed_extrema(self):
        """Non-byte widths share one bitstream without per-value padding."""
        for bits, signed in ((2, True), (4, True), (6, True), (6, False), (10, True)):
            lower = -(1 << (bits - 1)) if signed else 0
            upper = (1 << (bits - int(signed))) - 1
            values = [lower, upper, 0, 1, lower, upper, 1]
            with self.subTest(bits=bits, signed=signed):
                packed = pack_values(values, bits, signed)
                self.assertEqual(unpack_values(packed, bits, len(values), signed), values)
                with self.assertRaises(ValueError):
                    pack_values([upper + 1], bits, signed)
        # Two signed four-bit values occupy low then high nibble.
        self.assertEqual(pack_values([-8, 7], 4), "eA==")
        with self.assertRaises(ValueError):
            unpack_values("/w==", 2, 1)
        with self.assertRaises(ValueError):
            unpack_values("!", 4, 1)
        with self.assertRaises(ValueError):
            unpack_values("", 6, 1)
        with self.assertRaises(ValueError):
            pack_values([1.0], 4)

    def test_rom_layout_matches_logical_tensor_order(self):
        model = load_model(BASELINE_PATH)
        # Place distinguishable signed values across feature and vector boundaries.
        model["feature_weights"][model["size"]:model["size"] + 4] = [-2, -1, 0, 1]
        model["output_weights"][:4] = [-8, 7, -1, 0]
        model["output_weights"][256] = 3
        model["accumulator_bias"][:2] = [-32, 31]
        images = rom_images(model)
        self.assertEqual(int(images["feature_transformer.hex"].splitlines()[1], 16) & 255, 0b01001110)
        self.assertEqual(int(images["output_weights.hex"].splitlines()[0], 16) & 65535, 0x0f78)
        self.assertEqual(int(images["output_weights.hex"].splitlines()[1], 16) & 15, 3)
        self.assertEqual([int(v, 16) for v in images["accumulator_bias.hex"].splitlines()[:2]], [32, 31])

    def test_invalid_models_are_rejected_without_conversion(self):
        document = json.loads(BASELINE_PATH.read_text())
        variants = []
        wrong_dtype = copy.deepcopy(document)
        wrong_dtype["weights"]["output"]["weights"]["dtype"] = "int3"
        variants.append(wrong_dtype)
        short_data = copy.deepcopy(document)
        short_data["weights"]["accumulator"]["biases"]["data"] = ""
        variants.append(short_data)
        overlapping = copy.deepcopy(document)
        overlapping["architecture"]["output"]["bucket_ranges"][1][0] -= 1
        variants.append(overlapping)
        unknown_arch = copy.deepcopy(document)
        unknown_arch["architecture"]["input"]["type"] = "unsupported"
        variants.append(unknown_arch)
        for variant in variants:
            with self.subTest(architecture=variant["architecture"]), self.assertRaises(ValueError):
                decode_model(variant)

    def test_model_selection_is_isolated_and_fingerprints_weights(self):
        """Two builds retain their own ROM paths and exact selected contents."""
        document = json.loads(BASELINE_PATH.read_text())
        original = load_model(BASELINE_PATH)
        changed = list(original["output_weights"])
        changed[0] = 1 if changed[0] != 1 else -1
        document["weights"]["output"]["weights"] = tensor(changed, 4)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            selected = root / "selected.nnue.json"
            selected.write_text(json.dumps(document))
            configs = []
            for name, path in (("first", BASELINE_PATH), ("second", selected)):
                config = {"threads": 1, "stack_depth": 2, "nnue_cache_entries": 2,
                          **evaluation_config({"evaluation_file": str(path)})}
                configs.append(config)
                write_rtl_config(root / name, config)
            self.assertNotEqual(configs[0]["evaluation_digest"], configs[1]["evaluation_digest"])
            for name, config in zip(("first", "second"), configs):
                self.assertEqual((root / name / "output_weights.hex").read_text(),
                                 rom_images(load_model(config["evaluation_file"]))["output_weights.hex"])
                self.assertIn((root / name / "output_weights.hex").as_posix(),
                              (root / name / "rtl_config.sv").read_text())
        with self.assertRaises(BuildError):
            evaluation_config({})
