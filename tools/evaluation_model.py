"""Quantized evaluation model serialization and build-local ROM generation."""

import base64
import binascii
import hashlib
import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
EVALUATION_ROOT = REPO_ROOT / "hardware/data/evaluation"
BASELINE_PATH = EVALUATION_ROOT / "baseline.nnue.json"
PIECE_ORDER = ("pawn", "knight", "bishop", "rook", "queen", "king")
ROM_FILES = ("feature_transformer.hex", "accumulator_bias.hex", "output_weights.hex",
             "output_bias.hex", "pst_values.hex", "pst_values_endgame.hex")


def pack_values(values, bits, signed=True):
    """Encode consecutive integers least-significant bits first, without word padding."""
    lower, upper = (-(1 << (bits - 1)), (1 << (bits - 1)) - 1) if signed else (0, (1 << bits) - 1)
    data = bytearray()
    pending = available = 0
    for value in values:
        if type(value) is not int or not lower <= value <= upper:
            raise ValueError(f"value {value!r} does not fit {'int' if signed else 'uint'}{bits}")
        pending |= (value & ((1 << bits) - 1)) << available
        available += bits
        while available >= 8:
            data.append(pending & 255)
            pending >>= 8
            available -= 8
    if available:
        data.append(pending)
    return base64.b64encode(data).decode("ascii")


def unpack_values(data, bits, count, signed=True):
    """Decode exact-length packed integers and reject nonzero final padding bits."""
    try:
        raw = base64.b64decode(data, validate=True)
    except (ValueError, TypeError, binascii.Error) as exc:
        raise ValueError("invalid base64 parameter data") from exc
    if len(raw) != (bits * count + 7) // 8:
        raise ValueError(f"parameter payload must contain {count} packed {bits}-bit values")
    values = []
    pending = available = offset = 0
    for _ in range(count):
        while available < bits:
            pending |= raw[offset] << available
            available += 8
            offset += 1
        value = pending & ((1 << bits) - 1)
        pending >>= bits
        available -= bits
        if signed and value >= 1 << (bits - 1):
            value -= 1 << bits
        values.append(value)
    if pending:
        raise ValueError("parameter payload has nonzero padding bits")
    return values


def tensor(values, bits, signed=True):
    """Create one packed tensor with its required integer storage type."""
    return {"dtype": f"{'int' if signed else 'uint'}{bits}",
            "encoding": "base64", "data": pack_values(values, bits, signed)}


def architecture(size, ranges):
    """Describe the model geometry independently of FPGA execution parallelism."""
    return {"input": {"type": "relative_piece_square"},
            "accumulator": {"size": size, "activation": "screlu"},
            "output": {"type": "linear", "bucket_by": "piece_count", "bucket_ranges": ranges},
            "evaluation": {"units": "pawn/128", "phase_by": "piece_count",
                           "endgame_at": 2, "opening_at": 32}}


def format_model(document):
    """Render model JSON with each output bucket range on a single line."""
    ranges = document["architecture"]["output"]["bucket_ranges"]
    expanded = json.dumps(ranges, indent=2).replace("\n", "\n      ")
    compact = "[\n" + ",\n".join("        " + json.dumps(bounds) for bounds in ranges) + "\n      ]"
    return json.dumps(document, indent=2).replace(
        '"bucket_ranges": ' + expanded, '"bucket_ranges": ' + compact, 1
    ) + "\n"


def decode_model(document):
    """Validate supported architecture and decode all final integer parameters."""
    try:
        arch = document["architecture"]
        size = arch["accumulator"]["size"]
        ranges = arch["output"]["bucket_ranges"]
        if type(size) is not int or size < 256 or size % 256:
            raise ValueError("accumulator size must be a positive multiple of the supported vector width")
        if not isinstance(ranges, list) or not ranges:
            raise ValueError("output bucket_ranges must be a nonempty list")
        next_count = 2
        for bounds in ranges:
            if (not isinstance(bounds, list) or len(bounds) != 2
                    or any(type(v) is not int for v in bounds)
                    or bounds[0] != next_count or not bounds[0] <= bounds[1] <= 32):
                raise ValueError("bucket ranges must partition piece counts 2 through 32")
            next_count = bounds[1] + 1
        if next_count != 33:
            raise ValueError("bucket ranges must cover piece counts 2 through 32")
        if arch != architecture(size, ranges):
            raise ValueError("unsupported evaluation architecture")
        def read_tensor(item, bits, count, signed=True):
            """Require the datapath storage type before decoding a tensor."""
            if item["dtype"] != f"{'int' if signed else 'uint'}{bits}" or item["encoding"] != "base64":
                raise ValueError("unsupported parameter dtype or encoding")
            return unpack_values(item["data"], bits, count, signed)
        weights = document["weights"]
        result = {"size": size, "ranges": ranges,
                  "feature_weights": read_tensor(weights["accumulator"]["weights"], 2, 768 * size),
                  "accumulator_bias": read_tensor(weights["accumulator"]["biases"], 6, size),
                  "output_weights": read_tensor(weights["output"]["weights"], 4, len(ranges) * 2 * size),
                  "output_bias": read_tensor(weights["output"]["biases"], 6, len(ranges), False)}
        if document["material"]["dtype"] != "int16" or document["pst"]["dtype"] != "int10" or document["pst"]["encoding"] != "base64":
            raise ValueError("unsupported material/PST dtype or encoding")
        for phase in ("opening", "endgame"):
            material = document["material"][phase]
            pst = document["pst"][phase]
            if set(material) != set(PIECE_ORDER) or set(pst) != set(PIECE_ORDER):
                raise ValueError("material and PST must define exactly the six piece types")
            values = [material[piece] for piece in PIECE_ORDER]
            pack_values(values, 16)
            if values[0] != 128 or values[5] != 0:
                raise ValueError("pawn and king material must retain their fixed values")
            result["material_" + phase] = values
            result["pst_" + phase] = [v for piece in PIECE_ORDER for v in unpack_values(pst[piece], 10, 64)]
        result["score_bound"] = max(phase_score_bound(result["material_" + phase], result["pst_" + phase])
                                    for phase in ("opening", "endgame"))
        # Unreachable pawn end ranks must remain zero in the canonical model.
        for feature in (*range(8), *range(56, 64), *range(384, 392), *range(440, 448)):
            if any(result["feature_weights"][feature*size:(feature+1)*size]):
                raise ValueError("unreachable pawn transformer rows must be zero")
        for phase in ("opening", "endgame"):
            if any(result["pst_" + phase][sq] for sq in (*range(8), *range(56, 64))):
                raise ValueError("unreachable pawn PST entries must be zero")
        return result
    except (KeyError, TypeError, AttributeError) as exc:
        raise ValueError(f"invalid evaluation model: {exc}") from exc


