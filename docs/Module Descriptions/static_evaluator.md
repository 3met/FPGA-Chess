# Systolic Evaluation (`static_evaluator`)

| Direction | Port Name     | Description                              |
| --------- | ------------- | ---------------------------------------- |
| Input     | `clk`         |                                          |
| Input     | `board_tiles` | 64 x 4 bit tiles.                        |
| Output    | `static_eval` | Evaluation relative to the white player. |


| Pipeline Stage | Description          |
| -------------- | -------------------- |
| 0              | Register inputs      |
| 1-6            | Complete propagation |
| 7              | Set output score     |
