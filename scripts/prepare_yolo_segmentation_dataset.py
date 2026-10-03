#!/usr/bin/env python3
"""Convert a Collector export ZIP (already YOLO-segmentation, unsplit) into a
split YOLO-segmentation training dataset (train/valid/test), ready to train
a yolo11n-seg model on real traced outlines instead of boxes.

Unlike prepare_yolo_detection_dataset.py, this keeps every label row's
polygon points exactly as exported - no bounding-box reduction - since the
whole point is training on real outlines, not boxes.

Splitting is per-image, keyed by a deterministic hash of the sample ID, so
re-running produces the same assignment unless you change the ratios.
(Grouping by capture session is the safer default against near-duplicate
leakage when there are many sessions, but degenerates badly with very few
sessions - e.g. 2 sessions can only ever put each one entirely into a
single split. Use --split-by session to opt back into that behavior.)

Class order defaults to the export's own manifest.json order. Pass
--class-order to remap into another dataset's order instead (e.g. an
existing dataset.yaml) so the output merges in directly - never assume
matching class_id integers mean the same class across datasets exported
by different tools.
"""
import argparse
import hashlib
import json
import pathlib
import zipfile

DEFAULT_OUTPUT = (
    "/Users/ishraklatif/Documents/IE26/EachPathHealth-scrum/services/ml-kit-detection/"
    "data/processed/dataset-v3-segment"
)


def remap_label(text, remap):
    rows = []
    for line in text.splitlines():
        if not line.strip():
            continue
        tokens = line.split()
        class_id = remap[int(tokens[0])]
        rows.append(' '.join([str(class_id)] + tokens[1:]))
    return '\n'.join(rows) + ('\n' if rows else '')


def split_for(key, train_ratio, valid_ratio):
    bucket = int(hashlib.sha256(key.encode()).hexdigest(), 16) % 100
    if bucket < train_ratio * 100:
        return 'train'
    if bucket < (train_ratio + valid_ratio) * 100:
        return 'valid'
    return 'test'


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('export', help='Path to the Collector export ZIP (from /download/<token>/archive)')
    parser.add_argument('--output', type=pathlib.Path, default=pathlib.Path(DEFAULT_OUTPUT),
                         help='Directory to write the split YOLO-segmentation dataset into '
                              f'(default: {DEFAULT_OUTPUT})')
    parser.add_argument('--train-ratio', type=float, default=0.65)
    parser.add_argument('--valid-ratio', type=float, default=0.20)
    parser.add_argument('--split-by', choices=['image', 'session'], default='image',
                         help='Split key: "image" (default, per-sample) or "session" (groups a whole capture '
                              'session into one split - only sensible with many sessions).')
    parser.add_argument('--class-order', help='Comma-separated class names in the target data.yaml order '
                         '(e.g. matching an existing dataset you plan to train alongside). Must be the same '
                         'set of names as the export; only the order changes. Defaults to the export\'s own order.')
    args = parser.parse_args()

    output = args.output
    if output.exists() and any(output.iterdir()):
        raise SystemExit(f'{output} already exists and is not empty')
    for split in ('train', 'valid', 'test'):
        (output / split / 'images').mkdir(parents=True, exist_ok=True)
        (output / split / 'labels').mkdir(parents=True, exist_ok=True)

    counts = {'train': 0, 'valid': 0, 'test': 0}
    class_counts = {}
    with zipfile.ZipFile(args.export) as archive:
        manifest_name = next(n for n in archive.namelist() if n.endswith('/manifest.json'))
        prefix = manifest_name.removesuffix('manifest.json')
        manifest = json.loads(archive.read(manifest_name))
        source_classes = manifest['classes']
        target_classes = args.class_order.split(',') if args.class_order else list(source_classes)
        if sorted(target_classes) != sorted(source_classes):
            raise SystemExit(f'--class-order must contain exactly these names: {source_classes}')
        remap = [target_classes.index(name) for name in source_classes]
        for sample in manifest['samples']:
            key = sample['session_id'] if args.split_by == 'session' else sample['id']
            split = split_for(key, args.train_ratio, args.valid_ratio)
            counts[split] += 1
            image_bytes = archive.read(prefix + 'images/' + sample['id'] + '.jpg')
            label_text = archive.read(prefix + 'labels/' + sample['id'] + '.txt').decode()
            (output / split / 'images' / (sample['id'] + '.jpg')).write_bytes(image_bytes)
            remapped = remap_label(label_text, remap)
            (output / split / 'labels' / (sample['id'] + '.txt')).write_text(remapped)
            for row in remapped.splitlines():
                class_id = int(row.split()[0])
                class_counts[target_classes[class_id]] = class_counts.get(target_classes[class_id], 0) + 1

    (output / 'data.yaml').write_text(
        f'path: {output}\n'
        'train: train/images\n'
        'val: valid/images\n'
        'test: test/images\n'
        f'nc: {len(target_classes)}\n'
        'names:\n' + ''.join(f'  {i}: {name}\n' for i, name in enumerate(target_classes))
    )

    print(json.dumps({'samples': counts, 'instances_by_class': class_counts, 'classes_in_order': target_classes,
                       'output': str(output)}, indent=2))
    if not args.class_order:
        print('\nNo --class-order given: wrote classes in the Collector\'s own order. If training alongside '
              'another YOLO dataset, re-run with --class-order matching that dataset\'s data.yaml names list.')


if __name__ == '__main__':
    main()
