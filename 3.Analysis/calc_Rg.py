import os
import sys

def extract_last_rg_values(pid_file, start_line=None, end_line=None):
    """Mean Rg of the LAST fix ave/time block (2026-10-24). Parses blocks instead of fixed line numbers, so it is
    unchanged for a standard 8 ns file (last block = lines 5598-5603) and also correct when the file was appended
    across resumable eq2 chunks (extra '#' header lines) or the hold length differs."""
    with open(pid_file, 'r') as f:
        lines = [l.split() for l in f if l.strip() and not l.lstrip().startswith('#')]
    i, last = 0, None
    while i < len(lines):
        t = lines[i]
        if len(t) == 2:
            try:
                nrows = int(t[1])
            except ValueError:
                i += 1; continue
            block = lines[i + 1:i + 1 + nrows]
            if len(block) == nrows:
                last = block
            i += 1 + nrows
        else:
            i += 1
    if not last:
        print("Error: no complete Rg block found.")
        return None
    try:
        rg_values = [float(r[1]) for r in last]
    except (ValueError, IndexError) as e:
        print(f"Error parsing Rg values: {e}")
        return None
    return sum(rg_values) / len(rg_values)


def process_rg_results(pid):
    pid_file = f"{pid}_Rg.data"
    if not os.path.exists(pid_file):
        print(f"Missing: {pid_file}")
        return

    rg_mean = extract_last_rg_values(pid_file, 5598, 5603)
    if rg_mean is None:
        return

    # Save to new file
    output_file = f"{pid}_Rg_result.dat"
    with open(output_file, 'w') as f:
        f.write(f"{rg_mean:.6f}\n")

    print(f"Rg mean value for {pid} saved to {output_file}")


# Entry point
if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("Usage: python update_rg.py <PID>")
    else:
        process_rg_results(sys.argv[1])
