import unittest

from software.engine.protocol import (
    EndReason,
    Move,
    SearchResultResponse,
    STARTPOS_FEN,
    cmd_make_move,
    decode_response,
    encode_fen,
    encode_move,
    encode_time_ms,
    move_to_uci,
    parse_uci_move,
)


class ProtocolEncodingTests(unittest.TestCase):
    def test_startpos_full_board_payload_matches_documented_packing(self):
        payload = encode_fen(STARTPOS_FEN)
        self.assertEqual(len(payload), 36)
        self.assertEqual(payload[0:4], bytes.fromhex("24533642"))
        self.assertEqual(payload[4:8], bytes.fromhex("11111111"))
        self.assertEqual(payload[8:24], bytes(16))
        self.assertEqual(payload[24:28], bytes.fromhex("99999999"))
        self.assertEqual(payload[28:32], bytes.fromhex("acdbbeca"))
        self.assertEqual(payload[32], 0x0F)
        self.assertEqual(payload[33], 0x00)
        self.assertEqual(payload[34], 0x00)
        self.assertEqual(payload[35], 0x00)

    def test_full_board_payload_encodes_turn_ep_and_halfmove(self):
        payload = encode_fen("8/8/8/8/8/8/8/8 b - e3 12 34")
        self.assertEqual(payload[:32], bytes(32))
        self.assertEqual(payload[32], 0x00)
        self.assertEqual(payload[33], 0x09)
        self.assertEqual(payload[34], 0x01)
        self.assertEqual(payload[35], 12)

    def test_move_encoding_matches_rtl_layout(self):
        self.assertEqual(cmd_make_move("e2e4"), bytes.fromhex("02700c"))
        self.assertEqual(encode_move(parse_uci_move("e7e8n")), bytes.fromhex("f134"))
        self.assertEqual(move_to_uci(Move(12, 28)), "e2e4")
        self.assertEqual(move_to_uci(Move(52, 60, 1), promote=True), "e7e8n")

    def test_time_is_24_bit_little_endian(self):
        self.assertEqual(encode_time_ms(0x010203), bytes.fromhex("030201"))

    def test_search_response_decoding(self):
        response = decode_response(bytes.fromhex("82700cf0ff05040302010501"))
        self.assertIsInstance(response, SearchResultResponse)
        self.assertEqual(response.best_move, Move(12, 28, 0))
        self.assertEqual(response.score, -16)
        self.assertEqual(response.nodes, 0x0102030405)
        self.assertEqual(response.completed_depth, 5)
        self.assertEqual(response.end_reason, EndReason.DEPTH_LIMIT)


if __name__ == "__main__":
    unittest.main()