def load_model(path):
    """Read a complete quantized evaluation model without training dependencies."""
    return decode_model(json.loads(Path(path).read_text(encoding="utf-8")))


def model_digest(path):
    """Fingerprint model contents so changing weights invalidates every build cache."""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def phase_score_bound(material, words):
    """Bound a legal board using original pieces and at most eight promotions per side."""
    if any(not -4095 <= value <= 4095 for value in material):
        raise ValueError("material must fit the negatable search-score range")
    extrema = {}
    for index, piece in enumerate(PIECE_ORDER):
        scores = [material[index] + value for value in words[index * 64:(index + 1) * 64]]
        if min(scores) < -4095 or max(scores) > 4095:
            raise ValueError(f"material plus PST for {piece} must fit the negatable search-score range")
        extrema[piece] = (min(scores), max(scores))
    # Captures can remove any non-king; each pawn can remain or promote to any piece.
    # Root loading can temporarily omit a king while constructing the board.
    lower, upper = min(0, extrema["king"][0]), max(0, extrema["king"][1])
    for piece, count in (("knight", 2), ("bishop", 2), ("rook", 2), ("queen", 1)):
        lower += count * min(0, extrema[piece][0])
        upper += count * max(0, extrema[piece][1])
    lower += 8 * min(0, *(extrema[piece][0] for piece in PIECE_ORDER if piece != "king"))
    upper += 8 * max(0, *(extrema[piece][1] for piece in PIECE_ORDER if piece != "king"))
    # Opposing colors use mirrored copies of the same tables, with opposite signs.
    return upper - lower


def rom_images(model, lanes=256):
    """Render ROM rows in the lane order expected by the existing RTL datapath."""
    def rows(values, bits, width):
        """Place the first logical lane in the least-significant ROM bits."""
        mask = (1 << bits) - 1
        return "".join(f"{sum((v & mask) << (bits*i) for i, v in enumerate(values[start:start+width])):0{(bits*width+3)//4}x}\n"
                       for start in range(0, len(values), width))
    return dict(zip(ROM_FILES, (
        rows(model["feature_weights"], 2, model["size"]),
        "".join(f"{value & 63:x}\n" for value in model["accumulator_bias"]),
        rows(model["output_weights"], 4, lanes),
        rows(model["output_bias"], 6, 1),
        rows(model["pst_opening"], 10, 1), rows(model["pst_endgame"], 10, 1))))


def write_roms(directory, model):
    """Materialize private ROM images for one synthesis or simulation build."""
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    for name, text in rom_images(model).items():
        path = directory / name
        if not path.exists() or path.read_text(encoding="ascii") != text:
            path.write_text(text, encoding="ascii")


def rtl_parameters(model, directory=None):
    """Emit evaluation constants and ROM paths into the generated RTL package."""
    lines = [f"    localparam int PST_EVAL_BOUND = {model['score_bound']};",
             f"    localparam int NNUE_ACCUMULATOR_COUNT = {model['size']};",
             f"    localparam int NNUE_OUTPUT_BUCKET_COUNT = {len(model['ranges'])};"]
    for phase, name in (("opening", "PIECE_VALS_128"), ("endgame", "PIECE_VALS_ENDGAME_128")):
        values = [0, *model["material_" + phase], 0]
        literals = ", ".join(f"-13'd{-v}" if v < 0 else f"13'd{v}" for v in values)
        lines.append(f"    localparam logic signed [12:0] {name}[8] = '{{{literals}}};")
    bucket_bits = max(1, (len(model["ranges"])-1).bit_length())
    bucket_map = 0
    for count in range(33):
        bucket = next(i for i, (low, high) in enumerate(model["ranges"]) if low <= max(2, count) <= high)
        bucket_map |= bucket << (bucket_bits * count)
    lines.append(f"    localparam logic [{33*bucket_bits-1}:0] NNUE_OUTPUT_BUCKET_MAP = {33*bucket_bits}'h{bucket_map:x};")
    for name in ROM_FILES:
        path = (Path(directory) / name).resolve().as_posix() if directory else name
        lines.append(f"    localparam {name.removesuffix('.hex').upper()}_FILE = {json.dumps(path)};")
    return "\n".join(lines) + "\n"
