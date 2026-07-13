"""Command-line entry point for the deterministic reference compositor."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from .engine import composite_pair, load_mask, load_rgb, save_rgb


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("side_one", type=Path)
    parser.add_argument("side_two", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--mask-one", type=Path)
    parser.add_argument("--mask-two", type=Path)
    parser.add_argument("--debug-overlay", type=Path)
    parser.add_argument("--metrics", type=Path)
    parser.add_argument("--seam-start", type=float, default=0.32)
    parser.add_argument("--seam-end", type=float, default=0.68)
    parser.add_argument("--feather", type=int, default=18)
    return parser


def main() -> None:
    args = build_parser().parse_args()
    side_one = load_rgb(args.side_one)
    side_two = load_rgb(args.side_two)
    shape = side_one.shape[:2]
    result = composite_pair(
        side_one,
        side_two,
        protected_one=load_mask(args.mask_one, shape),
        protected_two=load_mask(args.mask_two, shape),
        search_range=(args.seam_start, args.seam_end),
        feather_width=args.feather,
    )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    save_rgb(args.output, result.image)
    if args.debug_overlay:
        args.debug_overlay.parent.mkdir(parents=True, exist_ok=True)
        save_rgb(args.debug_overlay, result.debug_overlay)
    if args.metrics:
        args.metrics.parent.mkdir(parents=True, exist_ok=True)
        args.metrics.write_text(
            json.dumps(result.metrics.as_dict(), indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )


if __name__ == "__main__":
    main()

