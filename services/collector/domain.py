"""Pure label and image checks. No files or model jobs."""
import hashlib
import io
import math
from PIL import Image, UnidentifiedImageError

CLASSES = ['collection_tube', 'kit_package', 'reply_paid_envelope', 'toilet_liner', 'ziplock_bag']
MODEL_HASH = '455888c9b0bc769b0a6307c324ed59879b706cab6283742d9f5aaf7097bf4937'
MODEL_METADATA = {'schema_version': 1, 'class_map': CLASSES, 'class_map_version': 1,
                  'input': [1, 320, 320, 3], 'output': [1, 9, 2100],
                  'preprocessing_version': 'upright-jpeg-rgb-contain-gray114-v1',
                  'coordinate_units': 'model_input_pixels', 'proposal_floor': 0.5, 'nms_iou': 0.45}

class Invalid(ValueError):
    pass

def boxes(value, width, height, predictions=False):
    if not isinstance(value, list) or len(value) > 200:
        raise Invalid('At most 200 boxes are allowed')
    result = []
    for box in value:
        if not isinstance(box, dict) or type(box.get('class_id')) is not int or box['class_id'] not in range(5):
            raise Invalid('Invalid class ID')
        keys = ('x', 'y', 'width', 'height')
        if any(type(box.get(k)) not in (int, float) or not math.isfinite(box[k]) for k in keys):
            raise Invalid('Invalid box coordinates')
        x, y, w, h = (float(box[k]) for k in keys)
        if x < 0 or y < 0 or w <= 0 or h <= 0 or x+w > width+1e-6 or y+h > height+1e-6:
            raise Invalid('Box outside image or empty')
        item = {'class_id': box['class_id'], **dict(zip(keys, (x, y, w, h)))}
        points = box.get('points')
        if points is not None:
            if not isinstance(points, list) or not 3 <= len(points) <= 256:
                raise Invalid('A polygon needs 3 to 256 points')
            polygon = []
            for point in points:
                if not isinstance(point, dict) or any(type(point.get(k)) not in (int, float) or not math.isfinite(point[k]) for k in ('x', 'y')):
                    raise Invalid('Invalid polygon point')
                px, py = float(point['x']), float(point['y'])
                if px < 0 or py < 0 or px > width or py > height:
                    raise Invalid('Polygon point outside image')
                polygon.append({'x': px, 'y': py})
            if len({(p['x'], p['y']) for p in polygon}) < 3:
                raise Invalid('Polygon needs 3 distinct points')
            area = sum(p['x']*polygon[(i+1)%len(polygon)]['y'] - polygon[(i+1)%len(polygon)]['x']*p['y'] for i,p in enumerate(polygon))
            if abs(area) < 1e-6:
                raise Invalid('Polygon area is empty')
            def orient(a,b,c):
                return (b['x']-a['x'])*(c['y']-a['y'])-(b['y']-a['y'])*(c['x']-a['x'])
            def on_segment(a,b,c):
                return min(a['x'],b['x'])-1e-9<=c['x']<=max(a['x'],b['x'])+1e-9 and min(a['y'],b['y'])-1e-9<=c['y']<=max(a['y'],b['y'])+1e-9
            def intersects(a,b,c,d):
                o1,o2,o3,o4=orient(a,b,c),orient(a,b,d),orient(c,d,a),orient(c,d,b)
                return (o1*o2 < 0 and o3*o4 < 0) or (abs(o1)<1e-9 and on_segment(a,b,c)) or (abs(o2)<1e-9 and on_segment(a,b,d)) or (abs(o3)<1e-9 and on_segment(c,d,a)) or (abs(o4)<1e-9 and on_segment(c,d,b))
            for i in range(len(polygon)):
                a,b=polygon[i],polygon[(i+1)%len(polygon)]
                for j in range(i+1,len(polygon)):
                    if j==i or j==(i+1)%len(polygon) or (j+1)%len(polygon)==i:
                        continue
                    if intersects(a,b,polygon[j],polygon[(j+1)%len(polygon)]):
                        raise Invalid('Polygon edges must not cross')
            left=min(p['x'] for p in polygon);top=min(p['y'] for p in polygon)
            right=max(p['x'] for p in polygon);bottom=max(p['y'] for p in polygon)
            item.update(x=left,y=top,width=right-left,height=bottom-top,points=polygon)
        if predictions:
            conf = box.get('confidence')
            if type(conf) not in (int, float) or not math.isfinite(conf) or not 0 <= conf <= 1:
                raise Invalid('Invalid confidence')
            item['confidence'] = conf
        result.append(item)
    return result

def image_info(data, max_bytes, max_dimension):
    if not data or len(data) > max_bytes:
        raise Invalid('Image exceeds byte limit')
    try:
        with Image.open(io.BytesIO(data)) as image:
            if image.format != 'JPEG' or image.width > max_dimension or image.height > max_dimension or min(image.size) < 1:
                raise Invalid('JPEG dimensions exceed configured limit')
            if image.getexif().get(274, 1) != 1 or image.getexif().get(34853):
                raise Invalid('Canonical pixels must be upright with location removed')
            image.load()
            width, height = image.size
    except (UnidentifiedImageError, OSError, Image.DecompressionBombError) as error:
        raise Invalid('Image cannot be decoded') from error
    return width, height, hashlib.sha256(data).hexdigest()

def yolo_labels(annotations, width, height):
    checked = boxes(annotations, width, height)
    rows=[]
    for b in checked:
        points=b.get('points') or [
            {'x':b['x'],'y':b['y']},{'x':b['x']+b['width'],'y':b['y']},
            {'x':b['x']+b['width'],'y':b['y']+b['height']},{'x':b['x'],'y':b['y']+b['height']}]
        rows.append(str(b['class_id'])+' '+' '.join(f'{p[axis]/(width if axis=="x" else height):.9f}' for p in points for axis in ('x','y'))+'\n')
    return ''.join(rows)
