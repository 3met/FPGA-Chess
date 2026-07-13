"""Module entrypoint for the FPGA hardware build tools."""

from .cli import main


if __name__ == "__main__":
    raise SystemExit(main())
