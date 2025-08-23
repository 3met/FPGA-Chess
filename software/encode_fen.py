
# By Emet Behrendt

# Function to convert FEN piece representation to the specified format
def piece_to_bits(piece):
	if piece == 'P': return '0001'
	elif piece == 'N': return '0010'
	elif piece == 'B': return '0011'
	elif piece == 'R': return '0100'
	elif piece == 'Q': return '0101'
	elif piece == 'K': return '0110'
	elif piece == 'p': return '1001'
	elif piece == 'n': return '1010'
	elif piece == 'b': return '1011'
	elif piece == 'r': return '1100'
	elif piece == 'q': return '1101'
	elif piece == 'k': return '1110'
	else: return '0000'  # Empty square


# Encodes the FEN format to binary
# Encoded like: <64 * 4 bits tiles>, <4 bits castle perms>, <4 bits en passant>, <1 bit turn>, <7 bits halfmove clock>
def encode_fen(fen):
	# Empty string to store encoded content
	encoded = ""

	# Parse the FEN string
	parts = fen.split()
	board = parts[0]
	turn = parts[1]
	castle_perms = parts[2]	
	en_passant = parts[3]
	halfmove_clock = parts[4]

	# Iterate through the board FEN and convert each piece to bits
	tiles = [None, ] * 64
	idx = 0
	for char in board:
		new_pos = 56 + idx%8 - 8*(idx//8)  # Convert to 0-63 index from FEN order
		if char == '/':
			continue  # Skip slashes in FEN
		elif char.isdigit():
			tiles[new_pos:new_pos+int(char)] = ['0000',] * int(char) # Empty squares
			idx += int(char)
		else:
			tiles[new_pos] = piece_to_bits(char)
			idx += 1

	assert None not in tiles, "Error: Not all tiles were filled."

	encoded += ''.join(tiles)

	# Map castle permissions letters to bits
	encoded += ''.join(['1' if letter in castle_perms else '0' for letter in 'KQkq'])

	# Represent en passant with 4 bits: 3 bits for file (a-h) and 1 bit for valid en passant
	if en_passant != '-':
		encoded += bin(ord(en_passant[0]) - ord('a'))[2:].zfill(3) + '1'
	else:
		encoded += '0000'

	# Add the turn
	encoded += '0' if turn == 'w' else '1'
	
	# Add the halfmove clock (7 bits)
	encoded += bin(int(halfmove_clock))[2:].zfill(7)

	# Check if the content length matches the specified width
	width = 64*4 + 4 + 4 + 1 + 7
	if len(encoded) != width:
		raise ValueError(f"Generated content length ({len(encoded)}) does not match the specified width ({width}).")

	# Return a bytes type object
	return int(encoded, 2).to_bytes(len(encoded) // 8, byteorder='big')


if __name__ == '__main__':

	# fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"
	fen = input('Enter FEN to convert: ')

	encoded = encode_fen(fen)
	print(encoded.hex())
