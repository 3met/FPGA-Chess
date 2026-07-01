### Time Management

Time must be managed well when playing with a clock. Five checkpoints are used to manage time effectively. Iterations refer to the method of iterative deepening. Based on the hardware limitations, all checkpoints must be less than 4.5 hours.

1. Earliest End
	* Checkpoint @ Increment + 1/128 remaining time
	* After iteration is over, exit if previous five iterations gave the same move with similar evaluations
2. Early End
	* Checkpoint @ Increment + 1/64 remaining time
	* After iteration is over, exit if previous four iterations gave the same move with similar evaluations
3. Target End
	* Checkpoint @ Increment + 1/32 remaining time
	* After iteration is over, exit if previous three iterations gave the same move with similar evaluations
4. Late End
	* Checkpoint @ Increment + 1/16 remaining time
	* After iteration is over, exit if previous two iterations gave the same move with similar evaluations
5. Latest End
	* Checkpoint @ Increment + 1/8 remaining time
	* End immediately and do not finish current iteration of search

