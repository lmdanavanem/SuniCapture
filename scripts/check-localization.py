"""Check FR/EN resource coverage and format arguments without changing app data."""
from pathlib import Path
import json
import re

app = Path(__file__).resolve().parents[1] / 'src/SuniCapture'
catalog = json.loads((app / 'Localization/strings.json').read_text(encoding='utf8'))
references = set()
for file in [*app.rglob('*.cs'), *app.rglob('*.xaml')]:
    if 'obj' in file.parts or 'bin' in file.parts:
        continue
    text = file.read_text(encoding='utf8')
    references.update(re.findall(r'L\.(?:T|F)\("([^"]+)"', text))
    references.update(re.findall(r'\{loc:Tr ([^}]+)\}', text))
missing = references - catalog.keys()
assert not missing, f'Missing resources: {sorted(missing)}'
for key, pair in catalog.items():
    assert set(pair) == {'fr', 'en'}, f'Incomplete languages: {key}'
    assert all(isinstance(value, str) and value.strip() for value in pair.values()), f'Empty value: {key}'
    def arguments(value):
        return sorted(re.findall(r'(?<!\{)\{(\d+)(?:[,:][^}]*)?\}(?!\})', value))
    assert arguments(pair['fr']) == arguments(pair['en']), f'Unequal format arguments: {key}'
print(f'PASS: {len(catalog)} complete FR/EN resources, {len(references)} literal references, matching format arguments.')
