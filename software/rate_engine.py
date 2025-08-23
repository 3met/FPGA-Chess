
import os
import pandas as pd
import chess
import chess.engine
import glicko2
import random
from datetime import datetime

PUZZLE_PATH = './puzzles/lichess_db_puzzle.csv'

ENGINE_PATH = 'C:\\Users\\Emet\\Desktop\\chess-engine\\downloaded-engines\\stockfish\\v15\\stockfish.exe'
# ENGINE_PATH = 'C:\\Users\\Emet\\Desktop\\chess-engine\\github\\bin\\valkyrie.exe'
# ENGINE_PATH = './engine_sim/bin/fpga_sim.exe'

global uci_engine

def solve_puzzle(fen, moves) -> bool:
	board = chess.Board(fen=fen)
	board.push_uci(moves[0])

	solved = True
	for solution in moves[1:]:
		result = uci_engine.play(board, chess.engine.Limit(time=0.1), game=solution)
		engine_guess = result.move.uci()
		board.push(result.move)

		if engine_guess != solution:

			# Check for multiple mate-in-one solutions for last move
			if solution == moves[-1]:
				if board.is_checkmate():
					solved = True
					break

			solved = False
			break


	return solved


def main():
	puzzles = pd.read_csv(PUZZLE_PATH, nrows=10_000)
	# puzzles = pd.read_csv(PUZZLE_PATH, nrows=50_000)
	puzzles.drop('Popularity', axis=1, inplace=True)
	puzzles.drop('NbPlays', axis=1, inplace=True)
	puzzles.drop('OpeningTags', axis=1, inplace=True)
	puzzles["Moves"] = puzzles["Moves"].str.split()

	opp_rating = []
	opp_rd = []
	outcomes = []

	start_time = datetime.now()

	for idx, row in enumerate(puzzles.itertuples(index=False)):
		score = 1 if solve_puzzle(row.FEN, row.Moves) else 0

		# Store results
		opp_rating.append(row.Rating)
		opp_rd.append(row.RatingDeviation)
		outcomes.append(score)

		# Print periodic rating updates
		if (idx & 31 == 0):
			temp_player = glicko2.Player()
			temp_player.update_player(opp_rating, opp_rd, outcomes)

			# Exit when rating deviation is less than threshold
			if (temp_player.getRd() < 20):
				break

			print(f'rating status: {temp_player.getRating():.1f} +- {temp_player.getRd():.1f}')


	# Final rating calculation
	engine_player = glicko2.Player()
	engine_player.update_player(opp_rating, opp_rd, outcomes)

	run_time = datetime.now() - start_time

	# Print the updated ratings
	print(f'\nscore: {sum(outcomes)}/{len(outcomes)} ({sum(outcomes)/len(outcomes)*100:.1f}%)')
	print(f'final rating: {engine_player.getRating():.1f} +- {engine_player.getRd():.1f}')
	print(f'runtime: {run_time}')


if __name__ == '__main__':
	uci_engine = chess.engine.SimpleEngine.popen_uci(ENGINE_PATH)
	main()
	uci_engine.quit()
