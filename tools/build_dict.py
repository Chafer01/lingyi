#!/usr/bin/env python3
"""从 ECDICT 官方 stardict.db 生成灵译使用的精简词库。

用法:
    python build_dict.py <stardict.db> <输出目录>

输出:
    core.db      常用词库（约 6 万词，含英文释义），打包进 App，装好即可离线查词
    standard.db  标准词库（约 135 万单词，不含词组），作为可选下载，覆盖大量专业术语
"""
import os
import sqlite3
import sys

SCHEMA = """
CREATE TABLE dict (
  word TEXT NOT NULL PRIMARY KEY COLLATE NOCASE,
  phonetic TEXT,
  definition TEXT,
  translation TEXT,
  pos TEXT,
  collins INTEGER DEFAULT 0,
  oxford INTEGER DEFAULT 0,
  tag TEXT,
  bnc INTEGER DEFAULT 0,
  frq INTEGER DEFAULT 0,
  exchange TEXT
) WITHOUT ROWID;
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
"""

COMMON = "(frq>0 OR bnc>0 OR collins>0 OR oxford>0 OR (tag IS NOT NULL AND tag!=''))"


def build(src, dst, where, keep_def_where, edition):
    if os.path.exists(dst):
        os.remove(dst)
    out = sqlite3.connect(dst)
    out.executescript(SCHEMA)
    out.execute("ATTACH DATABASE ? AS src", (src,))
    out.execute(f"""
        INSERT OR IGNORE INTO dict
        SELECT word, phonetic,
               CASE WHEN {keep_def_where} THEN definition ELSE '' END,
               translation, pos,
               IFNULL(collins,0), IFNULL(oxford,0), tag,
               IFNULL(bnc,0), IFNULL(frq,0), exchange
        FROM src.stardict
        WHERE translation IS NOT NULL AND translation!='' AND {where}
        ORDER BY word
    """)
    n = out.execute("SELECT count(*) FROM dict").fetchone()[0]
    out.execute("INSERT INTO meta VALUES ('edition', ?), ('count', ?), ('source', 'ECDICT 1.0.28')",
                (edition, str(n)))
    out.commit()
    out.execute("DETACH DATABASE src")
    out.execute("VACUUM")
    out.close()
    print(f"{dst}: {n} 词, {os.path.getsize(dst) / 1e6:.1f} MB")


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, out_dir = sys.argv[1], sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)
    build(src, os.path.join(out_dir, "core.db"), COMMON, "1", "core")
    build(src, os.path.join(out_dir, "standard.db"),
          "word NOT LIKE '% %' AND length(word)<=40", COMMON, "standard")


if __name__ == "__main__":
    main()
