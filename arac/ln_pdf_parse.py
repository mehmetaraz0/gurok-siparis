import pdfplumber, re, json, pickle

line_re = re.compile(
    r'^((?:YIY|GNL|ICA|ICB)\d{7,9})\s+(.+?)\s+([a-zA-ZğüşıöçĞÜŞİÖÇ]{1,5})\s+'
    r'(-?[\d.,]+)\s+(-?[\d.,]+)\s+(-?[\d.,]+)\s+(-?[\d.,]+)\s+'
    r'(-?[\d.,]+)\s+(-?[\d.,]+)\s+(-?[\d.,]+)\s+(-?[\d.,]+)\s+(-?[\d.,]+)\s+(-?[\d.,]+)$')
depo_re = re.compile(r'Depo\s*:\s*(CSM\d{3}|CMM\d{3}|\S+)\s+(.*?)\s*$')
grp_re  = re.compile(r'Kalem Grubu\s*:\s*(\S+)\s+(.*?)\s*$')

def num(s):
    s = s.strip()
    if re.match(r'^-?[\d.]+,\d+$', s):
        return float(s.replace('.', '').replace(',', '.'))
    return float(s.replace(',', '.'))

depolar = {}   # kod -> {"ad":..., "items": {kod: {...}}}
for f in ['3fcb11d8-FRWQ', '785bcbb4-SSE']:
    path = '/root/.claude/uploads/86aebd71-8b4b-5444-8814-d27ada59b6ab/%s.pdf' % f
    depo = grup = None
    with pdfplumber.open(path) as pdf:
        for page in pdf.pages:
            for ln in (page.extract_text() or '').split('\n'):
                ln = ln.strip()
                if ln.startswith('Depo'):
                    m = depo_re.match(ln)
                    if m:
                        depo = m.group(1)
                        depolar.setdefault(depo, {"ad": m.group(2), "items": {}})
                    continue
                if ln.startswith('Kalem Grubu'):
                    m = grp_re.match(ln)
                    if m: grup = m.group(1) + " " + m.group(2)
                    continue
                m = line_re.match(ln)
                if m and depo:
                    v = [num(m.group(i)) for i in range(4, 14)]
                    depolar[depo]["items"][m.group(1)] = {
                        "k": m.group(1), "a": m.group(2).strip(), "b": m.group(3),
                        "grup": grup, "cikis": abs(v[6]), "kalan": v[9]}

pickle.dump(depolar, open('/tmp/claude-0/-home-user-gurok-siparis/86aebd71-8b4b-5444-8814-d27ada59b6ab/scratchpad/depolar.pkl','wb'))
print("Depo sayisi:", len(depolar))
for k, v in sorted(depolar.items()):
    print(f"  {k:<8} {v['ad'][:32]:<34} kalem: {len(v['items'])}")
