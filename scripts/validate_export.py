#!/usr/bin/env python3
"""Independent desktop ZIP/image/label verification; optionally render overlay previews."""
import argparse
import hashlib
import io
import json
import math
import pathlib
import zipfile

from PIL import Image, ImageDraw

def validate(path, previews=None):
    with zipfile.ZipFile(path) as archive:
        names=archive.namelist()
        assert len(names)==len(set(names)), 'Duplicate archive paths'
        assert all(not pathlib.PurePosixPath(n).is_absolute() and '..' not in pathlib.PurePosixPath(n).parts for n in names), 'Unsafe archive path'
        manifests=[n for n in names if n.endswith('/manifest.json')]
        assert len(manifests)==1, 'Exactly one manifest is required'
        prefix=manifests[0].removesuffix('manifest.json')
        manifest=json.loads(archive.read(manifests[0]))
        schema=manifest['schema_version']
        assert schema in (1,2) and manifest['split']=='unsplit'
        if schema==2:assert manifest['label_format']=='yolo-segmentation'
        assert manifest['classes']==['collection_tube','kit_package','reply_paid_envelope','toilet_liner','ziplock_bag']
        samples=manifest['samples']
        assert len({s['id'] for s in samples})==len(samples), 'Duplicate samples'
        hashes={}
        objects=0
        for sample in samples:
            image_name=prefix+'images/'+sample['id']+'.jpg'
            label_name=prefix+'labels/'+sample['id']+'.txt'
            data=archive.read(image_name)
            assert hashlib.sha256(data).hexdigest()==sample['sha256'], 'Image checksum mismatch'
            with Image.open(io.BytesIO(data)) as image:
                image.load()
                assert image.format=='JPEG' and image.size==(sample['width'],sample['height'])
                assert image.getexif().get(274,1)==1, 'Noncanonical EXIF orientation'
                rows=archive.read(label_name).decode().splitlines()
                assert len(rows)==len(sample['annotations'])
                assert bool(not rows)==sample['explicit_negative'], 'Negative was not explicitly approved'
                drawing=ImageDraw.Draw(image)
                for row,box in zip(rows,sample['annotations']):
                    values=row.split();cls=int(values[0]);assert cls in range(5) and cls==box['class_id']
                    if schema==1:
                        assert len(values)==5, 'Legacy YOLO detection rows need five columns'
                        cx,cy,w,h=map(float,values[1:])
                        assert all(math.isfinite(v) for v in (cx,cy,w,h)) and w>0 and h>0
                        assert cx-w/2>=-1e-8 and cy-h/2>=-1e-8 and cx+w/2<=1+1e-8 and cy+h/2<=1+1e-8
                        px=(cx-w/2)*image.width;py=(cy-h/2)*image.height
                        for actual,expected_value in zip((px,py,w*image.width,h*image.height),(box['x'],box['y'],box['width'],box['height'])):
                            assert abs(actual-expected_value)<1e-4, 'Legacy label/manifest geometry mismatch'
                        pixels=[(px,py),(px+w*image.width,py),(px+w*image.width,py+h*image.height),(px,py+h*image.height)]
                    else:
                        assert len(values)>=7 and len(values)%2==1, 'YOLO segmentation rows need a class and at least three vertex pairs'
                        coords=list(map(float,values[1:]))
                        assert all(math.isfinite(v) and 0<=v<=1 for v in coords), 'Polygon coordinates must be finite and normalized'
                        expected=box.get('points') or [
                            {'x':box['x'],'y':box['y']},{'x':box['x']+box['width'],'y':box['y']},
                            {'x':box['x']+box['width'],'y':box['y']+box['height']},{'x':box['x'],'y':box['y']+box['height']}]
                        assert len(coords)==2*len(expected), 'Label/manifest vertex count mismatch'
                        pixels=[]
                        for i,point in enumerate(expected):
                            nx,ny=coords[2*i:2*i+2]
                            assert abs(nx-point['x']/image.width)<1e-8 and abs(ny-point['y']/image.height)<1e-8, 'Label/manifest polygon mismatch'
                            pixels.append((nx*image.width,ny*image.height))
                    drawing.line(pixels+[pixels[0]],fill='lime',width=max(2,image.width//400),joint='curve')
                    drawing.text(pixels[0],manifest['classes'][cls],fill='yellow')
                    objects+=1
                if previews:
                    out=pathlib.Path(previews);out.mkdir(parents=True,exist_ok=True)
                    image.thumbnail((1200,1200));image.save(out/(sample['id']+'.jpg'))
            hashes.setdefault(sample['sha256'],[]).append(sample['id'])
        expected={prefix+'images/'+s['id']+'.jpg' for s in samples}|{prefix+'labels/'+s['id']+'.txt' for s in samples}
        assert expected=={n for n in names if '/images/' in n or '/labels/' in n}, 'Unpaired or unexpected images/labels'
        return {'images':len(samples),'objects':objects,'exact_duplicate_groups':[ids for ids in hashes.values() if len(ids)>1],
                'capture_groups':len({s['session_id'] for s in samples}),'specimens':len({s['specimen_id'] for s in samples})}

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('archive');parser.add_argument('--previews',help='Write annotated previews on the training computer')
    args=parser.parse_args()
    print(json.dumps(validate(args.archive,args.previews),indent=2))
