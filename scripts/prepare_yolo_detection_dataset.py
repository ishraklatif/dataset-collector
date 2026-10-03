#!/usr/bin/env python3
"""Convert a Collector export ZIP (YOLO-segmentation, unsplit) into a
YOLO-detection dataset (class cx cy w h) split into train/valid/test,
ready to merge into or fine-tune the existing yolo11n detector.

Every polygon vertex list is reduced to its tightest axis-aligned bounding
box; this matches "polygon drawing work can be reused for a detector" -
collecting tighter polygon outlines gives more accurate derived boxes than
eyeballing a rectangle directly, without requiring a segmentation model.

Splitting is grouped by capture session (not by individual image), so near-
duplicate frames from the same session never leak across train/valid/test.
The split is a deterministic hash of the session ID, so re-running produces
the same assignment unless you change the ratios.

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


def bbox_from_polygon(values):
    xs, ys = values[0::2], values[1::2]
    minx, maxx, miny, maxy = min(xs), max(xs), min(ys), max(ys)
    return (minx + maxx) / 2, (miny + maxy) / 2, maxx - minx, maxy - miny


def convert_label(text, remap):
    rows = []
    for line in text.splitlines():
        if not line.strip():
            continue
        tokens = line.split()
        class_id = remap[int(tokens[0])]
        coords = list(map(float, tokens[1:]))
        cx, cy, w, h = bbox_from_polygon(coords)
        rows.append(f'{class_id} {cx:.9f} {cy:.9f} {w:.9f} {h:.9f}')
    return '\n'.join(rows) + ('\n' if rows else '')


def split_for(session_id, train_ratio, valid_ratio):
    bucket = int(hashlib.sha256(session_id.encode()).hexdigest(), 16) % 100
    if bucket < train_ratio * 100:
        return 'train'
    if bucket < (train_ratio + valid_ratio) * 100:
        return 'valid'
    return 'test'


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('export', help='Path to the Collector export ZIP (from /download/<token>/archive)')
    parser.add_argument('output', help='Directory to write the split YOLO-detection dataset into')
    parser.add_argument('--train-ratio', type=float, default=0.65)
    parser.add_argument('--valid-ratio', type=float, default=0.20)
    parser.add_argument('--class-order', help='Comma-separated class names in the target data.yaml order '
                         '(e.g. matching an existing dataset you plan to merge this into). Must be the same '
                         'set of names as the export; only the order changes. Defaults to the export\'s own order.')
    args = parser.parse_args()

    output = pathlib.Path(args.output)
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
            split = split_for(sample['session_id'], args.train_ratio, args.valid_ratio)
            counts[split] += 1
            image_bytes = archive.read(prefix + 'images/' + sample['id'] + '.jpg')
            label_text = archive.read(prefix + 'labels/' + sample['id'] + '.txt').decode()
            (output / split / 'images' / (sample['id'] + '.jpg')).write_bytes(image_bytes)
            converted = convert_label(label_text, remap)
            (output / split / 'labels' / (sample['id'] + '.txt')).write_text(converted)
            for row in converted.splitlines():
                class_id = int(row.split()[0])
                class_counts[target_classes[class_id]] = class_counts.get(target_classes[class_id], 0) + 1

    (output / 'data.yaml').write_text(
        'path: .\n'
        'train: train/images\n'
        'val: valid/images\n'
        'test: test/images\n'
        f'nc: {len(target_classes)}\n'
        'names:\n' + ''.join(f'  {i}: {name}\n' for i, name in enumerate(target_classes))
    )

    print(json.dumps({'samples': counts, 'instances_by_class': class_counts, 'classes_in_order': target_classes}, indent=2))
    if not args.class_order:
        print('\nNo --class-order given: wrote classes in the Collector\'s own order. If merging into another '
              'YOLO dataset, re-run with --class-order matching that dataset\'s data.yaml names list.')


if __name__ == '__main__':
    main()
