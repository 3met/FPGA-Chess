# Static Evaluator (`static_evaluator`)

| Direction | Port Name     | Description                              |
| --------- | ------------- | ---------------------------------------- |
| Input     | `clk`         |                                          |
| Input     | `board_tiles` | 64 x 4 bit tiles.                        |
| Output    | `static_eval` | Static evaluation score. The existing RTL computes this relative to White; integration should normalize final search scores to point-of-view format. |


| Pipeline Stage | Description          |
| -------------- | -------------------- |
| 0              | Register inputs      |
| 1-6            | Complete propagation |
| 7              | Set output score     |
