# Examples

- `SMILES_demo.csv` — five demo polymers (`PID00001`–`PID00005`)
- `tasks_demo.txt` — HTCondor task indices `2`–`6` (1-based data rows after the header; here rows for PID00002–PID00006 if using the full `SMILES.csv`)

For a minimal demo with only the five rows in `SMILES_demo.csv`, use:

```text
1
2
3
4
5
```

as `tasks_full.txt` (each line = 1-based index into the CSV data rows).
