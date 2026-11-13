#!/usr/bin/env python3
"""공공 식품영양성분 파일(CSV/XLSX) -> Supabase foods 테이블용 SQL 변환.

사용:
  python3 import_foods.py 내려받은파일.csv --pick pick.txt --units units.csv -o foods_import.sql
  (만들어진 SQL을 Supabase SQL Editor에 붙여넣어 실행. 같은 음식은 건너뜁니다)

- 모든 영양값은 '100g 기준'으로 정규화합니다.
- 헤더 이름은 별칭 표로 자동 인식합니다. 인식 실패 시 --map 으로 직접 지정:
    --map name=식품명 kcal=에너지(kcal) carb=탄수화물(g) prot=단백질(g) fat=지방(g)
- pick.txt : 앱에 넣을 음식 이름 목록(한 줄에 하나, 부분 일치). 없으면 전체.
- units.csv: 이름,단위명,그램  (예: 쌀밥,공기,210) 여러 줄 가능.
- 출력: foods 테이블 INSERT 문 (source 'P'=공공). 음식 code는 이름으로 만든 고정값이라 다시 실행해도 중복되지 않습니다.
"""
import argparse, csv, hashlib, io, json, re, sys

ALIAS = {
    'name': ['식품명', '식품이름', 'FOOD_NM_KR', 'DESC_KOR', '음식명', '식품명(한글)'],
    'cat':  ['식품대분류명', '식품군', 'FOOD_CAT1_NM', '대분류', '식품상세분류', 'GROUP_NAME'],
    'kcal': ['에너지(kcal)', '에너지', 'AMT_NUM1', 'NUM1', '열량(kcal)', '열량'],
    'prot': ['단백질(g)', '단백질', 'AMT_NUM3', 'NUM3'],
    'fat':  ['지방(g)', '지방', 'AMT_NUM4', 'NUM4'],
    'carb': ['탄수화물(g)', '탄수화물', 'AMT_NUM6', 'NUM6'],
    'base': ['영양성분함량기준량', '기준량', 'NUTRI_AMOUNT_SERVING'],
}


def read_rows(path):
    if path.lower().endswith(('.xlsx', '.xlsm')):
        import openpyxl
        ws = openpyxl.load_workbook(path, read_only=True, data_only=True).worksheets[0]
        it = ws.iter_rows(values_only=True)
        head = [str(h or '').strip() for h in next(it)]
        return head, [dict(zip(head, r)) for r in it]
    raw = open(path, 'rb').read()
    for enc in ('utf-8-sig', 'cp949', 'euc-kr'):
        try:
            txt = raw.decode(enc)
            break
        except UnicodeDecodeError:
            continue
    rd = csv.DictReader(io.StringIO(txt))
    return [h.strip() for h in rd.fieldnames], list(rd)


def num(v):
    if v is None:
        return None
    s = re.sub(r'[^0-9.\-]', '', str(v).replace(',', ''))
    try:
        return float(s)
    except ValueError:
        return None


def base_g(v):
    """'100g', '100 ml', 100 -> 100.0 (없으면 100)."""
    n = num(v)
    return n if n and n > 0 else 100.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('file')
    ap.add_argument('--pick')
    ap.add_argument('--units')
    ap.add_argument('--map', nargs='*', default=[])
    ap.add_argument('-o', '--out', default='foods_import.sql')
    a = ap.parse_args()

    head, rows = read_rows(a.file)
    col = {}
    for k, names in ALIAS.items():
        for n in names:
            if n in head:
                col[k] = n
                break
    for kv in a.map:
        k, v = kv.split('=', 1)
        col[k] = v
    miss = [k for k in ('name', 'kcal', 'carb', 'prot', 'fat') if k not in col or col[k] not in head]
    if miss:
        sys.exit('필수 열을 못 찾음: %s\n파일 헤더: %s\n--map 으로 지정하세요.' % (miss, head))

    picks = []
    if a.pick:
        picks = [l.strip() for l in open(a.pick, encoding='utf-8') if l.strip() and not l.startswith('#')]
    units = {}
    if a.units:
        for r in csv.reader(open(a.units, encoding='utf-8')):
            if len(r) >= 3 and num(r[2]):
                units.setdefault(r[0].strip(), []).append([r[1].strip(), num(r[2])])

    out, seen, skipped = [], set(), 0
    for r in rows:
        name = str(r.get(col['name']) or '').strip()
        if not name or (picks and not any(p in name for p in picks)):
            continue
        k, c, p, f = (num(r.get(col[x])) for x in ('kcal', 'carb', 'prot', 'fat'))
        if None in (k, c, p, f):
            skipped += 1
            continue
        b = base_g(r.get(col['base'])) if 'base' in col else 100.0
        s = 100.0 / b
        key = name
        if key in seen:
            continue
        seen.add(key)
        # 단위: 이름이 units.csv 키를 포함하면 매핑
        u = []
        for un, lst in units.items():
            if un in name:
                u = lst
                break
        cat = str(r.get(col['cat']) or '기타').strip() if 'cat' in col else '기타'
        out.append(['p' + hashlib.md5(name.encode('utf-8')).hexdigest()[:10], name, cat, 'P',
                    round(k * s), round(c * s, 1), round(p * s, 1), round(f * s, 1), u])

    q = lambda v: "'" + str(v).replace("'", "''") + "'"
    with open(a.out, 'w', encoding='utf-8') as fh:
        fh.write('-- 공공 식품영양성분 가져오기 (100g 기준). 수치는 트레이너가 검수한 뒤 사용하세요.\n')
        for i in range(0, len(out), 200):
            fh.write('insert into public.foods (code,name,category,source,kcal,carb,prot,fat,units) values\n')
            fh.write(',\n'.join('  (%s,%s,%s,%s,%s,%s,%s,%s,%s::jsonb)' % (q(r[0]), q(r[1]), q(r[2]), q(r[3]), r[4], r[5], r[6], r[7], q(json.dumps(r[8], ensure_ascii=False))) for r in out[i:i + 200]))
            fh.write('\non conflict (code) do nothing;\n')
    print('변환 %d건, 건너뜀(값 누락) %d건 -> %s' % (len(out), skipped, a.out))


if __name__ == '__main__':
    main()
