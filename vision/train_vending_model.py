#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import logging
from pathlib import Path
from typing import Any

import torch
import yaml
from ultralytics import RTDETR, YOLO


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Train a vending-product detector")
    parser.add_argument("--dataset-root", required=True, help="Dataset root containing data.yaml")
    parser.add_argument("--backend", choices=["yolo", "rtdetr"], default="yolo")
    parser.add_argument("--weights", default="yolo26n.pt")
    parser.add_argument("--epochs", type=int, default=40)
    parser.add_argument("--imgsz", type=int, default=960)
    parser.add_argument("--batch-size", default="8")
    parser.add_argument("--run-name", default="vending-products")
    parser.add_argument("--project-dir", required=True)
    parser.add_argument("--device", default="auto")
    parser.add_argument("--validate-only", action="store_true")
    return parser.parse_args()


def resolve_device(requested: str) -> str:
    if requested != "auto":
        return requested
    if torch.cuda.is_available():
        return "0"
    if torch.backends.mps.is_available():
        return "mps"
    return "cpu"


def load_dataset_yaml(dataset_root: Path) -> tuple[Path, dict[str, Any]]:
    data_yaml = dataset_root / "data.yaml"
    if not data_yaml.exists():
        raise FileNotFoundError(f"dataset file not found: {data_yaml}")
    payload = yaml.safe_load(data_yaml.read_text()) or {}
    return data_yaml, payload


def validate_dataset(dataset_root: Path, payload: dict[str, Any]) -> dict[str, Any]:
    names = payload.get("names") or {}
    if isinstance(names, list):
        class_names = [str(item) for item in names]
    elif isinstance(names, dict):
        class_names = [str(names[key]) for key in sorted(names, key=lambda item: int(item))]
    else:
        raise ValueError("data.yaml names must be a list or mapping")

    train_dir = dataset_root / "images" / "train"
    val_dir = dataset_root / "images" / "val"
    train_count = len(list(train_dir.glob("*.jpg")))
    val_count = len(list(val_dir.glob("*.jpg")))

    if not class_names:
        raise ValueError("dataset needs at least one class")
    if train_count < 2:
        raise ValueError("dataset needs at least two training images")
    if val_count < 1:
        raise ValueError("dataset needs at least one validation image")

    return {
        "dataset_root": str(dataset_root),
        "class_names": class_names,
        "train_images": train_count,
        "val_images": val_count,
    }


def parse_batch_size(raw_value: str) -> int | str:
    try:
        number = int(raw_value)
    except ValueError:
        return raw_value
    if number < 1:
        raise ValueError("batch size must be at least 1")
    return number


def load_model(backend: str, weights: str):
    if backend == "yolo":
        return YOLO(weights)
    return RTDETR(weights)


def main() -> int:
    args = parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    dataset_root = Path(args.dataset_root).expanduser().resolve()
    project_dir = Path(args.project_dir).expanduser().resolve()
    data_yaml, payload = load_dataset_yaml(dataset_root)
    dataset_summary = validate_dataset(dataset_root, payload)

    if args.validate_only:
        print(json.dumps({"status": "validated", **dataset_summary}, indent=2))
        return 0

    device = resolve_device(args.device)
    batch_size = parse_batch_size(str(args.batch_size))

    logging.info("training backend=%s weights=%s device=%s", args.backend, args.weights, device)
    logging.info("dataset root=%s train=%s val=%s", dataset_root, dataset_summary["train_images"], dataset_summary["val_images"])

    model = load_model(args.backend, args.weights)
    results = model.train(
        data=str(data_yaml),
        epochs=args.epochs,
        imgsz=args.imgsz,
        batch=batch_size,
        project=str(project_dir),
        name=args.run_name,
        device=device,
        workers=0,
        exist_ok=True,
        verbose=True,
    )

    save_dir = Path(getattr(results, "save_dir", getattr(model.trainer, "save_dir", project_dir / args.run_name)))
    best_weights = Path(getattr(model.trainer, "best", save_dir / "weights" / "best.pt"))

    summary = {
        "status": "ok",
        "dataset_root": str(dataset_root),
        "save_dir": str(save_dir),
        "best_weights": str(best_weights),
        "device": device,
        "backend": args.backend,
        "weights": args.weights,
    }
    print(f"TRAINING_RESULT {json.dumps(summary)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
