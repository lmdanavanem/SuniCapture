"""Check FR/EN resource coverage and format arguments without changing app data."""
from pathlib import Path
import ast
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

linux = app.parent / 'SuniCapture.Linux/sunicapture'
overrides = json.loads((linux / 'strings.json').read_text(encoding='utf8'))
merged = {**catalog, **overrides}
linux_references = set()
for file in linux.glob('*.py'):
    for node in ast.walk(ast.parse(file.read_text(encoding='utf8'))):
        if not isinstance(node, ast.Call) or not isinstance(node.func, ast.Attribute):
            continue
        index = 1 if node.func.attr == 'bind' else 0
        if node.func.attr not in ('t', 'label', 'dialog_label', 'button', 'bind') or len(node.args) <= index:
            continue
        value = node.args[index]
        if isinstance(value, ast.Constant) and isinstance(value.value, str):
            linux_references.add(value.value)
assert not linux_references - merged.keys(), f'Missing Linux resources: {sorted(linux_references - merged.keys())}'
for key, pair in overrides.items():
    assert set(pair) == {'fr', 'en'} and all(isinstance(value, str) and value.strip() for value in pair.values()), f'Incomplete Linux resource: {key}'
    assert arguments(pair['fr']) == arguments(pair['en']), f'Unequal Linux format arguments: {key}'
print(f'PASS: {len(merged)} merged Linux FR/EN resources, {len(linux_references)} literal references, matching format arguments.')
