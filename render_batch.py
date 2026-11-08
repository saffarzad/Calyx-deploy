import json
from pathlib import Path
import subprocess
import sys
from PIL import Image

item, interval = sys.argv[1:]
settings = json.loads(Path('camera.json').read_text())[item]
options = [value for key, setting in settings.items() for value in ('--' + key, str(setting))]
subprocess.run([sys.executable, 'render_cycles.py', f'models/{item}.glb', 'raw', '--frames', '125', '--range', interval, '--size', '720', '--samples', '24', *options], check=True)
start, end = map(int, interval.split('-'))
Path('output').mkdir(exist_ok=True)
for i in range(start, end + 1):
    with Image.open(f'raw/{i:04d}.png') as frame:
        if frame.size != (720, 720):
            raise ValueError(f'Incorrect dimensions for frame {i}')
        frame.save(f'output/{i:03d}.webp', quality=87, method=4)
