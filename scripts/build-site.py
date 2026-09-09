#!/usr/bin/env python3
"""Render the privacy document as a static page without external dependencies."""
import html
from pathlib import Path
import re

root = Path(__file__).resolve().parent.parent
source = (root / 'docs/PRIVACY.md').read_text()
parts = []
for block in source.strip().split('\n\n'):
    text = html.escape(block)
    text = re.sub(r'\[([^]]+)\]\((https://[^)]+|mailto:[^)]+)\)', r'<a href="\2">\1</a>', text)
    if text.startswith('# '):
        parts.append('<h1>' + text[2:] + '</h1>')
    elif text.startswith('## '):
        anchor = 'rights' if '你的权利' in text else 'section-' + text[3]
        parts.append(f'<h2 id="{anchor}">' + text[3:] + '</h2>')
    else:
        parts.append('<p>' + text + '</p>')
style = ('body{margin:0;background:#f4f7f6;color:#243d36;font:16px/1.85 system-ui,-apple-system,"Segoe UI",sans-serif}'
         'main{max-width:800px;margin:0 auto;padding:48px 24px 72px}'
         'h1{font-size:32px;color:#176b5b;line-height:1.4}h2{font-size:22px;margin:36px 0 12px;scroll-margin-top:24px}'
         'p{overflow-wrap:anywhere}a{color:#176b5b;text-underline-offset:3px}nav{margin-bottom:28px}'
         'footer{border-top:1px solid #d5e0db;margin-top:40px;padding-top:20px;font-size:14px}')
document = ('<!doctype html>\n<html lang="zh-CN"><head><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width, initial-scale=1">'
            '<meta name="color-scheme" content="light"><title>USB 网络隐私政策 · linloir</title>'
            '<meta name="description" content="USB 网络的数据处理、隐私权利和联系方式。">'
            '<style>' + style + '</style></head><body><main><nav><a href="../">USB 网络</a></nav>\n'
            + '\n'.join(parts) + '\n<footer>本页面不包含统计脚本、广告或 Cookie。</footer></main></body></html>\n')
target = root / 'site/privacy/index.html'
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text(document)
print(target)
