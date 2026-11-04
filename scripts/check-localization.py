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

mac = app.parent / 'SuniCapture.macOS'
mac_overrides = json.loads((mac / 'Resources/strings.macos.json').read_text(encoding='utf8'))
mac_merged = {**catalog, **mac_overrides}
namespaces = {key.split('.')[0] for key in mac_merged}
symbols = {'record.circle'}  # SF Symbols whose names share a resource namespace
mac_references = set()
for file in (mac / 'Sources').rglob('*.swift'):
    for literal in re.findall(r'"([a-z]+(?:\.[A-Za-z0-9]+)+)"', file.read_text(encoding='utf8')):
        # Resource keys share the catalog namespaces; file names and identifiers do not.
        if literal.split('.')[0] in namespaces and literal not in symbols and not re.search(r'\.(json|png|md|csproj|mp4)$', literal):
            mac_references.add(literal)
assert not mac_references - mac_merged.keys(), f'Missing macOS resources: {sorted(mac_references - mac_merged.keys())}'
for key, pair in mac_overrides.items():
    assert set(pair) == {'fr', 'en'} and all(isinstance(value, str) and value.strip() for value in pair.values()), f'Incomplete macOS resource: {key}'
    assert arguments(pair['fr']) == arguments(pair['en']), f'Unequal macOS format arguments: {key}'
print(f'PASS: {len(mac_merged)} merged macOS FR/EN resources, {len(mac_references)} literal references, matching format arguments.')
