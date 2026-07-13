"""Generate committed non-person fixtures for the groupCam reference harness."""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont
from skimage import transform


@dataclass(frozen=True)
class SyntheticPerson:
    name: str
    center_x: int
    shirt: tuple[int, int, int]


WIDTH = 1_200
HEIGHT = 800
PEOPLE = [
    SyntheticPerson("A", 120, (207, 67, 73)),
    SyntheticPerson("C", 340, (48, 120, 198)),
    SyntheticPerson("D", 540, (235, 176, 52)),
    SyntheticPerson("E", 740, (127, 82, 170)),
    SyntheticPerson("B", 1_045, (226, 112, 48)),
]


def _background(seed: int = 7) -> Image.Image:
    rng = np.random.default_rng(seed)
    y = np.linspace(0.0, 1.0, HEIGHT)[:, None]
    x = np.linspace(0.0, 1.0, WIDTH)[None, :]
    pixels = np.empty((HEIGHT, WIDTH, 3), dtype=np.float32)
    pixels[..., 0] = 118 + 42 * (1 - y) + 12 * x
    pixels[..., 1] = 159 + 45 * (1 - y) - 18 * x
    pixels[..., 2] = 174 + 39 * (1 - y) - 24 * x
    noise = rng.normal(0, 2.0, size=(HEIGHT, WIDTH, 1))
    pixels = np.clip(pixels + noise, 0, 255).astype(np.uint8)
    image = Image.fromarray(pixels, mode="RGB")
    draw = ImageDraw.Draw(image)

    # Static high-frequency structure gives the registration harness a
    # deterministic background that is richer than the synthetic people.
    for x_value in range(25, WIDTH, 75):
        draw.line((x_value, 0, x_value + 36, HEIGHT), fill=(90, 125, 135), width=2)
    for y_value in range(35, HEIGHT, 68):
        draw.line((0, y_value, WIDTH, y_value + 17), fill=(151, 185, 188), width=2)
    for _ in range(175):
        cx = int(rng.integers(10, WIDTH - 10))
        cy = int(rng.integers(20, HEIGHT - 190))
        radius = int(rng.integers(3, 11))
        color = tuple(int(value) for value in rng.integers(45, 220, size=3))
        draw.ellipse((cx - radius, cy - radius, cx + radius, cy + radius), fill=color)

    draw.rectangle((0, 650, WIDTH, HEIGHT), fill=(67, 118, 74))
    for x_value in range(0, WIDTH, 40):
        draw.line((x_value, 650, x_value + 100, HEIGHT), fill=(77, 132, 81), width=3)
    return image


def _draw_person(image: Image.Image, mask: Image.Image, person: SyntheticPerson) -> None:
    draw = ImageDraw.Draw(image)
    mask_draw = ImageDraw.Draw(mask)
    x = person.center_x
    head = (x - 34, 354, x + 34, 426)
    torso = (x - 58, 419, x + 58, 607)
    left_leg = (x - 47, 570, x - 6, 688)
    right_leg = (x + 6, 570, x + 47, 688)

    draw.ellipse(head, fill=(174, 118, 88), outline=(92, 59, 45), width=3)
    draw.rounded_rectangle(torso, radius=28, fill=person.shirt, outline=(40, 40, 42), width=3)
    draw.rounded_rectangle(left_leg, radius=13, fill=(43, 49, 63))
    draw.rounded_rectangle(right_leg, radius=13, fill=(43, 49, 63))
    draw.text((x - 11, 470), person.name, fill=(255, 255, 255), font=ImageFont.load_default(size=28))

    for shape in (head, torso, left_leg, right_leg):
        if shape == head:
            mask_draw.ellipse(shape, fill=255)
        else:
            mask_draw.rounded_rectangle(shape, radius=18, fill=255)


def _render(names: set[str]) -> tuple[Image.Image, Image.Image]:
    image = _background()
    mask = Image.new("L", (WIDTH, HEIGHT), 0)
    for person in PEOPLE:
        if person.name in names:
            _draw_person(image, mask, person)
    return image, mask


def _warp(
    image: Image.Image,
    model: transform.ProjectiveTransform,
    *,
    is_mask: bool,
) -> Image.Image:
    array = np.asarray(image)
    warped = transform.warp(
        array,
        inverse_map=model.inverse,
        output_shape=(HEIGHT, WIDTH),
        order=0 if is_mask else 1,
        mode="constant",
        cval=0,
        preserve_range=True,
    )
    return Image.fromarray(np.uint8(np.clip(warped, 0, 255)), mode="L" if is_mask else "RGB")


def generate_fixture(output_directory: Path) -> dict[str, object]:
    output_directory.mkdir(parents=True, exist_ok=True)

    side_one, mask_one = _render({"B", "C", "D", "E"})
    canonical_side_two, canonical_mask_two = _render({"A", "C", "D", "E"})
    ground_truth, ground_truth_mask = _render({"A", "B", "C", "D", "E"})

    canonical_to_side_two = transform.ProjectiveTransform(
        matrix=np.array(
            [
                [1.003, 0.006, 14.0],
                [-0.004, 1.002, 8.0],
                [0.000006, -0.000004, 1.0],
            ],
            dtype=np.float64,
        )
    )
    side_two = _warp(canonical_side_two, canonical_to_side_two, is_mask=False)
    mask_two = _warp(canonical_mask_two, canonical_to_side_two, is_mask=True)

    files = {
        "side_one": "side_one.png",
        "side_two": "side_two.png",
        "protected_one": "protected_side_one.png",
        "protected_two": "protected_side_two.png",
        "ground_truth": "ground_truth_all.png",
        "ground_truth_mask": "ground_truth_mask.png",
    }
    side_one.save(output_directory / files["side_one"])
    side_two.save(output_directory / files["side_two"])
    mask_one.save(output_directory / files["protected_one"])
    mask_two.save(output_directory / files["protected_two"])
    ground_truth.save(output_directory / files["ground_truth"])
    ground_truth_mask.save(output_directory / files["ground_truth_mask"])

    manifest: dict[str, object] = {
        "schema_version": 1,
        "description": "Synthetic opposite-edge handoff with a mild projective camera change.",
        "files": files,
        "expected_side_two_to_side_one": canonical_to_side_two.inverse.params.tolist(),
        "seam_search_range": [0.57, 0.69],
        "joining_regions": {
            "photographer_a": [62, 350, 178, 690],
            "photographer_b": [987, 350, 1103, 690],
        },
    }
    (output_directory / "fixture.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "output_directory",
        type=Path,
        nargs="?",
        default=Path("Fixtures/Synthetic/opposite_edges"),
    )
    args = parser.parse_args()
    generate_fixture(args.output_directory)


if __name__ == "__main__":
    main()
